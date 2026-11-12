import { describe, it, expect, vi, afterEach } from 'vitest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createAccountService, ACTIVATION_TTL_HOURS } from '../../src/services/accountService.js';
import { createUserService } from '../../src/services/userService.js';
import { createPasswordService } from '../../src/services/passwordService.js';
import { checkPasswordPolicy } from '../../src/services/passwordPolicy.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createTokenService } from '../../src/services/tokenService.js';
import { normalise, hash as hashCode, matches } from '../../src/services/activationCode.js';

// Officer and administrator accounts created by an administrator (FR-10), before activation
// exists (A4): creation, a new code, and how every existing path treats an invited account.

const t = useTestDb();

const accounts = () => createServices({ db: t.db, config: FAKE_CONFIG }).accounts;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.7';
const DISPLAY = /^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/;

const failingAudit = {
  record: async () => {
    throw new Error('audit unavailable');
  },
};

afterEach(() => {
  vi.restoreAllMocks();
});

const activeAdmin = () => insertUser(t.db, { role: 'admin', status: 'active' });

const create = async (overrides = {}) => {
  const admin = overrides.admin ?? (await activeAdmin());
  return accounts().createAccount({
    username: 'chanda_mwale',
    fullName: 'Chanda Mwale',
    role: 'officer',
    actorId: admin.id,
    ipAddress: IP,
    ...overrides,
  });
};

async function stored(id) {
  const { rows } = await t.db.query(
    `SELECT status, role, password_hash, approved_by, activation_code_hash, activation_failed_attempts,
            activation_expires_at, EXTRACT(EPOCH FROM (activation_expires_at - clock_timestamp())) AS seconds_left
       FROM users WHERE id = $1`,
    [id],
  );
  return rows[0];
}

async function auditFor(id, action) {
  const { rows } = await t.db.query(
    `SELECT actor_id, entity_type, entity_id, details, host(ip_address) AS ip
       FROM audit_logs WHERE entity_id = $1 AND action = $2 ORDER BY id`,
    [id, action],
  );
  return rows;
}

const userCount = async () => (await t.db.query('SELECT count(*)::int AS n FROM users')).rows[0].n;
const auditCount = async () => (await t.db.query('SELECT count(*)::int AS n FROM audit_logs')).rows[0].n;

const TTL_SECONDS = ACTIVATION_TTL_HOURS * 3600;

describe('createAccount', () => {
  it.each(['officer', 'admin'])('creates an invited %s with no password, owned by nobody, and shows the code once', async (role) => {
    const admin = await activeAdmin();

    const { user, activation } = await create({ admin, role });

    expect(user).toMatchObject({ username: 'chanda_mwale', fullName: 'Chanda Mwale', role, status: 'invited', approvedBy: null });
    expect(activation.code).toMatch(DISPLAY);
    expect(activation.expiresAt).toEqual(user.activationExpiresAt);
    expect(await stored(user.id)).toMatchObject({ status: 'invited', role, password_hash: null, approved_by: null, activation_failed_attempts: 0 });
  });

  it('stores only the SHA-256 of the code, the same as hashing what the person will type', async () => {
    const { user, activation } = await create();

    const row = await stored(user.id);
    expect(row.activation_code_hash.equals(hashCode(normalise(activation.code)))).toBe(true);
    // Typed in lower case without hyphens, it still matches.
    expect(matches(hashCode(normalise(activation.code.toLowerCase().replaceAll('-', ''))), row.activation_code_hash)).toBe(true);
  });

  it('never stores the plain code, in the row or in the audit entry', async () => {
    const { user, activation } = await create();
    const canonical = normalise(activation.code);

    const { rows: rowText } = await t.db.query('SELECT to_jsonb(u)::text AS text FROM users u WHERE id = $1', [user.id]);
    const { rows: auditText } = await t.db.query('SELECT details::text AS text FROM audit_logs WHERE entity_id = $1', [user.id]);

    for (const text of [rowText[0].text, ...auditText.map((r) => r.text)]) {
      expect(text).not.toContain(canonical);
      expect(text).not.toContain(activation.code);
    }
  });

  it(`sets the expiry ${ACTIVATION_TTL_HOURS} hours after the database clock`, async () => {
    const { user } = await create();

    const { seconds_left: secondsLeft } = await stored(user.id);
    // A little under 72 hours: the INSERT ran a moment ago.
    expect(Number(secondsLeft)).toBeLessThanOrEqual(TTL_SECONDS);
    expect(Number(secondsLeft)).toBeGreaterThan(TTL_SECONDS - 60);
  });

  it('records user.create with the admin, the role and the expiry, never the code', async () => {
    const admin = await activeAdmin();

    const { user, activation } = await create({ admin });

    expect(await auditFor(user.id, 'user.create')).toEqual([
      {
        actor_id: admin.id,
        entity_type: 'user',
        entity_id: user.id,
        details: { source: 'admin', role: 'officer', activationExpiresAt: activation.expiresAt.toISOString() },
        ip: IP,
      },
    ]);
  });

  it('shows no hash of any kind in the admin view', async () => {
    const { user } = await create();
    const row = await stored(user.id);

    const text = JSON.stringify(user);
    expect(text).not.toContain(row.activation_code_hash.toString('hex'));
    expect(text).not.toContain(row.activation_code_hash.toString('base64'));
    expect(text).not.toMatch(/hash|actor_?ref|argon2/i);
  });

  it.each(['miner', 'transporter', 'buyer', 'superuser'])('refuses to create a %s, writing nothing', async (role) => {
    const admin = await activeAdmin();
    const usersBefore = await userCount();

    await expect(create({ admin, role })).rejects.toMatchObject({ status: 400, code: 'ROLE_NOT_CREATABLE' });
    expect(await userCount()).toBe(usersBefore);
  });

  it.each([
    ['an active account', { status: 'active' }],
    ['an invited account', null],
    ['a rejected account', { status: 'rejected', status_reason: 'Licence not found' }],
  ])('refuses a username already used by %s, in any letter case, writing nothing', async (_label, existing) => {
    const admin = await activeAdmin();
    if (existing) {
      await insertUser(t.db, { username: 'Chanda_Mwale', ...existing });
    } else {
      await create({ admin, username: 'Chanda_Mwale' });
    }
    const usersBefore = await userCount();
    const auditsBefore = await auditCount();

    await expect(create({ admin, username: 'CHANDA_MWALE' })).rejects.toMatchObject({ status: 409, code: 'USERNAME_TAKEN' });

    expect(await userCount()).toBe(usersBefore);
    expect(await auditCount()).toBe(auditsBefore);
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const usersBefore = await userCount();
    const service = createAccountService({ db: t.db, audit: failingAudit });

    await expect(
      service.createAccount({ username: 'chanda_mwale', fullName: 'Chanda Mwale', role: 'officer', actorId: admin.id }),
    ).rejects.toThrow('audit unavailable');

    expect(await userCount()).toBe(usersBefore);
  });

  it('lists invited accounts with their expiry', async () => {
    const { user } = await create();

    const { users } = await accounts().list({ status: 'invited', limit: 20, offset: 0 });

    expect(users).toEqual([expect.objectContaining({ id: user.id, status: 'invited', activationExpiresAt: user.activationExpiresAt })]);
  });
});

describe('reissueActivation', () => {
  it('replaces the code: the old one no longer matches, the new one does, and the attempts start again', async () => {
    const admin = await activeAdmin();
    const { user, activation: first } = await create({ admin });
    await t.db.query('UPDATE users SET activation_failed_attempts = 3 WHERE id = $1', [user.id]);

    const { user: after, activation: second } = await accounts().reissueActivation({ userId: user.id, actorId: admin.id, ipAddress: IP });

    const row = await stored(user.id);
    expect(second.code).toMatch(DISPLAY);
    expect(second.code).not.toBe(first.code);
    expect(matches(hashCode(normalise(first.code)), row.activation_code_hash)).toBe(false);
    expect(matches(hashCode(normalise(second.code)), row.activation_code_hash)).toBe(true);
    expect(row.activation_failed_attempts).toBe(0);
    expect(Number(row.seconds_left)).toBeGreaterThan(TTL_SECONDS - 60);
    expect(after).toMatchObject({ id: user.id, status: 'invited', activationExpiresAt: second.expiresAt });
  });

  it('records user.activation_reissue with the new expiry, never the code', async () => {
    const admin = await activeAdmin();
    const { user } = await create({ admin });

    const { activation } = await accounts().reissueActivation({ userId: user.id, actorId: admin.id, ipAddress: IP });

    expect(await auditFor(user.id, 'user.activation_reissue')).toEqual([
      { actor_id: admin.id, entity_type: 'user', entity_id: user.id, details: { activationExpiresAt: activation.expiresAt.toISOString() }, ip: IP },
    ]);
    const { rows } = await t.db.query('SELECT details::text AS text FROM audit_logs WHERE entity_id = $1', [user.id]);
    for (const { text } of rows) expect(text).not.toContain(normalise(activation.code));
  });

  it('gives a new code to an invited account whose code was erased', async () => {
    const admin = await activeAdmin();
    const { user } = await create({ admin });
    await t.db.query(
      'UPDATE users SET activation_code_hash = NULL, activation_expires_at = NULL, activation_failed_attempts = 5 WHERE id = $1',
      [user.id],
    );

    const { activation } = await accounts().reissueActivation({ userId: user.id, actorId: admin.id });

    expect(matches(hashCode(normalise(activation.code)), (await stored(user.id)).activation_code_hash)).toBe(true);
  });

  it('accepts the id in capitals', async () => {
    const admin = await activeAdmin();
    const { user } = await create({ admin });

    const { user: after } = await accounts().reissueActivation({ userId: user.id.toUpperCase(), actorId: admin.id });

    expect(after.id).toBe(user.id);
  });

  it('refuses an account that is not invited with 409, changing nothing', async () => {
    const admin = await activeAdmin();
    const active = await insertUser(t.db, { role: 'officer', status: 'active' });
    const auditsBefore = await auditCount();

    const err = await accounts()
      .reissueActivation({ userId: active.id, actorId: admin.id })
      .catch((e) => e);

    expect(err).toMatchObject({
      status: 409,
      code: 'INVALID_STATUS_TRANSITION',
      message: 'Only an invited account can get a new activation code. This account is active.',
    });
    expect((await stored(active.id)).activation_code_hash).toBeNull();
    expect(await auditCount()).toBe(auditsBefore);
  });

  it('refuses an unknown id with 404 USER_NOT_FOUND', async () => {
    const admin = await activeAdmin();

    await expect(accounts().reissueActivation({ userId: MISSING_ID, actorId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'USER_NOT_FOUND',
    });
  });

  it('keeps the old code when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const { user, activation } = await create({ admin });
    const service = createAccountService({ db: t.db, audit: failingAudit });

    await expect(service.reissueActivation({ userId: user.id, actorId: admin.id })).rejects.toThrow('audit unavailable');

    expect(matches(hashCode(normalise(activation.code)), (await stored(user.id)).activation_code_hash)).toBe(true);
  });
});

describe('an invited account on the existing paths', () => {
  const passwords = createPasswordService();
  const users = () =>
    createUserService({
      db: t.db,
      passwords,
      passwordPolicy: checkPasswordPolicy,
      audit: createAuditService(),
      tokens: createTokenService({ secret: FAKE_CONFIG.jwtSecret, expiresInSeconds: FAKE_CONFIG.jwtExpiresInSeconds }),
    });
  const shape = (err) => ({ status: err.status, code: err.code, message: err.message });

  it('cannot log in: the same 401 as an unknown username, after the same Argon2 work, never a 500', async () => {
    const { user, activation } = await create();
    const dummy = vi.spyOn(passwords, 'verifyDummy');

    // Even the activation code itself is not a password.
    const invited = await users().authenticate('chanda_mwale', activation.code).catch((e) => e);
    const unknown = await users().authenticate('nobody_here', activation.code).catch((e) => e);

    expect(shape(invited)).toEqual({ status: 401, code: 'INVALID_CREDENTIALS', message: 'Username or password is incorrect.' });
    expect(shape(invited)).toEqual(shape(unknown));
    expect(dummy).toHaveBeenCalledTimes(2);
    const { rows } = await t.db.query(
      "SELECT actor_id, details FROM audit_logs WHERE action = 'user.login_failed' AND entity_id = $1",
      [user.id],
    );
    expect(rows).toEqual([{ actor_id: user.id, details: { reason: 'account_invited' } }]);
  });

  it('is not counted as the administrator who remains, so the last active admin cannot be suspended by one', async () => {
    const onlyActive = await activeAdmin();
    const { user: invitedAdmin } = await create({ admin: onlyActive, role: 'admin', username: 'invited_admin' });

    // Called on the service directly: an invited admin cannot log in, so no route could do this.
    await expect(
      accounts().suspend({ targetId: onlyActive.id, actorId: invitedAdmin.id, reason: 'Testing the rule' }),
    ).rejects.toMatchObject({ status: 409, code: 'LAST_ACTIVE_ADMIN' });
  });

  it('cannot be approved', async () => {
    const admin = await activeAdmin();
    const { user } = await create({ admin });

    // An officer account is never approvable, whatever its status.
    await expect(accounts().approve({ targetId: user.id, actorId: admin.id })).rejects.toMatchObject({ status: 409 });
    expect((await stored(user.id)).status).toBe('invited');
  });

  it('cannot be suspended: only an active account can', async () => {
    const admin = await activeAdmin();
    const { user } = await create({ admin });

    const err = await accounts()
      .suspend({ targetId: user.id, actorId: admin.id, reason: 'Testing the rule' })
      .catch((e) => e);

    expect(err).toMatchObject({ status: 409, code: 'INVALID_STATUS_TRANSITION' });
    expect(err.message).toContain('This account is invited.');
    expect((await stored(user.id)).status).toBe('invited');
  });
});
