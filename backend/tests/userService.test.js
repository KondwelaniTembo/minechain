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
