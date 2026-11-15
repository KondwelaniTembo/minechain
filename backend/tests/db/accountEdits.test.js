import { randomBytes } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { FAKE_CONFIG, FAKE_ARGON2_HASH, MISSING_ID, insertUser, insertTransaction, insertAlert } from './fixtures.js';
import { newPhone, stepItem, TEST_PASSPHRASE } from './realStackHelpers.js';
import { createServices } from '../../src/services/index.js';
import { createAccountService } from '../../src/services/accountService.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createSyncService } from '../../src/services/syncService.js';
import { createSignatureService, spkiFingerprint } from '../../src/services/signatureService.js';
import { createPool, createDb } from '../../src/db.js';

// Account rename and soft delete (B3.2) against the real database: what each writes, what it
// refuses, what a deleted account can no longer do, and what history it keeps.

const t = useTestDb();

const services = () => createServices({ db: t.db, config: FAKE_CONFIG });
const accounts = () => services().accounts;

// The app server's clock pinned part-way through a second, so the cut-off is known exactly.
const FIXED_NOW = Date.parse('2026-11-15T10:00:00.400Z');
const FIXED_SECOND = Math.floor(FIXED_NOW / 1000);
const pinnedAccounts = () => createAccountService({ db: t.db, audit: createAuditService(), now: () => FIXED_NOW });

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.7';
const REASON = 'Left the cooperative';
const NEW_NAME = 'Chanda Mwila';
const NOV_10 = { from: '2026-11-10', to: '2026-11-10' };

const ADMIN_KEYS = [
  'id', 'username', 'fullName', 'licenceNumber', 'role', 'status', 'statusReason',
  'approvedBy', 'approvedAt', 'createdAt', 'updatedAt', 'publicKeyFingerprint',
  'activationExpiresAt',
].sort();

const failingAudit = {
  record: async () => {
    throw new Error('audit unavailable');
  },
};

const activeAdmin = () => insertUser(t.db, { role: 'admin', status: 'active' });

// One account in each status. Active and suspended ones have a device key, and the invited
// one a live code with some wrong attempts, so the delete has something to clear.
const SET_CODE = `
  UPDATE users
     SET activation_code_hash = $2, activation_expires_at = clock_timestamp() + interval '72 hours',
         activation_failed_attempts = 2
   WHERE id = $1`;
const ACCOUNT_IN = {
  pending: () => insertUser(t.db, { role: 'miner', status: 'pending' }),
  active: () => insertUser(t.db, { role: 'miner', status: 'active', public_key: randomBytes(91) }),
  suspended: () =>
    insertUser(t.db, { role: 'miner', status: 'suspended', status_reason: 'Lost device reported', public_key: randomBytes(91) }),
  rejected: () => insertUser(t.db, { role: 'miner', status: 'rejected', status_reason: 'Licence not found' }),
  invited: async () => {
    const user = await insertUser(t.db, { role: 'officer', status: 'invited', password_hash: null });
    await t.db.query(SET_CODE, [user.id, randomBytes(32)]);
    return user;
  },
  deleted: () => insertUser(t.db, { role: 'miner', status: 'deleted', password_hash: null, status_reason: REASON }),
};

// Everything an edit could touch. ctid is the row version's physical place: any UPDATE writes
// a new version with a new ctid, even one that changes nothing, so an equal ctid proves no
// UPDATE ran. (updated_at cannot prove it here: now() stays the same in a test's transaction.)
async function snapshot(id) {
  const { rows } = await t.db.query(
    `SELECT ctid::text AS ctid, username, full_name, licence_number, role, status, status_reason,
            public_key, password_hash, activation_code_hash, activation_expires_at,
            activation_failed_attempts, extract(epoch FROM tokens_valid_after)::bigint AS cut_off
       FROM users WHERE id = $1`,
    [id],
  );
  return rows[0];
}

async function auditFor(id) {
  const { rows } = await t.db.query(
    'SELECT actor_id, action, details, ip_address FROM audit_logs WHERE entity_id = $1 ORDER BY id',
    [id],
  );
  return rows;
}

// Takes a function that starts the action, not a promise already running (see the working
// rules): the snapshot is taken first.
async function expectRefused(startAction, expected, target) {
  const before = await snapshot(target.id);
  await expect(startAction()).rejects.toMatchObject(expected);
  expect(await snapshot(target.id)).toEqual(before);
  expect(await auditFor(target.id)).toEqual([]);
}

describe('rename', () => {
  it.each(['pending', 'invited', 'active', 'suspended'])(
    'renames a %s account, changing nothing else and recording only which field changed',
    async (status) => {
      const admin = await activeAdmin();
      const target = await ACCOUNT_IN[status]();
      const before = await snapshot(target.id);

      const user = await accounts().rename({ userId: target.id, fullName: NEW_NAME, adminId: admin.id, ipAddress: IP });

      expect(Object.keys(user).sort()).toEqual(ADMIN_KEYS);
      expect(user).toMatchObject({ id: target.id, status, fullName: NEW_NAME });
      const { ctid: _before, full_name: oldName, ...rest } = before;
      const { ctid: _after, full_name: newName, ...restAfter } = await snapshot(target.id);
      expect(newName).toBe(NEW_NAME);
      expect(restAfter).toEqual(rest);

      const entries = await auditFor(target.id);
      expect(entries).toEqual([{ actor_id: admin.id, action: 'user.rename', details: { field: 'fullName' }, ip_address: IP }]);
      // Neither name is ever written into the append-only log.
      expect(JSON.stringify(entries)).not.toContain(NEW_NAME);
      expect(JSON.stringify(entries)).not.toContain(oldName);
    },
  );

  it.each([
    ['rejected', 'A rejected account cannot be changed.'],
    ['deleted', 'A deleted account cannot be changed.'],
  ])('refuses a %s account, which is final', async (status, message) => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN[status]();

    await expectRefused(
      () => accounts().rename({ userId: target.id, fullName: NEW_NAME, adminId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION', message },
      target,
    );
  });

  it('answers the same name with the account, writing nothing and recording nothing', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    const before = await snapshot(target.id);

    const user = await accounts().rename({ userId: target.id, fullName: before.full_name, adminId: admin.id });

    expect(user).toMatchObject({ id: target.id, fullName: before.full_name });
    expect(await snapshot(target.id)).toEqual(before);
    expect(await auditFor(target.id)).toEqual([]);
  });

  it('refuses an id that matches no user with 404', async () => {
    const admin = await activeAdmin();

    await expect(accounts().rename({ userId: MISSING_ID, fullName: NEW_NAME, adminId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'USER_NOT_FOUND',
    });
  });

  it('accepts the id in capitals and records it in lower case', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();

    await accounts().rename({ userId: target.id.toUpperCase(), fullName: NEW_NAME, adminId: admin.id });

    expect((await snapshot(target.id)).full_name).toBe(NEW_NAME);
    expect(await auditFor(target.id)).toHaveLength(1);
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    const before = await snapshot(target.id);
    const service = createAccountService({ db: t.db, audit: failingAudit });

    await expect(service.rename({ userId: target.id, fullName: NEW_NAME, adminId: admin.id })).rejects.toThrow('audit unavailable');

    // The UPDATE ran, but it was rolled back with the failed entry (a new ctid would remain
    // only if it had been kept).
    expect(await snapshot(target.id)).toEqual(before);
  });
});

describe('deleteAccount', () => {
  it.each(['active', 'suspended', 'invited'])(
    'deletes a %s account: reason kept; key, hash and code gone; tokens cut off',
    async (status) => {
      const admin = await activeAdmin();
      const target = await ACCOUNT_IN[status]();
      const before = await snapshot(target.id);

      const user = await pinnedAccounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id, ipAddress: IP });

      expect(Object.keys(user).sort()).toEqual(ADMIN_KEYS);
      expect(user).toMatchObject({
        id: target.id,
        status: 'deleted',
        statusReason: REASON,
        publicKeyFingerprint: null,
        activationExpiresAt: null,
      });
      expect(await snapshot(target.id)).toMatchObject({
        username: before.username,
        full_name: before.full_name,
        role: before.role,
        status: 'deleted',
        status_reason: REASON,
        public_key: null,
        password_hash: null,
        activation_code_hash: null,
        activation_expires_at: null,
        activation_failed_attempts: 0,
        // One second after the app server's clock (see the cut-off tests below).
        cut_off: String(FIXED_SECOND + 1),
      });

      const entries = await auditFor(target.id);
      expect(entries).toEqual([
        {
          actor_id: admin.id,
          action: 'user.delete',
          details: {
            from: status,
            to: 'deleted',
            reason: REASON,
            keyFingerprint: before.public_key ? spkiFingerprint(before.public_key) : null,
          },
          ip_address: IP,
        },
      ]);
      // The fingerprint only: never the key, a hash or a code.
      const text = JSON.stringify(entries);
      expect(text).not.toContain('$argon2');
      if (before.public_key) expect(text).not.toContain(before.public_key.toString('hex'));
      if (before.activation_code_hash) expect(text).not.toContain(before.activation_code_hash.toString('hex'));
    },
  );

  it.each([
    ['pending', 'A pending account cannot be deleted. Reject the request instead, so the person is told why.'],
    ['rejected', 'Only an active, suspended or invited account can be deleted. This account is rejected.'],
    ['deleted', 'This account has already been deleted.'],
  ])('refuses a %s account with 409', async (status, message) => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN[status]();

    await expectRefused(
      () => accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION', message },
      target,
    );
  });

  it('refuses a second delete of the same account, keeping the first entry only', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    await accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });
    const afterFirst = await snapshot(target.id);

    await expect(
      accounts().deleteAccount({ userId: target.id, reason: 'Second attempt', adminId: admin.id }),
    ).rejects.toMatchObject({ status: 409, code: 'INVALID_STATUS_TRANSITION', message: 'This account has already been deleted.' });

    expect(await snapshot(target.id)).toEqual(afterFirst);
    expect((await auditFor(target.id)).map((e) => e.action)).toEqual(['user.delete']);
  });

  it('refuses an id that matches no user with 404', async () => {
    const admin = await activeAdmin();

    await expect(accounts().deleteAccount({ userId: MISSING_ID, reason: REASON, adminId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'USER_NOT_FOUND',
    });
  });

  describe('administrators', () => {
    it('refuses an admin deleting themselves with 403, before any SQL', async () => {
      const admin = await activeAdmin();
      // Any query or transaction would throw a different error, so the 403 proves none ran.
      const noSql = {
        query: () => Promise.reject(new Error('SQL was used')),
        transaction: () => Promise.reject(new Error('SQL was used')),
      };
      const service = createAccountService({ db: noSql, audit: failingAudit });

      await expect(service.deleteAccount({ userId: admin.id.toUpperCase(), reason: REASON, adminId: admin.id })).rejects.toMatchObject({
        status: 403,
        code: 'CANNOT_DELETE_SELF',
        message: 'You cannot delete your own account.',
      });
    });

    it('refuses it through the real service too, leaving the account as it was', async () => {
      const admin = await activeAdmin();
      await activeAdmin();

      await expectRefused(
        () => accounts().deleteAccount({ userId: admin.id, reason: REASON, adminId: admin.id }),
        { status: 403, code: 'CANNOT_DELETE_SELF' },
        admin,
      );
    });

    it('lets one admin delete another when two are active', async () => {
      const first = await activeAdmin();
      const second = await activeAdmin();

      const user = await accounts().deleteAccount({ userId: second.id, reason: REASON, adminId: first.id });

      expect(user.status).toBe('deleted');
    });

    it('refuses to delete the last active admin when the actor is no longer active', async () => {
      // What the second of two admins deleting each other sees (the race itself is below).
      const a = await activeAdmin();
      const b = await activeAdmin();
      await t.db.query("UPDATE users SET status = 'suspended', status_reason = 'Suspended by b' WHERE id = $1", [a.id]);

      await expectRefused(
        () => accounts().deleteAccount({ userId: b.id, reason: REASON, adminId: a.id }),
        {
          status: 409,
          code: 'LAST_ACTIVE_ADMIN',
          message: 'At least one other active administrator must remain, so this account cannot be deleted.',
        },
        b,
      );
    });
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    const before = await snapshot(target.id);
    const service = createAccountService({ db: t.db, audit: failingAudit });

    await expect(service.deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id })).rejects.toThrow('audit unavailable');

    // Key, hash and status all as they were: the UPDATE was rolled back with the entry.
    expect(await snapshot(target.id)).toEqual(before);
  });
});

describe('a deleted account cannot sign in by any path', () => {
  it('login answers INVALID_CREDENTIALS, exactly as for an unknown username, and records account_deleted', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    await accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });

    const deletedErr = await services().users.authenticate(target.username, TEST_PASSPHRASE).catch((e) => e);
    const unknownErr = await services().users.authenticate('nobody_by_this_name', TEST_PASSPHRASE).catch((e) => e);

    expect(deletedErr).toMatchObject({ status: 401, code: 'INVALID_CREDENTIALS', message: 'Username or password is incorrect.' });
    expect([deletedErr.status, deletedErr.code, deletedErr.message]).toEqual([unknownErr.status, unknownErr.code, unknownErr.message]);
    const { rows } = await t.db.query(
      "SELECT actor_id, details FROM audit_logs WHERE action = 'user.login_failed' AND entity_id = $1",
      [target.id],
    );
    expect(rows).toEqual([{ actor_id: target.id, details: { reason: 'account_deleted' } }]);
  });

  it('activation with a code issued before the delete answers ACTIVATION_INVALID', async () => {
    const admin = await activeAdmin();
    const { user, activation } = await accounts().createAccount({
      username: 'deleted_officer',
      fullName: 'Test Officer',
      role: 'officer',
      actorId: admin.id,
    });
    await accounts().deleteAccount({ userId: user.id, reason: REASON, adminId: admin.id });

    await expect(
      services().users.activate({ username: 'deleted_officer', code: activation.code, password: TEST_PASSPHRASE }),
    ).rejects.toMatchObject({ status: 401, code: 'ACTIVATION_INVALID' });

    expect(await snapshot(user.id)).toMatchObject({ status: 'deleted', password_hash: null, activation_code_hash: null });
  });

  it('refuses a token issued before the delete with 401 TOKEN_INVALID', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    const { issuedAt } = await services().tokens.sign({ userId: target.id, role: 'miner' });
    // Control: the token works before the delete.
    await expect(services().users.getAuthenticatedUser(target.id, 'miner', issuedAt)).resolves.toMatchObject({ id: target.id });

    await accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });

    await expect(services().users.getAuthenticatedUser(target.id, 'miner', issuedAt)).rejects.toMatchObject({
      status: 401,
      code: 'TOKEN_INVALID',
    });
  });

  it('still refuses that token if the cut-off were ever cleared', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    const { issuedAt } = await services().tokens.sign({ userId: target.id, role: 'miner' });
    await accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });

    await t.db.query('UPDATE users SET tokens_valid_after = NULL WHERE id = $1', [target.id]);

    await expect(services().users.getAuthenticatedUser(target.id, 'miner', issuedAt)).rejects.toMatchObject({
      status: 401,
      code: 'TOKEN_INVALID',
    });
  });

  it('sets a cut-off that alone refuses a token from the same second as the delete', async () => {
    // The status rule is taken away by hand, so only the cut-off is left to decide.
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    await pinnedAccounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });
    await t.db.query("UPDATE users SET status = 'active', password_hash = $2 WHERE id = $1", [target.id, FAKE_ARGON2_HASH]);
    const users = services().users;

    // iat in the delete's own second: earlier than the cut-off, refused.
    await expect(users.getAuthenticatedUser(target.id, 'miner', FIXED_SECOND)).rejects.toMatchObject({ code: 'TOKEN_INVALID' });
    // iat equal to the cut-off: allowed, as for a password change's own fresh token.
    await expect(users.getAuthenticatedUser(target.id, 'miner', FIXED_SECOND + 1)).resolves.toMatchObject({ id: target.id });
  });

  it('keeps the username taken, in any letter case, for registration and account creation', async () => {
    const admin = await activeAdmin();
    const target = await ACCOUNT_IN.active();
    await accounts().deleteAccount({ userId: target.id, reason: REASON, adminId: admin.id });

    await expect(
      services().users.register({
        username: target.username.toUpperCase(),
        fullName: 'Someone Else',
        password: TEST_PASSPHRASE,
        role: 'transporter',
      }),
    ).rejects.toMatchObject({ status: 409, code: 'USERNAME_TAKEN' });
    await expect(
      accounts().createAccount({ username: target.username, fullName: 'Someone Else', role: 'officer', actorId: admin.id }),
    ).rejects.toMatchObject({ status: 409, code: 'USERNAME_TAKEN' });
  });
});

describe('history kept after a delete', () => {
  it('keeps the steps and alerts, and reports still name the deleted user', async () => {
    const officer = await insertUser(t.db, { role: 'officer', status: 'active' });
    const admin = await activeAdmin();
    const miner = await insertUser(t.db, { role: 'miner', status: 'active', username: 'deleted_report_miner', public_key: randomBytes(91) });
    const step = await insertTransaction(t.db, { actor_id: miner.id, captured_at: new Date('2026-11-10T08:00:00.000Z') });
    await t.db.query('UPDATE transactions SET received_at = $1 WHERE id = $2', [new Date('2026-11-10T08:05:00.000Z'), step.id]);
    const alert = await insertAlert(t.db, { transaction_id: step.id });

    await accounts().deleteAccount({ userId: miner.id, reason: REASON, adminId: admin.id });

    const { rows: steps } = await t.db.query('SELECT actor_id, signer_public_key FROM transactions WHERE id = $1', [step.id]);
    // The step keeps its own copy of the signing key, so it still verifies (D5).
    expect(steps).toEqual([{ actor_id: miner.id, signer_public_key: step.signer_public_key }]);
    const { rows: alerts } = await t.db.query('SELECT transaction_id FROM alerts WHERE id = $1', [alert.id]);
    expect(alerts).toEqual([{ transaction_id: step.id }]);
    const { rows: consignments } = await t.db.query('SELECT miner_id FROM consignments WHERE id = $1', [step.consignment_id]);
    expect(consignments).toEqual([{ miner_id: miner.id }]);

    const requester = { id: officer.id, role: 'officer' };
    const report = await services().reports.transactions(NOV_10, requester);
    expect(report.rows.find((r) => r.step_id === step.id)).toMatchObject({ actor_username: 'deleted_report_miner', actor_role: 'miner' });
    const trail = await services().reports.auditTrail({ consignmentId: step.consignment_id }, requester);
    expect(trail.rows.find((r) => r.event === 'step_recorded')).toMatchObject({ actor_username: 'deleted_report_miner' });
  });
});

// Two races on real connections, so their rows must commit and are deleted afterwards. The
// audit service is a no-op, because audit_logs is append-only and committed entries could
// never be removed. (The same pattern as zoneService.test.js and anomalyRules.test.js.)
describe('deletes racing other work on real connections', () => {
  let pool;
  let db;
  const noAudit = { record: async () => {} };

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
    db = createDb(pool);
  });
  afterAll(async () => {
    await db.close();
  });

  // A db object on one fixed connection, so the test knows B's backend pid.
  const singleConnection = (client) => ({
    query: (text, params) => client.query(text, params),
    connect: async () => ({ query: (text, params) => client.query(text, params), release: () => {} }),
  });

  // Polls pg_locks until the backend has a lock it is waiting for, and fails the test if that
  // never happens, so "B waited for A" is proven, not assumed.
  async function waitUntilBlocked(pid, timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const { rows } = await db.query('SELECT count(*)::int AS waiting FROM pg_locks WHERE pid = $1 AND NOT granted', [pid]);
      if (rows[0].waiting > 0) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`backend ${pid} never waited on a lock within ${timeoutMs} ms`);
  }

  it('two admins deleting each other at the same moment: the one that waited is refused', async () => {
    const created = [];
    let clientA;
    let clientB;
    let pendingB;
    try {
      // The rule counts every active admin in the database, so a committed admin left by an
      // earlier, interrupted run would change the answer. Say so plainly.
      const { rows: leftover } = await db.query("SELECT count(*)::int AS n FROM users WHERE role = 'admin' AND status = 'active'");
      expect(leftover[0].n, 'minechain_test already has committed active admins; remove them and run again').toBe(0);

      const a = await insertUser(db, { role: 'admin', status: 'active' });
      const b = await insertUser(db, { role: 'admin', status: 'active' });
      created.push(a.id, b.id);

      // A deletes B inside an open transaction and does not commit yet.
      clientA = await pool.connect();
      await clientA.query('BEGIN');
      const serviceA = createAccountService({ db: createDb(clientA, { inTransaction: true }), audit: noAudit });
      const resA = await serviceA.deleteAccount({ userId: b.id, reason: REASON, adminId: a.id });
      expect(resA.status).toBe('deleted');

      // B deletes A on its own connection. Its lock on the active admins must wait for A's.
      clientB = await pool.connect();
      const { rows: pidRows } = await clientB.query('SELECT pg_backend_pid() AS pid');
      const serviceB = createAccountService({ db: createDb(singleConnection(clientB)), audit: noAudit });
      // Caught at once, so the rejection is never left unhandled while the test waits.
      pendingB = serviceB.deleteAccount({ userId: a.id, reason: REASON, adminId: b.id }).then(() => null, (err) => err);
      await waitUntilBlocked(pidRows[0].pid);

      // Only now, with B provably waiting, does A commit.
      await clientA.query('COMMIT');

      expect(await pendingB).toMatchObject({ status: 409, code: 'LAST_ACTIVE_ADMIN' });
      const { rows } = await db.query('SELECT id, status FROM users WHERE id = ANY($1::uuid[]) ORDER BY status', [created]);
      expect(rows).toEqual([
        { id: a.id, status: 'active' },
        { id: b.id, status: 'deleted' },
      ]);
    } finally {
      if (clientA) {
        // Harmless after the COMMIT; undoes A if a check failed before it, which also lets a
        // waiting B go on.
        await clientA.query('ROLLBACK').catch(() => {});
        clientA.release();
      }
      if (pendingB) await pendingB;
      if (clientB) clientB.release();
      await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [created]);
    }
  });

  it('a sync waiting on the delete stores nothing, and answers deferred NO_DEVICE_KEY', async () => {
    const suffix = randomBytes(4).toString('hex');
    const qr = `MC-DELETE-${suffix}`;
    const created = [];
    let clientA;
    let clientB;
    let pendingB;
    try {
      const phone = newPhone();
      const admin = await insertUser(db, { role: 'admin', status: 'active' });
      const miner = await insertUser(db, { role: 'miner', status: 'active', public_key: Buffer.from(phone.spkiBase64, 'base64') });
      created.push(admin.id, miner.id);
      const party = { user: { id: miner.id, role: 'miner' }, phone };

      // A deletes the miner inside an open transaction and does not commit yet.
      clientA = await pool.connect();
      await clientA.query('BEGIN');
      const serviceA = createAccountService({ db: createDb(clientA, { inTransaction: true }), audit: noAudit });
      await serviceA.deleteAccount({ userId: miner.id, reason: REASON, adminId: admin.id });

      // The miner's phone syncs a step signed with its key, on a connection of its own: a
      // request that passed requireAuth before the delete. Its FOR SHARE read of the key must
      // wait for A's lock on the row.
      clientB = await pool.connect();
      const { rows: pidRows } = await clientB.query('SELECT pg_backend_pid() AS pid');
      const serviceB = createSyncService({ db: createDb(singleConnection(clientB)), signatures: createSignatureService(), audit: noAudit });
      pendingB = serviceB.syncSteps(party.user, [stepItem(party, 'registration', qr)]);
      await waitUntilBlocked(pidRows[0].pid);

      await clientA.query('COMMIT');

      const [resB] = await pendingB;
      expect(resB).toMatchObject({ outcome: 'deferred', code: 'NO_DEVICE_KEY' });
      const { rows } = await db.query(
        `SELECT (SELECT count(*)::int FROM consignments WHERE qr_code = $1) AS consignments,
                (SELECT count(*)::int FROM transactions WHERE actor_id = $2) AS steps`,
        [qr, miner.id],
      );
      expect(rows[0]).toEqual({ consignments: 0, steps: 0 });
    } finally {
      if (clientA) {
        await clientA.query('ROLLBACK').catch(() => {});
        clientA.release();
      }
      if (pendingB) await pendingB.catch(() => {});
      if (clientB) clientB.release();
      // Only if the test failed after B stored something; children first (ON DELETE RESTRICT).
      await db.query(
        'DELETE FROM alerts WHERE transaction_id IN (SELECT t.id FROM transactions t JOIN consignments c ON c.id = t.consignment_id WHERE c.qr_code = $1)',
        [qr],
      );
      await db.query('DELETE FROM transactions WHERE consignment_id IN (SELECT id FROM consignments WHERE qr_code = $1)', [qr]);
      await db.query('DELETE FROM consignments WHERE qr_code = $1', [qr]);
      await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [created]);
    }
  });
});
