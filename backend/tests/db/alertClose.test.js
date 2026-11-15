import { describe, it, expect } from 'vitest';
import { randomBytes } from 'node:crypto';
import { useTestDb } from './helpers.js';
import {
  FAKE_CONFIG,
  MISSING_ID,
  insertUser,
  insertConsignment,
  insertTransaction,
  insertAlert,
  insertCampusZone,
} from './fixtures.js';
import { newPhone, signWith } from './realStackHelpers.js';
import { createServices } from '../../src/services/index.js';
import { createAlertService, NOT_CLEARABLE_MESSAGES } from '../../src/services/alertService.js';
import { isConsignmentHeld, peekEligibleStep } from '../../src/services/anchorQueue.js';
import { canonicalise } from '../../src/services/stepPayload.js';

// The two closing actions (plan B1.2, §2 "The close transaction"): the decision, the step's
// status worked out from all its alerts, the stage, the three steps that can never be
// cleared, record_tampered, refusals, and the audit entry saved with the change.

const t = useTestDb();

const services = () => createServices({ db: t.db, config: FAKE_CONFIG });
const alerts = () => services().alerts;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.31';
const NOTES = 'Weighed again at the depot: the scale was faulty';

const failingAudit = {
  record: async () => {
    throw new Error('audit unavailable');
  },
};

const officer = () => insertUser(t.db, { role: 'officer', status: 'active' });

// A consignment with its own miner, transporter and buyer, so each step has the right actor.
async function journey({ stage = 'registered' } = {}) {
  const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
  const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
  const buyer = await insertUser(t.db, { role: 'buyer', status: 'active' });
  const consignment = await insertConsignment(t.db, { miner_id: miner.id, stage });
  const actorFor = { registration: miner, handoff: transporter, purchase: buyer };
  const step = (type, overrides = {}) =>
    insertTransaction(t.db, { consignment_id: consignment.id, actor_id: actorFor[type].id, type, ...overrides });
  return { consignment, miner, transporter, buyer, step };
}

const alertOn = (stepRow, overrides = {}) => insertAlert(t.db, { transaction_id: stepRow.id, ...overrides });

async function alertRow(id) {
  const { rows } = await t.db.query(
    'SELECT status, reviewed_by, review_notes, reviewed_at, created_at FROM alerts WHERE id = $1',
    [id],
  );
  return rows[0];
}
const reviewStatusOf = async (id) => (await t.db.query('SELECT review_status FROM transactions WHERE id = $1', [id])).rows[0].review_status;
const stageOf = async (id) => (await t.db.query('SELECT stage FROM consignments WHERE id = $1', [id])).rows[0].stage;

async function auditFor(alertId) {
  const { rows } = await t.db.query(
    `SELECT actor_id, action, entity_type, entity_id, details, host(ip_address) AS ip
       FROM audit_logs WHERE entity_id = $1 ORDER BY id`,
    [alertId],
  );
  return rows;
}

// Everything a close could touch, for "nothing was written".
async function snapshot() {
  const { rows } = await t.db.query(`
    SELECT (SELECT json_agg(json_build_object('id', id, 'status', status, 'notes', review_notes) ORDER BY id) FROM alerts) AS alerts,
           (SELECT json_agg(json_build_object('id', id, 'review', review_status) ORDER BY id) FROM transactions) AS steps,
           (SELECT json_agg(json_build_object('id', id, 'stage', stage) ORDER BY id) FROM consignments) AS consignments,
           (SELECT count(*)::int FROM audit_logs) AS audits`);
  return rows[0];
}

// Takes a function that starts the action, not a promise already running, so the snapshot is
// taken first and the rejection always has a handler (the working rule for refusal tests).
async function expectRefused(startAction, { status, code, message }) {
  const before = await snapshot();
  await expect(startAction()).rejects.toMatchObject({ status, code, ...(message && { message }) });
  expect(await snapshot()).toEqual(before);
}

describe('review: "Confirm problem"', () => {
  it('closes the alert, rejects the step, releases the hold, and records who and why', async () => {
    const { consignment, step } = await journey();
    const registration = await step('registration', { review_status: 'flagged' });
    const alert = await alertOn(registration, { type: 'gps_zone' });
    const reviewer = await officer();
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(true);

    const result = await alerts().review({ alertId: alert.id, officerId: reviewer.id, notes: NOTES, ipAddress: IP });

    expect(result.step).toEqual({ id: registration.id, reviewStatus: 'rejected' });
    expect(result.consignment).toEqual({ id: consignment.id, stage: 'registered', held: false });
    expect(result.alert).toMatchObject({
      id: alert.id,
      status: 'reviewed',
      review: { by: { id: reviewer.id }, notes: NOTES },
      step: { reviewStatus: 'rejected' },
    });
    expect(await alertRow(alert.id)).toMatchObject({ status: 'reviewed', reviewed_by: reviewer.id, review_notes: NOTES });
    expect(await reviewStatusOf(registration.id)).toBe('rejected');
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(false);
    expect(await auditFor(alert.id)).toEqual([
      {
        actor_id: reviewer.id,
        action: 'alert.review',
        entity_type: 'alert',
        entity_id: alert.id,
        details: {
          notes: NOTES,
          alertType: 'gps_zone',
          transactionId: registration.id,
          stepStatus: { from: 'flagged', to: 'rejected' },
          stage: null,
        },
        ip: IP,
      },
    ]);
  });

  it('accepts the alert id in capitals', async () => {
    const { step } = await journey();
    const alert = await alertOn(await step('registration', { review_status: 'flagged' }));

    const result = await alerts().review({ alertId: alert.id.toUpperCase(), officerId: (await officer()).id, notes: NOTES });

    expect(result.alert.id).toBe(alert.id);
    expect((await auditFor(alert.id))[0].entity_id).toBe(alert.id);
  });
});

describe('dismiss: "Clear, no problem"', () => {
  it('clears the step and releases the hold, so the step can be anchored', async () => {
    const { consignment, step } = await journey();
    const registration = await step('registration', { review_status: 'flagged' });
    const alert = await alertOn(registration, { type: 'gps_zone' });
    const reviewer = await officer();
    expect(await peekEligibleStep(t.db)).toBeNull();

    const result = await alerts().dismiss({ alertId: alert.id, officerId: reviewer.id, notes: NOTES, ipAddress: IP });

    expect(result.step).toEqual({ id: registration.id, reviewStatus: 'cleared' });
    expect(result.consignment).toEqual({ id: consignment.id, stage: 'registered', held: false });
    expect(await reviewStatusOf(registration.id)).toBe('cleared');
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(false);
    // The anchoring worker would now send it.
    expect((await peekEligibleStep(t.db))?.id).toBe(registration.id);
    expect((await auditFor(alert.id))[0]).toMatchObject({
      action: 'alert.dismiss',
      details: { alertType: 'gps_zone', stepStatus: { from: 'flagged', to: 'cleared' }, stage: null },
    });
  });

  it('keeps the hold while another alert on the consignment is still open', async () => {
    const { step } = await journey({ stage: 'in_transit' });
    await step('registration');
    const handoff = await step('handoff', { review_status: 'flagged' });
    await alertOn(handoff, { type: 'quantity_discrepancy' });
    const relay = await step('handoff', { review_status: 'flagged' });
    const other = await alertOn(relay, { type: 'quantity_discrepancy' });

    const result = await alerts().dismiss({ alertId: other.id, officerId: (await officer()).id, notes: NOTES });

    expect(result.step.reviewStatus).toBe('cleared');
    expect(result.consignment.held).toBe(true);
  });
});

describe('two alerts on one step: the step status comes from both', () => {
  async function twoAlerts() {
    const { consignment, step } = await journey();
    const registration = await step('registration', { review_status: 'flagged' });
    const gps = await alertOn(registration, { type: 'gps_zone' });
    const weight = await alertOn(registration, { type: 'quantity_discrepancy' });
    return { consignment, registration, gps, weight, reviewer: await officer() };
  }

  it('dismissing one leaves the step flagged and held; reviewing the other then rejects it', async () => {
    const { consignment, registration, gps, weight, reviewer } = await twoAlerts();

    const first = await alerts().dismiss({ alertId: gps.id, officerId: reviewer.id, notes: NOTES });
    expect(first.step.reviewStatus).toBe('flagged');
    expect(first.consignment.held).toBe(true);
    expect((await auditFor(gps.id))[0].details.stepStatus).toBeNull();

    const second = await alerts().review({ alertId: weight.id, officerId: reviewer.id, notes: NOTES });
    expect(second.step.reviewStatus).toBe('rejected');
    expect(await reviewStatusOf(registration.id)).toBe('rejected');
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(false);
  });

  it('dismissing both clears the step', async () => {
    const { registration, gps, weight, reviewer } = await twoAlerts();

    await alerts().dismiss({ alertId: gps.id, officerId: reviewer.id, notes: NOTES });
    const second = await alerts().dismiss({ alertId: weight.id, officerId: reviewer.id, notes: NOTES });

    expect(second.step.reviewStatus).toBe('cleared');
    expect(await reviewStatusOf(registration.id)).toBe('cleared');
    expect((await auditFor(weight.id))[0].details.stepStatus).toEqual({ from: 'flagged', to: 'cleared' });
  });

  it('a dismissal after a review does not overturn the rejection', async () => {
    const { registration, gps, weight, reviewer } = await twoAlerts();

    await alerts().review({ alertId: gps.id, officerId: reviewer.id, notes: NOTES });
    const second = await alerts().dismiss({ alertId: weight.id, officerId: reviewer.id, notes: NOTES });

    expect(second.step.reviewStatus).toBe('rejected');
    expect(await reviewStatusOf(registration.id)).toBe('rejected');
    expect((await auditFor(weight.id))[0].details.stepStatus).toBeNull();
  });
});

describe('the stage after a step is cleared', () => {
  // The whole path through the real sync service, with real signatures: a handoff 12% light
  // is flagged, the purchase behind it is deferred, the officer clears the handoff, and the
  // same signed purchase is then accepted.
  it('a cleared handoff moves registered to in_transit, and the deferred purchase then syncs', async () => {
    await insertCampusZone(t.db);
    const parties = {};
    for (const role of ['miner', 'transporter', 'buyer']) {
      const phone = newPhone();
      const row = await insertUser(t.db, { role, status: 'active', public_key: Buffer.from(phone.spkiBase64, 'base64') });
      parties[role] = { user: { id: row.id, role }, phone };
    }
    const qrCode = `MC-CLEAR-${randomBytes(3).toString('hex')}`;
    const item = (role, fields) => {
      const payload = canonicalise({
        stepId: `6f1d2c3a-0000-4000-8000-${randomBytes(6).toString('hex')}`,
        actorId: parties[role].user.id,
        qrCode,
        latitude: '-15.419751',
        longitude: '28.287496',
        capturedAt: '2026-11-10T08:00:00.000Z',
        ...fields,
      });
      return { payload, signature: signWith(parties[role].phone, payload) };
    };
    const syncOne = async (role, it) => (await services().sync.syncSteps(parties[role].user, [it]))[0];

    expect((await syncOne('miner', item('miner', { type: 'registration', mineral: 'gold', weightMg: '1500000' }))).outcome).toBe('created');
    // 1.32 kg against 1.5 kg: 12% light, over the 10% rule.
    const handoff = await syncOne('transporter', item('transporter', { type: 'handoff', weightMg: '1320000' }));
    expect(handoff).toMatchObject({ outcome: 'flagged', code: 'QUANTITY_DISCREPANCY' });
    // 1.4 kg: within 10% of both the handoff and the registration once the handoff counts.
    const purchase = item('buyer', { type: 'purchase', weightMg: '1400000' });
    expect(await syncOne('buyer', purchase)).toMatchObject({ outcome: 'deferred', code: 'STAGE_NOT_READY' });

    const { rows } = await t.db.query('SELECT a.id, t.consignment_id FROM alerts a JOIN transactions t ON t.id = a.transaction_id');
    const result = await alerts().dismiss({ alertId: rows[0].id, officerId: (await officer()).id, notes: NOTES });

    expect(result.consignment).toMatchObject({ stage: 'in_transit', held: false });
    expect((await auditFor(rows[0].id))[0].details.stage).toEqual({ from: 'registered', to: 'in_transit' });
    expect(await syncOne('buyer', purchase)).toMatchObject({ outcome: 'created' });
    expect(await stageOf(rows[0].consignment_id)).toBe('purchased');
  });

  it('a cleared relay handoff leaves the consignment in_transit', async () => {
    const { consignment, step } = await journey({ stage: 'in_transit' });
    await step('registration');
    await step('handoff');
    const relay = await step('handoff', { review_status: 'flagged' });
    const alert = await alertOn(relay);

    const result = await alerts().dismiss({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(result.consignment.stage).toBe('in_transit');
    expect(await stageOf(consignment.id)).toBe('in_transit');
    expect((await auditFor(alert.id))[0].details.stage).toBeNull();
  });

  it('a cleared purchase moves in_transit to purchased', async () => {
    const { consignment, step } = await journey({ stage: 'in_transit' });
    await step('registration');
    await step('handoff');
    const purchase = await step('purchase', { review_status: 'flagged' });
    const alert = await alertOn(purchase);

    const result = await alerts().dismiss({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(result.consignment.stage).toBe('purchased');
    expect(await stageOf(consignment.id)).toBe('purchased');
  });

  it('never moves the stage backwards: a handoff cleared after the purchase leaves it purchased', async () => {
    const { consignment, step } = await journey({ stage: 'purchased' });
    await step('registration');
    const late = await step('handoff', { review_status: 'flagged' });
    await step('purchase');
    const alert = await alertOn(late, { type: 'quantity_discrepancy' });

    await alerts().dismiss({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(await reviewStatusOf(late.id)).toBe('cleared');
    expect(await stageOf(consignment.id)).toBe('purchased');
  });

  it('a rejected step never moves the stage', async () => {
    const { consignment, step } = await journey();
    await step('registration');
    const handoff = await step('handoff', { review_status: 'flagged' });
    const alert = await alertOn(handoff);

    await alerts().review({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(await stageOf(consignment.id)).toBe('registered');
  });
});

describe('STEP_CANNOT_BE_CLEARED: dismissal refused, nothing written', () => {
  it('a flagged duplicate of an accepted registration', async () => {
    const { consignment, step } = await journey();
    await step('registration');
    const copier = await insertUser(t.db, { role: 'miner', status: 'active' });
    const duplicate = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: copier.id, review_status: 'flagged' });
    const alert = await alertOn(duplicate, { type: 'duplicate_consignment', severity: 'high' });
    const reviewer = await officer();

    await expectRefused(() => alerts().dismiss({ alertId: alert.id, officerId: reviewer.id, notes: NOTES }), {
      status: 409,
      code: 'STEP_CANNOT_BE_CLEARED',
      message: NOT_CLEARABLE_MESSAGES.duplicateRegistration,
    });
  });

  it('any alert on such a duplicate, not only duplicate_consignment', async () => {
    const { consignment, step } = await journey();
    await step('registration');
    const copier = await insertUser(t.db, { role: 'miner', status: 'active' });
    const duplicate = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: copier.id, review_status: 'flagged' });
    const alert = await alertOn(duplicate, { type: 'gps_zone' });
    const reviewer = await officer();

    await expectRefused(() => alerts().dismiss({ alertId: alert.id, officerId: reviewer.id, notes: NOTES }), {
      status: 409,
      code: 'STEP_CANNOT_BE_CLEARED',
      message: NOT_CLEARABLE_MESSAGES.duplicateRegistration,
    });
  });

  it('a second purchase of a consignment that already has an accepted one', async () => {
    const { consignment, step } = await journey({ stage: 'purchased' });
    await step('registration');
    await step('handoff');
    await step('purchase');
    const otherBuyer = await insertUser(t.db, { role: 'buyer', status: 'active' });
    const second = await insertTransaction(t.db, {
      consignment_id: consignment.id,
      actor_id: otherBuyer.id,
      type: 'purchase',
      review_status: 'flagged',
    });
    const alert = await alertOn(second, { type: 'quantity_discrepancy' });
    const reviewer = await officer();

    await expectRefused(() => alerts().dismiss({ alertId: alert.id, officerId: reviewer.id, notes: NOTES }), {
      status: 409,
      code: 'STEP_CANNOT_BE_CLEARED',
      message: NOT_CLEARABLE_MESSAGES.secondPurchase,
    });
  });

  it('a handoff_order alert: a step after the purchase', async () => {
    const { step } = await journey({ stage: 'purchased' });
    await step('registration');
    await step('handoff');
    await step('purchase');
    const late = await step('handoff', { review_status: 'flagged' });
    const alert = await alertOn(late, { type: 'handoff_order', severity: 'medium', details: { consignmentStage: 'purchased', stepType: 'handoff' } });
    const reviewer = await officer();

    await expectRefused(() => alerts().dismiss({ alertId: alert.id, officerId: reviewer.id, notes: NOTES }), {
      status: 409,
      code: 'STEP_CANNOT_BE_CLEARED',
      message: NOT_CLEARABLE_MESSAGES.afterPurchase,
    });
  });

  it('the same steps can still be confirmed as a problem', async () => {
    const { consignment, step } = await journey();
    await step('registration');
    const copier = await insertUser(t.db, { role: 'miner', status: 'active' });
    const duplicate = await insertTransaction(t.db, { consignment_id: consignment.id, actor_id: copier.id, review_status: 'flagged' });
    const alert = await alertOn(duplicate, { type: 'duplicate_consignment', severity: 'high' });

    const result = await alerts().review({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(result.step.reviewStatus).toBe('rejected');
  });
});

describe('record_tampered', () => {
  // An anchored step whose database copy no longer matches the chain (raised by verification
  // in B2). The step's review_status can never change once it was sent.
  async function tampered() {
    const { consignment, step } = await journey();
    const registration = await step('registration', {
      anchor_status: 'confirmed',
      chain_tx_hash: randomBytes(32),
      block_number: '12047700',
      anchored_at: new Date('2026-11-10T09:00:00Z'),
    });
    const alert = await alertOn(registration, { type: 'record_tampered', severity: 'high', details: { source: 'verification', fields: ['dataHash'] } });
    return { consignment, registration, alert };
  }

  it.each(['review', 'dismiss'])('%s closes the alert, leaves the step as it was, and releases the hold', async (action) => {
    const { consignment, registration, alert } = await tampered();
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(true);

    const result = await alerts()[action]({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    expect(result.alert.status).toBe(action === 'review' ? 'reviewed' : 'dismissed');
    expect(result.step).toEqual({ id: registration.id, reviewStatus: 'passed' });
    expect(result.consignment.held).toBe(false);
    const { rows } = await t.db.query('SELECT review_status, anchor_status FROM transactions WHERE id = $1', [registration.id]);
    expect(rows[0]).toEqual({ review_status: 'passed', anchor_status: 'confirmed' });
    expect((await auditFor(alert.id))[0].details).toMatchObject({ alertType: 'record_tampered', stepStatus: null, stage: null });
  });
});

describe('refusals', () => {
  it.each([
    ['review', 'reviewed', 'Only an open alert can be reviewed. This alert is reviewed.'],
    ['dismiss', 'reviewed', 'Only an open alert can be dismissed. This alert is reviewed.'],
    ['review', 'dismissed', 'Only an open alert can be reviewed. This alert is dismissed.'],
  ])('a second close (%s after %s) is 409 INVALID_STATUS_TRANSITION, nothing written', async (action, firstStatus, message) => {
    const { step } = await journey();
    const registration = await step('registration', { review_status: 'flagged' });
    const alert = await alertOn(registration, { type: 'gps_zone' });
    const reviewer = await officer();
    await alerts()[firstStatus === 'reviewed' ? 'review' : 'dismiss']({ alertId: alert.id, officerId: reviewer.id, notes: NOTES });

    await expectRefused(() => alerts()[action]({ alertId: alert.id, officerId: reviewer.id, notes: 'Another opinion' }), {
      status: 409,
      code: 'INVALID_STATUS_TRANSITION',
      message,
    });
    expect(await auditFor(alert.id)).toHaveLength(1);
  });

  it.each(['review', 'dismiss'])('%s of an unknown alert is 404 ALERT_NOT_FOUND', async (action) => {
    const reviewer = await officer();

    await expectRefused(() => alerts()[action]({ alertId: MISSING_ID, officerId: reviewer.id, notes: NOTES }), {
      status: 404,
      code: 'ALERT_NOT_FOUND',
    });
  });

  // The 404 comes first: an unknown alert is reported as unknown even to a caller who may not
  // decide alerts, so the answer does not depend on who asks.
  it('an unknown alert is 404 even for a caller who is not an officer', async () => {
    const admin = await insertUser(t.db, { role: 'admin', status: 'active' });

    await expectRefused(() => alerts().review({ alertId: MISSING_ID, officerId: admin.id, notes: NOTES }), {
      status: 404,
      code: 'ALERT_NOT_FOUND',
    });
  });

  // Only an active officer may decide (database-schema.md, rules enforced by the service).
  // The route's guard refuses these first; this is the service's own check.
  it.each([
    ['an administrator', { role: 'admin', status: 'active' }],
    ['a suspended officer', { role: 'officer', status: 'suspended', status_reason: 'Under investigation' }],
    ['a miner', { role: 'miner', status: 'active' }],
    ['an unknown user id', null],
  ])('%s is refused with 403 FORBIDDEN on both actions, nothing written', async (_label, user) => {
    const { step } = await journey();
    const alert = await alertOn(await step('registration', { review_status: 'flagged' }), { type: 'gps_zone' });
    const callerId = user === null ? MISSING_ID : (await insertUser(t.db, user)).id;

    for (const action of ['review', 'dismiss']) {
      await expectRefused(() => alerts()[action]({ alertId: alert.id, officerId: callerId, notes: NOTES }), {
        status: 403,
        code: 'FORBIDDEN',
        message: 'You do not have permission to do this.',
      });
    }
    expect(await alertRow(alert.id)).toMatchObject({ status: 'open', reviewed_by: null });
    expect(await auditFor(alert.id)).toEqual([]);
  });

  it.each(['review', 'dismiss'])('a failed audit write saves nothing (%s)', async (action) => {
    const { consignment, step } = await journey();
    await step('registration');
    const handoff = await step('handoff', { review_status: 'flagged' });
    const alert = await alertOn(handoff);
    const reviewer = await officer();
    const withFailingAudit = createAlertService({ db: t.db, audit: failingAudit });

    const startClose = () => withFailingAudit[action]({ alertId: alert.id, officerId: reviewer.id, notes: NOTES });

    const before = await snapshot();
    await expect(startClose()).rejects.toThrow('audit unavailable');

    expect(await snapshot()).toEqual(before);
    expect(await alertRow(alert.id)).toMatchObject({ status: 'open', reviewed_by: null });
    expect(await stageOf(consignment.id)).toBe('registered');
  });
});

describe('reviewed_at', () => {
  // The test runs inside one transaction that began before the alert was inserted. now()
  // would therefore give a reviewed_at earlier than the alert's created_at; clock_timestamp()
  // cannot.
  it('is never before the alert was raised', async () => {
    const { step } = await journey();
    const alert = await alertOn(await step('registration', { review_status: 'flagged' }));

    await alerts().review({ alertId: alert.id, officerId: (await officer()).id, notes: NOTES });

    const row = await alertRow(alert.id);
    expect(row.reviewed_at.getTime()).toBeGreaterThanOrEqual(row.created_at.getTime());
    const { rows } = await t.db.query('SELECT now() AS started');
    expect(row.reviewed_at.getTime()).toBeGreaterThan(rows[0].started.getTime());
  });
});
