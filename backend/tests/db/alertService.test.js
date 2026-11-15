import { describe, it, expect } from 'vitest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createServices } from '../../src/services/index.js';

// The read side of the officers' alert queue (plan B1.1): order for each status, the type
// filter, the total, paging, the held flag by the queue's own rule (including the duplicate
// exception), and exactly what the view shows.

const t = useTestDb();

// The real service, as createServices wires it, on the test's own connection.
const alerts = () => createServices({ db: t.db, config: FAKE_CONFIG }).alerts;

const T0 = new Date('2026-11-10T08:00:00.000Z');
const at = (minutes) => new Date(T0.getTime() + minutes * 60 * 1000);

const NOTES = 'Checked with the miner and the transporter';

const ALERT_KEYS = ['id', 'type', 'severity', 'status', 'details', 'createdAt', 'step', 'consignment', 'actor', 'review'].sort();
const STEP_KEYS = ['id', 'type', 'reviewStatus', 'anchorStatus', 'capturedAt', 'receivedAt'].sort();
const CONSIGNMENT_KEYS = ['id', 'qrCode', 'mineral', 'stage', 'held'].sort();

const officer = () => insertUser(t.db, { role: 'officer', status: 'active' });

// created_at is set by the database (clock_timestamp()), so it is moved afterwards to a
// fixed time, which makes every order in these tests exact.
async function alertAt(minutes, overrides = {}) {
  const alert = await insertAlert(t.db, overrides);
  await t.db.query('UPDATE alerts SET created_at = $2 WHERE id = $1', [alert.id, at(minutes)]);
  return alert;
}

// A flagged step with one open alert raised at `minutes`, on a consignment of its own unless
// one is given.
async function openAlert(minutes, { type = 'quantity_discrepancy', severity = 'medium', step = {} } = {}) {
  const row = await insertTransaction(t.db, { review_status: 'flagged', ...step });
  return alertAt(minutes, { transaction_id: row.id, type, severity });
}

// A closed alert, decided at `reviewedMinutes`. Its step's status follows the decision, as the
// close actions will write it: reviewed -> rejected, dismissed -> cleared.
async function closedAlert(status, createdMinutes, reviewedMinutes, { reviewer, type = 'quantity_discrepancy', step = {} } = {}) {
  const row = await insertTransaction(t.db, { review_status: status === 'reviewed' ? 'rejected' : 'cleared', ...step });
  return alertAt(createdMinutes, {
    transaction_id: row.id,
    type,
    status,
    reviewed_by: (reviewer ?? (await officer())).id,
    review_notes: NOTES,
    reviewed_at: at(reviewedMinutes),
  });
}

const ids = (page) => page.alerts.map((a) => a.id);
const page = (query) => alerts().list({ status: 'open', limit: 20, offset: 0, ...query });

describe('alertService.list order', () => {
  it('lists open alerts oldest first, and only open ones', async () => {
    const second = await openAlert(20);
    const first = await openAlert(10);
    const third = await openAlert(30);
    await closedAlert('reviewed', 5, 40);
    await closedAlert('dismissed', 6, 41);

    const result = await page({ status: 'open' });

    expect(ids(result)).toEqual([first.id, second.id, third.id]);
    expect(result.total).toBe(3);
  });

  it('breaks a tie in created_at by id, the same way every time', async () => {
    const a = await openAlert(10);
    const b = await openAlert(10);
    const expected = [a.id, b.id].sort();

    expect(ids(await page({ status: 'open' }))).toEqual(expected);
  });

  it.each(['reviewed', 'dismissed'])('lists %s alerts newest decision first, and only those', async (status) => {
    const other = status === 'reviewed' ? 'dismissed' : 'reviewed';
    // Raised in one order, decided in another: the decision time is what sorts.
    const oldestDecision = await closedAlert(status, 30, 50);
    const newestDecision = await closedAlert(status, 10, 70);
    const middle = await closedAlert(status, 20, 60);
    await closedAlert(other, 1, 80);
    await openAlert(2);

    const result = await page({ status });

    expect(ids(result)).toEqual([newestDecision.id, middle.id, oldestDecision.id]);
    expect(result.total).toBe(3);
  });

  it('breaks a tie in reviewed_at by id', async () => {
    const a = await closedAlert('dismissed', 10, 50);
    const b = await closedAlert('dismissed', 20, 50);

    expect(ids(await page({ status: 'dismissed' }))).toEqual([a.id, b.id].sort());
  });
});

describe('alertService.list filter, total and paging', () => {
  it('keeps only the given type, and counts only that type', async () => {
    const gps1 = await openAlert(10, { type: 'gps_zone' });
    await openAlert(20, { type: 'quantity_discrepancy' });
    const gps2 = await openAlert(30, { type: 'gps_zone' });
    await closedAlert('reviewed', 5, 40, { type: 'gps_zone' });

    const result = await page({ status: 'open', type: 'gps_zone' });

    expect(ids(result)).toEqual([gps1.id, gps2.id]);
    expect(result.total).toBe(2);
  });

  it('applies the type filter to closed lists too', async () => {
    const dup = await closedAlert('reviewed', 10, 50, { type: 'duplicate_consignment' });
    await closedAlert('reviewed', 11, 51, { type: 'gps_zone' });

    const result = await page({ status: 'reviewed', type: 'duplicate_consignment' });

    expect(ids(result)).toEqual([dup.id]);
    expect(result.total).toBe(1);
  });

  it('gives an empty page and a total of 0 when nothing matches', async () => {
    await openAlert(10, { type: 'gps_zone' });

    expect(await page({ status: 'open', type: 'handoff_order' })).toEqual({ alerts: [], total: 0, limit: 20, offset: 0 });
  });

  it('pages with limit and offset, and the total counts every matching alert', async () => {
    const all = [];
    for (let minute = 1; minute <= 5; minute += 1) all.push(await openAlert(minute));

    const first = await page({ limit: 2, offset: 0 });
    const second = await page({ limit: 2, offset: 2 });
    const last = await page({ limit: 2, offset: 4 });

    expect(ids(first)).toEqual([all[0].id, all[1].id]);
    expect(ids(second)).toEqual([all[2].id, all[3].id]);
    expect(ids(last)).toEqual([all[4].id]);
    expect([first.total, second.total, last.total]).toEqual([5, 5, 5]);
    expect(second).toMatchObject({ limit: 2, offset: 2 });
  });

  it('gives an empty page with the real total for an offset past the end', async () => {
    await openAlert(1);
    await openAlert(2);

    expect(await page({ limit: 20, offset: 50 })).toEqual({ alerts: [], total: 2, limit: 20, offset: 50 });
  });
});

describe('alertService view', () => {
  it('shows exactly the planned fields, with no full name, key, signature or GPS', async () => {
    const miner = await insertUser(t.db, { role: 'miner', status: 'active', full_name: 'Mutale Banda (fake)' });
    const consignment = await insertConsignment(t.db, { miner_id: miner.id, mineral_type: 'copper' });
    const step = await insertTransaction(t.db, {
      consignment_id: consignment.id,
      actor_id: miner.id,
      review_status: 'flagged',
    });
    const details = { nearestZoneId: '5c0d7e21-0000-4000-8000-000000000001', nearestZoneName: 'Demo zone', distanceMetres: 142, toleranceMetres: 25 };
    const alert = await alertAt(10, { transaction_id: step.id, type: 'gps_zone', severity: 'medium', details });

    const [view] = (await page({})).alerts;

    expect(Object.keys(view).sort()).toEqual(ALERT_KEYS);
    expect(Object.keys(view.step).sort()).toEqual(STEP_KEYS);
    expect(Object.keys(view.consignment).sort()).toEqual(CONSIGNMENT_KEYS);
    expect(view).toEqual({
      id: alert.id,
      type: 'gps_zone',
      severity: 'medium',
      status: 'open',
      details,
      createdAt: at(10),
      step: {
        id: step.id,
        type: 'registration',
        reviewStatus: 'flagged',
        anchorStatus: 'pending',
        capturedAt: step.captured_at,
        receivedAt: step.received_at,
      },
      consignment: { id: consignment.id, qrCode: consignment.qr_code, mineral: 'copper', stage: 'registered', held: true },
      actor: { id: miner.id, username: miner.username, role: 'miner' },
      review: null,
    });

    // Nothing private anywhere in the body, whatever its nesting.
    const body = JSON.stringify(view);
    expect(body).not.toContain('Mutale Banda');
    expect(body).not.toContain(step.signed_payload);
    for (const field of ['fullName', 'full_name', 'latitude', 'longitude', 'signature', 'signedPayload', 'publicKey', 'signerPublicKey', 'dataHash', 'actorRef']) {
      expect(body).not.toContain(field);
    }
  });

  it('shows the review of a closed alert, with the reviewer by id and username only', async () => {
    const reviewer = await insertUser(t.db, { role: 'officer', status: 'active', full_name: 'Chanda Mwale (fake)' });
    const alert = await closedAlert('dismissed', 10, 50, { reviewer });

    const [view] = (await page({ status: 'dismissed' })).alerts;

    expect(view.id).toBe(alert.id);
    expect(view.review).toEqual({ by: { id: reviewer.id, username: reviewer.username }, notes: NOTES, at: at(50) });
    expect(view.step.reviewStatus).toBe('cleared');
    expect(JSON.stringify(view)).not.toContain('Chanda Mwale');
  });
});

describe('alertService held flag', () => {
  it('is true while an alert on the consignment is open', async () => {
    await openAlert(10);

    expect((await page({})).alerts[0].consignment.held).toBe(true);
  });

  it('is false once every alert on the consignment is closed', async () => {
    await closedAlert('dismissed', 10, 50);

    expect((await page({ status: 'dismissed' })).alerts[0].consignment.held).toBe(false);
  });

  it('is for the whole consignment: a closed alert shows held while another step there has an open one', async () => {
    const consignment = await insertConsignment(t.db);
    const closed = await closedAlert('dismissed', 10, 50, { step: { consignment_id: consignment.id, actor_id: consignment.miner_id } });
    const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
    await openAlert(20, { step: { consignment_id: consignment.id, actor_id: transporter.id, type: 'handoff' } });

    const [view] = (await page({ status: 'dismissed' })).alerts;

    expect(view.id).toBe(closed.id);
    expect(view.consignment.held).toBe(true);
  });

  // The duplicate exception (database-schema.md, Held consignments): alerts on a flagged
  // registration do not hold a consignment that has a different, accepted registration, so a
  // copied QR code cannot freeze another miner's consignment. All of the duplicate's alerts
  // are excused, not only duplicate_consignment.
  it('is false when the only open alerts are on a flagged duplicate of an accepted registration', async () => {
    const consignment = await insertConsignment(t.db);
    await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: consignment.miner_id, review_status: 'passed' });
    const copier = await insertUser(t.db, { role: 'miner', status: 'active' });
    const duplicate = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: copier.id, review_status: 'flagged' });
    await alertAt(10, { transaction_id: duplicate.id, type: 'duplicate_consignment', severity: 'high' });
    await alertAt(11, { transaction_id: duplicate.id, type: 'gps_zone', severity: 'medium' });

    const result = await page({});

    // The officer still gets both alerts; they just do not hold the consignment.
    expect(result.total).toBe(2);
    expect(result.alerts.map((a) => a.consignment.held)).toEqual([false, false]);
  });

  it('is true for a duplicate when the consignment has no accepted registration', async () => {
    const consignment = await insertConsignment(t.db);
    await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: consignment.miner_id, review_status: 'flagged' });
    const copier = await insertUser(t.db, { role: 'miner', status: 'active' });
    const duplicate = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: copier.id, review_status: 'flagged' });
    await alertAt(10, { transaction_id: duplicate.id, type: 'duplicate_consignment', severity: 'high' });

    expect((await page({})).alerts[0].consignment.held).toBe(true);
  });
});

describe('alertService.get', () => {
  it('gives the alert view and the other alerts on the same consignment, oldest first', async () => {
    const consignment = await insertConsignment(t.db);
    const registration = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: consignment.miner_id, review_status: 'flagged' });
    const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
    const handoff = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: transporter.id, type: 'handoff', review_status: 'flagged' });

    const target = await alertAt(20, { transaction_id: registration.id, type: 'gps_zone' });
    const sameStep = await alertAt(30, { transaction_id: registration.id, type: 'quantity_discrepancy' });
    const otherStep = await alertAt(10, { transaction_id: handoff.id, type: 'quantity_discrepancy' });
    // On another consignment: never listed here.
    await openAlert(5);

    const view = await alerts().get(target.id);

    expect(view.id).toBe(target.id);
    expect(view.consignment).toMatchObject({ id: consignment.id, held: true });
    expect(view.otherAlerts).toEqual([
      { id: otherStep.id, type: 'quantity_discrepancy', severity: 'medium', status: 'open', stepId: handoff.id, createdAt: at(10) },
      { id: sameStep.id, type: 'quantity_discrepancy', severity: 'medium', status: 'open', stepId: registration.id, createdAt: at(30) },
    ]);
  });

  it('includes closed alerts among the others, and an empty list when there are none', async () => {
    const lone = await openAlert(10);
    expect((await alerts().get(lone.id)).otherAlerts).toEqual([]);

    const consignment = await insertConsignment(t.db);
    const stepOne = { consignment_id: consignment.id, actor_id: consignment.miner_id };
    const closed = await closedAlert('reviewed', 5, 50, { step: stepOne });
    const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
    const open = await openAlert(20, { step: { consignment_id: consignment.id, actor_id: transporter.id, type: 'handoff' } });

    expect((await alerts().get(open.id)).otherAlerts.map((a) => [a.id, a.status])).toEqual([[closed.id, 'reviewed']]);
  });

  it('finds an alert whose id is sent in capitals', async () => {
    const alert = await openAlert(10);

    expect((await alerts().get(alert.id.toUpperCase())).id).toBe(alert.id);
  });

  it('answers 404 ALERT_NOT_FOUND for an unknown id', async () => {
    const getMissing = () => alerts().get(MISSING_ID);

    await expect(getMissing()).rejects.toMatchObject({ status: 404, code: 'ALERT_NOT_FOUND', message: 'No alert has this id.' });
  });
});
