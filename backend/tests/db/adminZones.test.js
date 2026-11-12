import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser } from './fixtures.js';
import { auth, bindRealStack, loggedInSigner, stepItem, syncSteps } from './realStackHelpers.js';
import { FLAGGED_MESSAGES } from '../../src/services/anomalyChecks.js';
import { ZONE_TOLERANCE_METRES } from '../../src/services/zoneMatch.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../../src/seed/seedData.js';

// GPS zone management (FR-11) through the whole stack: HTTP, the admin guard, validation, the
// zone service, PostgreSQL, and then sync reading the zones an admin set up. Nothing here
// inserts a zone directly, so every zone comes from the API.
//
// stepItem's coordinates (-15.419012, 28.288105) are inside the ZCAS campus polygon.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const REASON = 'Licence revoked by the Mines Cadastre';

// Every item gets a random step id, as in flaggedChain.test.js.
const registration = (party, qrCode) => stepItem(party, 'registration', qrCode, { stepId: randomUUID() });

async function setup() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const asAdmin = (req) => auth(req, adminToken);
  return { app, admin, adminToken, asAdmin };
}

async function zoneIdOf(transactionId) {
  const { rows } = await t.db.query('SELECT zone_id FROM transactions WHERE id = $1', [transactionId]);
  return rows[0].zone_id;
}

describe('GPS zones through the real stack', () => {
  it('a zone made through the API is used by sync, and deactivating it flags the next registration', async () => {
    const { app, admin, adminToken, asAdmin } = await setup();
    const miner = await loggedInSigner(app, adminToken, 'miner');

    // ---------- the admin creates the zone ----------
    const created = await asAdmin(request(app).post('/admin/zones')).send({
      name: 'ZCAS Campus (API)',
      licenceNumber: 'DEMO-LML-0001',
      boundary: ZCAS_CAMPUS_BOUNDARY,
    });

    expect(created.status).toBe(201);
    expect(created.headers['cache-control']).toBe('no-store');
    const zone = created.body.zone;
    expect(zone).toMatchObject({
      name: 'ZCAS Campus (API)',
      licenceNumber: 'DEMO-LML-0001',
      status: 'active',
      boundary: ZCAS_CAMPUS_BOUNDARY,
      createdBy: admin.id,
    });

    const listed = await asAdmin(request(app).get('/admin/zones'));
    expect(listed.status).toBe(200);
    expect(listed.body).toEqual({ zones: [zone], total: 1, limit: 20, offset: 0 });

    // ---------- a registration inside it is matched to it ----------
    const first = await syncSteps(app, miner, [registration(miner, `MC-ZONE-${randomUUID()}`)]);

    expect(first.status).toBe(200);
    expect(first.body.results).toEqual([
      { index: 0, stepId: expect.any(String), outcome: 'created', transactionId: expect.any(String), reviewStatus: 'passed' },
    ]);
    expect(await zoneIdOf(first.body.results[0].transactionId)).toBe(zone.id);

    // ---------- the admin deactivates the only zone, and is warned ----------
    const deactivated = await asAdmin(request(app).post(`/admin/zones/${zone.id}/deactivate`)).send({ reason: REASON });

    expect(deactivated.status).toBe(200);
    expect(deactivated.body.zone).toMatchObject({ id: zone.id, status: 'inactive' });
    expect(deactivated.body.warning).toEqual({ code: 'NO_ACTIVE_ZONES', message: expect.stringContaining('every new registration will be flagged') });

    // ---------- the same point is now outside every active zone ----------
    const second = await syncSteps(app, miner, [registration(miner, `MC-ZONE-${randomUUID()}`)]);

    expect(second.status).toBe(200);
    const flagged = second.body.results[0];
    expect(flagged).toEqual({
      index: 0,
      stepId: expect.any(String),
      outcome: 'flagged',
      code: 'GPS_ZONE',
      message: FLAGGED_MESSAGES.GPS_ZONE,
      transactionId: expect.any(String),
      reviewStatus: 'flagged',
      alerts: ['gps_zone'],
    });
    expect(await zoneIdOf(flagged.transactionId)).toBeNull();
    const { rows: alerts } = await t.db.query('SELECT type, severity, details FROM alerts WHERE transaction_id = $1', [flagged.transactionId]);
    expect(alerts).toEqual([{ type: 'gps_zone', severity: 'medium', details: { noActiveZones: true, toleranceMetres: ZONE_TOLERANCE_METRES } }]);

    // The earlier step still points at the zone it was checked against.
    expect(await zoneIdOf(first.body.results[0].transactionId)).toBe(zone.id);

    // ---------- both admin actions were recorded, with the admin and the reason ----------
    const { rows: audits } = await t.db.query(
      'SELECT actor_id, action, details FROM audit_logs WHERE entity_type = $1 AND entity_id = $2 ORDER BY id',
      ['gps_zone', zone.id],
    );
    expect(audits).toEqual([
      { actor_id: admin.id, action: 'gps_zone.create', details: { name: 'ZCAS Campus (API)', licenceNumber: 'DEMO-LML-0001', cornerCount: ZCAS_CAMPUS_BOUNDARY.length } },
      { actor_id: admin.id, action: 'gps_zone.deactivate', details: { from: 'active', to: 'inactive', reason: REASON, activeZonesLeft: 0 } },
    ]);
  });

  it('replaces a zone with the rename-first flow, and a reused name is refused with 409', async () => {
    const { app, asAdmin } = await setup();
    const boundary = ZCAS_CAMPUS_BOUNDARY;

    const old = (await asAdmin(request(app).post('/admin/zones')).send({ name: 'Kasempa North', boundary })).body.zone;

    // The name is taken, in any letter case, so the replacement cannot use it yet.
    const clash = await asAdmin(request(app).post('/admin/zones')).send({ name: 'KASEMPA NORTH', boundary });
    expect(clash.status).toBe(409);
    expect(clash.body.error.code).toBe('ZONE_NAME_TAKEN');

    // Rename the old zone, create the replacement with the original name, then deactivate
    // the old one. A zone is active at every moment, so there is no warning.
    const renamed = await asAdmin(request(app).post(`/admin/zones/${old.id}/rename`)).send({ name: 'Kasempa North (until Nov 2026)' });
    expect(renamed.status).toBe(200);
    const replacement = await asAdmin(request(app).post('/admin/zones')).send({ name: 'Kasempa North', boundary });
    expect(replacement.status).toBe(201);
    const deactivated = await asAdmin(request(app).post(`/admin/zones/${old.id}/deactivate`)).send({ reason: 'Replaced by a new boundary' });
    expect(deactivated.status).toBe(200);
    expect(deactivated.body.warning).toBeNull();

    // The old zone's name stays taken while it is inactive.
    const reuse = await asAdmin(request(app).post(`/admin/zones/${replacement.body.zone.id}/rename`)).send({
      name: 'kasempa north (until nov 2026)',
    });
    expect(reuse.status).toBe(409);
    expect(reuse.body.error.code).toBe('ZONE_NAME_TAKEN');

    const inactive = await asAdmin(request(app).get('/admin/zones?status=inactive'));
    expect(inactive.body.zones.map((z) => z.name)).toEqual(['Kasempa North (until Nov 2026)']);
  });

  it('refuses a boundary in [lng, lat] order with a 400 naming the corner, and writes nothing', async () => {
    const { app, asAdmin } = await setup();
    const swapped = ZCAS_CAMPUS_BOUNDARY.map(([lat, lng]) => [lng, lat]);

    const res = await asAdmin(request(app).post('/admin/zones')).send({ name: 'Swapped corners', boundary: swapped });

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'boundary.0', message: expect.stringContaining('[latitude, longitude], latitude first') }]);
    const { rows } = await t.db.query('SELECT count(*)::int AS n FROM gps_zones');
    expect(rows[0].n).toBe(0);
  });
});
