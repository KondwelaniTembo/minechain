import { describe, it, expect } from 'vitest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createAccountService } from '../../src/services/accountService.js';

const t = useTestDb();

// The real services, as createServices wires them, on the test's own connection.
const accounts = () => createServices({ db: t.db, config: FAKE_CONFIG }).accounts;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.7';

const ADMIN_KEYS = [
  'id', 'username', 'fullName', 'licenceNumber', 'role', 'status', 'statusReason',
  'approvedBy', 'approvedAt', 'createdAt', 'updatedAt',
].sort();

const activeAdmin = (overrides = {}) => insertUser(t.db, { role: 'admin', status: 'active', ...overrides });
const pendingUser = (overrides = {}) => insertUser(t.db, { role: 'miner', status: 'pending', ...overrides });
const activeUser = (overrides = {}) => insertUser(t.db, { role: 'miner', status: 'active', ...overrides });
const suspendedUser = (overrides = {}) =>
  insertUser(t.db, { role: 'miner', status: 'suspended', status_reason: 'Lost device reported', ...overrides });
const rejectedUser = (overrides = {}) =>
  insertUser(t.db, { role: 'miner', status: 'rejected', status_reason: 'Licence not found', ...overrides });

async function row(id) {
  const { rows } = await t.db.query(
    'SELECT status, status_reason, approved_by, approved_at FROM users WHERE id = $1',
    [id],
  );
  return rows[0];
}

async function auditFor(id) {
  const { rows } = await t.db.query(
    `SELECT actor_id, action, entity_type, entity_id, details, ip_address
       FROM audit_logs WHERE entity_id = $1 ORDER BY id`,
    [id],
  );
  return rows;
}

// Every refused action must leave the row and the audit log exactly as they were.
// Takes a function that starts the action, not a promise that is already running: the
// snapshot must be taken first, and a promise that rejects at once (CANNOT_SUSPEND_SELF
// is thrown before any SQL) would sit unhandled while the snapshot query ran, which
// Vitest reports as an unhandled rejection. Starting it only once .rejects is attached
// means a handler is always there.
async function expectRefused(startAction, { status, code }, target) {
  const before = await row(target.id);
  await expect(startAction()).rejects.toMatchObject({ status, code });
  expect(await row(target.id)).toEqual(before);
  expect(await auditFor(target.id)).toEqual([]);
}

describe('list', () => {
  it('returns only the requested status, oldest request first', async () => {
    const newer = await pendingUser();
    const older = await pendingUser();
    await activeUser();
    // Inside one transaction now() never moves, so the dates are set by hand.
    await t.db.query('UPDATE users SET created_at = $1 WHERE id = $2', ['2026-11-01T08:00:00Z', older.id]);
    await t.db.query('UPDATE users SET created_at = $1 WHERE id = $2', ['2026-11-02T08:00:00Z', newer.id]);

    const result = await accounts().list({ status: 'pending', limit: 20, offset: 0 });

    expect(result.users.map((u) => u.id)).toEqual([older.id, newer.id]);
    expect(result).toMatchObject({ total: 2, limit: 20, offset: 0 });
  });

  it('returns exactly the admin columns, never the hash, actor_ref or public key', async () => {
    await pendingUser({ public_key: Buffer.alloc(91, 1) });

    const { users } = await accounts().list({ status: 'pending', limit: 20, offset: 0 });

    expect(Object.keys(users[0]).sort()).toEqual(ADMIN_KEYS);
    const text = JSON.stringify(users);
    expect(text).not.toContain('argon2');
    expect(text).not.toMatch(/password|actor_?ref|public_?key/i);
  });

  it('pages with limit and offset, while total counts every match', async () => {
    const ids = [];
    for (let day = 1; day <= 5; day += 1) {
      const user = await pendingUser();
      await t.db.query('UPDATE users SET created_at = $1 WHERE id = $2', [`2026-11-0${day}T08:00:00Z`, user.id]);
      ids.push(user.id);
    }

    const page = await accounts().list({ status: 'pending', limit: 2, offset: 2 });

    expect(page.users.map((u) => u.id)).toEqual(ids.slice(2, 4));
    expect(page.total).toBe(5);
  });

  it('returns an empty page past the end, with the real total', async () => {
    await pendingUser();

    const page = await accounts().list({ status: 'pending', limit: 20, offset: 40 });

    expect(page).toEqual({ users: [], total: 1, limit: 20, offset: 40 });
  });

  it('shows the status reason to administrators', async () => {
    await suspendedUser({ status_reason: 'Under investigation' });

    const { users } = await accounts().list({ status: 'suspended', limit: 20, offset: 0 });

    expect(users[0].statusReason).toBe('Under investigation');
  });
});

describe('approve', () => {
  it.each(['miner', 'transporter', 'buyer'])('makes a pending %s active and records who approved it', async (role) => {
    const admin = await activeAdmin();
    const target = await pendingUser({ role });

    const user = await accounts().approve({ targetId: target.id, actorId: admin.id, ipAddress: IP });

    expect(user).toMatchObject({ id: target.id, role, status: 'active', approvedBy: admin.id, statusReason: null });
    expect(user.approvedAt).toBeInstanceOf(Date);
    const stored = await row(target.id);
    expect(stored).toMatchObject({ status: 'active', approved_by: admin.id });
    expect(stored.approved_at).toBeInstanceOf(Date);
  });

  it('writes one audit entry with the admin as actor', async () => {
    const admin = await activeAdmin();
    const target = await pendingUser();

    await accounts().approve({ targetId: target.id, actorId: admin.id, ipAddress: IP });

    expect(await auditFor(target.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'user.approve',
        entity_type: 'user',
        entity_id: target.id,
        details: { from: 'pending', to: 'active' },
        ip_address: IP,
      },
    ]);
  });

  it.each([
    ['active', activeUser],
    ['suspended', suspendedUser],
    ['rejected (rejected is final)', rejectedUser],
  ])('refuses an account that is %s', async (_label, make) => {
    const admin = await activeAdmin();
    const target = await make();

    await expectRefused(
      () => accounts().approve({ targetId: target.id, actorId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      target,
    );
  });

  it.each(['officer', 'admin'])('refuses a pending %s', async (role) => {
    const admin = await activeAdmin();
    const target = await pendingUser({ role });

    await expectRefused(
      () => accounts().approve({ targetId: target.id, actorId: admin.id }),
      { status: 409, code: 'ROLE_NOT_APPROVABLE' },
      target,
    );
  });

  it('refuses an id that matches no user', async () => {
    const admin = await activeAdmin();

    await expect(accounts().approve({ targetId: MISSING_ID, actorId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'USER_NOT_FOUND',
    });
  });

  it('lets only the first of two approvals win', async () => {
    // The sequential version of two admins clicking at once. The concurrent version rests
    // on the UPDATE's own WHERE and row lock; it would need real commits to test.
    const first = await activeAdmin();
    const second = await activeAdmin();
    const target = await pendingUser();

    await accounts().approve({ targetId: target.id, actorId: first.id });
    await expect(accounts().approve({ targetId: target.id, actorId: second.id })).rejects.toMatchObject({
      status: 409,
      code: 'INVALID_STATUS_TRANSITION',
    });

    expect((await row(target.id)).approved_by).toBe(first.id);
    expect(await auditFor(target.id)).toHaveLength(1);
  });

  it('accepts the id in capitals and records it in its usual form', async () => {
    const admin = await activeAdmin();
    const target = await pendingUser();

    await accounts().approve({ targetId: target.id.toUpperCase(), actorId: admin.id });

    expect((await row(target.id)).status).toBe('active');
    expect((await auditFor(target.id))[0].entity_id).toBe(target.id);
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const target = await pendingUser();
    const failingAudit = {
      record: async () => {
        throw new Error('audit unavailable');
      },
    };
    const service = createAccountService({ db: t.db, audit: failingAudit });

    await expect(service.approve({ targetId: target.id, actorId: admin.id })).rejects.toThrow('audit unavailable');

    // The UPDATE ran, but it was rolled back with the failed entry.
    expect((await row(target.id)).status).toBe('pending');
  });
});

describe('reject', () => {
  it('rejects a pending request with its reason, and records the reason', async () => {
    const admin = await activeAdmin();
    const target = await pendingUser();

    const user = await accounts().reject({
      targetId: target.id,
      actorId: admin.id,
      reason: 'Licence number could not be verified',
      ipAddress: IP,
    });

    expect(user).toMatchObject({ status: 'rejected', statusReason: 'Licence number could not be verified', approvedBy: null });
    const [entry] = await auditFor(target.id);
    expect(entry).toMatchObject({
      actor_id: admin.id,
      action: 'user.reject',
      details: { from: 'pending', to: 'rejected', reason: 'Licence number could not be verified' },
    });
  });

  it.each([
    ['active', activeUser],
    ['suspended', suspendedUser],
    ['already rejected', rejectedUser],
  ])('refuses an account that is %s', async (_label, make) => {
    const admin = await activeAdmin();
    const target = await make();

    await expectRefused(
      () => accounts().reject({ targetId: target.id, actorId: admin.id, reason: 'Duplicate request' }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      target,
    );
  });

  it.each(['officer', 'admin'])('refuses a pending %s', async (role) => {
    const admin = await activeAdmin();
    const target = await pendingUser({ role });

    await expectRefused(
      () => accounts().reject({ targetId: target.id, actorId: admin.id, reason: 'Duplicate request' }),
      { status: 409, code: 'ROLE_NOT_APPROVABLE' },
      target,
    );
  });

  it('leaves a rejected account with no way out', async () => {
    const admin = await activeAdmin();
    const target = await pendingUser();
    await accounts().reject({ targetId: target.id, actorId: admin.id, reason: 'Duplicate request' });

    for (const action of ['approve', 'reactivate']) {
      await expect(accounts()[action]({ targetId: target.id, actorId: admin.id })).rejects.toMatchObject({
        status: 409,
        code: 'INVALID_STATUS_TRANSITION',
      });
    }
    await expect(
      accounts().suspend({ targetId: target.id, actorId: admin.id, reason: 'Duplicate request' }),
    ).rejects.toMatchObject({ status: 409, code: 'INVALID_STATUS_TRANSITION' });
  });

  it('refuses an id that matches no user', async () => {
    const admin = await activeAdmin();

    await expect(
      accounts().reject({ targetId: MISSING_ID, actorId: admin.id, reason: 'Duplicate request' }),
    ).rejects.toMatchObject({ status: 404, code: 'USER_NOT_FOUND' });
  });
});

describe('suspend', () => {
  it.each(['miner', 'transporter', 'buyer', 'officer'])('suspends an active %s with a reason', async (role) => {
    const admin = await activeAdmin();
    const target = await activeUser({ role });

    const user = await accounts().suspend({
      targetId: target.id,
      actorId: admin.id,
      reason: 'Lost device reported',
      ipAddress: IP,
    });

    expect(user).toMatchObject({ role, status: 'suspended', statusReason: 'Lost device reported' });
    expect(await auditFor(target.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'user.suspend',
        entity_type: 'user',
        entity_id: target.id,
        details: { from: 'active', to: 'suspended', reason: 'Lost device reported' },
        ip_address: IP,
      },
    ]);
  });

  it.each([
    ['pending', pendingUser],
    ['already suspended', suspendedUser],
    ['rejected', rejectedUser],
  ])('refuses an account that is %s', async (_label, make) => {
    const admin = await activeAdmin();
    const target = await make();

    await expectRefused(
      () => accounts().suspend({ targetId: target.id, actorId: admin.id, reason: 'Under investigation' }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      target,
    );
  });

  it('refuses an id that matches no user', async () => {
    const admin = await activeAdmin();

    await expect(
      accounts().suspend({ targetId: MISSING_ID, actorId: admin.id, reason: 'Under investigation' }),
    ).rejects.toMatchObject({ status: 404, code: 'USER_NOT_FOUND' });
  });

  describe('administrators', () => {
    it('refuses an admin suspending themselves, even with another admin present', async () => {
      const admin = await activeAdmin();
      await activeAdmin();

      await expectRefused(
        () => accounts().suspend({ targetId: admin.id, actorId: admin.id, reason: 'Testing' }),
        { status: 403, code: 'CANNOT_SUSPEND_SELF' },
        admin,
      );
    });

    it('refuses their own id written in capitals', async () => {
      // Without normalising, the string comparison would miss this while the UPDATE,
      // which compares uuids, would still find the row.
      const admin = await activeAdmin();
      await activeAdmin();

      await expectRefused(
        () => accounts().suspend({ targetId: admin.id.toUpperCase(), actorId: admin.id, reason: 'Testing' }),
        { status: 403, code: 'CANNOT_SUSPEND_SELF' },
        admin,
      );
    });

    it('lets one admin suspend another when two are active', async () => {
      const first = await activeAdmin();
      const second = await activeAdmin();

      const user = await accounts().suspend({ targetId: second.id, actorId: first.id, reason: 'Left the project' });

      expect(user.status).toBe('suspended');
    });

    it('can go down to one active admin, never to none', async () => {
      const a = await activeAdmin();
      const b = await activeAdmin();
      const c = await activeAdmin();

      await accounts().suspend({ targetId: b.id, actorId: a.id, reason: 'Left the project' });
      await accounts().suspend({ targetId: c.id, actorId: a.id, reason: 'Left the project' });

      // a is now the only active admin. Nobody else can act as an admin, and a cannot
      // suspend themselves.
      const { rows } = await t.db.query("SELECT id FROM users WHERE role = 'admin' AND status = 'active'");
      expect(rows.map((r) => r.id)).toEqual([a.id]);
      await expect(accounts().suspend({ targetId: a.id, actorId: a.id, reason: 'Testing' })).rejects.toMatchObject({
        code: 'CANNOT_SUSPEND_SELF',
      });
    });

    it('refuses to suspend the last active admin when the actor is no longer active', async () => {
      // What the second of two admins suspending each other at the same moment sees: a was
      // suspended by b a moment ago, and a's request to suspend b arrives afterwards.
      const a = await activeAdmin();
      const b = await activeAdmin();
      await t.db.query("UPDATE users SET status = 'suspended', status_reason = 'Suspended by b' WHERE id = $1", [a.id]);

      await expectRefused(
        () => accounts().suspend({ targetId: b.id, actorId: a.id, reason: 'Suspended by a' }),
        { status: 409, code: 'LAST_ACTIVE_ADMIN' },
        b,
      );
    });

    it('still lets a non-admin be suspended when only one admin exists', async () => {
      const admin = await activeAdmin();
      const target = await activeUser();

      const user = await accounts().suspend({ targetId: target.id, actorId: admin.id, reason: 'Under investigation' });

      expect(user.status).toBe('suspended');
    });
  });
});

describe('reactivate', () => {
  it('makes a suspended account active, clears the reason and keeps the original approval', async () => {
    const admin = await activeAdmin();
    const approver = await activeAdmin();
    const approvedAt = new Date('2026-11-02T09:00:00Z');
    const target = await suspendedUser({ approved_by: approver.id, approved_at: approvedAt });

    const user = await accounts().reactivate({ targetId: target.id, actorId: admin.id, ipAddress: IP });

    expect(user).toMatchObject({ status: 'active', statusReason: null, approvedBy: approver.id, approvedAt });
    expect(await row(target.id)).toEqual({
      status: 'active',
      status_reason: null,
      approved_by: approver.id,
      approved_at: approvedAt,
    });
  });

  it('writes an audit entry without a reason', async () => {
    const admin = await activeAdmin();
    const target = await suspendedUser();

    await accounts().reactivate({ targetId: target.id, actorId: admin.id, ipAddress: IP });

    const [entry] = await auditFor(target.id);
    expect(entry).toMatchObject({ actor_id: admin.id, action: 'user.reactivate', ip_address: IP });
    expect(entry.details).toEqual({ from: 'suspended', to: 'active' });
  });

  it('keeps the suspension reason in the audit log after clearing it from the account', async () => {
    const admin = await activeAdmin();
    const target = await activeUser();

    await accounts().suspend({ targetId: target.id, actorId: admin.id, reason: 'Lost device reported' });
    await accounts().reactivate({ targetId: target.id, actorId: admin.id });

    expect((await row(target.id)).status_reason).toBeNull();
    const entries = await auditFor(target.id);
    expect(entries.map((e) => e.action)).toEqual(['user.suspend', 'user.reactivate']);
    expect(entries[0].details.reason).toBe('Lost device reported');
  });

  it.each([
    ['pending', pendingUser],
    ['active', activeUser],
    ['rejected (rejected is final)', rejectedUser],
  ])('refuses an account that is %s', async (_label, make) => {
    const admin = await activeAdmin();
    const target = await make();

    await expectRefused(
      () => accounts().reactivate({ targetId: target.id, actorId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      target,
    );
  });

  it('refuses an id that matches no user', async () => {
    const admin = await activeAdmin();

    await expect(accounts().reactivate({ targetId: MISSING_ID, actorId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'USER_NOT_FOUND',
    });
  });
});
