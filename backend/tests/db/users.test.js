import { randomBytes } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { FAKE_ARGON2_HASH, MISSING_ID, insertUser as insertUserInto, userInsert } from './fixtures.js';

const t = useTestDb();

// Fake: just 91 random bytes, the length of a P-256 SubjectPublicKeyInfo.
const FAKE_P256_SPKI = randomBytes(91);

const insertUser = (overrides) => insertUserInto(t.db, overrides);

function expectInsertRejected(overrides, code) {
  const { text, params } = userInsert(overrides);
  return expectPgError(t.db, text, params, code);
}

describe('users table', () => {
  it('fills in id, status and timestamps when they are left out', async () => {
    const { rows } = await t.db.query(
      `INSERT INTO users (username, full_name, password_hash, role, actor_ref)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      ['defaults_user', 'Test User', FAKE_ARGON2_HASH, 'buyer', randomBytes(32)],
    );

    expect(rows[0].id).toMatch(/^[0-9a-f-]{36}$/);
    expect(rows[0].status).toBe('pending');
    expect(rows[0].created_at).toBeInstanceOf(Date);
    expect(rows[0].updated_at).toBeInstanceOf(Date);
  });

  it('accepts every one of the five roles', async () => {
    for (const role of ['miner', 'transporter', 'buyer', 'officer', 'admin']) {
      expect((await insertUser({ role })).role).toBe(role);
    }
  });

  describe('uniqueness', () => {
    it('rejects a username that differs only in letter case', async () => {
      await insertUser({ username: 'Banda' });

      await expectInsertRejected({ username: 'banda' }, PG_ERROR.UNIQUE_VIOLATION);
    });

    it('rejects a second user with the same actor_ref', async () => {
      const actorRef = randomBytes(32);
      await insertUser({ actor_ref: actorRef });

      const err = await expectInsertRejected({ actor_ref: actorRef }, PG_ERROR.UNIQUE_VIOLATION);
      expect(err.constraint).toBe('users_actor_ref_unique');
    });

    it('rejects a second user with the same public key', async () => {
      const key = randomBytes(91);
      await insertUser({ public_key: key });

      const err = await expectInsertRejected({ public_key: key }, PG_ERROR.UNIQUE_VIOLATION);
      // The name the service will map to 409 PUBLIC_KEY_IN_USE.
      expect(err.constraint).toBe('users_public_key_key');
    });

    it('rejects giving an existing user a key another user already has', async () => {
      const key = randomBytes(91);
      await insertUser({ public_key: key });
      const other = await insertUser();

      const err = await expectPgError(
        t.db,
        'UPDATE users SET public_key = $1 WHERE id = $2',
        [key, other.id],
        PG_ERROR.UNIQUE_VIOLATION,
      );
      expect(err.constraint).toBe('users_public_key_key');
    });

    it('allows any number of users with no key', async () => {
      for (let i = 0; i < 3; i += 1) await insertUser({ public_key: null });

      const { rows } = await t.db.query('SELECT count(*)::int AS n FROM users WHERE public_key IS NULL');
      expect(rows[0].n).toBeGreaterThanOrEqual(3);
    });

    it('allows different keys on different users', async () => {
      await insertUser({ public_key: randomBytes(91) });

      await expect(insertUser({ public_key: randomBytes(91) })).resolves.toBeDefined();
    });
  });

  describe('CHECK rules', () => {
    // Each case names the constraint expected to fire, so a test cannot pass because a
    // different rule happened to reject the row.
    it.each([
      ['an unknown role', { role: 'superuser' }, 'users_role_valid'],
      ['an unknown status', { status: 'deleted' }, 'users_status_valid'],
      ['a plain-text password', { password_hash: 'hunter2' }, 'users_password_is_hash'],
      ['a 31-byte actor_ref', { actor_ref: randomBytes(31) }, 'users_actor_ref_32_bytes'],
      ['a public key of the wrong length', { public_key: randomBytes(65) }, 'users_public_key_p256_spki'],
      ['a username with a space', { username: 'john banda' }, 'users_username_format'],
      ['a 2-character username', { username: 'jb' }, 'users_username_format'],
      ['a blank full name', { full_name: '   ' }, 'users_full_name_not_blank'],
      ['a rejected user with no reason', { status: 'rejected' }, 'users_status_reason_required'],
      ['a suspended user with a blank reason', { status: 'suspended', status_reason: '  ' }, 'users_status_reason_required'],
    ])('rejects %s', async (_label, overrides, constraint) => {
      const err = await expectInsertRejected(overrides, PG_ERROR.CHECK_VIOLATION);

      expect(err.constraint).toBe(constraint);
    });

    it('accepts a bcrypt hash, the approved fallback', async () => {
      const user = await insertUser({ password_hash: '$2b$12$abcdefghijklmnopqrstuuFakeFakeFakeFakeFakeFakeFakeFa' });

      expect(user.password_hash).toMatch(/^\$2b\$/);
    });

    it('accepts a suspended user when a reason is given', async () => {
      const user = await insertUser({ status: 'suspended', status_reason: 'Lost device reported' });

      expect(user.status).toBe('suspended');
    });

    it('accepts a 91-byte public key and stores it unchanged', async () => {
      const user = await insertUser({ public_key: FAKE_P256_SPKI });

      expect(Buffer.compare(user.public_key, FAKE_P256_SPKI)).toBe(0);
    });
  });

  describe('approval', () => {
    it('rejects approved_by without approved_at', async () => {
      const admin = await insertUser({ role: 'admin', status: 'active' });

      const err = await expectInsertRejected({ approved_by: admin.id }, PG_ERROR.CHECK_VIOLATION);
      expect(err.constraint).toBe('users_approval_complete');
    });

    it('accepts an approval by another user', async () => {
      const admin = await insertUser({ role: 'admin', status: 'active' });

      const user = await insertUser({ status: 'active', approved_by: admin.id, approved_at: new Date() });

      expect(user.approved_by).toBe(admin.id);
    });

    it('rejects a user approving their own account', async () => {
      const admin = await insertUser({ role: 'admin', status: 'active' });

      const err = await expectPgError(
        t.db,
        'UPDATE users SET approved_by = id, approved_at = now() WHERE id = $1',
        [admin.id],
        PG_ERROR.CHECK_VIOLATION,
      );
      expect(err.constraint).toBe('users_no_self_approval');
    });

    it('rejects approved_by pointing at a user that does not exist', async () => {
      await expectInsertRejected(
        { approved_by: MISSING_ID, approved_at: new Date() },
        PG_ERROR.FOREIGN_KEY_VIOLATION,
      );
    });

    it('refuses to delete an admin who approved someone (D9)', async () => {
      const admin = await insertUser({ role: 'admin', status: 'active' });
      await insertUser({ status: 'active', approved_by: admin.id, approved_at: new Date() });

      const err = await expectPgError(
        t.db,
        'DELETE FROM users WHERE id = $1',
        [admin.id],
        PG_ERROR.RESTRICT_VIOLATION,
      );
      expect(err.constraint).toBe('users_approved_by_fkey');
    });
  });

  describe('set_updated_at trigger', () => {
    // now() is fixed for the whole test transaction, so the row starts with an old
    // updated_at; otherwise "before" and "after" would be identical.
    const OLD = new Date('2020-01-01T00:00:00Z');

    async function insertOldUser() {
      const { rows } = await t.db.query(
        `INSERT INTO users (username, full_name, password_hash, role, actor_ref, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, $6) RETURNING id`,
        ['old_user', 'Test User', FAKE_ARGON2_HASH, 'miner', randomBytes(32), OLD],
      );
      return rows[0].id;
    }

    it('moves updated_at forward on every update', async () => {
      const id = await insertOldUser();

      const { rows } = await t.db.query(
        'UPDATE users SET full_name = $1 WHERE id = $2 RETURNING created_at, updated_at',
        ['Renamed User', id],
      );

      expect(rows[0].updated_at.getTime()).toBeGreaterThan(OLD.getTime());
      expect(rows[0].created_at.getTime()).toBe(OLD.getTime());
    });

    it('overrides an updated_at set by hand in the UPDATE', async () => {
      const id = await insertOldUser();

      const { rows } = await t.db.query(
        'UPDATE users SET updated_at = $1 WHERE id = $2 RETURNING updated_at',
        [OLD, id],
      );

      expect(rows[0].updated_at.getTime()).toBeGreaterThan(OLD.getTime());
    });
  });
});
