import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser, insertZone, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createPool, createDb } from '../../src/db.js';
import { createServices } from '../../src/services/index.js';
import { createAuditService } from '../../src/services/auditService.js';
import {
  createReportService,
  TRANSACTION_COLUMNS,
  AUDIT_TRAIL_COLUMNS,
  ACCOUNT_EVENT_ACTIONS,
} from '../../src/services/reportService.js';

const t = useTestDb();

// The real service, as createServices wires it, on the test's own connection.
const reports = () => createServices({ db: t.db, config: FAKE_CONFIG }).reports;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.7';
const NOV_10 = { from: '2026-11-10', to: '2026-11-10' };

const failingAudit = {
  record: async () => {
    throw new Error('audit unavailable');
  },
};

// The real audit service, for tests that build their own report service (a small row limit,
// a recording db).
const realAudit = () => createAuditService();

const at = (iso) => new Date(iso);
const bytes = (byte) => Buffer.alloc(32, byte);
const hex = (byte) => `0x${bytes(byte).toString('hex')}`;

// ---------- fixtures ----------

const user = (role, overrides = {}) => insertUser(t.db, { role, status: 'active', ...overrides });

// A requester as req.user carries it. The row must exist: the audit entry refers to it.
async function requester(role) {
  const row = await user(role);
  return { id: row.id, role };
}

// A step captured at the given time. received_at has no fixture field, and now() is the
// same for the whole test transaction, so it is set afterwards when a test needs it.
async function step({ capturedAt = '2026-11-10T08:00:00.000Z', receivedAt, ...overrides } = {}) {
  const row = await insertTransaction(t.db, { captured_at: at(capturedAt), ...overrides });
  if (receivedAt) await t.db.query('UPDATE transactions SET received_at = $1 WHERE id = $2', [at(receivedAt), row.id]);
  return row;
}

const confirmed = (byte, block, anchoredAt) => ({
  anchor_status: 'confirmed',
  chain_tx_hash: bytes(byte),
  block_number: block,
  anchored_at: at(anchoredAt),
});

// audit_logs is append-only, so occurred_at cannot be changed after the insert; this fixed
// statement sets it at the insert instead.
async function accountEvent({ occurredAt, actorId = null, action, subjectId, details = {}, ip = IP }) {
  await t.db.query(
    `INSERT INTO audit_logs (occurred_at, actor_id, action, entity_type, entity_id, details, ip_address)
     VALUES ($1, $2, $3, 'user', $4, $5, $6)`,
    [at(occurredAt), actorId, action, subjectId, JSON.stringify(details), ip],
  );
}

async function reportAudits(action) {
  const { rows } = await t.db.query(
    `SELECT actor_id, action, entity_type, entity_id, details, host(ip_address) AS ip
       FROM audit_logs WHERE action = $1 ORDER BY id`,
    [action],
  );
  return rows;
}

const ids = (rows, key = 'step_id') => rows.map((r) => r[key]);

// ---------- transactions report ----------

describe('transactions report: rows and columns', () => {
  it('returns one row per step with exactly the report columns and exact values', async () => {
    const officer = await requester('officer');
    const miner = await user('miner', { username: 'report_miner', licence_number: 'DEMO-ASM-0001' });
    const zone = await insertZone(t.db, { name: 'Kasempa North', licence_number: 'DEMO-LML-0001' });
    const consignment = await insertConsignment(t.db, { qr_code: 'MC-REPORT-0001', mineral_type: 'gold', miner_id: miner.id });
    const registration = await step({
      consignment_id: consignment.id,
      actor_id: miner.id,
      zone_id: zone.id,
      weight_mg: '1500000',
      data_hash: bytes(0xcd),
      receivedAt: '2026-11-10T08:05:00.000Z',
      ...confirmed(0xab, '1234', '2026-11-10T09:00:00.000Z'),
    });

    const result = await reports().transactions(NOV_10, officer);

    expect(result.columns).toBe(TRANSACTION_COLUMNS);
    expect(result.rows).toEqual([
      {
        step_id: registration.id,
        consignment_id: consignment.id,
        qr_code: 'MC-REPORT-0001',
        mineral: 'gold',
        consignment_stage: 'registered',
        step_type: 'registration',
        actor_username: 'report_miner',
        actor_role: 'miner',
        actor_licence_number: 'DEMO-ASM-0001',
        weight_mg: '1500000',
        weight_kg: '1.500000',
        latitude: '-13.450000',
        longitude: '25.820000',
        zone_name: 'Kasempa North',
        zone_licence_number: 'DEMO-LML-0001',
        captured_at_utc: at('2026-11-10T08:00:00.000Z'),
        received_at_utc: at('2026-11-10T08:05:00.000Z'),
        review_status: 'passed',
        anchor_status: 'confirmed',
        chain_tx_hash: hex(0xab),
        block_number: '1234',
        anchored_at_utc: at('2026-11-10T09:00:00.000Z'),
        data_hash: hex(0xcd),
      },
    ]);
    // Every column the file will have is a key of every row, so toCsv never reads a gap.
    expect(Object.keys(result.rows[0]).sort()).toEqual(TRANSACTION_COLUMNS.map((c) => c.header).sort());
  });

  it('leaves the chain columns empty unless the step is confirmed, even with a hash already sent', async () => {
    const officer = await requester('officer');
    await step({ anchor_status: 'submitted', chain_tx_hash: bytes(0xee), anchor_nonce: '7', anchor_submitted_at: at('2026-11-10T08:01:00.000Z') });

    const { rows } = await reports().transactions(NOV_10, officer);

    expect(rows[0]).toMatchObject({ anchor_status: 'submitted', chain_tx_hash: null, block_number: null, anchored_at_utc: null });
  });

  it('shows an empty zone for a step outside every zone', async () => {
    const officer = await requester('officer');
    await step({ zone_id: null });

    const { rows } = await reports().transactions(NOV_10, officer);

    expect(rows[0]).toMatchObject({ zone_name: null, zone_licence_number: null });
  });

  it('orders by capture time, then by received time when capture times are equal, not by id', async () => {
    const officer = await requester('officer');
    const late = await step({ capturedAt: '2026-11-10T10:00:00.000Z' });
    const one = await step({ capturedAt: '2026-11-10T09:00:00.000Z' });
    const two = await step({ capturedAt: '2026-11-10T09:00:00.000Z' });
    // uuids compare byte by byte, which is the same as comparing their lower-case text.
    const [lowerId, higherId] = [one, two].sort((a, b) => (a.id < b.id ? -1 : 1));
    // Received in the OPPOSITE order to their ids, so ordering by id would give the wrong
    // answer and only received_at gives the right one.
    await t.db.query('UPDATE transactions SET received_at = $1 WHERE id = $2', [at('2026-11-10T09:05:00.000Z'), higherId.id]);
    await t.db.query('UPDATE transactions SET received_at = $1 WHERE id = $2', [at('2026-11-10T09:06:00.000Z'), lowerId.id]);

    const { rows } = await reports().transactions(NOV_10, officer);

    expect(ids(rows)).toEqual([higherId.id, lowerId.id, late.id]);
  });

  it('falls back to id when both the capture and the received times are equal', async () => {
    const officer = await requester('officer');
    const sameA = await step({ capturedAt: '2026-11-10T09:00:00.000Z', receivedAt: '2026-11-10T09:05:00.000Z' });
    const sameB = await step({ capturedAt: '2026-11-10T09:00:00.000Z', receivedAt: '2026-11-10T09:05:00.000Z' });

    const { rows } = await reports().transactions(NOV_10, officer);

    expect(ids(rows)).toEqual([sameA.id, sameB.id].sort());
  });

  it('returns no rows, and still records the export, when nothing matches', async () => {
    const officer = await requester('officer');

    const result = await reports().transactions(NOV_10, officer);

    expect(result.rows).toEqual([]);
    expect((await reportAudits('report.transactions_export'))[0].details.rowCount).toBe(0);
  });

  it('names the file after the date range', async () => {
    const officer = await requester('officer');

    const { filename } = await reports().transactions({ from: '2026-11-01', to: '2026-11-30' }, officer);

    expect(filename).toBe('minechain-transactions-2026-11-01-to-2026-11-30.csv');
  });
});

describe('transactions report: the UTC day range', () => {
  it('includes from 00:00:00.000 to the last millisecond of to, and nothing either side', async () => {
    const officer = await requester('officer');
    await step({ capturedAt: '2026-11-09T23:59:59.999Z' });
    const first = await step({ capturedAt: '2026-11-10T00:00:00.000Z' });
    const last = await step({ capturedAt: '2026-11-10T23:59:59.999Z' });
    await step({ capturedAt: '2026-11-11T00:00:00.000Z' });

    const { rows } = await reports().transactions(NOV_10, officer);

    expect(ids(rows)).toEqual([first.id, last.id]);
  });
});

describe('transactions report: filters', () => {
  // Two steps that differ in every filter. Each filter, set to A's value, keeps only A.
  async function twoSteps() {
    const zoneA = await insertZone(t.db, { name: 'Zone A' });
    const zoneB = await insertZone(t.db, { name: 'Zone B' });
    const a = await step({
      consignment_id: (await insertConsignment(t.db, { mineral_type: 'gold' })).id,
      zone_id: zoneA.id,
      type: 'registration',
      review_status: 'passed',
      ...confirmed(0x01, '10', '2026-11-10T09:00:00.000Z'),
    });
    const b = await step({
      consignment_id: (await insertConsignment(t.db, { mineral_type: 'copper' })).id,
      zone_id: zoneB.id,
      type: 'handoff',
      review_status: 'flagged',
      anchor_status: 'pending',
    });
    return { a, b, zoneA };
  }

  it.each([
    ['mineral', () => ({ mineral: 'gold' })],
    ['actorId', ({ a }) => ({ actorId: a.actor_id })],
    ['actorId given in capitals', ({ a }) => ({ actorId: a.actor_id.toUpperCase() })],
    ['zoneId', ({ zoneA }) => ({ zoneId: zoneA.id })],
    ['type', () => ({ type: 'registration' })],
    ['reviewStatus', () => ({ reviewStatus: 'passed' })],
    ['anchorStatus', () => ({ anchorStatus: 'confirmed' })],
  ])('filters by %s', async (_label, filter) => {
    const officer = await requester('officer');
    const scene = await twoSteps();

    const { rows } = await reports().transactions({ ...NOV_10, ...filter(scene) }, officer);

    expect(ids(rows)).toEqual([scene.a.id]);
  });

  it('applies every given filter together', async () => {
    const officer = await requester('officer');
    await twoSteps();

    // A is gold but a registration; B is a handoff but copper. Nothing is both.
    const { rows } = await reports().transactions({ ...NOV_10, mineral: 'gold', type: 'handoff' }, officer);

    expect(rows).toEqual([]);
  });
});

describe('transactions report: who sees what', () => {
  // C1 was bought by this buyer; C2 by another buyer; on C3 this buyer's purchase is flagged.
  async function market() {
    const buyer = await user('buyer');
    const otherBuyer = await user('buyer');
    const transporter = await user('transporter');

    const c1 = await insertConsignment(t.db, { stage: 'purchased' });
    const c1Registration = await step({ consignment_id: c1.id, actor_id: c1.miner_id, capturedAt: '2026-11-10T08:00:00.000Z' });
    const c1Handoff = await step({ consignment_id: c1.id, actor_id: transporter.id, type: 'handoff', capturedAt: '2026-11-10T09:00:00.000Z' });
    const c1Flagged = await step({
      consignment_id: c1.id,
      actor_id: transporter.id,
      type: 'handoff',
      review_status: 'flagged',
      capturedAt: '2026-11-10T09:30:00.000Z',
    });
    const c1Purchase = await step({ consignment_id: c1.id, actor_id: buyer.id, type: 'purchase', capturedAt: '2026-11-10T10:00:00.000Z' });

    const c2 = await insertConsignment(t.db, { stage: 'purchased' });
    const c2Registration = await step({ consignment_id: c2.id, actor_id: c2.miner_id, capturedAt: '2026-11-10T08:10:00.000Z' });
    await step({ consignment_id: c2.id, actor_id: otherBuyer.id, type: 'purchase', capturedAt: '2026-11-10T10:10:00.000Z' });

    const c3 = await insertConsignment(t.db);
    const c3Registration = await step({ consignment_id: c3.id, actor_id: c3.miner_id, capturedAt: '2026-11-10T08:20:00.000Z' });
    await step({ consignment_id: c3.id, actor_id: buyer.id, type: 'purchase', review_status: 'flagged', capturedAt: '2026-11-10T10:20:00.000Z' });

    return { buyer, c1Registration, c1Handoff, c1Flagged, c1Purchase, c2Registration, c3Registration };
  }

  it("shows a buyer only the accepted steps of consignments they bought, never another buyer's or an unreviewed step", async () => {
    const scene = await market();

    const { rows } = await reports().transactions(NOV_10, { id: scene.buyer.id, role: 'buyer' });

    expect(ids(rows)).toEqual([scene.c1Registration.id, scene.c1Handoff.id, scene.c1Purchase.id]);
    // Named outright, so the test says what the limit is for.
    expect(ids(rows)).not.toContain(scene.c1Flagged.id);
    expect(ids(rows)).not.toContain(scene.c2Registration.id);
    expect(ids(rows)).not.toContain(scene.c3Registration.id);
  });

  it('records a buyer export with the own_purchases scope', async () => {
    const scene = await market();

    await reports().transactions(NOV_10, { id: scene.buyer.id, role: 'buyer' });

    expect((await reportAudits('report.transactions_export'))[0].details).toMatchObject({ scope: 'own_purchases', rowCount: 3 });
  });

  it.each(['officer', 'admin'])('shows an %s every step, flagged ones included', async (role) => {
    const scene = await market();

    const { rows } = await reports().transactions(NOV_10, await requester(role));

    expect(rows).toHaveLength(8);
    expect(ids(rows)).toContain(scene.c1Flagged.id);
  });

  it.each(['miner', 'transporter'])('refuses a %s, recording nothing', async (role) => {
    const who = await requester(role);

    await expect(reports().transactions(NOV_10, who)).rejects.toMatchObject({ status: 403, code: 'FORBIDDEN' });
    expect(await reportAudits('report.transactions_export')).toEqual([]);
  });
});

describe('transactions report: the row limit', () => {
  it('refuses more rows than the limit with 422 REPORT_TOO_LARGE, and records nothing', async () => {
    const officer = await requester('officer');
    for (let i = 0; i < 3; i += 1) await step();
    const service = createReportService({ db: t.db, audit: realAudit(), rowLimit: 2 });

    await expect(service.transactions(NOV_10, officer)).rejects.toMatchObject({
      status: 422,
      code: 'REPORT_TOO_LARGE',
      message: 'This report has more than 2 rows. Choose a shorter date range or add a filter.',
    });
    expect(await reportAudits('report.transactions_export')).toEqual([]);
  });

  it('allows exactly the limit', async () => {
    const officer = await requester('officer');
    for (let i = 0; i < 2; i += 1) await step();
    const service = createReportService({ db: t.db, audit: realAudit(), rowLimit: 2 });

    expect((await service.transactions(NOV_10, officer)).rows).toHaveLength(2);
  });

  it('refuses a row limit that is not a whole number of 1 or more', () => {
    expect(() => createReportService({ db: t.db, audit: failingAudit, rowLimit: 0 })).toThrow(TypeError);
  });
});

describe('transactions report: the audit entry', () => {
  it('records who exported, the normalised filters, the scope and the row count, with the IP', async () => {
    const officer = await requester('officer');
    const s = await step();

    await reports().transactions({ ...NOV_10, actorId: s.actor_id.toUpperCase(), mineral: 'gold' }, officer, { ipAddress: IP });

    expect(await reportAudits('report.transactions_export')).toEqual([
      {
        actor_id: officer.id,
        action: 'report.transactions_export',
        entity_type: null,
        entity_id: null,
        details: { filters: { ...NOV_10, actorId: s.actor_id, mineral: 'gold' }, scope: 'all', rowCount: 1 },
        ip: IP,
      },
    ]);
  });

  it('returns nothing when the audit entry cannot be written', async () => {
    const officer = await requester('officer');
    await step();
    const service = createReportService({ db: t.db, audit: failingAudit });

    await expect(service.transactions(NOV_10, officer)).rejects.toThrow('audit unavailable');
  });

  it('asks for one REPEATABLE READ transaction', async () => {
    const officer = await requester('officer');
    const seen = [];
    const recordingDb = {
      query: (text, params) => t.db.query(text, params),
      transaction: (fn, options) => {
        seen.push(options);
        return t.db.transaction(fn, options);
      },
    };

    await createReportService({ db: recordingDb, audit: realAudit() }).transactions(NOV_10, officer);

    expect(seen).toEqual([{ isolation: 'repeatable read' }]);
  });
});

// ---------- audit trail ----------

describe('audit trail: one consignment', () => {
  it('lists its steps, alerts and anchoring in time order, and nothing from other consignments', async () => {
    const officer = await requester('officer');
    const miner = await user('miner', { username: 'trail_miner' });
    const transporter = await user('transporter', { username: 'trail_transporter' });
    const consignment = await insertConsignment(t.db, { qr_code: 'MC-TRAIL-0001', miner_id: miner.id, stage: 'in_transit' });
    const registration = await step({
      consignment_id: consignment.id,
      actor_id: miner.id,
      data_hash: bytes(0x11),
      receivedAt: '2026-11-10T08:00:00.000Z',
      ...confirmed(0xab, '1234', '2026-11-10T08:30:00.000Z'),
    });
    const handoff = await step({
      consignment_id: consignment.id,
      actor_id: transporter.id,
      type: 'handoff',
      weight_mg: '1200000',
      review_status: 'flagged',
      data_hash: bytes(0x22),
      receivedAt: '2026-11-10T09:00:00.000Z',
    });
    const alert = await insertAlert(t.db, { transaction_id: handoff.id, details: { weightMg: '1200000', thresholdPercent: 10 } });
    await t.db.query('UPDATE alerts SET created_at = $1 WHERE id = $2', [at('2026-11-10T09:00:00.000Z'), alert.id]);
    await step({ receivedAt: '2026-11-10T08:15:00.000Z' });

    const result = await reports().auditTrail({ consignmentId: consignment.id }, officer);

    expect(result.columns).toBe(AUDIT_TRAIL_COLUMNS);
    // At 09:00 the step comes before the alert it raised: a fixed event order breaks ties.
    expect(result.rows.map((r) => [r.event_time_utc.toISOString(), r.event, r.step_id])).toEqual([
      ['2026-11-10T08:00:00.000Z', 'step_recorded', registration.id],
      ['2026-11-10T08:30:00.000Z', 'step_anchored', registration.id],
      ['2026-11-10T09:00:00.000Z', 'step_recorded', handoff.id],
      ['2026-11-10T09:00:00.000Z', 'alert_raised', handoff.id],
    ]);

    const [recorded, anchored, , raised] = result.rows;
    expect(recorded).toMatchObject({
      consignment_id: consignment.id,
      qr_code: 'MC-TRAIL-0001',
      step_type: 'registration',
      actor_username: 'trail_miner',
      actor_role: 'miner',
      weight_mg: '1500000',
      weight_kg: '1.500000',
      chain_tx_hash: null,
      data_hash: hex(0x11),
      alert_id: null,
      account_action: null,
    });
    expect(anchored).toMatchObject({ chain_tx_hash: hex(0xab), block_number: '1234', data_hash: hex(0x11) });
    expect(raised).toMatchObject({
      actor_username: 'trail_transporter',
      review_status: 'flagged',
      alert_id: alert.id,
      alert_type: 'quantity_discrepancy',
      alert_severity: 'medium',
      alert_status: 'open',
      reviewer_username: null,
      review_notes: null,
    });
    expect(JSON.parse(raised.alert_details)).toEqual({ weightMg: '1200000', thresholdPercent: 10 });
    expect(Object.keys(recorded).sort()).toEqual(AUDIT_TRAIL_COLUMNS.map((c) => c.header).sort());
  });

  it.each([
    ['reviewed', 'alert_reviewed'],
    ['dismissed', 'alert_dismissed'],
  ])('adds the closing of a %s alert, with the reviewer and notes', async (status, event) => {
    const officer = await requester('officer');
    const reviewer = await user('officer', { username: 'trail_officer' });
    const s = await step({ review_status: status === 'reviewed' ? 'rejected' : 'cleared', receivedAt: '2026-11-10T08:00:00.000Z' });
    const alert = await insertAlert(t.db, {
      transaction_id: s.id,
      status,
      reviewed_by: reviewer.id,
      review_notes: 'Scale checked on site',
      reviewed_at: at('2026-11-10T12:00:00.000Z'),
    });
    await t.db.query('UPDATE alerts SET created_at = $1 WHERE id = $2', [at('2026-11-10T08:00:00.000Z'), alert.id]);

    const { rows } = await reports().auditTrail({ consignmentId: s.consignment_id }, officer);

    expect(rows.map((r) => r.event)).toEqual(['step_recorded', 'alert_raised', event]);
    expect(rows[2]).toMatchObject({ alert_status: status, reviewer_username: 'trail_officer', review_notes: 'Scale checked on site' });
  });

  it('refuses a consignment that does not exist, recording nothing', async () => {
    const officer = await requester('officer');

    await expect(reports().auditTrail({ consignmentId: MISSING_ID }, officer)).rejects.toMatchObject({
      status: 404,
      code: 'CONSIGNMENT_NOT_FOUND',
    });
    expect(await reportAudits('report.audit_trail_export')).toEqual([]);
  });

  it('records the export against the consignment and names the file after it', async () => {
    const officer = await requester('officer');
    const s = await step();

    const { filename } = await reports().auditTrail({ consignmentId: s.consignment_id.toUpperCase() }, officer, { ipAddress: IP });

    expect(filename).toBe(`minechain-audit-trail-consignment-${s.consignment_id}.csv`);
    expect(await reportAudits('report.audit_trail_export')).toEqual([
      {
        actor_id: officer.id,
        action: 'report.audit_trail_export',
        entity_type: 'consignment',
        entity_id: s.consignment_id,
        details: { filters: { consignmentId: s.consignment_id }, rowCount: 1 },
        ip: IP,
      },
    ]);
  });
});

describe('audit trail: one actor', () => {
  it("lists the actor's own steps and account events in the period, without logins or IP addresses", async () => {
    const officer = await requester('officer');
    const admin = await user('admin', { username: 'trail_admin' });
    const miner = await user('miner', { username: 'trail_subject' });
    const other = await user('miner');

    await accountEvent({ occurredAt: '2026-11-09T23:59:59.999Z', actorId: miner.id, action: 'user.register', subjectId: miner.id });
    await accountEvent({ occurredAt: '2026-11-10T07:00:00.000Z', actorId: admin.id, action: 'user.approve', subjectId: miner.id, details: { from: 'pending', to: 'active' } });
    await accountEvent({ occurredAt: '2026-11-10T07:30:00.000Z', actorId: miner.id, action: 'user.login', subjectId: miner.id });
    await accountEvent({ occurredAt: '2026-11-10T07:45:00.000Z', actorId: miner.id, action: 'user.key_register', subjectId: miner.id, details: { keyFingerprint: 'ab'.repeat(32) } });
    await accountEvent({ occurredAt: '2026-11-10T07:50:00.000Z', actorId: admin.id, action: 'user.approve', subjectId: other.id });
    const own = await step({ actor_id: miner.id, receivedAt: '2026-11-10T08:00:00.000Z' });
    // Same consignment, another actor: not in this actor's trail.
    await step({ consignment_id: own.consignment_id, actor_id: other.id, type: 'handoff', receivedAt: '2026-11-10T09:00:00.000Z' });
    await step({ actor_id: miner.id, receivedAt: '2026-11-11T00:00:00.000Z' });

    const { rows } = await reports().auditTrail({ actorId: miner.id, ...NOV_10 }, officer);

    expect(rows.map((r) => [r.event_time_utc.toISOString(), r.event, r.account_action ?? r.step_id])).toEqual([
      ['2026-11-10T07:00:00.000Z', 'account_event', 'user.approve'],
      ['2026-11-10T07:45:00.000Z', 'account_event', 'user.key_register'],
      ['2026-11-10T08:00:00.000Z', 'step_recorded', own.id],
    ]);
    // An account event names who made the change: here the administrator.
    expect(rows[0]).toMatchObject({ actor_username: 'trail_admin', actor_role: 'admin', step_id: null, weight_kg: null });
    expect(JSON.parse(rows[0].account_details)).toEqual({ from: 'pending', to: 'active' });
    expect(JSON.stringify(rows)).not.toContain(IP);
  });

  it('includes every account action on the list, and no other', () => {
    expect(ACCOUNT_EVENT_ACTIONS).toEqual([
      'user.create',
      'user.register',
      'user.approve',
      'user.reject',
      'user.suspend',
      'user.reactivate',
      'user.key_register',
      'user.key_reset',
    ]);
  });

  it('refuses an actor that does not exist, recording nothing', async () => {
    const officer = await requester('officer');

    await expect(reports().auditTrail({ actorId: MISSING_ID, ...NOV_10 }, officer)).rejects.toMatchObject({ status: 404, code: 'USER_NOT_FOUND' });
    expect(await reportAudits('report.audit_trail_export')).toEqual([]);
  });

  it('records the export against the user and names the file after them and the period', async () => {
    const officer = await requester('officer');
    const miner = await user('miner');

    const { filename } = await reports().auditTrail({ actorId: miner.id, ...NOV_10 }, officer);

    expect(filename).toBe(`minechain-audit-trail-user-${miner.id}-2026-11-10-to-2026-11-10.csv`);
    expect((await reportAudits('report.audit_trail_export'))[0]).toMatchObject({
      entity_type: 'user',
      entity_id: miner.id,
      details: { filters: { actorId: miner.id, ...NOV_10 }, rowCount: 0 },
    });
  });
});

describe('audit trail: refusals and limits', () => {
  it.each(['admin', 'buyer', 'miner'])('refuses a %s: the trail is for officers only', async (role) => {
    const who = await requester(role);
    const s = await step();

    await expect(reports().auditTrail({ consignmentId: s.consignment_id }, who)).rejects.toMatchObject({ status: 403, code: 'FORBIDDEN' });
  });

  it('refuses more events than the limit with 422 REPORT_TOO_LARGE', async () => {
    const officer = await requester('officer');
    // A confirmed step is two events; with an alert, three.
    const s = await step({ ...confirmed(0x01, '1', '2026-11-10T09:00:00.000Z') });
    await insertAlert(t.db, { transaction_id: s.id });
    const service = createReportService({ db: t.db, audit: realAudit(), rowLimit: 2 });

    await expect(service.auditTrail({ consignmentId: s.consignment_id }, officer)).rejects.toMatchObject({ status: 422, code: 'REPORT_TOO_LARGE' });
    expect(await reportAudits('report.audit_trail_export')).toEqual([]);
  });

  it('returns nothing when the audit entry cannot be written', async () => {
    const officer = await requester('officer');
    const s = await step();
    const service = createReportService({ db: t.db, audit: failingAudit });

    await expect(service.auditTrail({ consignmentId: s.consignment_id }, officer)).rejects.toThrow('audit unavailable');
  });
});

// ---------- privacy ----------

describe('privacy: what never appears in a report', () => {
  const FORBIDDEN_COLUMNS = ['password_hash', 'public_key', 'signer_public_key', 'signature', 'signed_payload', 'actor_ref', 'full_name', 'ip_address'];

  it.each([
    ['transactions', TRANSACTION_COLUMNS],
    ['audit trail', AUDIT_TRAIL_COLUMNS],
  ])('the %s report has none of the sensitive columns', (_label, columns) => {
    const headers = columns.map((c) => c.header);
    for (const name of FORBIDDEN_COLUMNS) expect(headers).not.toContain(name);
  });

  it('no sensitive value reaches either report, even when every one is set', async () => {
    const officer = await requester('officer');
    const publicKey = Buffer.alloc(91, 0x5a);
    const actorRef = Buffer.alloc(32, 0x6b);
    const signature = Buffer.alloc(70, 0x7c);
    const signerKey = Buffer.alloc(91, 0x4d);
    const miner = await user('miner', { full_name: 'Secret Fullname', public_key: publicKey, actor_ref: actorRef });
    const s = await step({
      actor_id: miner.id,
      signature,
      signer_public_key: signerKey,
      signed_payload: '{"marker":"SIGNED-PAYLOAD-MARKER"}',
    });
    await accountEvent({ occurredAt: '2026-11-10T07:00:00.000Z', actorId: miner.id, action: 'user.key_register', subjectId: miner.id });

    const reportsSeen = [
      await reports().transactions(NOV_10, officer),
      await reports().auditTrail({ consignmentId: s.consignment_id }, officer),
      await reports().auditTrail({ actorId: miner.id, ...NOV_10 }, officer),
    ];

    const text = JSON.stringify(reportsSeen.map((r) => r.rows));
    for (const secret of [
      'Secret Fullname',
      'argon2',
      'SIGNED-PAYLOAD-MARKER',
      IP,
      ...[publicKey, actorRef, signature, signerKey].flatMap((b) => [b.toString('hex'), b.toString('base64')]),
    ]) {
      expect(text).not.toContain(secret);
    }
  });
});

// ---------- the isolation level on a real connection ----------

// Inside the test's own transaction a savepoint cannot change the isolation level, so this
// one test uses a connection of its own. It writes nothing: the audit service only collects.
describe('REPEATABLE READ on a real connection', () => {
  let pool;
  let poolDb;

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
    poolDb = createDb(pool);
  });
  afterAll(async () => {
    await poolDb.close();
  });

  it('runs the export at REPEATABLE READ', async () => {
    const levels = [];
    // Asks PostgreSQL for the level as the first statement of the service's own transaction.
    const checkingDb = {
      query: (text, params) => poolDb.query(text, params),
      transaction: (fn, options) =>
        poolDb.transaction(async (tx) => {
          levels.push((await tx.query('SHOW transaction_isolation')).rows[0].transaction_isolation);
          return fn(tx);
        }, options),
    };
    const collecting = { record: async () => {} };

    await createReportService({ db: checkingDb, audit: collecting }).transactions(NOV_10, { id: MISSING_ID, role: 'officer' });

    expect(levels).toEqual(['repeatable read']);
  });

  it('leaves the default at READ COMMITTED for everything else', async () => {
    const level = await poolDb.transaction(async (tx) => (await tx.query('SHOW transaction_isolation')).rows[0].transaction_isolation);

    expect(level).toBe('read committed');
  });
});
