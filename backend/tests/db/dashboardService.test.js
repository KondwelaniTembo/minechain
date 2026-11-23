import { describe, it, expect } from 'vitest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser, insertZone, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createServices } from '../../src/services/index.js';

// The officer's dashboard counts (FR-14) against the real database. Rows are inserted with
// the fixtures, so each test sets exactly the capture times, minerals, zones and review
// states it is about.

const t = useTestDb();

// The real service, as createServices wires it, on the test's own connection.
const dashboard = () => createServices({ db: t.db, config: FAKE_CONFIG }).dashboard;

const WEEK = { from: '2026-11-17', to: '2026-11-23' };
const OFFICER = { id: '3f2b6c1e-0000-4000-8000-000000000001', role: 'officer' };
const WEEK_DAYS = ['2026-11-17', '2026-11-18', '2026-11-19', '2026-11-20', '2026-11-21', '2026-11-22', '2026-11-23'];

const at = (iso) => new Date(iso);
const summary = (query = WEEK) => dashboard().summary(query, OFFICER);

// A consignment of the given mineral, and steps on it captured at chosen times.
const consignment = (mineral = 'gold', overrides = {}) => insertConsignment(t.db, { mineral_type: mineral, ...overrides });
const step = (c, capturedAt, overrides = {}) =>
  insertTransaction(t.db, { consignment_id: c.id, actor_id: c.miner_id, captured_at: at(capturedAt), ...overrides });

async function closedAlert(transactionId, status, overrides = {}) {
  const officer = await insertUser(t.db, { role: 'officer', status: 'active' });
  return insertAlert(t.db, {
    transaction_id: transactionId,
    status,
    reviewed_by: officer.id,
    review_notes: 'Checked with the miner',
    reviewed_at: at('2026-11-23T10:00:00.000Z'),
    ...overrides,
  });
}

const dayRow = (day, counts = {}) => ({ day, registration: 0, handoff: 0, purchase: 0, ...counts });

describe('dashboard summary: an empty period', () => {
  it('has every key, every day of the period, and zeros', async () => {
    expect(await summary()).toEqual({
      period: { from: '2026-11-17', to: '2026-11-23', days: 7 },
      mineral: null,
      now: { openAlerts: 0, consignments: { registered: 0, in_transit: 0, purchased: 0 } },
      steps: { total: 0, registration: 0, handoff: 0, purchase: 0 },
      registeredWeightMg: '0',
      byDay: WEEK_DAYS.map((day) => dayRow(day)),
      byMineral: [],
      byZone: [],
      outsideZones: 0,
      anomalies: {
        total: 0,
        open: 0,
        byType: {
          duplicate_consignment: 0,
          quantity_discrepancy: 0,
          gps_zone: 0,
          invalid_signature: 0,
          handoff_order: 0,
          record_tampered: 0,
        },
        bySeverity: { low: 0, medium: 0, high: 0 },
      },
    });
  });

  it('lists a single day, and 366 days in a leap year', async () => {
    expect((await summary({ from: '2026-11-23', to: '2026-11-23' })).byDay).toEqual([dayRow('2026-11-23')]);

    const year = await summary({ from: '2028-01-01', to: '2028-12-31' });
    expect(year.period.days).toBe(366);
    expect(year.byDay).toHaveLength(366);
    expect(year.byDay[59].day).toBe('2028-02-29');
    expect(year.byDay.at(-1).day).toBe('2028-12-31');
  });
});

describe('dashboard summary: steps by day', () => {
  it('counts a step on the UTC day its phone recorded it, both ends of the period included', async () => {
    const c = await consignment();
    await step(c, '2026-11-16T23:59:59.999Z'); // the day before: left out
    await step(c, '2026-11-17T00:00:00.000Z', { review_status: 'flagged' }); // first moment of the period
    // 01:00 on 18 Nov in Lusaka (UTC+2) is still 17 Nov in UTC.
    await step(c, '2026-11-17T23:00:00.000Z', { type: 'handoff' });
    await step(c, '2026-11-20T12:00:00.000Z', { type: 'handoff' });
    await step(c, '2026-11-23T23:59:59.999Z', { type: 'purchase' }); // last moment of the period
    await step(c, '2026-11-24T00:00:00.000Z', { type: 'handoff' }); // the day after: left out

    const result = await summary();

    expect(result.steps).toEqual({ total: 4, registration: 1, handoff: 2, purchase: 1 });
    expect(result.byDay).toEqual([
      dayRow('2026-11-17', { registration: 1, handoff: 1 }),
      dayRow('2026-11-18'),
      dayRow('2026-11-19'),
      dayRow('2026-11-20', { handoff: 1 }),
      dayRow('2026-11-21'),
      dayRow('2026-11-22'),
      dayRow('2026-11-23', { purchase: 1 }),
    ]);
  });

  it('counts the same days whatever the session time zone', async () => {
    const c = await consignment();
    await step(c, '2026-11-17T23:00:00.000Z');
    await t.db.query("SET LOCAL TIME ZONE 'Africa/Lusaka'");

    expect((await summary()).byDay[0]).toEqual(dayRow('2026-11-17', { registration: 1 }));
  });
});

describe('dashboard summary: minerals and weight', () => {
  it('sums the weight of accepted registrations only, by mineral, most steps first', async () => {
    const gold = await consignment('gold');
    await step(gold, '2026-11-18T08:00:00.000Z', { weight_mg: '1500000' });
    // A flagged duplicate registration of the same load: a step, but not more weight.
    await step(gold, '2026-11-18T09:00:00.000Z', { weight_mg: '1500000', review_status: 'flagged' });
    await step(gold, '2026-11-19T08:00:00.000Z', { type: 'handoff', weight_mg: '1490000' });

    const copper = await consignment('copper');
    await step(copper, '2026-11-18T08:00:00.000Z', { weight_mg: '250000000', review_status: 'flagged' });

    const cobalt = await consignment('cobalt');
    // Cleared after review: accepted, so its weight counts.
    await step(cobalt, '2026-11-20T08:00:00.000Z', { weight_mg: '2000000', review_status: 'cleared' });
    // Rejected: not accepted.
    const rejected = await consignment('cobalt');
    await step(rejected, '2026-11-20T09:00:00.000Z', { weight_mg: '9000000', review_status: 'rejected' });

    const result = await summary();

    expect(result.byMineral).toEqual([
      { mineral: 'gold', steps: 3, registeredWeightMg: '1500000' },
      { mineral: 'cobalt', steps: 2, registeredWeightMg: '2000000' },
      { mineral: 'copper', steps: 1, registeredWeightMg: '0' },
    ]);
    expect(result.registeredWeightMg).toBe('3500000');
  });

  it('keeps a total weight past 2^53 milligrams exact', async () => {
    await step(await consignment('copper'), '2026-11-18T08:00:00.000Z', { weight_mg: '6000000000000001' });
    await step(await consignment('copper'), '2026-11-18T09:00:00.000Z', { weight_mg: '6000000000000001' });

    const result = await summary();

    expect(result.byMineral).toEqual([{ mineral: 'copper', steps: 2, registeredWeightMg: '12000000000000002' }]);
    expect(result.registeredWeightMg).toBe('12000000000000002');
  });

  it('with a mineral, counts only that mineral, in the period and now', async () => {
    const gold = await consignment('gold', { stage: 'in_transit' });
    const goldStep = await step(gold, '2026-11-18T08:00:00.000Z');
    await insertAlert(t.db, { transaction_id: goldStep.id });
    const copper = await consignment('copper');
    await step(copper, '2026-11-18T08:00:00.000Z', { weight_mg: '4000000' });

    const result = await summary({ ...WEEK, mineral: 'copper' });

    expect(result.mineral).toBe('copper');
    expect(result.steps.total).toBe(1);
    expect(result.byMineral).toEqual([{ mineral: 'copper', steps: 1, registeredWeightMg: '4000000' }]);
    expect(result.registeredWeightMg).toBe('4000000');
    expect(result.now).toEqual({ openAlerts: 0, consignments: { registered: 1, in_transit: 0, purchased: 0 } });
    expect(result.anomalies.total).toBe(0);
  });
});

describe('dashboard summary: where', () => {
  it('counts steps per zone, a deactivated zone included, and steps outside every zone', async () => {
    const campus = await insertZone(t.db, { name: 'ZCAS Campus (demo)' });
    const old = await insertZone(t.db, { name: 'Old Site', status: 'inactive' });
    const c = await consignment();
    await step(c, '2026-11-18T08:00:00.000Z', { zone_id: campus.id });
    await step(c, '2026-11-19T08:00:00.000Z', { type: 'handoff', zone_id: campus.id });
    await step(c, '2026-11-19T09:00:00.000Z', { type: 'handoff', zone_id: old.id });
    await step(c, '2026-11-20T08:00:00.000Z', { type: 'purchase' });
    // Outside the period: not counted for its zone.
    await step(c, '2026-11-10T08:00:00.000Z', { type: 'handoff', zone_id: old.id });

    const result = await summary();

    expect(result.byZone).toEqual([
      { zoneId: campus.id, zoneName: 'ZCAS Campus (demo)', active: true, steps: 2 },
      { zoneId: old.id, zoneName: 'Old Site', active: false, steps: 1 },
    ]);
    expect(result.outsideZones).toBe(1);
  });

  it('orders zones with the same count by name', async () => {
    const b = await insertZone(t.db, { name: 'Bravo' });
    const a = await insertZone(t.db, { name: 'Alpha' });
    const c = await consignment();
    await step(c, '2026-11-18T08:00:00.000Z', { zone_id: b.id });
    await step(c, '2026-11-18T09:00:00.000Z', { type: 'handoff', zone_id: a.id });

    expect((await summary()).byZone.map((z) => z.zoneName)).toEqual(['Alpha', 'Bravo']);
  });
});

describe('dashboard summary: anomalies and now', () => {
  it("counts alerts by their step's day, by type and severity, and how many are open", async () => {
    const c = await consignment('gold', { stage: 'in_transit' });
    const registration = await step(c, '2026-11-18T08:00:00.000Z', { review_status: 'flagged' });
    const handoff = await step(c, '2026-11-19T08:00:00.000Z', { type: 'handoff', review_status: 'flagged' });
    await insertAlert(t.db, { transaction_id: registration.id, type: 'gps_zone', severity: 'medium', details: { nearestZoneId: null } });
    await insertAlert(t.db, { transaction_id: handoff.id });
    await closedAlert(handoff.id, 'reviewed', { type: 'invalid_signature', severity: 'high', details: { keyFingerprint: 'ab'.repeat(32) } });
    // An open alert on a step before the period: in "now", not in the period's anomalies.
    const earlier = await step(await consignment(), '2026-11-02T08:00:00.000Z', { review_status: 'flagged' });
    await insertAlert(t.db, { transaction_id: earlier.id });

    const result = await summary();

    expect(result.anomalies).toEqual({
      total: 3,
      open: 2,
      byType: {
        duplicate_consignment: 0,
        quantity_discrepancy: 1,
        gps_zone: 1,
        invalid_signature: 1,
        handoff_order: 0,
        record_tampered: 0,
      },
      bySeverity: { low: 0, medium: 2, high: 1 },
    });
    expect(result.now).toEqual({ openAlerts: 3, consignments: { registered: 1, in_transit: 1, purchased: 0 } });
  });

  it('counts consignments by their stage now, whatever the period', async () => {
    await consignment('gold', { stage: 'registered' });
    await consignment('gold', { stage: 'purchased' });
    await consignment('copper', { stage: 'purchased' });

    expect((await summary()).now.consignments).toEqual({ registered: 1, in_transit: 0, purchased: 2 });
  });
});

describe('dashboard summary: who may read it', () => {
  it.each(['admin', 'buyer', 'miner', 'transporter'])('refuses a %s with FORBIDDEN', async (role) => {
    await expect(() => dashboard().summary(WEEK, { ...OFFICER, role })).rejects.toMatchObject({
      status: 403,
      code: 'FORBIDDEN',
    });
  });

  it('returns no names, licence numbers or coordinates', async () => {
    const miner = await insertUser(t.db, { role: 'miner', status: 'active', username: 'dash_miner', full_name: 'Dash Miner', licence_number: 'DEMO-ASM-0042' });
    const c = await consignment('gold', { miner_id: miner.id });
    await step(c, '2026-11-18T08:00:00.000Z', { latitude: -15.419012, longitude: 28.288105 });

    const text = JSON.stringify(await summary());

    for (const secret of ['dash_miner', 'Dash Miner', 'DEMO-ASM-0042', miner.id, c.id, c.qr_code, '15.419', '28.288']) {
      expect(text).not.toContain(secret);
    }
  });
});
