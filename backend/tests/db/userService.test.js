import { describe, it, expect, vi } from 'vitest';
import { useTestDb } from './helpers.js';
import { createUserService } from '../../src/services/userService.js';
import { createPasswordService } from '../../src/services/passwordService.js';
import { checkPasswordPolicy } from '../../src/services/passwordPolicy.js';
import { createAuditService } from '../../src/services/auditService.js';

const t = useTestDb();

// The real dependencies, as the app will wire them. t.db is the test's connection inside
// an open transaction, so register's db.transaction becomes a savepoint, and the test's
// final ROLLBACK still undoes everything.
const passwords = createPasswordService();
const realDeps = () => ({ db: t.db, passwords, passwordPolicy: checkPasswordPolicy, audit: createAuditService() });

const INPUT = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
  licenceNumber: 'ZM-ASM-0042',
};

const usersNamed = async (username) =>
  (await t.db.query('SELECT * FROM users WHERE lower(username) = lower($1)', [username])).rows;
const registerEntriesFor = async (userId) =>
  (await t.db.query("SELECT * FROM audit_logs WHERE action = 'user.register' AND entity_id = $1", [userId])).rows;
const registerEntryCount = async () =>
  (await t.db.query("SELECT count(*)::int AS n FROM audit_logs WHERE action = 'user.register'")).rows[0].n;

describe('userService.register against PostgreSQL', () => {
  it('saves a pending user with an Argon2id hash and a random 32-byte actor_ref', async () => {
    const user = await createUserService(realDeps()).register(INPUT);

    const [row] = await usersNamed('mutale_banda');
    expect(row.id).toBe(user.id);
    expect(row.status).toBe('pending');
    expect(row.role).toBe('miner');
    expect(row.licence_number).toBe('ZM-ASM-0042');
    expect(row.password_hash).toMatch(/^\$argon2id\$v=19\$m=19456,t=2,p=1\$/);
    expect(row.actor_ref).toHaveLength(32);
    expect(row.approved_by).toBeNull();
    // The stored hash really is the password's: login will be able to verify it.
    expect(await passwords.verify(row.password_hash, INPUT.password)).toBe(true);
  });

  it('saves the user and its user.register audit entry together', async () => {
    const user = await createUserService(realDeps()).register(INPUT, { ipAddress: '196.46.10.7' });

    const entries = await registerEntriesFor(user.id);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      actor_id: user.id,
      entity_type: 'user',
      entity_id: user.id,
      details: { role: 'miner' },
      ip_address: '196.46.10.7',
    });
    // Neither the password nor anything from its hash is in the log.
    const stored = JSON.stringify(entries[0]);
    expect(stored).not.toContain(INPUT.password);
    expect(stored).not.toContain('$argon2id$');
  });

  it('saves neither when the audit entry fails, because both are in one transaction', async () => {
    const failingAudit = { record: vi.fn().mockRejectedValue(new Error('audit insert failed')) };
    const service = createUserService({ ...realDeps(), audit: failingAudit });

    await expect(service.register(INPUT)).rejects.toThrow('audit insert failed');

    // The user was inserted before the audit call, and the rollback removed it.
    expect(failingAudit.record).toHaveBeenCalledOnce();
    expect(await usersNamed('mutale_banda')).toHaveLength(0);
  });

  it('returns a safe user without password_hash or actor_ref', async () => {
    const user = await createUserService(realDeps()).register(INPUT);

    expect(Object.keys(user).sort()).toEqual(['createdAt', 'fullName', 'id', 'licenceNumber', 'role', 'status', 'username']);
    expect(JSON.stringify(user)).not.toContain('argon2');
  });

  describe('taken usernames', () => {
    it('gives 409 USERNAME_TAKEN for the same name in different case, and keeps the first account', async () => {
      const service = createUserService(realDeps());
      const first = await service.register(INPUT);
      const entriesBefore = await registerEntryCount();

      const err = await service.register({ ...INPUT, username: 'MUTALE_BANDA', fullName: 'Someone Else' }).catch((e) => e);

      expect(err).toMatchObject({ status: 409, code: 'USERNAME_TAKEN' });
      const rows = await usersNamed('mutale_banda');
      expect(rows).toHaveLength(1);
      expect(rows[0].id).toBe(first.id);
      expect(rows[0].full_name).toBe('Mutale Banda');
      // The failed attempt left no audit entry behind.
      expect(await registerEntryCount()).toBe(entriesBefore);
    });

    it('leaves the surrounding transaction usable after the 409', async () => {
      const service = createUserService(realDeps());
      await service.register(INPUT);
      await service.register(INPUT).catch(() => {});

      // The insert failed inside a savepoint, so this connection can carry on.
      const second = await service.register({ ...INPUT, username: 'chanda_mwila' });

      expect(second.username).toBe('chanda_mwila');
    });
  });

  describe('weak passwords', () => {
    it.each([
      ['too short', 'copperbelt2', 'PASSWORD_TOO_SHORT'],
      ['too common', 'kindergarten', 'PASSWORD_TOO_COMMON'],
      ['containing the username', 'i am mutale_banda', 'PASSWORD_CONTAINS_USERNAME'],
    ])('saves nothing when the password is %s', async (_label, password, code) => {
      const entriesBefore = await registerEntryCount();

      const err = await createUserService(realDeps()).register({ ...INPUT, password }).catch((e) => e);

      expect(err).toMatchObject({ status: 400, code: 'WEAK_PASSWORD' });
      expect(err.details.map((d) => d.code)).toContain(code);
      expect(await usersNamed('mutale_banda')).toHaveLength(0);
      expect(await registerEntryCount()).toBe(entriesBefore);
    });
  });
});
