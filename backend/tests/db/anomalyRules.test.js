import { describe, it, expect, beforeEach, beforeAll, afterAll } from 'vitest';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { FAKE_CONFIG, insertUser, insertCampusZone } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createSyncService } from '../../src/services/syncService.js';
import { createSignatureService } from '../../src/services/signatureService.js';
import { createPool, createDb } from '../../src/db.js';
import { canonicalise } from '../../src/services/stepPayload.js';
import { ZONE_TOLERANCE_METRES } from '../../src/services/zoneMatch.js';

// The anomaly rules through the real sync service (FR-08): each finding is stored as a
// flagged step with its alert, and the consignment's stage does not move. The hold rules for
// duplicates are 9.4's, so they are not asserted here.

const t = useTestDb();
let campus;
beforeEach(async () => {
  campus = await insertCampusZone(t.db);
});

const sync = () => createServices({ db: t.db, config: FAKE_CONFIG }).sync;

// Points relative to the campus zone (src/seed/seedData.js).
const ON_CAMPUS = { latitude: '-15.419012', longitude: '28.288105' };
// 0.00009 degree of latitude due south of the zone's southernmost corner: about 10 m out.
const TEN_METRES_OUT = { latitude: '-15.419841', longitude: '28.287496' };
// About 1.2 km south of campus.
const FAR_AWAY = { latitude: '-15.430000', longitude: '28.288105' };

function newPhone() {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { spki: publicKey.export({ type: 'spki', format: 'der' }), privateKey };
}
const signWith = (phone, payload) => sign('sha256', Buffer.from(payload, 'utf8'), phone.privateKey).toString('base64');

let counter = 0;
function fieldsFor(user, type, qrCode, overrides = {}) {
  counter += 1;
  return {
    type,
    stepId: `9a1d2c3a-0000-4000-8000-${String(counter).padStart(12, '0')}`,
    actorId: user.id,
    qrCode,
    ...(type === 'registration' && { mineral: 'gold' }),
    weightMg: '1500000',
    ...ON_CAMPUS,
    capturedAt: '2026-11-10T08:00:00.000Z',
    ...overrides,
  };
}
const itemFor = (phone, fields) => {
  const payload = canonicalise(fields);
  return { payload, signature: signWith(phone, payload) };
};

async function party(db, role) {
  const phone = newPhone();
  const row = await insertUser(db, { role, status: 'active', public_key: phone.spki });
  return { user: { id: row.id, role }, phone };
}

const ROLE = { registration: 'miner', handoff: 'transporter', purchase: 'buyer' };
let qrCounter = 0;
const newQr = () => `MC-RULES-${String((qrCounter += 1)).padStart(6, '0')}`;

// One step by a fresh party of the right role. badSignature signs with another phone.
async function syncStep(type, qrCode, overrides = {}, { badSignature = false, service = sync() } = {}) {
  const p = await party(t.db, ROLE[type]);
  const fields = fieldsFor(p.user, type, qrCode, overrides);
  const item = badSignature
    ? { payload: canonicalise(fields), signature: signWith(newPhone(), canonicalise(fields)) }
    : itemFor(p.phone, fields);
  const [res] = await service.syncSteps(p.user, [item]);
  return { ...p, fields, item, res };
}

async function alertsOf(transactionId) {
  const { rows } = await t.db.query('SELECT type, severity, status, details FROM alerts WHERE transaction_id = $1 ORDER BY type', [
    transactionId,
  ]);
  return rows;
}
async function stepRow(transactionId) {
  const { rows } = await t.db.query('SELECT consignment_id, review_status, zone_id, type FROM transactions WHERE id = $1', [transactionId]);
  return rows[0];
}
async function consignment(qrCode) {
  const { rows } = await t.db.query('SELECT id, miner_id, stage, mineral_type FROM consignments WHERE qr_code = $1', [qrCode]);
  return rows[0];
}

describe('quantity discrepancy', () => {
  it('flags a handoff more than 10% lighter than the registration, and the stage stays registered', async () => {
    const qr = newQr();
    const reg = await syncStep('registration', qr);

    const { res } = await syncStep('handoff', qr, { weightMg: '1349999' });

    expect(res).toMatchObject({ outcome: 'flagged', code: 'QUANTITY_DISCREPANCY', alerts: ['quantity_discrepancy'] });
    expect(await alertsOf(res.transactionId)).toEqual([
      {
        type: 'quantity_discrepancy',
        severity: 'medium',
        status: 'open',
        details: {
          weightMg: '1349999',
          thresholdPercent: 10,
          failedBaselines: ['registration'],
          registration: { stepId: reg.res.transactionId, weightMg: '1500000', differenceMg: '-150001', exceeded: true },
        },
      },
    ]);
    expect((await consignment(qr)).stage).toBe('registered');
    expect(await stepRow(res.transactionId)).toMatchObject({ review_status: 'flagged', zone_id: campus.id });
  });

  it('accepts a handoff exactly 10% lighter', async () => {
    const qr = newQr();
    await syncStep('registration', qr);

    const { res } = await syncStep('handoff', qr, { weightMg: '1350000' });

    expect(res).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect((await consignment(qr)).stage).toBe('in_transit');
  });

  it('catches gradual loss: each handoff under 10% from the previous, more than 10% from the registration', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    const first = await syncStep('handoff', qr, { weightMg: '1400000' });
    expect(first.res.outcome).toBe('created');

    const { res } = await syncStep('handoff', qr, { weightMg: '1320000' });

    expect(res.code).toBe('QUANTITY_DISCREPANCY');
    const [alert] = await alertsOf(res.transactionId);
    expect(alert.details.failedBaselines).toEqual(['registration']);
    expect(alert.details.previous).toEqual({ stepId: first.res.transactionId, weightMg: '1400000', differenceMg: '-80000', exceeded: false });
  });

  it('compares a purchase with the latest accepted handoff too', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    await syncStep('handoff', qr, { weightMg: '1400000' });

    // +10.7% from the handoff, +3.3% from the registration.
    const { res } = await syncStep('purchase', qr, { weightMg: '1550000' });

    expect(res.code).toBe('QUANTITY_DISCREPANCY');
    expect((await alertsOf(res.transactionId))[0].details.failedBaselines).toEqual(['previous']);
    expect((await consignment(qr)).stage).toBe('in_transit');
  });

  it('never uses a flagged step as a baseline', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    // A forged handoff claiming a much lower weight.
    const forged = await syncStep('handoff', qr, { weightMg: '1000000' }, { badSignature: true });
    expect(forged.res.outcome).toBe('flagged');

    // Within 10% of the registration, though 49% above the forged one.
    const { res } = await syncStep('handoff', qr, { weightMg: '1490000' });

    expect(res.outcome).toBe('created');
  });
});

describe('GPS zone', () => {
  it('flags a registration outside every zone, with zone_id NULL and the nearest zone named', async () => {
    const qr = newQr();

    const { res } = await syncStep('registration', qr, FAR_AWAY);

    expect(res).toMatchObject({ outcome: 'flagged', code: 'GPS_ZONE', alerts: ['gps_zone'] });
    const [alert] = await alertsOf(res.transactionId);
    expect(alert).toMatchObject({ type: 'gps_zone', severity: 'medium', status: 'open' });
    expect(alert.details).toMatchObject({ nearestZoneId: campus.id, nearestZoneName: 'ZCAS Campus (test)', toleranceMetres: ZONE_TOLERANCE_METRES });
    expect(Number.isInteger(alert.details.distanceMetres)).toBe(true);
    expect(alert.details.distanceMetres).toBeGreaterThan(1000);
    expect((await stepRow(res.transactionId)).zone_id).toBeNull();
    // The consignment is still created: the record is kept as evidence.
    expect((await consignment(qr)).stage).toBe('registered');
  });

  it('accepts a registration about 10 m outside (ordinary GPS error), recording the zone', async () => {
    const { res } = await syncStep('registration', newQr(), TEN_METRES_OUT);

    expect(res.outcome).toBe('created');
    expect((await stepRow(res.transactionId)).zone_id).toBe(campus.id);
  });

  it('records the zone of handoffs and purchases too', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    const handoff = await syncStep('handoff', qr);
    const purchase = await syncStep('purchase', qr);

    expect((await stepRow(handoff.res.transactionId)).zone_id).toBe(campus.id);
    expect((await stepRow(purchase.res.transactionId)).zone_id).toBe(campus.id);
  });

  it('never flags a handoff or purchase outside every zone, but records zone_id NULL', async () => {
    const qr = newQr();
    await syncStep('registration', qr);

    const handoff = await syncStep('handoff', qr, FAR_AWAY);
    const purchase = await syncStep('purchase', qr, FAR_AWAY);

    expect(handoff.res.outcome).toBe('created');
    expect(purchase.res.outcome).toBe('created');
    expect((await stepRow(handoff.res.transactionId)).zone_id).toBeNull();
    expect((await stepRow(purchase.res.transactionId)).zone_id).toBeNull();
  });

  it('flags every registration when no zone is active, even on campus', async () => {
    await t.db.query("UPDATE gps_zones SET status = 'inactive' WHERE id = $1", [campus.id]);

    const { res } = await syncStep('registration', newQr());

    expect(res.code).toBe('GPS_ZONE');
    expect((await alertsOf(res.transactionId))[0].details).toEqual({ noActiveZones: true, toleranceMetres: ZONE_TOLERANCE_METRES });
    expect((await stepRow(res.transactionId)).zone_id).toBeNull();
  });
});

describe('duplicate consignment', () => {
  it('stores a second registration of a known QR code flagged on the existing consignment, which is unchanged', async () => {
    const qr = newQr();
    const original = await syncStep('registration', qr);
    const before = await consignment(qr);

    const { res, user } = await syncStep('registration', qr, { mineral: 'copper' });

    expect(res).toMatchObject({ outcome: 'flagged', code: 'DUPLICATE_CONSIGNMENT', alerts: ['duplicate_consignment'] });
    expect(await alertsOf(res.transactionId)).toEqual([
      {
        type: 'duplicate_consignment',
        severity: 'high',
        status: 'open',
        details: {
          originalTransactionId: original.res.transactionId,
          originalReviewStatus: 'passed',
          sameMiner: false,
          mineral: 'copper',
          originalMineral: 'gold',
        },
      },
    ]);
    // On the existing consignment, whose miner, stage and mineral stay the original's.
    expect(await stepRow(res.transactionId)).toMatchObject({ consignment_id: before.id, type: 'registration', review_status: 'flagged' });
    expect(await consignment(qr)).toEqual(before);
    expect(before.miner_id).not.toBe(user.id);
  });

  it('answers a resend of the flagged duplicate as duplicate, still flagged, writing nothing', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    const second = await syncStep('registration', qr);

    const [again] = await sync().syncSteps(second.user, [second.item]);

    expect(again).toMatchObject({ outcome: 'duplicate', transactionId: second.res.transactionId, reviewStatus: 'flagged' });
    const { rows } = await t.db.query('SELECT count(*)::int AS n FROM alerts WHERE transaction_id = $1', [second.res.transactionId]);
    expect(rows[0].n).toBe(1);
  });
});

// A consignment taken through registration, handoff and purchase, all passed.
async function purchasedConsignment() {
  const qr = newQr();
  await syncStep('registration', qr);
  await syncStep('handoff', qr);
  await syncStep('purchase', qr);
  return qr;
}

describe('handoff order', () => {
  it.each([
    ['handoff', 'medium'],
    ['purchase', 'high'],
  ])('stores a %s after the purchase flagged, with severity %s, and the stage stays purchased', async (type, severity) => {
    const qr = await purchasedConsignment();

    const { res } = await syncStep(type, qr);

    expect(res).toMatchObject({ outcome: 'flagged', code: 'HANDOFF_ORDER' });
    expect(await alertsOf(res.transactionId)).toEqual([
      { type: 'handoff_order', severity, status: 'open', details: { consignmentStage: 'purchased', stepType: type } },
    ]);
    expect((await consignment(qr)).stage).toBe('purchased');
  });

  it('still defers a purchase while the consignment is registered (its handoff is probably on the way)', async () => {
    const qr = newQr();
    await syncStep('registration', qr);
    const before = await t.db.query('SELECT count(*)::int AS n FROM transactions');

    const { res } = await syncStep('purchase', qr);

    expect(res).toMatchObject({ outcome: 'deferred', code: 'STAGE_NOT_READY' });
    const after = await t.db.query('SELECT count(*)::int AS n FROM transactions');
    expect(after.rows[0].n).toBe(before.rows[0].n);
  });
});

describe('several findings on one step', () => {
  it('names the step by its most severe finding, ties by check order, and stores every alert', async () => {
    const qr = await purchasedConsignment();

    // After the purchase (medium) and 33% lighter (medium): the tie goes to check order.
    const { res } = await syncStep('handoff', qr, { weightMg: '1000000' });

    expect(res).toMatchObject({ outcome: 'flagged', code: 'HANDOFF_ORDER', alerts: ['handoff_order', 'quantity_discrepancy'] });
    expect((await alertsOf(res.transactionId)).map((a) => [a.type, a.severity])).toEqual([
      ['handoff_order', 'medium'],
      ['quantity_discrepancy', 'medium'],
    ]);
  });

  it('puts a high finding first: a forged duplicate outside every zone is named by its signature', async () => {
    const qr = newQr();
    await syncStep('registration', qr);

    const { res } = await syncStep('registration', qr, FAR_AWAY, { badSignature: true });

    expect(res.code).toBe('INVALID_SIGNATURE');
    expect(res.alerts).toEqual(['invalid_signature', 'duplicate_consignment', 'gps_zone']);
    expect(await alertsOf(res.transactionId)).toHaveLength(3);
  });
});

describe('context gathering', () => {
  // A db object that counts zone queries, on the test's own connection.
  function countingDb(db, counter) {
    const wrap = (inner) => ({
      ...inner,
      async query(text, params) {
        if (text.includes('FROM gps_zones')) counter.zoneQueries += 1;
        return inner.query(text, params);
      },
      transaction: (fn) => inner.transaction((tx) => fn(wrap(tx))),
    });
    return wrap(db);
  }

  it('reads the zones once per sync call, however many steps it holds', async () => {
    const counter = { zoneQueries: 0 };
    const service = createSyncService({ db: countingDb(t.db, counter), signatures: createSignatureService(), audit: { record: async () => {} } });
    const miner = await party(t.db, 'miner');
    const items = [1, 2, 3, 4, 5].map(() => itemFor(miner.phone, fieldsFor(miner.user, 'registration', newQr())));

    const results = await service.syncSteps(miner.user, items);

    expect(results.map((r) => r.outcome)).toEqual(['created', 'created', 'created', 'created', 'created']);
    expect(counter.zoneQueries).toBe(1);

    await service.syncSteps(miner.user, [itemFor(miner.phone, fieldsFor(miner.user, 'registration', newQr()))]);
    expect(counter.zoneQueries).toBe(2);
  });

  it('does not read the zones at all when no item gets that far', async () => {
    const counter = { zoneQueries: 0 };
    const service = createSyncService({ db: countingDb(t.db, counter), signatures: createSignatureService(), audit: { record: async () => {} } });
    const transporter = await party(t.db, 'transporter');
    // A handoff for an unknown consignment is deferred before the zones are needed.
    const item = itemFor(transporter.phone, fieldsFor(transporter.user, 'handoff', 'MC-RULES-UNKNOWN'));

    const [res] = await service.syncSteps(transporter.user, [item]);

    expect(res.outcome).toBe('deferred');
    expect(counter.zoneQueries).toBe(0);
  });
});

// Two registrations of the same NEW code at the same moment, on two real connections. They
// must commit, so the rows are deleted afterwards. The audit service is a no-op here,
// because audit_logs is append-only and committed entries could never be removed.
describe('two registrations of a new QR code at the same moment', () => {
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

  it('makes the one that loses the consignment insert a flagged duplicate, not an error', async () => {
    const suffix = randomBytes(4).toString('hex');
    const qr = `MC-RACE-${suffix}`;
    const created = { users: [], zones: [] };
    let clientA;
    try {
      // Committed set-up: two miners with keys, and an active zone.
      const minerA = await party(db, 'miner');
      const minerB = await party(db, 'miner');
      created.users.push(minerA.user.id, minerB.user.id);
      const zone = await insertCampusZone(db, { name: `ZCAS race ${suffix}` });
      created.zones.push(zone.id);
      created.users.push(zone.created_by);

      // A registers inside an open transaction and does not commit yet.
      clientA = await pool.connect();
      await clientA.query('BEGIN');
      const serviceA = createSyncService({ db: createDb(clientA, { inTransaction: true }), signatures: createSignatureService(), audit: noAudit });
      const [resA] = await serviceA.syncSteps(minerA.user, [itemFor(minerA.phone, fieldsFor(minerA.user, 'registration', qr))]);
      expect(resA.outcome).toBe('created');

      // B registers the same code on its own connection. Its consignment insert waits on
      // A's uncommitted row in the unique index.
      const serviceB = createSyncService({ db, signatures: createSignatureService(), audit: noAudit });
      const pendingB = serviceB.syncSteps(minerB.user, [itemFor(minerB.phone, fieldsFor(minerB.user, 'registration', qr))]);
      await new Promise((resolve) => setTimeout(resolve, 200));
      await clientA.query('COMMIT');

      const [resB] = await pendingB;

      expect(resB).toMatchObject({ outcome: 'flagged', code: 'DUPLICATE_CONSIGNMENT' });
      const { rows } = await db.query(
        `SELECT t.actor_id, t.review_status FROM transactions t JOIN consignments c ON c.id = t.consignment_id
          WHERE c.qr_code = $1 ORDER BY t.received_at`,
        [qr],
      );
      expect(rows).toEqual([
        { actor_id: minerA.user.id, review_status: 'passed' },
        { actor_id: minerB.user.id, review_status: 'flagged' },
      ]);
    } finally {
      if (clientA) {
        // Harmless after the COMMIT ("no transaction in progress"); undoes A if a check
        // failed before it.
        await clientA.query('ROLLBACK').catch(() => {});
        clientA.release();
      }
      // Children first: every foreign key here is ON DELETE RESTRICT.
      await db.query(
        'DELETE FROM alerts WHERE transaction_id IN (SELECT t.id FROM transactions t JOIN consignments c ON c.id = t.consignment_id WHERE c.qr_code = $1)',
        [qr],
      );
      await db.query('DELETE FROM transactions WHERE consignment_id IN (SELECT id FROM consignments WHERE qr_code = $1)', [qr]);
      await db.query('DELETE FROM consignments WHERE qr_code = $1', [qr]);
      await db.query('DELETE FROM gps_zones WHERE id = ANY($1::uuid[])', [created.zones]);
      await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [created.users]);
    }
  });
});
