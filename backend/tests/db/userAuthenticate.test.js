import { describe, it, expect, vi, afterEach } from 'vitest';
import argon2 from 'argon2';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG } from './fixtures.js';
import { createUserService } from '../../src/services/userService.js';
import { createPasswordService, ARGON2_OPTIONS } from '../../src/services/passwordService.js';
import { checkPasswordPolicy } from '../../src/services/passwordPolicy.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createTokenService } from '../../src/services/tokenService.js';

const t = useTestDb();

// The real services, as createServices wires them, on the test's own connection.
const passwords = createPasswordService();
const tokens = createTokenService({ secret: FAKE_CONFIG.jwtSecret, expiresInSeconds: FAKE_CONFIG.jwtExpiresInSeconds });
const users = () =>
  createUserService({ db: t.db, passwords, passwordPolicy: checkPasswordPolicy, audit: createAuditService(), tokens });

const PASSWORD = 'gold river kasempa';

// Registers through the real service, then sets the status directly: the admin approval
// endpoint (FR-10) comes later.
async function createUser({ username = 'mutale_banda', status = 'active', statusReason = null } = {}) {
  const user = await users().register({ username, fullName: 'Mutale Banda', password: PASSWORD, role: 'miner' });
  await t.db.query('UPDATE users SET status = $1, status_reason = $2 WHERE id = $3', [status, statusReason, user.id]);
  return user;
}

const entries = async (action) =>
  (await t.db.query('SELECT * FROM audit_logs WHERE action = $1 ORDER BY id', [action])).rows;
const errorShape = (err) => ({ status: err.status, code: err.code, message: err.message, details: err.details });

afterEach(() => {
  vi.restoreAllMocks();
});

describe('userService.authenticate against PostgreSQL', () => {
  describe('successful login', () => {
    it('returns a token the real token service accepts, and no password hash', async () => {
      const user = await createUser();

      const result = await users().authenticate('mutale_banda', PASSWORD);

      expect(await tokens.verify(result.token)).toEqual({ userId: user.id, role: 'miner' });
      expect(result.expiresIn).toBe(3600);
      expect(result.user).toMatchObject({ id: user.id, status: 'active' });
      expect(JSON.stringify(result.user)).not.toContain('argon2');
    });

    it('accepts the username in different letter case', async () => {
      const user = await createUser();

      const result = await users().authenticate('MUTALE_Banda', PASSWORD);

      expect(result.user.id).toBe(user.id);
    });

    it('records user.login with the client address', async () => {
      const user = await createUser();

      await users().authenticate('mutale_banda', PASSWORD, { ipAddress: '196.46.10.7' });

      const [entry] = await entries('user.login');
      expect(entry).toMatchObject({ actor_id: user.id, entity_id: user.id, details: { rehashed: false }, ip_address: '196.46.10.7' });
    });
  });

  // After each of these failures, authenticate has thrown. The entry must still be there:
  // had it been written inside a transaction whose callback threw, the rollback would have
  // removed it.
  describe('failed logins keep their user.login_failed entry after the throw', () => {
    it('for a wrong password', async () => {
      const user = await createUser();

      const err = await users().authenticate('mutale_banda', 'not the password').catch((e) => e);

      expect(err).toMatchObject({ status: 401, code: 'INVALID_CREDENTIALS' });
      const [entry] = await entries('user.login_failed');
      expect(entry).toMatchObject({ actor_id: user.id, entity_type: 'user', entity_id: user.id });
      expect(entry.details).toEqual({ reason: 'wrong_password' });
    });

    it('for an unknown username', async () => {
      const err = await users().authenticate('nobody_here', PASSWORD).catch((e) => e);

      expect(err).toMatchObject({ status: 401, code: 'INVALID_CREDENTIALS' });
      const [entry] = await entries('user.login_failed');
      expect(entry).toMatchObject({ actor_id: null, entity_type: null, entity_id: null });
      expect(entry.details).toEqual({ reason: 'unknown_username' });
    });

    it('for a pending account', async () => {
      const user = await createUser({ status: 'pending' });

      const err = await users().authenticate('mutale_banda', PASSWORD).catch((e) => e);

      expect(err).toMatchObject({ status: 403, code: 'ACCOUNT_PENDING' });
      const [entry] = await entries('user.login_failed');
      expect(entry).toMatchObject({ actor_id: user.id });
      expect(entry.details).toEqual({ reason: 'account_pending' });
    });
  });

  describe('no user enumeration', () => {
    it('gives an unknown username exactly the same error as a wrong password', async () => {
      await createUser();

      const wrong = await users().authenticate('mutale_banda', 'not the password').catch((e) => e);
      const unknown = await users().authenticate('nobody_here', 'not the password').catch((e) => e);

      expect(errorShape(unknown)).toEqual(errorShape(wrong));
    });

    it('runs the dummy Argon2 check for an unknown username', async () => {
      const dummy = vi.spyOn(passwords, 'verifyDummy');

      await users().authenticate('nobody_here', PASSWORD).catch(() => {});

      expect(dummy).toHaveBeenCalledOnce();
    });

    it('stores the typed username nowhere in audit_logs, even a password typed by mistake', async () => {
      const typedByMistake = 'my secret passphrase typed as a username';

      await users().authenticate(typedByMistake, PASSWORD).catch(() => {});

      const { rows } = await t.db.query('SELECT * FROM audit_logs');
      expect(rows.length).toBeGreaterThan(0);
      expect(JSON.stringify(rows)).not.toContain(typedByMistake);
      expect(JSON.stringify(rows)).not.toContain(PASSWORD);
    });

    it('keeps a pending status hidden when the password is wrong', async () => {
      await createUser({ status: 'pending' });

      const err = await users().authenticate('mutale_banda', 'not the password').catch((e) => e);

      expect(err).toMatchObject({ status: 401, code: 'INVALID_CREDENTIALS' });
    });
  });

  describe('accounts that are not active', () => {
    it.each([
      ['suspended', 'Lost device reported', 'ACCOUNT_SUSPENDED'],
      ['rejected', 'Licence could not be verified', 'ACCOUNT_REJECTED'],
    ])('a %s account gets 403 %s, and its reason stays internal', async (status, statusReason, code) => {
      await createUser({ status, statusReason });

      const err = await users().authenticate('mutale_banda', PASSWORD).catch((e) => e);

      expect(err).toMatchObject({ status: 403, code });
      expect(err.message).not.toContain(statusReason);
    });
  });

  it('upgrades a hash made with older, weaker settings on the next successful login', async () => {
    const user = await createUser();
    // Simulate an account from before the current settings: one pass instead of two.
    const oldHash = await argon2.hash(PASSWORD, { ...ARGON2_OPTIONS, timeCost: 1 });
    await t.db.query('UPDATE users SET password_hash = $1 WHERE id = $2', [oldHash, user.id]);

    await users().authenticate('mutale_banda', PASSWORD);

    const { rows } = await t.db.query('SELECT password_hash FROM users WHERE id = $1', [user.id]);
    expect(rows[0].password_hash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    expect(rows[0].password_hash).not.toBe(oldHash);
    const [entry] = await entries('user.login');
    expect(entry.details).toEqual({ rehashed: true });
    // The same password still works with the new hash.
    await expect(users().authenticate('mutale_banda', PASSWORD)).resolves.toMatchObject({ user: { id: user.id } });
  });
});
