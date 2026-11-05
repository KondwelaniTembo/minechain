import { describe, it, expect, vi } from 'vitest';
import { createUserService } from '../src/services/userService.js';
import { AppError } from '../src/errors.js';

const INPUT = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
  licenceNumber: 'ZM-ASM-0042',
};

const FAKE_HASH = '$argon2id$v=19$m=19456,t=2,p=1$fake$fake';

const insertedRow = {
  id: 'user-1',
  username: 'mutale_banda',
  full_name: 'Mutale Banda',
  licence_number: 'ZM-ASM-0042',
  role: 'miner',
  status: 'pending',
  created_at: new Date('2026-11-05T09:00:00Z'),
};

// Fakes for every dependency. The fake db runs fn with a fake tx and records its queries,
// so the tests can see exactly what would be sent to PostgreSQL.
function setup({ policyProblems = [], insertError, auditError } = {}) {
  const tx = {
    query: vi.fn(async () => {
      if (insertError) throw insertError;
      return { rows: [insertedRow], rowCount: 1 };
    }),
  };
  const db = { transaction: vi.fn(async (fn) => fn(tx)) };
  const passwords = { hash: vi.fn().mockResolvedValue(FAKE_HASH) };
  const passwordPolicy = vi.fn().mockReturnValue(policyProblems);
  const audit = {
    record: vi.fn(async () => {
      if (auditError) throw auditError;
      return { id: '1', occurredAt: new Date() };
    }),
  };
  const service = createUserService({ db, passwords, passwordPolicy, audit });
  return { service, db, tx, passwords, passwordPolicy, audit };
}

const pgError = (code, constraint) => Object.assign(new Error('duplicate key value'), { code, constraint });

describe('userService.register', () => {
  describe('password policy', () => {
    it('checks the policy with the username', async () => {
      const { service, passwordPolicy } = setup();

      await service.register(INPUT);

      expect(passwordPolicy).toHaveBeenCalledWith(INPUT.password, { username: INPUT.username });
    });

    it('refuses a weak password with 400 WEAK_PASSWORD and the policy codes', async () => {
      const { service } = setup({
        policyProblems: [{ code: 'PASSWORD_TOO_SHORT', message: 'Use at least 12 characters. A few words with spaces works well.' }],
      });

      const err = await service.register({ ...INPUT, password: 'short' }).catch((e) => e);

      expect(err).toBeInstanceOf(AppError);
      expect(err).toMatchObject({ status: 400, code: 'WEAK_PASSWORD' });
      expect(err.details).toEqual([
        { field: 'password', code: 'PASSWORD_TOO_SHORT', message: 'Use at least 12 characters. A few words with spaces works well.' },
      ]);
    });

    it('never puts the password in the error', async () => {
      const { service } = setup({ policyProblems: [{ code: 'PASSWORD_TOO_COMMON', message: 'This password is too common.' }] });

      const err = await service.register({ ...INPUT, password: 'kindergarten' }).catch((e) => e);

      expect(JSON.stringify({ message: err.message, details: err.details })).not.toContain('kindergarten');
    });

    it('does not hash or touch the database when the policy fails', async () => {
      const { service, passwords, db } = setup({ policyProblems: [{ code: 'PASSWORD_TOO_SHORT', message: 'x' }] });

      await service.register(INPUT).catch(() => {});

      expect(passwords.hash).not.toHaveBeenCalled();
      expect(db.transaction).not.toHaveBeenCalled();
    });
  });

  describe('saving the user', () => {
    it('hashes the password before the transaction starts', async () => {
      const { service, passwords, db } = setup();

      await service.register(INPUT);

      expect(passwords.hash).toHaveBeenCalledWith(INPUT.password);
      expect(passwords.hash.mock.invocationCallOrder[0]).toBeLessThan(db.transaction.mock.invocationCallOrder[0]);
    });

    it('stores the hash, never the password, with parameters', async () => {
      const { service, tx } = setup();

      await service.register(INPUT);

      const [text, params] = tx.query.mock.calls[0];
      expect(text).toMatch(/INSERT INTO users/);
      expect(params.slice(0, 5)).toEqual(['mutale_banda', 'Mutale Banda', 'ZM-ASM-0042', FAKE_HASH, 'miner']);
      expect(params).not.toContain(INPUT.password);
    });

    it("writes status as 'pending' in the SQL, so input can never set it", async () => {
      const { service, tx } = setup();

      // Even if something got past the schema, the service never reads a status field.
      await service.register({ ...INPUT, status: 'active' });

      const [text, params] = tx.query.mock.calls[0];
      expect(text).toContain("'pending'");
      expect(params).not.toContain('active');
    });

    it('gives each user a fresh random 32-byte actor_ref', async () => {
      const first = setup();
      const second = setup();

      await first.service.register(INPUT);
      await second.service.register(INPUT);

      const refA = first.tx.query.mock.calls[0][1][5];
      const refB = second.tx.query.mock.calls[0][1][5];
      expect(Buffer.isBuffer(refA)).toBe(true);
      expect(refA).toHaveLength(32);
      expect(refA.equals(refB)).toBe(false);
    });

    it('sends NULL when there is no licence number', async () => {
      const { service, tx } = setup();
      const { licenceNumber: _none, ...withoutLicence } = INPUT;

      await service.register(withoutLicence);

      expect(tx.query.mock.calls[0][1][2]).toBeNull();
    });
  });

  describe('audit entry', () => {
    it('records user.register in the same transaction, with only the role in details', async () => {
      const { service, tx, audit } = setup();

      await service.register(INPUT, { ipAddress: '196.46.10.7' });

      // The first argument is the transaction's tx, not the top-level db.
      expect(audit.record).toHaveBeenCalledWith(tx, {
        action: 'user.register',
        actorId: 'user-1',
        entityType: 'user',
        entityId: 'user-1',
        details: { role: 'miner' },
        ipAddress: '196.46.10.7',
      });
    });

    it('never puts the password or its hash in the entry', async () => {
      const { service, audit } = setup();

      await service.register(INPUT);

      const entry = JSON.stringify(audit.record.mock.calls[0][1]);
      expect(entry).not.toContain(INPUT.password);
      expect(entry).not.toContain('$argon2id$');
    });

    it('passes on an audit failure, so the transaction rolls back', async () => {
      const { service } = setup({ auditError: new Error('audit insert failed') });

      await expect(service.register(INPUT)).rejects.toThrow('audit insert failed');
    });
  });

  it('returns a safe user with no password hash or actor_ref', async () => {
    const { service } = setup();

    const user = await service.register(INPUT);

    expect(user).toEqual({
      id: 'user-1',
      username: 'mutale_banda',
      fullName: 'Mutale Banda',
      licenceNumber: 'ZM-ASM-0042',
      role: 'miner',
      status: 'pending',
      createdAt: new Date('2026-11-05T09:00:00Z'),
    });
  });

  describe('taken usernames', () => {
    it('turns a unique violation on the username index into 409 USERNAME_TAKEN', async () => {
      const { service } = setup({ insertError: pgError('23505', 'users_username_lower_key') });

      const err = await service.register(INPUT).catch((e) => e);

      expect(err).toBeInstanceOf(AppError);
      expect(err).toMatchObject({ status: 409, code: 'USERNAME_TAKEN' });
    });

    it('passes on a unique violation on any other constraint unchanged', async () => {
      const original = pgError('23505', 'users_actor_ref_unique');
      const { service } = setup({ insertError: original });

      await expect(service.register(INPUT)).rejects.toBe(original);
    });

    it('passes on other database errors unchanged', async () => {
      const original = pgError('23514', 'users_role_valid');
      const { service } = setup({ insertError: original });

      await expect(service.register(INPUT)).rejects.toBe(original);
    });
  });
});

// ---------- authenticate ----------

const STORED_HASH = '$argon2id$v=19$m=19456,t=2,p=1$stored$stored';
const NEW_HASH = '$argon2id$v=19$m=19456,t=2,p=1$new$new';
const PASSWORD = 'gold river kasempa';

const userRow = (overrides = {}) => ({
  id: 'user-1',
  username: 'mutale_banda',
  full_name: 'Mutale Banda',
  licence_number: null,
  role: 'miner',
  status: 'active',
  created_at: new Date('2026-11-05T09:00:00Z'),
  password_hash: STORED_HASH,
  ...overrides,
});

// user: the row the lookup finds, or null for an unknown username.
function setupAuth({ user = userRow(), passwordCorrect = true, needsRehash = false } = {}) {
  const tx = { query: vi.fn().mockResolvedValue({ rows: [], rowCount: 1 }) };
  const db = {
    query: vi.fn().mockResolvedValue({ rows: user ? [user] : [], rowCount: user ? 1 : 0 }),
    transaction: vi.fn(async (fn) => fn(tx)),
  };
  const passwords = {
    verify: vi.fn().mockResolvedValue(passwordCorrect),
    verifyDummy: vi.fn().mockResolvedValue(false),
    needsRehash: vi.fn().mockReturnValue(needsRehash),
    hash: vi.fn().mockResolvedValue(NEW_HASH),
  };
  const audit = { record: vi.fn().mockResolvedValue({ id: '1', occurredAt: new Date() }) };
  const tokens = { sign: vi.fn().mockResolvedValue({ token: 'header.payload.signature', expiresIn: 3600 }) };
  const service = createUserService({ db, passwords, passwordPolicy: vi.fn(), audit, tokens });
  return { service, db, tx, passwords, audit, tokens };
}

const errorShape = (err) => ({ status: err.status, code: err.code, message: err.message, details: err.details });

describe('userService.authenticate', () => {
  it('looks the user up ignoring case, with the username as a parameter', async () => {
    const { service, db } = setupAuth();

    await service.authenticate('Mutale_Banda', PASSWORD);

    const [text, params] = db.query.mock.calls[0];
    expect(text).toMatch(/WHERE lower\(username\) = lower\(\$1\)/);
    expect(params).toEqual(['Mutale_Banda']);
  });

  describe('unknown username', () => {
    it('runs the dummy Argon2 check, then answers 401 INVALID_CREDENTIALS', async () => {
      const { service, passwords } = setupAuth({ user: null });

      const err = await service.authenticate('nobody_here', PASSWORD).catch((e) => e);

      expect(passwords.verifyDummy).toHaveBeenCalledWith(PASSWORD);
      expect(passwords.verify).not.toHaveBeenCalled();
      expect(errorShape(err)).toEqual({ status: 401, code: 'INVALID_CREDENTIALS', message: 'Username or password is incorrect.', details: undefined });
    });

    it('records user.login_failed with no actor, no entity and only the reason', async () => {
      const { service, db, audit } = setupAuth({ user: null });

      await service.authenticate('nobody_here', PASSWORD, { ipAddress: '196.46.10.7' }).catch(() => {});

      expect(audit.record).toHaveBeenCalledWith(db, {
        action: 'user.login_failed',
        actorId: null,
        entityType: null,
        entityId: null,
        details: { reason: 'unknown_username' },
        ipAddress: '196.46.10.7',
      });
    });

    it('never stores what was typed, even a password typed into the username field', async () => {
      const { service, audit } = setupAuth({ user: null });

      await service.authenticate(PASSWORD, 'whatever was typed second').catch(() => {});

      const logged = JSON.stringify(audit.record.mock.calls);
      expect(logged).not.toContain(PASSWORD);
      expect(logged).not.toContain('whatever was typed second');
    });
  });

  describe('wrong password', () => {
    it('checks the real hash, then answers exactly like an unknown username', async () => {
      const wrong = setupAuth({ passwordCorrect: false });
      const unknown = setupAuth({ user: null });

      const wrongErr = await wrong.service.authenticate('mutale_banda', 'not the password').catch((e) => e);
      const unknownErr = await unknown.service.authenticate('nobody_here', 'not the password').catch((e) => e);

      expect(wrong.passwords.verify).toHaveBeenCalledWith(STORED_HASH, 'not the password');
      expect(wrong.passwords.verifyDummy).not.toHaveBeenCalled();
      expect(errorShape(wrongErr)).toEqual(errorShape(unknownErr));
    });

    it('records user.login_failed with the user and the reason only', async () => {
      const { service, db, audit } = setupAuth({ passwordCorrect: false });

      await service.authenticate('mutale_banda', 'not the password').catch(() => {});

      expect(audit.record).toHaveBeenCalledWith(db, {
        action: 'user.login_failed',
        actorId: 'user-1',
        entityType: 'user',
        entityId: 'user-1',
        details: { reason: 'wrong_password' },
        ipAddress: null,
      });
      expect(JSON.stringify(audit.record.mock.calls)).not.toContain('not the password');
    });
  });

  describe('accounts that are not active', () => {
    it.each([
      ['pending', 'ACCOUNT_PENDING', 'Your account is waiting for approval by an administrator.'],
      ['suspended', 'ACCOUNT_SUSPENDED', 'Your account has been suspended. Please contact an administrator.'],
      ['rejected', 'ACCOUNT_REJECTED', 'Your account request was not approved. Please contact an administrator.'],
    ])('a %s account with the right password gets 403 %s and no token', async (status, code, message) => {
      const { service, audit, tokens } = setupAuth({ user: userRow({ status }) });

      const err = await service.authenticate('mutale_banda', PASSWORD).catch((e) => e);

      expect(errorShape(err)).toEqual({ status: 403, code, message, details: undefined });
      expect(audit.record.mock.calls[0][1]).toMatchObject({ action: 'user.login_failed', details: { reason: `account_${status}` } });
      expect(tokens.sign).not.toHaveBeenCalled();
    });

    it('treats a status it does not know as not active', async () => {
      const { service, tokens } = setupAuth({ user: userRow({ status: 'archived' }) });

      const err = await service.authenticate('mutale_banda', PASSWORD).catch((e) => e);

      expect(err).toMatchObject({ status: 403, code: 'ACCOUNT_NOT_ACTIVE' });
      expect(tokens.sign).not.toHaveBeenCalled();
    });

    it('gives a pending account with the wrong password the generic 401, so its status stays hidden', async () => {
      const { service, audit } = setupAuth({ user: userRow({ status: 'pending' }), passwordCorrect: false });

      const err = await service.authenticate('mutale_banda', 'not the password').catch((e) => e);

      expect(err).toMatchObject({ status: 401, code: 'INVALID_CREDENTIALS' });
      expect(audit.record.mock.calls[0][1].details).toEqual({ reason: 'wrong_password' });
    });
  });

  // Failed attempts must survive the throw that follows them, so they are never written
  // inside a db.transaction callback, where the throw would roll them back.
  describe('failed-login entries are written outside any transaction', () => {
    it.each([
      ['an unknown username', { user: null }],
      ['a wrong password', { passwordCorrect: false }],
      ['a pending account', { user: userRow({ status: 'pending' }) }],
    ])('for %s', async (_label, options) => {
      const { service, db, audit } = setupAuth(options);

      await service.authenticate('mutale_banda', PASSWORD).catch(() => {});

      expect(db.transaction).not.toHaveBeenCalled();
      expect(audit.record).toHaveBeenCalledOnce();
      // The first argument is the top-level db, not a transaction's tx.
      expect(audit.record.mock.calls[0][0]).toBe(db);
    });
  });

  describe('active account with the right password', () => {
    it('returns the safe user, a token and its lifetime', async () => {
      const { service, tokens } = setupAuth();

      const result = await service.authenticate('mutale_banda', PASSWORD);

      expect(result).toEqual({
        user: {
          id: 'user-1',
          username: 'mutale_banda',
          fullName: 'Mutale Banda',
          licenceNumber: null,
          role: 'miner',
          status: 'active',
          createdAt: new Date('2026-11-05T09:00:00Z'),
        },
        token: 'header.payload.signature',
        expiresIn: 3600,
      });
      expect(tokens.sign).toHaveBeenCalledWith({ userId: 'user-1', role: 'miner' });
    });

    it('records user.login inside the transaction', async () => {
      const { service, tx, audit } = setupAuth();

      await service.authenticate('mutale_banda', PASSWORD, { ipAddress: '196.46.10.7' });

      expect(audit.record).toHaveBeenCalledWith(tx, {
        action: 'user.login',
        actorId: 'user-1',
        entityType: 'user',
        entityId: 'user-1',
        details: { rehashed: false },
        ipAddress: '196.46.10.7',
      });
    });

    it('leaves the hash alone when it already uses the current settings', async () => {
      const { service, tx, passwords } = setupAuth({ needsRehash: false });

      await service.authenticate('mutale_banda', PASSWORD);

      expect(passwords.hash).not.toHaveBeenCalled();
      expect(tx.query).not.toHaveBeenCalled();
    });

    it('re-hashes an older hash and saves it, without overwriting a newer change', async () => {
      const { service, tx, passwords, audit } = setupAuth({ needsRehash: true });

      await service.authenticate('mutale_banda', PASSWORD);

      expect(passwords.needsRehash).toHaveBeenCalledWith(STORED_HASH);
      expect(passwords.hash).toHaveBeenCalledWith(PASSWORD);
      const [text, params] = tx.query.mock.calls[0];
      expect(text).toMatch(/UPDATE users SET password_hash = \$1 WHERE id = \$2 AND password_hash = \$3/);
      expect(params).toEqual([NEW_HASH, 'user-1', STORED_HASH]);
      expect(audit.record.mock.calls[0][1].details).toEqual({ rehashed: true });
    });

    it('never logs the password or a hash', async () => {
      const { service, audit } = setupAuth({ needsRehash: true });

      await service.authenticate('mutale_banda', PASSWORD);

      const logged = JSON.stringify(audit.record.mock.calls);
      expect(logged).not.toContain(PASSWORD);
      expect(logged).not.toContain('$argon2id$');
    });
  });
});

// ---------- getAuthenticatedUser ----------

describe('userService.getAuthenticatedUser', () => {
  // The lookup selects no password_hash, so the fake row has none either.
  const { password_hash: _hash, ...dbRow } = userRow();

  function setupLookup(rows) {
    const db = { query: vi.fn().mockResolvedValue({ rows, rowCount: rows.length }) };
    const service = createUserService({ db, passwords: {}, passwordPolicy: vi.fn(), audit: {}, tokens: {} });
    return { service, db };
  }

  it('looks the user up by id, as a parameter, without selecting the password hash', async () => {
    const { service, db } = setupLookup([dbRow]);

    await service.getAuthenticatedUser('user-1', 'miner');

    const [text, params] = db.query.mock.calls[0];
    expect(text).toMatch(/WHERE id = \$1/);
    expect(text).not.toMatch(/password_hash/);
    expect(params).toEqual(['user-1']);
  });

  it('returns the safe user for an active account whose role matches', async () => {
    const { service } = setupLookup([dbRow]);

    expect(await service.getAuthenticatedUser('user-1', 'miner')).toEqual({
      id: 'user-1',
      username: 'mutale_banda',
      fullName: 'Mutale Banda',
      licenceNumber: null,
      role: 'miner',
      status: 'active',
      createdAt: new Date('2026-11-05T09:00:00Z'),
    });
  });

  it.each([
    ['pending', 'ACCOUNT_PENDING'],
    ['suspended', 'ACCOUNT_SUSPENDED'],
    ['rejected', 'ACCOUNT_REJECTED'],
    ['archived', 'ACCOUNT_NOT_ACTIVE'],
  ])('refuses a %s account with 403 %s, the same answer as at login', async (status, code) => {
    const { service } = setupLookup([{ ...dbRow, status }]);

    await expect(service.getAuthenticatedUser('user-1', 'miner')).rejects.toMatchObject({ status: 403, code });
  });

  it('refuses a token whose role no longer matches with 401 TOKEN_INVALID', async () => {
    const { service } = setupLookup([{ ...dbRow, role: 'buyer' }]);

    await expect(service.getAuthenticatedUser('user-1', 'miner')).rejects.toMatchObject({ status: 401, code: 'TOKEN_INVALID' });
  });

  it('refuses a token for a user who no longer exists with 401 TOKEN_INVALID', async () => {
    const { service } = setupLookup([]);

    await expect(service.getAuthenticatedUser('user-1', 'miner')).rejects.toMatchObject({ status: 401, code: 'TOKEN_INVALID' });
  });

  it('reports a status problem before a role mismatch', async () => {
    const { service } = setupLookup([{ ...dbRow, status: 'suspended', role: 'buyer' }]);

    await expect(service.getAuthenticatedUser('user-1', 'miner')).rejects.toMatchObject({ status: 403, code: 'ACCOUNT_SUSPENDED' });
  });
});
