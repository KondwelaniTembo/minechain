import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser, insertCampusZone } from './fixtures.js';
import { auth, bindRealStack, loggedInSigner, stepItem, syncSteps } from './realStackHelpers.js';

// The dashboard (FR-14) through the whole stack: accounts made through the API, real P-256
// signatures synced over HTTP, then GET /dashboard as an officer. stepItem's coordinates are
// inside the ZCAS campus polygon and its capture time is 2026-11-10T08:00:00.000Z.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const DAY = '/dashboard?from=2026-11-10&to=2026-11-10';
const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

let campus;
beforeEach(async () => {
  campus = await insertCampusZone(t.db, { name: 'ZCAS Campus (demo)' });
});

async function setup() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const miner = await loggedInSigner(app, adminToken, 'miner', { licenceNumber: 'DEMO-ASM-0077' });
  const transporter = await loggedInSigner(app, adminToken, 'transporter');
  // Officers are created by an administrator and activated (FR-10), tested elsewhere; here a
  // fixture row with a token signed as a login would.
  const officerRow = await insertUser(t.db, { role: 'officer', status: 'active' });
  const officerToken = await tokenFor({ id: officerRow.id, role: 'officer' });
  return { app, adminToken, miner, transporter, officerToken };
}

describe('GET /dashboard (real stack)', () => {
  it('counts synced steps, a flagged handoff and its alert, and returns no personal data', async () => {
    const { app, adminToken, miner, transporter, officerToken } = await setup();
    const qrCode = `MC-DASH-${randomUUID()}`;

    const registered = await syncSteps(app, miner, [item(miner, 'registration', qrCode, { weightMg: '1500000' })]);
    expect(registered.body.results[0]).toMatchObject({ outcome: 'created' });
    // 20% light: flagged with a quantity_discrepancy alert, and the consignment stays registered.
    const handedOff = await syncSteps(app, transporter, [
      item(transporter, 'handoff', qrCode, { weightMg: '1200000', capturedAt: '2026-11-10T09:00:00.000Z' }),
    ]);
    expect(handedOff.body.results[0]).toMatchObject({ outcome: 'flagged', alerts: ['quantity_discrepancy'] });

    const res = await auth(request(app).get(DAY), officerToken);

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body).toMatchObject({
      period: { from: '2026-11-10', to: '2026-11-10', days: 1 },
      mineral: null,
      now: { openAlerts: 1, consignments: { registered: 1, in_transit: 0, purchased: 0 } },
      steps: { total: 2, registration: 1, handoff: 1, purchase: 0 },
      registeredWeightMg: '1500000',
      byDay: [{ day: '2026-11-10', registration: 1, handoff: 1, purchase: 0 }],
      byMineral: [{ mineral: 'gold', steps: 2, registeredWeightMg: '1500000' }],
      byZone: [{ zoneId: campus.id, zoneName: 'ZCAS Campus (demo)', active: true, steps: 2 }],
      outsideZones: 0,
      anomalies: { total: 1, open: 1 },
    });
    expect(res.body.anomalies.byType.quantity_discrepancy).toBe(1);
    expect(res.body.anomalies.bySeverity.medium).toBe(1);

    const text = JSON.stringify(res.body);
    for (const secret of [miner.user.id, miner.username, 'DEMO-ASM-0077', transporter.user.id, transporter.username, qrCode, '-15.419012', '28.288105']) {
      expect(text).not.toContain(secret);
    }

    // The administrator runs the system but is not the dashboard's audience (plan Q2).
    expect((await auth(request(app).get(DAY), adminToken)).status).toBe(403);
    expect((await auth(request(app).get(DAY), miner.token)).status).toBe(403);
  });

  it('writes nothing to the audit log', async () => {
    const { app, officerToken } = await setup();
    const before = await t.db.query('SELECT count(*)::int AS n FROM audit_logs');

    expect((await auth(request(app).get(DAY), officerToken)).status).toBe(200);

    const after = await t.db.query('SELECT count(*)::int AS n FROM audit_logs');
    expect(after.rows[0].n).toBe(before.rows[0].n);
  });
});
