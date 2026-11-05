import { describe, it, expect } from 'vitest';
import { useTestDb, PG_ERROR } from './helpers.js';
import { insertUser } from './fixtures.js';
import { createAuditService } from '../../src/services/auditService.js';

const t = useTestDb();
const audit = createAuditService();

const findEntry = async (id) => (await t.db.query('SELECT * FROM audit_logs WHERE id = $1', [id])).rows[0];

describe('auditService.record against PostgreSQL', () => {
  it('writes every field and returns the new id as a string', async () => {
    const user = await insertUser(t.db);

    const { id, occurredAt } = await audit.record(t.db, {
      action: 'user.register',
      actorId: user.id,
      entityType: 'user',
      entityId: user.id,
      details: { role: 'miner' },
      ipAddress: '196.46.10.7',
    });

    expect(id).toMatch(/^\d+$/);
    expect(occurredAt).toBeInstanceOf(Date);
    const row = await findEntry(id);
    expect(row).toMatchObject({
      actor_id: user.id,
      action: 'user.register',
      entity_type: 'user',
      entity_id: user.id,
      details: { role: 'miner' },
      ip_address: '196.46.10.7',
    });
  });

  it('writes a system entry with no actor or entity', async () => {
    const { id } = await audit.record(t.db, { action: 'system.start' });

    expect(await findEntry(id)).toMatchObject({ actor_id: null, entity_type: null, details: {} });
  });

  it('accepts the address Express reports for a local IPv4 client', async () => {
    const { id } = await audit.record(t.db, { action: 'user.login', ipAddress: '::ffff:127.0.0.1' });

    expect((await findEntry(id)).ip_address).toBe('::ffff:127.0.0.1');
  });

  it('is undone together with the rest of its transaction', async () => {
    let entryId;
    let userId;

    await expect(
      t.db.transaction(async (tx) => {
        const user = await insertUser(tx);
        userId = user.id;
        ({ id: entryId } = await audit.record(tx, { action: 'user.register', actorId: user.id, entityType: 'user', entityId: user.id }));
        throw new Error('something after the audit entry failed');
      }),
    ).rejects.toThrow();

    // Rolling back is not a DELETE, so the append-only trigger does not stop it.
    expect(await findEntry(entryId)).toBeUndefined();
    expect((await t.db.query('SELECT 1 FROM users WHERE id = $1', [userId])).rowCount).toBe(0);
  });

  it.each([
    ['an action in the wrong format', { action: 'UserLogin' }, PG_ERROR.CHECK_VIOLATION],
    ['an invalid IP address', { action: 'user.login', ipAddress: 'not-an-ip' }, PG_ERROR.INVALID_TEXT_REPRESENTATION],
  ])('passes on the database error for %s', async (_label, entry, code) => {
    // Inside db.transaction, so the failed insert rolls back to a savepoint and the test's
    // own transaction stays usable.
    const err = await t.db.transaction((tx) => audit.record(tx, entry)).catch((e) => e);

    expect(err.code).toBe(code);
    const { rows } = await t.db.query('SELECT 1 AS ok');
    expect(rows[0].ok).toBe(1);
  });
});
