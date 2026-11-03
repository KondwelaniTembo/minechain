import { randomBytes } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';

const t = useTestDb();

// Fake values. The hash is well-formed but hashes nothing, and the key is just 91 bytes.
const FAKE_ARGON2_HASH = '$argon2id$v=19$m=19456,t=2,p=1$ZmFrZXNhbHQ$ZmFrZWhhc2g';
const FAKE_P256_SPKI = randomBytes(91);

let counter = 0;
function validUser(overrides = {}) {
  counter += 1;
  return {
    username: `user_${counter}`,
    full_name: 'Test User',
    licence_number: null,
    password_hash: FAKE_ARGON2_HASH,
    role: 'miner',
    status: 'pending',
    status_reason: null,
    public_key: null,
    actor_ref: randomBytes(32),
    approved_by: null,
    approved_at: null,
    ...overrides,
  };
}

// One fixed statement with every column as a parameter, so no test builds SQL from strings.
const INSERT_USER = `
  INSERT INTO users (username, full_name, licence_number, password_hash, role, status,
                     status_reason, public_key, actor_ref, approved_by, approved_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
  RETURNING *`;

function params(user) {
  return [
    user.username, user.full_name, user.licence_number, user.password_hash, user.role,
    user.status, user.status_reason, user.public_key, user.actor_ref, user.approved_by,
    user.approved_at,
  ];
}

async function insertUser(overrides) {
  const { rows } = await t.db.query(INSERT_USER, params(validUser(overrides)));
  return rows[0];
}

function expectInsertRejected(overrides, code) {
  return expectPgError(t.db, INSERT_USER, params(validUser(overrides)), code);
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
      const missingId = '00000000-0000-4000-8000-000000000000';

      await expectInsertRejected(
        { approved_by: missingId, approved_at: new Date() },
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
