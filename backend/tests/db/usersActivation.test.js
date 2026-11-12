import { randomBytes } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { FAKE_ARGON2_HASH, insertUser } from './fixtures.js';

// The users-activation migration: the 'invited' status, an optional password hash, the
// activation code columns and tokens_valid_after.
//
// PostgreSQL checks CHECK constraints in alphabetical order of their names and reports the
// first that fails, so every row below breaks exactly one rule: the constraint a test names
// is then the real reason the row was refused.

const t = useTestDb();

const HOURS = 3_600_000;
let counter = 0;

// An invited account with a live code, as account creation will write it. Each test changes
// only the field it is about. Every column is a parameter of one fixed statement.
function invitedRow(overrides = {}) {
  counter += 1;
  const row = {
    username: `invited_${counter}`,
    full_name: 'Test Officer',
    password_hash: null,
    role: 'officer',
    status: 'invited',
    status_reason: null,
    actor_ref: randomBytes(32),
    activation_code_hash: randomBytes(32),
    activation_expires_at: new Date(Date.now() + 72 * HOURS),
    activation_failed_attempts: 0,
    tokens_valid_after: null,
    ...overrides,
  };
  return {
    text: `
      INSERT INTO users (username, full_name, password_hash, role, status, status_reason, actor_ref,
                         activation_code_hash, activation_expires_at, activation_failed_attempts,
                         tokens_valid_after)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      RETURNING *`,
    params: [
      row.username, row.full_name, row.password_hash, row.role, row.status, row.status_reason,
      row.actor_ref, row.activation_code_hash, row.activation_expires_at,
      row.activation_failed_attempts, row.tokens_valid_after,
    ],
  };
}

async function insertInvited(overrides) {
  const { text, params } = invitedRow(overrides);
  return (await t.db.query(text, params)).rows[0];
}

const expectRejected = (overrides, code) => {
  const { text, params } = invitedRow(overrides);
  return expectPgError(t.db, text, params, code);
};

// No code and no expiry, for rows that are not invited.
const NO_CODE = { activation_code_hash: null, activation_expires_at: null };

describe('users: activation columns', () => {
  it('leaves the new columns empty, with no attempts, on an ordinary insert', async () => {
    const user = await insertUser(t.db);

    expect(user).toMatchObject({
      activation_code_hash: null,
      activation_expires_at: null,
      activation_failed_attempts: 0,
      tokens_valid_after: null,
    });
  });

  it('accepts an invited account with no password hash, a 32-byte code and an expiry', async () => {
    const user = await insertInvited();

    expect(user).toMatchObject({ status: 'invited', password_hash: null, activation_failed_attempts: 0 });
    expect(user.activation_code_hash).toHaveLength(32);
  });

  it('accepts an invited account with no code at all, after its code was erased', async () => {
    const user = await insertInvited({ ...NO_CODE, activation_failed_attempts: 5 });

    expect(user).toMatchObject({ status: 'invited', activation_code_hash: null, activation_expires_at: null });
  });

  it('accepts a cut-off for old tokens on an active account', async () => {
    const cutOff = new Date('2026-11-11T09:00:00.000Z');

    const user = await insertInvited({ ...NO_CODE, status: 'active', password_hash: FAKE_ARGON2_HASH, tokens_valid_after: cutOff });

    expect(user.tokens_valid_after).toEqual(cutOff);
  });
});

describe('users: activation CHECK rules', () => {
  it.each([
    ['an invited account that has a password hash', { password_hash: FAKE_ARGON2_HASH }, 'users_password_only_when_invited'],
    ['a 31-byte code hash', { activation_code_hash: randomBytes(31) }, 'users_activation_code_32_bytes'],
    ['a 33-byte code hash', { activation_code_hash: randomBytes(33) }, 'users_activation_code_32_bytes'],
    ['a code with no expiry', { activation_expires_at: null }, 'users_activation_complete'],
    ['an expiry with no code', { activation_code_hash: null }, 'users_activation_complete'],
    ['a code on an active account', { status: 'active', password_hash: FAKE_ARGON2_HASH }, 'users_activation_only_when_invited'],
    ['negative attempts', { activation_failed_attempts: -1 }, 'users_activation_attempts_non_negative'],
  ])('rejects %s', async (_label, overrides, constraint) => {
    const err = await expectRejected(overrides, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe(constraint);
  });

  it.each([
    ['pending', null],
    ['active', null],
    ['suspended', 'Lost device reported'],
    ['rejected', 'Licence not found'],
  ])('still requires a password hash on a %s account', async (status, reason) => {
    const err = await expectRejected({ ...NO_CODE, status, status_reason: reason }, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe('users_password_only_when_invited');
  });

  it('still refuses a plain-text password, now that the column can be NULL', async () => {
    const err = await expectRejected({ ...NO_CODE, status: 'pending', password_hash: 'hunter2' }, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe('users_password_is_hash');
  });

  it('refuses a NULL attempt count', async () => {
    await expectRejected({ activation_failed_attempts: null }, PG_ERROR.NOT_NULL_VIOLATION);
  });
});

describe('users: activation as one UPDATE', () => {
  it('accepts setting the hash, the status and clearing the code together', async () => {
    const user = await insertInvited();

    const { rows } = await t.db.query(
      `UPDATE users
          SET password_hash = $2, status = 'active', activation_code_hash = NULL, activation_expires_at = NULL
        WHERE id = $1
        RETURNING status, password_hash, activation_code_hash`,
      [user.id, FAKE_ARGON2_HASH],
    );

    expect(rows[0]).toEqual({ status: 'active', password_hash: FAKE_ARGON2_HASH, activation_code_hash: null });
  });

  it('refuses making an invited account active without a password hash', async () => {
    const user = await insertInvited(NO_CODE);

    const err = await expectPgError(t.db, "UPDATE users SET status = 'active' WHERE id = $1", [user.id], PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe('users_password_only_when_invited');
  });

  it('refuses activating while leaving the code in place', async () => {
    const user = await insertInvited();

    const err = await expectPgError(
      t.db,
      "UPDATE users SET password_hash = $2, status = 'active' WHERE id = $1",
      [user.id, FAKE_ARGON2_HASH],
      PG_ERROR.CHECK_VIOLATION,
    );

    expect(err.constraint).toBe('users_activation_only_when_invited');
  });

  it('accepts erasing the code and its expiry together, leaving the account invited', async () => {
    const user = await insertInvited();

    const { rows } = await t.db.query(
      `UPDATE users SET activation_code_hash = NULL, activation_expires_at = NULL, activation_failed_attempts = 5
        WHERE id = $1 RETURNING status, activation_code_hash`,
      [user.id],
    );

    expect(rows[0]).toEqual({ status: 'invited', activation_code_hash: null });
  });
});
