import { readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, SAMPLE_BOUNDARY, insertUser, insertZone, insertTransaction } from './fixtures.js';
import { createPool, createDb } from '../../src/db.js';
import { createServices } from '../../src/services/index.js';
import { createZoneService, NO_ACTIVE_ZONES_WARNING } from '../../src/services/zoneService.js';

const t = useTestDb();

// The real services, as createServices wires them, on the test's own connection.
const zones = () => createServices({ db: t.db, config: FAKE_CONFIG }).zones;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.7';
const REASON = 'Licence revoked by the Mines Cadastre';

const ZONE_KEYS = ['id', 'name', 'licenceNumber', 'status', 'boundary', 'createdBy', 'createdAt', 'updatedAt'].sort();

const failingAudit = {
  record: async () => {
    throw new Error('audit unavailable');
  },
};

const activeAdmin = () => insertUser(t.db, { role: 'admin', status: 'active' });

async function zoneRow(id) {
  const { rows } = await t.db.query('SELECT name, licence_number, boundary, status FROM gps_zones WHERE id = $1', [id]);
  return rows[0];
}

async function auditFor(id) {
  const { rows } = await t.db.query(
    `SELECT actor_id, action, entity_type, entity_id, details, host(ip_address) AS ip
       FROM audit_logs WHERE entity_id = $1 ORDER BY id`,
    [id],
  );
  return rows;
}

const zoneCount = async () => (await t.db.query('SELECT count(*)::int AS n FROM gps_zones')).rows[0].n;
const auditCount = async () => (await t.db.query('SELECT count(*)::int AS n FROM audit_logs')).rows[0].n;

// Every refused action must leave the zone and the audit log exactly as they were.
// Takes a function that starts the action, not a promise already running, so the snapshot
// is taken first and the rejection always has a handler (the working rule for refusal tests).
async function expectRefused(startAction, { status, code }, zone) {
  const before = await zoneRow(zone.id);
  const auditsBefore = await auditCount();
  const err = await startAction().then(
    () => {
      throw new Error('expected the action to be refused');
    },
    (e) => e,
  );
  expect(err).toMatchObject({ status, code });
  expect(await zoneRow(zone.id)).toEqual(before);
  expect(await auditCount()).toBe(auditsBefore);
  return err;
}

describe('list', () => {
  it('returns only the requested status, ordered by name ignoring letter case', async () => {
    await insertZone(t.db, { name: 'Charlie' });
    await insertZone(t.db, { name: 'alpha' });
    await insertZone(t.db, { name: 'Bravo' });
    await insertZone(t.db, { name: 'Delta (old)', status: 'inactive' });

    const result = await zones().list({ status: 'active', limit: 20, offset: 0 });

    expect(result.zones.map((z) => z.name)).toEqual(['alpha', 'Bravo', 'Charlie']);
    expect(result).toMatchObject({ total: 3, limit: 20, offset: 0 });
  });

  it('lists inactive zones when asked', async () => {
    await insertZone(t.db, { name: 'Active one' });
    await insertZone(t.db, { name: 'Old one', status: 'inactive' });

    const { zones: list } = await zones().list({ status: 'inactive', limit: 20, offset: 0 });

    expect(list.map((z) => z.name)).toEqual(['Old one']);
  });

  it('returns exactly the zone view, with the boundary as [lat, lng] pairs', async () => {
    const zone = await insertZone(t.db, { name: 'Kasempa North', licence_number: 'DEMO-LML-0001' });

    const { zones: list } = await zones().list({ status: 'active', limit: 20, offset: 0 });

    expect(Object.keys(list[0]).sort()).toEqual(ZONE_KEYS);
    expect(list[0]).toMatchObject({
      id: zone.id,
      name: 'Kasempa North',
      licenceNumber: 'DEMO-LML-0001',
      status: 'active',
      boundary: SAMPLE_BOUNDARY,
      createdBy: zone.created_by,
    });
  });

  it('pages with limit and offset, while total counts every match', async () => {
    for (const name of ['Zone A', 'Zone B', 'Zone C', 'Zone D', 'Zone E']) await insertZone(t.db, { name });

    const page = await zones().list({ status: 'active', limit: 2, offset: 2 });

    expect(page.zones.map((z) => z.name)).toEqual(['Zone C', 'Zone D']);
    expect(page.total).toBe(5);
  });

  it('returns an empty page past the end, with the real total', async () => {
    await insertZone(t.db);

    expect(await zones().list({ status: 'active', limit: 20, offset: 40 })).toEqual({ zones: [], total: 1, limit: 20, offset: 40 });
  });
});

describe('create', () => {
  it('creates an active zone owned by the admin, and records who did it', async () => {
    const admin = await activeAdmin();

    const zone = await zones().create({ name: 'Kasempa North', boundary: SAMPLE_BOUNDARY, actorId: admin.id, ipAddress: IP });

    expect(zone).toMatchObject({ name: 'Kasempa North', licenceNumber: null, status: 'active', boundary: SAMPLE_BOUNDARY, createdBy: admin.id });
    expect(await zoneRow(zone.id)).toEqual({ name: 'Kasempa North', licence_number: null, boundary: SAMPLE_BOUNDARY, status: 'active' });
    expect(await auditFor(zone.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'gps_zone.create',
        entity_type: 'gps_zone',
        entity_id: zone.id,
        details: { name: 'Kasempa North', licenceNumber: null, cornerCount: 3 },
        ip: IP,
      },
    ]);
  });

  it('stores and records the licence number', async () => {
    const admin = await activeAdmin();

    const zone = await zones().create({ name: 'Kasempa North', licenceNumber: 'DEMO-LML-0001', boundary: SAMPLE_BOUNDARY, actorId: admin.id });

    expect(zone.licenceNumber).toBe('DEMO-LML-0001');
    expect((await auditFor(zone.id))[0].details.licenceNumber).toBe('DEMO-LML-0001');
  });

  it.each([
    ['an active zone, in another letter case', 'active'],
    ['an INACTIVE zone, in another letter case', 'inactive'],
  ])('refuses a name already used by %s, writing nothing', async (_label, status) => {
    const admin = await activeAdmin();
    await insertZone(t.db, { name: 'Kasempa North', status });
    const zonesBefore = await zoneCount();
    const auditsBefore = await auditCount();

    await expect(zones().create({ name: 'KASEMPA north', boundary: SAMPLE_BOUNDARY, actorId: admin.id })).rejects.toMatchObject({
      status: 409,
      code: 'ZONE_NAME_TAKEN',
    });

    expect(await zoneCount()).toBe(zonesBefore);
    expect(await auditCount()).toBe(auditsBefore);
  });

  it('saves nothing when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const service = createZoneService({ db: t.db, audit: failingAudit });

    await expect(service.create({ name: 'Kasempa North', boundary: SAMPLE_BOUNDARY, actorId: admin.id })).rejects.toThrow('audit unavailable');

    // The INSERT ran, but it was rolled back with the failed entry.
    expect(await zoneCount()).toBe(0);
  });
});

describe('rename', () => {
  it('renames the zone and records the old and new names', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });

    const renamed = await zones().rename({ zoneId: zone.id, name: 'Kasempa North (until Nov 2026)', actorId: admin.id, ipAddress: IP });

    expect(renamed).toMatchObject({ id: zone.id, name: 'Kasempa North (until Nov 2026)', status: 'active' });
    expect((await zoneRow(zone.id)).name).toBe('Kasempa North (until Nov 2026)');
    expect(await auditFor(zone.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'gps_zone.rename',
        entity_type: 'gps_zone',
        entity_id: zone.id,
        details: { from: 'Kasempa North', to: 'Kasempa North (until Nov 2026)' },
        ip: IP,
      },
    ]);
  });

  it('allows a change of letter case only, and records it', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'kasempa north' });

    const renamed = await zones().rename({ zoneId: zone.id, name: 'Kasempa North', actorId: admin.id });

    expect(renamed.name).toBe('Kasempa North');
    expect((await auditFor(zone.id)).map((a) => a.details)).toEqual([{ from: 'kasempa north', to: 'Kasempa North' }]);
  });

  it('writes nothing and records nothing when the name is exactly the same', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    // Records every statement, to prove no UPDATE was sent at all.
    const sent = [];
    const recording = (db) => ({
      query: (text, params) => {
        sent.push(text.trim().split(/\s+/)[0]);
        return db.query(text, params);
      },
      transaction: (fn) => db.transaction((tx) => fn(recording(tx))),
    });
    const service = createZoneService({ db: recording(t.db), audit: failingAudit });

    const result = await service.rename({ zoneId: zone.id, name: 'Kasempa North', actorId: admin.id });

    expect(result).toMatchObject({ id: zone.id, name: 'Kasempa North' });
    // Only the locking SELECT; a failing audit service also proves no entry was attempted.
    expect(sent).toEqual(['SELECT']);
    expect(await auditFor(zone.id)).toEqual([]);
  });

  it('renames an inactive zone, which frees its name for a replacement', async () => {
    const admin = await activeAdmin();
    const old = await insertZone(t.db, { name: 'Kasempa North', status: 'inactive' });

    await zones().rename({ zoneId: old.id, name: 'Kasempa North (old)', actorId: admin.id });
    const replacement = await zones().create({ name: 'Kasempa North', boundary: SAMPLE_BOUNDARY, actorId: admin.id });

    expect((await zoneRow(old.id)).status).toBe('inactive');
    expect(replacement.name).toBe('Kasempa North');
  });

  it('accepts the id in capitals and records it in lower case', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });

    await zones().rename({ zoneId: zone.id.toUpperCase(), name: 'Kasempa South', actorId: admin.id });

    expect((await auditFor(zone.id)).map((a) => a.entity_id)).toEqual([zone.id]);
  });

  it('refuses an unknown zone with ZONE_NOT_FOUND', async () => {
    const admin = await activeAdmin();

    await expect(zones().rename({ zoneId: MISSING_ID, name: 'Anything', actorId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'ZONE_NOT_FOUND',
    });
  });

  it.each([
    ['an active zone', 'active'],
    ['an INACTIVE zone', 'inactive'],
  ])('refuses a name already used by %s in another letter case, changing nothing', async (_label, status) => {
    const admin = await activeAdmin();
    await insertZone(t.db, { name: 'Kasempa South', status });
    const zone = await insertZone(t.db, { name: 'Kasempa North' });

    await expectRefused(
      () => zones().rename({ zoneId: zone.id, name: 'kasempa SOUTH', actorId: admin.id }),
      { status: 409, code: 'ZONE_NAME_TAKEN' },
      zone,
    );
  });

  it('keeps the old name when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    const service = createZoneService({ db: t.db, audit: failingAudit });

    await expect(service.rename({ zoneId: zone.id, name: 'Kasempa South', actorId: admin.id })).rejects.toThrow('audit unavailable');

    expect((await zoneRow(zone.id)).name).toBe('Kasempa North');
  });
});

describe('deactivate', () => {
  it('deactivates with no warning while another zone stays active, and records the reason', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    await insertZone(t.db, { name: 'Kasempa South' });

    const result = await zones().deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id, ipAddress: IP });

    expect(result.warning).toBeNull();
    expect(result.zone).toMatchObject({ id: zone.id, status: 'inactive' });
    expect((await zoneRow(zone.id)).status).toBe('inactive');
    expect(await auditFor(zone.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'gps_zone.deactivate',
        entity_type: 'gps_zone',
        entity_id: zone.id,
        details: { from: 'active', to: 'inactive', reason: REASON, activeZonesLeft: 1 },
        ip: IP,
      },
    ]);
  });

  it('allows deactivating the last active zone, with the NO_ACTIVE_ZONES warning', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    // An inactive zone does not count as one left.
    await insertZone(t.db, { name: 'Kasempa South', status: 'inactive' });

    const result = await zones().deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id });

    expect(result.warning).toEqual({ code: 'NO_ACTIVE_ZONES', message: NO_ACTIVE_ZONES_WARNING.message });
    expect(result.warning.message).toContain('every new registration will be flagged');
    expect((await auditFor(zone.id))[0].details.activeZonesLeft).toBe(0);
  });

  it('refuses a zone that is already inactive', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North', status: 'inactive' });

    const err = await expectRefused(
      () => zones().deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      zone,
    );
    expect(err.message).toBe('Only an active zone can be deactivated. This zone is inactive.');
  });

  it('refuses an unknown zone with ZONE_NOT_FOUND', async () => {
    const admin = await activeAdmin();

    await expect(zones().deactivate({ zoneId: MISSING_ID, reason: REASON, actorId: admin.id })).rejects.toMatchObject({
      status: 404,
      code: 'ZONE_NOT_FOUND',
    });
  });

  it('keeps past steps pointing at the zone', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    const step = await insertTransaction(t.db, { zone_id: zone.id });

    await zones().deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id });

    const { rows } = await t.db.query('SELECT zone_id FROM transactions WHERE id = $1', [step.id]);
    expect(rows[0].zone_id).toBe(zone.id);
  });

  it('stays active when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });
    const service = createZoneService({ db: t.db, audit: failingAudit });

    await expect(service.deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id })).rejects.toThrow('audit unavailable');

    expect((await zoneRow(zone.id)).status).toBe('active');
  });
});

describe('reactivate', () => {
  it('reactivates an inactive zone and records it', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North', status: 'inactive' });

    const result = await zones().reactivate({ zoneId: zone.id, actorId: admin.id, ipAddress: IP });

    expect(result).toMatchObject({ id: zone.id, status: 'active' });
    expect(await auditFor(zone.id)).toEqual([
      {
        actor_id: admin.id,
        action: 'gps_zone.reactivate',
        entity_type: 'gps_zone',
        entity_id: zone.id,
        details: { from: 'inactive', to: 'active' },
        ip: IP,
      },
    ]);
  });

  it('refuses a zone that is already active', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North' });

    const err = await expectRefused(
      () => zones().reactivate({ zoneId: zone.id, actorId: admin.id }),
      { status: 409, code: 'INVALID_STATUS_TRANSITION' },
      zone,
    );
    expect(err.message).toBe('Only an inactive zone can be reactivated. This zone is active.');
  });

  it('refuses an unknown zone with ZONE_NOT_FOUND', async () => {
    const admin = await activeAdmin();

    await expect(zones().reactivate({ zoneId: MISSING_ID, actorId: admin.id })).rejects.toMatchObject({ status: 404, code: 'ZONE_NOT_FOUND' });
  });

  it('stays inactive when the audit entry cannot be written', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North', status: 'inactive' });
    const service = createZoneService({ db: t.db, audit: failingAudit });

    await expect(service.reactivate({ zoneId: zone.id, actorId: admin.id })).rejects.toThrow('audit unavailable');

    expect((await zoneRow(zone.id)).status).toBe('inactive');
  });
});

describe('boundaries and licence numbers never change', () => {
  it('stay the same through rename, deactivate and reactivate', async () => {
    const admin = await activeAdmin();
    const zone = await insertZone(t.db, { name: 'Kasempa North', licence_number: 'DEMO-LML-0001' });

    await zones().rename({ zoneId: zone.id, name: 'Kasempa South', actorId: admin.id });
    await zones().deactivate({ zoneId: zone.id, reason: REASON, actorId: admin.id });
    await zones().reactivate({ zoneId: zone.id, actorId: admin.id });

    expect(await zoneRow(zone.id)).toMatchObject({ licence_number: 'DEMO-LML-0001', boundary: SAMPLE_BOUNDARY });
  });

  it('no UPDATE statement in zoneService.js sets either column', () => {
    // A guard on the source itself, so a later change cannot quietly add an edit path.
    const source = readFileSync(new URL('../../src/services/zoneService.js', import.meta.url), 'utf8');
    const setClauses = [...source.matchAll(/UPDATE\s+gps_zones\s+SET([\s\S]*?)WHERE/g)].map((m) => m[1]);

    expect(setClauses).toHaveLength(3);
    for (const clause of setClauses) expect(clause).not.toMatch(/boundary|licence_number/);
  });
});

// Two admins deactivate the last two active zones at the same moment, on two real
// connections. Without the lock on the active zones, each would still see the other's zone
// as active and neither would be warned. The rows must be committed for the second
// connection to see them, so they are deleted afterwards. The audit service only collects
// entries in memory, because audit_logs is append-only and committed entries could never
// be removed.
describe('two admins deactivating the last two zones at the same moment', () => {
  let pool;
  let db;

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
    db = createDb(pool);
  });
  afterAll(async () => {
    await db.close();
  });

  // A db object on one fixed connection, so the test knows B's backend pid. It looks like a
  // pool to createDb: transaction() "borrows" the same connection and gives nothing back.
  // (The same helper as in anomalyRules.test.js.)
  const singleConnection = (client) => ({
    query: (text, params) => client.query(text, params),
    connect: async () => ({ query: (text, params) => client.query(text, params), release: () => {} }),
  });

  // Polls pg_locks until the backend has a lock it is waiting for (granted = false), and
  // fails the test if that never happens, so "B waited for A" is proven, not assumed.
  // (The same helper as in anomalyRules.test.js.)
  async function waitUntilBlocked(pid, timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const { rows } = await db.query('SELECT count(*)::int AS waiting FROM pg_locks WHERE pid = $1 AND NOT granted', [pid]);
      if (rows[0].waiting > 0) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`backend ${pid} never waited on a lock within ${timeoutMs} ms`);
  }

  it('warns exactly one of them, the one that waited', async () => {
    const suffix = randomBytes(4).toString('hex');
    const entries = [];
    const collectingAudit = { record: async (_tx, entry) => entries.push(entry) };
    const created = { users: [], zones: [] };
    let clientA;
    let clientB;
    let pendingB;
    try {
      // The warning counts every active zone in the database, so a committed active zone
      // left by an earlier, interrupted run would change the answer. Say so plainly.
      const { rows: leftover } = await db.query("SELECT count(*)::int AS n FROM gps_zones WHERE status = 'active'");
      expect(leftover[0].n, 'minechain_test already has committed active zones; remove them and run again').toBe(0);

      const admin = await insertUser(db, { role: 'admin', status: 'active' });
      created.users.push(admin.id);
      const first = await insertZone(db, { name: `Race North ${suffix}`, created_by: admin.id });
      const second = await insertZone(db, { name: `Race South ${suffix}`, created_by: admin.id });
      created.zones.push(first.id, second.id);

      // A deactivates the first zone inside an open transaction and does not commit yet.
      clientA = await pool.connect();
      await clientA.query('BEGIN');
      const serviceA = createZoneService({ db: createDb(clientA, { inTransaction: true }), audit: collectingAudit });
      const resA = await serviceA.deactivate({ zoneId: first.id, reason: REASON, actorId: admin.id });
      expect(resA.warning).toBeNull();

      // B deactivates the second zone on a connection of its own. Its lock on the active
      // zones must wait for A's.
      clientB = await pool.connect();
      const { rows: pidRows } = await clientB.query('SELECT pg_backend_pid() AS pid');
      const serviceB = createZoneService({ db: createDb(singleConnection(clientB)), audit: collectingAudit });
      pendingB = serviceB.deactivate({ zoneId: second.id, reason: REASON, actorId: admin.id });
      await waitUntilBlocked(pidRows[0].pid);

      // Only now, with B provably waiting, does A commit.
      await clientA.query('COMMIT');

      const resB = await pendingB;

      expect(resB.warning).toEqual(NO_ACTIVE_ZONES_WARNING);
      expect(entries.map((e) => [e.entityId, e.details.activeZonesLeft])).toEqual([
        [first.id, 1],
        [second.id, 0],
      ]);
      const { rows } = await db.query('SELECT status FROM gps_zones WHERE id = ANY($1::uuid[])', [created.zones]);
      expect(rows.map((r) => r.status)).toEqual(['inactive', 'inactive']);
    } finally {
      if (clientA) {
        // Harmless after the COMMIT; undoes A if a check failed before it, which also lets
        // a waiting B go on.
        await clientA.query('ROLLBACK').catch(() => {});
        clientA.release();
      }
      // B must have finished before its rows are deleted, whatever it answered.
      if (pendingB) await pendingB.catch(() => {});
      if (clientB) clientB.release();
      // Zones first: gps_zones.created_by is ON DELETE RESTRICT.
      await db.query('DELETE FROM gps_zones WHERE id = ANY($1::uuid[])', [created.zones]);
      await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [created.users]);
    }
  });
});
