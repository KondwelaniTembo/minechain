import { randomUUID } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { MISSING_ID, insertUser, insertConsignment, insertAudit, auditInsert } from './fixtures.js';

const t = useTestDb();

const audit = (overrides) => insertAudit(t.db, overrides);

async function expectAuditRejected(overrides, code) {
  const { text, params } = auditInsert(overrides);
  return expectPgError(t.db, text, params, code);
}

// Every reject test names the rule expected to fire.
async function expectCheckFails(overrides, constraint) {
  const err = await expectAuditRejected(overrides, PG_ERROR.CHECK_VIOLATION);
  expect(err.constraint).toBe(constraint);
}

describe('audit_logs table', () => {
  it('fills in id, occurred_at and empty details', async () => {
    const { rows } = await t.db.query('INSERT INTO audit_logs (action) VALUES ($1) RETURNING *', ['system.start']);

    // bigint arrives as a string, so it is checked as digits, not as a number.
    expect(rows[0].id).toMatch(/^\d+$/);
    expect(rows[0].occurred_at).toBeInstanceOf(Date);
    expect(rows[0].details).toEqual({});
  });

  describe('identity id', () => {
    it('gives a later entry a larger id', async () => {
      const first = await audit();
      const second = await audit();

      // Compared as BigInt; comparing the strings would put "10" before "9".
      expect(BigInt(second.id) > BigInt(first.id)).toBe(true);
    });

    it('refuses an id supplied by hand', async () => {
      await expectPgError(
        t.db,
        'INSERT INTO audit_logs (id, action) VALUES ($1, $2)',
        ['1', 'user.login'],
        PG_ERROR.GENERATED_ALWAYS,
      );
    });
  });

  describe('action', () => {
    it.each(['user.login', 'alert.dismiss', 'consignment.register'])('accepts %s', async (action) => {
      expect((await audit({ action })).action).toBe(action);
    });

    it.each(['Login', 'user.', 'user login', 'user.login.extra', ''])('rejects "%s"', async (action) => {
      await expectCheckFails({ action }, 'audit_logs_action_format');
    });
  });

  describe('entity reference', () => {
    it('accepts an entry about nothing in particular', async () => {
      const entry = await audit();

      expect(entry.entity_type).toBeNull();
      expect(entry.entity_id).toBeNull();
    });

    it('accepts an entry about a real consignment', async () => {
      const consignment = await insertConsignment(t.db);

      const entry = await audit({ action: 'consignment.register', entity_type: 'consignment', entity_id: consignment.id });

      expect(entry.entity_id).toBe(consignment.id);
    });

    it('accepts an id that matches no row, because there is no foreign key', async () => {
      const entry = await audit({ action: 'transaction.sync', entity_type: 'transaction', entity_id: randomUUID() });

      expect(entry.entity_type).toBe('transaction');
    });

    it.each([
      ['a type without an id', { entity_type: 'consignment' }, 'audit_logs_entity_complete'],
      ['an id without a type', { entity_id: MISSING_ID }, 'audit_logs_entity_complete'],
      ['an unknown type', { entity_type: 'invoice', entity_id: MISSING_ID }, 'audit_logs_entity_type_valid'],
    ])('rejects %s', async (_label, overrides, constraint) => {
      await expectCheckFails(overrides, constraint);
    });
  });

  describe('actor', () => {
    it('accepts a system entry with no actor', async () => {
      expect((await audit({ action: 'system.start' })).actor_id).toBeNull();
    });

    it('rejects an actor who does not exist', async () => {
      const err = await expectAuditRejected({ actor_id: MISSING_ID }, PG_ERROR.FOREIGN_KEY_VIOLATION);

      expect(err.constraint).toBe('audit_logs_actor_id_fkey');
    });

    it('refuses to delete a user who has log entries', async () => {
      const user = await insertUser(t.db);
      await audit({ actor_id: user.id });

      const err = await expectPgError(t.db, 'DELETE FROM users WHERE id = $1', [user.id], PG_ERROR.RESTRICT_VIOLATION);
      expect(err.constraint).toBe('audit_logs_actor_id_fkey');
    });
  });

  describe('ip_address and details', () => {
    it.each(['196.46.10.7', '2001:db8::1'])('accepts the address %s', async (ip_address) => {
      // pg returns inet as a string.
      expect((await audit({ ip_address })).ip_address).toBe(ip_address);
    });

    it('rejects text that is not an IP address before any CHECK runs', async () => {
      await expectAuditRejected({ ip_address: 'not-an-ip' }, PG_ERROR.INVALID_TEXT_REPRESENTATION);
    });

    it('accepts details as an object', async () => {
      expect((await audit({ details: { method: 'password' } })).details).toEqual({ method: 'password' });
    });

    it('rejects details as an array', async () => {
      await expectCheckFails({ details: ['password'] }, 'audit_logs_details_is_object');
    });
  });

  describe('append-only', () => {
    it('refuses UPDATE and leaves the row unchanged', async () => {
      const entry = await audit({ action: 'user.login' });

      const err = await expectPgError(
        t.db,
        "UPDATE audit_logs SET action = 'user.logout' WHERE id = $1",
        [entry.id],
        PG_ERROR.RAISED_EXCEPTION,
      );

      expect(err.message).toBe('audit_logs is append-only: UPDATE is not allowed');
      expect(err.hint).toMatch(/new audit entry/);
      const { rows } = await t.db.query('SELECT action FROM audit_logs WHERE id = $1', [entry.id]);
      expect(rows[0].action).toBe('user.login');
    });

    it('refuses an UPDATE even when it matches no rows (statement-level trigger)', async () => {
      const err = await expectPgError(
        t.db,
        "UPDATE audit_logs SET action = 'user.logout' WHERE id = $1",
        ['-1'],
        PG_ERROR.RAISED_EXCEPTION,
      );

      expect(err.message).toMatch(/UPDATE is not allowed/);
    });

    it('refuses DELETE and keeps the row', async () => {
      const entry = await audit();

      const err = await expectPgError(t.db, 'DELETE FROM audit_logs WHERE id = $1', [entry.id], PG_ERROR.RAISED_EXCEPTION);

      expect(err.message).toBe('audit_logs is append-only: DELETE is not allowed');
      const { rowCount } = await t.db.query('SELECT 1 FROM audit_logs WHERE id = $1', [entry.id]);
      expect(rowCount).toBe(1);
    });

    it('refuses TRUNCATE', async () => {
      await audit();

      const err = await expectPgError(t.db, 'TRUNCATE audit_logs', [], PG_ERROR.RAISED_EXCEPTION);

      expect(err.message).toBe('audit_logs is append-only: TRUNCATE is not allowed');
      const { rows } = await t.db.query('SELECT count(*)::int AS n FROM audit_logs');
      expect(rows[0].n).toBeGreaterThan(0);
    });

    it('still accepts new entries after refused changes', async () => {
      const entry = await audit();
      await expectPgError(t.db, 'DELETE FROM audit_logs WHERE id = $1', [entry.id], PG_ERROR.RAISED_EXCEPTION);

      const correction = await audit({ action: 'audit.correct', details: { corrects: entry.id } });

      expect(BigInt(correction.id) > BigInt(entry.id)).toBe(true);
    });

    // Records the honest limit instead of hiding it. The test runs as the table owner, which
    // is also how the app connects today. DDL is transactional in PostgreSQL, so the
    // trigger is back as soon as this test's transaction rolls back.
    it('LIMIT: the table owner can disable the trigger and then change rows', async () => {
      const entry = await audit({ action: 'user.login' });

      await t.db.query('ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_no_update_or_delete');
      const { rowCount } = await t.db.query("UPDATE audit_logs SET action = 'user.logout' WHERE id = $1", [entry.id]);

      expect(rowCount).toBe(1);
    });
  });
});
