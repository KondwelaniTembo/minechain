import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { FAKE_ARGON2_HASH, insertUser, userInsert } from './fixtures.js';

// The users-deleted migration: the 'deleted' status, a reason for it, and no password hash on
// a deleted account.
//
// PostgreSQL checks CHECK constraints in alphabetical order of their names and reports the
// first that fails, so every refused row below breaks exactly one rule: the constraint a test
// names is then the real reason the row was refused.

const t = useTestDb();

const MIGRATION_URL = new URL('../../migrations/1794528000000_users-deleted.sql', import.meta.url);
const HOURS = 3_600_000;
const REASON = 'Left the cooperative';

// A deleted account as the delete will leave it: no hash, a reason, no key, no code.
const DELETED = { status: 'deleted', password_hash: null, status_reason: REASON, public_key: null };

const expectInsertRejected = (overrides, code) => {
  const { text, params } = userInsert(overrides);
  return expectPgError(t.db, text, params, code);
};

// userInsert has no activation columns, so an invited account with a live code gets its own
// fixed statement, every value a parameter.
let counter = 0;
async function insertInvitedWithCode() {
  counter += 1;
  const { rows } = await t.db.query(
    `INSERT INTO users (username, full_name, password_hash, role, status, actor_ref,
                        activation_code_hash, activation_expires_at)
     VALUES ($1, 'Test Officer', NULL, 'officer', 'invited', $2, $3, $4)
     RETURNING *`,
    [`deleted_invited_${counter}`, randomBytes(32), randomBytes(32), new Date(Date.now() + 72 * HOURS)],
  );
  return rows[0];
}

async function usersConstraintNames() {
  const { rows } = await t.db.query(
    "SELECT conname FROM pg_constraint WHERE conrelid = 'users'::regclass AND contype = 'c'",
  );
  return rows.map((r) => r.conname);
}

describe('users-deleted: constraint names', () => {
  it('replaces users_password_only_when_invited with users_password_null_when_invited_or_deleted', async () => {
    const names = await usersConstraintNames();

    expect(names).toContain('users_password_null_when_invited_or_deleted');
    expect(names).not.toContain('users_password_only_when_invited');
  });

  it('keeps the names users_status_valid and users_status_reason_required', async () => {
    const names = await usersConstraintNames();

    expect(names).toEqual(expect.arrayContaining(['users_status_valid', 'users_status_reason_required']));
  });

  it('adds users_deleted_has_no_public_key', async () => {
    expect(await usersConstraintNames()).toContain('users_deleted_has_no_public_key');
  });
});

describe('users-deleted: accepted rows', () => {
  it('accepts a deleted account with no password hash and a reason', async () => {
    const user = await insertUser(t.db, DELETED);

    expect(user).toMatchObject({ status: 'deleted', password_hash: null, status_reason: REASON });
  });

  it.each([
    ['pending', { status_reason: null }],
    ['active', { status_reason: null }],
    ['suspended', { status_reason: 'Lost device reported' }],
    ['rejected', { status_reason: 'Licence not found' }],
  ])('still accepts a %s account with a password hash', async (status, extra) => {
    const user = await insertUser(t.db, { status, ...extra });

    expect(user.status).toBe(status);
  });

  it('still accepts an invited account with no password hash', async () => {
    const user = await insertInvitedWithCode();

    expect(user).toMatchObject({ status: 'invited', password_hash: null });
  });
});

describe('users-deleted: refused rows', () => {
  it.each([
    // A status that is still unknown, with everything else valid.
    ['an unknown status', { status: 'archived' }, 'users_status_valid'],
    ['a deleted account with no reason', { ...DELETED, status_reason: null }, 'users_status_reason_required'],
    ['a deleted account with a blank reason', { ...DELETED, status_reason: '   ' }, 'users_status_reason_required'],
    ['a deleted account that has a password hash', { ...DELETED, password_hash: FAKE_ARGON2_HASH }, 'users_password_null_when_invited_or_deleted'],
    ['a deleted account that has a public key', { ...DELETED, public_key: randomBytes(91) }, 'users_deleted_has_no_public_key'],
    // The replaced reason rule still covers the two statuses it covered before.
    ['a suspended account with no reason', { status: 'suspended' }, 'users_status_reason_required'],
    ['a rejected account with no reason', { status: 'rejected' }, 'users_status_reason_required'],
    // And the replaced password rule still requires a hash on every other status.
    ['an active account with no password hash', { status: 'active', password_hash: null }, 'users_password_null_when_invited_or_deleted'],
  ])('refuses %s', async (_label, overrides, constraint) => {
    const err = await expectInsertRejected(overrides, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe(constraint);
  });
});

describe('users-deleted: deleting as one UPDATE', () => {
  // The shape of the delete B3.2 will write: status, reason, key and hash in one statement.
  const DELETE_ROW = `
    UPDATE users
       SET status = 'deleted', status_reason = $2, public_key = NULL, password_hash = NULL,
           activation_code_hash = NULL, activation_expires_at = NULL, activation_failed_attempts = 0
     WHERE id = $1
     RETURNING status, status_reason, password_hash, public_key`;

  it.each([
    ['active', { status: 'active', public_key: randomBytes(91) }],
    ['suspended', { status: 'suspended', status_reason: 'Lost device reported' }],
  ])('accepts deleting a %s account', async (_label, overrides) => {
    const user = await insertUser(t.db, overrides);

    const { rows } = await t.db.query(DELETE_ROW, [user.id, REASON]);

    expect(rows[0]).toEqual({ status: 'deleted', status_reason: REASON, password_hash: null, public_key: null });
  });

  it('accepts deleting an invited account when its code is cleared in the same UPDATE', async () => {
    const user = await insertInvitedWithCode();

    const { rows } = await t.db.query(DELETE_ROW, [user.id, REASON]);

    expect(rows[0]).toMatchObject({ status: 'deleted', password_hash: null });
  });

  it('refuses deleting an invited account while leaving its code in place', async () => {
    const user = await insertInvitedWithCode();

    const err = await expectPgError(
      t.db,
      "UPDATE users SET status = 'deleted', status_reason = $2 WHERE id = $1",
      [user.id, REASON],
      PG_ERROR.CHECK_VIOLATION,
    );

    expect(err.constraint).toBe('users_activation_only_when_invited');
  });

  it('refuses deleting an account while keeping its password hash', async () => {
    const user = await insertUser(t.db, { status: 'active' });

    const err = await expectPgError(
      t.db,
      "UPDATE users SET status = 'deleted', status_reason = $2 WHERE id = $1",
      [user.id, REASON],
      PG_ERROR.CHECK_VIOLATION,
    );

    expect(err.constraint).toBe('users_password_null_when_invited_or_deleted');
  });

  it('refuses deleting an account while leaving its device key in place', async () => {
    const user = await insertUser(t.db, { status: 'active', public_key: randomBytes(91) });

    const err = await expectPgError(
      t.db,
      "UPDATE users SET status = 'deleted', status_reason = $2, password_hash = NULL WHERE id = $1",
      [user.id, REASON],
      PG_ERROR.CHECK_VIOLATION,
    );

    expect(err.constraint).toBe('users_deleted_has_no_public_key');
  });

  it('refuses registering a device key on a deleted account', async () => {
    const user = await insertUser(t.db, DELETED);

    const err = await expectPgError(
      t.db,
      'UPDATE users SET public_key = $2 WHERE id = $1',
      [user.id, randomBytes(91)],
      PG_ERROR.CHECK_VIOLATION,
    );

    expect(err.constraint).toBe('users_deleted_has_no_public_key');
  });

  it('refuses making a deleted account active again by changing its status alone', async () => {
    const user = await insertUser(t.db, DELETED);

    const err = await expectPgError(t.db, "UPDATE users SET status = 'active' WHERE id = $1", [user.id], PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe('users_password_null_when_invited_or_deleted');
  });
});

describe('users-deleted: Down migration', () => {
  // The Down section exactly as node-pg-migrate would run it. It is several statements with
  // no parameters, so pg sends it as one simple query. Everything runs inside the test's own
  // transaction, which is rolled back afterwards, so the test database keeps the new schema
  // and pgmigrations is never touched. Test files run one at a time (vitest.db.config.js),
  // so the lock this DDL takes on users cannot block another file.
  const downSql = () => {
    const [, down] = readFileSync(MIGRATION_URL, 'utf8').split('-- Down Migration');
    expect(down?.trim(), 'the migration has a Down section').toBeTruthy();
    return down;
  };

  it('refuses while a deleted account exists, and leaves the schema as it was', async () => {
    const user = await insertUser(t.db, DELETED);

    const err = await expectPgError(t.db, downSql(), [], PG_ERROR.RAISED_EXCEPTION);

    expect(err.message).toMatch(/^Cannot roll back users-deleted: 1 deleted account\(s\) exist\./);
    expect(await usersConstraintNames()).toContain('users_password_null_when_invited_or_deleted');
    const { rows } = await t.db.query('SELECT status FROM users WHERE id = $1', [user.id]);
    expect(rows[0].status).toBe('deleted');
  });

  it('with no deleted account, restores the rules users-activation left', async () => {
    // Rows the old rules allow, so the restored CHECKs are validated against real data.
    await insertInvitedWithCode();
    await insertUser(t.db, { status: 'suspended', status_reason: 'Lost device reported' });

    await t.db.query(downSql());

    const names = await usersConstraintNames();
    expect(names).toContain('users_password_only_when_invited');
    expect(names).not.toContain('users_password_null_when_invited_or_deleted');
    expect(names).not.toContain('users_deleted_has_no_public_key');
    // With a hash, so only the status list can refuse it: 'deleted' is unknown again.
    const err = await expectInsertRejected({ status: 'deleted', status_reason: REASON }, PG_ERROR.CHECK_VIOLATION);
    expect(err.constraint).toBe('users_status_valid');
  });
});
