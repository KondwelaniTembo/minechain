import { describe, it, expect, beforeEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertCampusZone, insertUser } from './fixtures.js';
import { anchorUntilIdle, bindRealStack, freeLock, silentLog, stepItem, syncSteps } from './realStackHelpers.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';
import { createAnchorService } from '../../src/services/anchorService.js';
import { isConsignmentHeld } from '../../src/services/anchorQueue.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';
import { createFakeChainReader } from '../fakes/fakeChainReader.js';

// The consignment view (plan B2.4) against the real database: steps signed with real P-256
// keys and synced over HTTP, anchored by the real worker on the in-memory chain, and checked
// through the fake reader over that same chain. No test touches Sepolia. The routes come in
// B2.5, so the view is called on the service directly.
//
// test:db runs files in parallel, so every step id and QR code here is random.

const t = useTestDb();
const { signer } = bindRealStack(t);

const GWEI = 1_000_000_000n;
const CONFIRMATIONS = 2;
const ANCHOR_CONFIG = Object.freeze({ confirmations: CONFIRMATIONS, maxAttempts: 5, maxFeePerGasWei: 50n * GWEI });
const NOTES = 'Weighed again at the depot: the load really is short';

beforeEach(async () => {
  await insertCampusZone(t.db);
});

const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

// The whole stack, with the reader given to createServices as server.js does.
// reader: 'fake' (over the fake chain), or null for no reader configured.
async function setup({ reader = 'fake' } = {}) {
  const fake = createFakeChainClient();
  const fakeReader = createFakeChainReader({ chain: fake.client });
  const services = createServices({
    db: t.db,
    config: { ...FAKE_CONFIG, anchor: { confirmations: CONFIRMATIONS } },
    chainReader: reader === 'fake' ? fakeReader.reader : null,
  });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;

  const party = (role) => signer(app, tokenFor, role);
  const parties = {
    miner: await party('miner'),
    transporter: await party('transporter'),
    otherTransporter: await party('transporter'),
    thirdTransporter: await party('transporter'),
    buyer: await party('buyer'),
    otherBuyer: await party('buyer'),
  };
  const officerRow = await insertUser(t.db, { role: 'officer', status: 'active' });
  const officer = { user: { id: officerRow.id, role: 'officer' } };

  const worker = createAnchorService({ db: t.db, chain: fake.client, config: ANCHOR_CONFIG, lock: freeLock, log: silentLog() });
  const anchor = () => anchorUntilIdle(worker, fake, { confirmations: CONFIRMATIONS });

  const qrCode = `MC-VIEW-${randomUUID()}`;
  // The sync result, plus the signed item that was sent (for comparing evidence).
  async function sync(who, type, overrides) {
    const signed = item(parties[who], type, qrCode, overrides);
    const res = await syncSteps(app, parties[who], [signed]);
    expect(res.status).toBe(200);
    return { ...res.body.results[0], item: signed };
  }
  const view = (who) => services.consignments.viewByQr(who === 'officer' ? officer.user : parties[who].user, qrCode);

  return { services, parties, officer, fake, fakeReader, anchor, sync, view, qrCode };
}

async function refusalOf(promise) {
  const err = await promise.then(() => null, (e) => e);
  expect(err).not.toBeNull();
  return { status: err.status, code: err.code, message: err.message, details: err.details };
}

const tamperedAlerts = async (stepId) =>
  (await t.db.query("SELECT type, severity, status, details FROM alerts WHERE transaction_id = $1 AND type = 'record_tampered'", [stepId])).rows;

const allTamperedAlerts = async () => (await t.db.query("SELECT id FROM alerts WHERE type = 'record_tampered'")).rows;

describe('the consignment view: steps and checks', () => {
  it('lists every step in custody order, each confirmed step matching the chain', async () => {
    const s = await setup();
    await s.sync('miner', 'registration');
    expect(await s.anchor()).toEqual(['sent', 'idle']);
    await s.sync('transporter', 'handoff');
    await s.sync('buyer', 'purchase');
    expect((await s.anchor()).at(-1)).toBe('idle');

    const body = await s.view('officer');

    expect(body.consignment).toMatchObject({ qrCode: s.qrCode, mineral: 'gold', stage: 'purchased', held: false });
    expect(body.steps.map((step) => step.type)).toEqual(['registration', 'handoff', 'purchase']);
    expect(body.steps.map((step) => step.check)).toEqual([{ result: 'match' }, { result: 'match' }, { result: 'match' }]);
    expect(body.steps.map((step) => step.anchor.status)).toEqual(['confirmed', 'confirmed', 'confirmed']);
    expect(body.steps[0]).toMatchObject({ capturedAt: '2026-11-10T08:00:00.000Z', zoneName: 'ZCAS Campus (test)' });
    const received = body.steps.map((step) => step.receivedAt);
    expect([...received].sort()).toEqual(received);
  });

  it('a step not anchored yet is not_anchored_yet, and asks the chain nothing for it', async () => {
    const s = await setup();
    await s.sync('miner', 'registration');

    const body = await s.view('officer');

    expect(body.steps[0].check).toEqual({ result: 'not_anchored_yet' });
    expect(s.fakeReader.control.calls).toEqual([]);
  });

  it('flagged and rejected steps are shown to officers only', async () => {
    const s = await setup();
    await s.sync('miner', 'registration');
    await s.anchor();
    await s.sync('transporter', 'handoff');
    await s.anchor();
    // Two relay handoffs 20% light: both flagged; the officer confirms the second one.
    const flagged = await s.sync('otherTransporter', 'handoff', { weightMg: '1200000' });
    const rejected = await s.sync('thirdTransporter', 'handoff', { weightMg: '1200000' });
    expect(flagged).toMatchObject({ outcome: 'flagged' });
    const { rows } = await t.db.query('SELECT id FROM alerts WHERE transaction_id = $1', [rejected.transactionId]);
    await s.services.alerts.review({ alertId: rows[0].id, notes: NOTES, officerId: s.officer.user.id, ipAddress: '127.0.0.1' });

    const officerBody = await s.view('officer');
    expect(officerBody.steps.map((step) => step.reviewStatus)).toEqual(['passed', 'passed', 'flagged', 'rejected']);
    expect(officerBody.steps[2].alerts).toEqual([{ id: expect.any(String), type: 'quantity_discrepancy', status: 'open' }]);
    expect(officerBody.steps[3].alerts).toEqual([{ id: rows[0].id, type: 'quantity_discrepancy', status: 'reviewed' }]);

    for (const who of ['transporter', 'buyer']) {
      const body = await s.view(who);
      expect(body.steps.map((step) => step.type)).toEqual(['registration', 'handoff']);
      expect(body.steps.map((step) => step.id)).not.toContain(flagged.transactionId);
      expect(body.steps.map((step) => step.id)).not.toContain(rejected.transactionId);
    }
  });
});

describe('the consignment view: who sees what', () => {
  it('blind weight: a transporter sees weights only after storing their own handoff', async () => {
    const s = await setup();
    await s.sync('miner', 'registration');
    await s.anchor();

    const before = await s.view('transporter');
    expect(before.consignment.weightsHidden).toBe(true);
    expect(before.steps[0]).not.toHaveProperty('weightMg');
    expect(before.steps[0].anchor).toEqual({ status: 'confirmed' });

    await s.sync('transporter', 'handoff');

    const after = await s.view('transporter');
    expect(after.consignment.weightsHidden).toBe(false);
    expect(after.steps.map((step) => step.weightMg)).toEqual(['1500000', '1500000']);
    expect(after.steps[0].anchor.chainTxHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(after.steps.map((step) => step.byYou)).toEqual([false, true]);

    // Another transporter's handoff unlocks nothing for someone who has not weighed.
    expect((await s.view('otherTransporter')).consignment.weightsHidden).toBe(true);
  });

  it('a buyer is refused at registered and after another buyer\'s purchase, exactly as for an unknown code', async () => {
    const s = await setup();
    const unknown = await refusalOf(s.services.consignments.viewByQr(s.parties.buyer.user, `MC-NONE-${randomUUID()}`));
    expect(unknown).toEqual({ status: 404, code: 'CONSIGNMENT_NOT_FOUND', message: 'No consignment has this QR code.', details: undefined });

    await s.sync('miner', 'registration');
    expect(await refusalOf(s.view('buyer'))).toEqual(unknown);

    await s.sync('transporter', 'handoff');
    expect((await s.view('buyer')).consignment.stage).toBe('in_transit');

    await s.sync('otherBuyer', 'purchase');
    expect(await refusalOf(s.view('buyer'))).toEqual(unknown);
    expect((await s.view('otherBuyer')).consignment.stage).toBe('purchased');
  });

  it('evidence goes only to officers and to the buyer who owns the consignment', async () => {
    const s = await setup();
    const { item: registration } = await s.sync('miner', 'registration');
    await s.sync('transporter', 'handoff');

    expect((await s.view('buyer')).steps[0]).not.toHaveProperty('evidence');
    await s.sync('buyer', 'purchase');

    for (const who of ['officer', 'buyer']) {
      const body = await s.view(who);
      expect(body.steps[0].evidence).toEqual({
        signedPayload: registration.payload,
        signature: registration.signature,
        signerPublicKey: s.parties.miner.phone.spkiBase64,
      });
      expect(body.steps[0].location).toEqual({ latitude: '-15.419012', longitude: '28.288105' });
    }
    for (const step of (await s.view('transporter')).steps) expect(step).not.toHaveProperty('evidence');
  });
});

describe('the consignment view: a row edited after anchoring', () => {
  it('weight_mg edited: mismatch, exactly one record_tampered alert, held, and the next anchor waits', async () => {
    const s = await setup();
    const registration = await s.sync('miner', 'registration');
    await s.anchor();
    await t.db.query("UPDATE transactions SET weight_mg = '1400000' WHERE id = $1", [registration.transactionId]);
    const { rows: [{ chain_tx_hash: txHash, consignment_id: consignmentId }] } = await t.db.query(
      'SELECT chain_tx_hash, consignment_id FROM transactions WHERE id = $1',
      [registration.transactionId],
    );

    // A transporter's scan raises it: whoever views, the check runs.
    const body = await s.view('transporter');

    expect(body.steps[0].check).toEqual({ result: 'mismatch' });
    expect(body.consignment.held).toBe(true);
    expect(await tamperedAlerts(registration.transactionId)).toEqual([
      {
        type: 'record_tampered',
        severity: 'high',
        status: 'open',
        details: { source: 'verification', fields: ['weight_mg'], chainTxHash: `0x${txHash.toString('hex')}` },
      },
    ]);
    expect(await isConsignmentHeld(t.db, consignmentId)).toBe(true);

    // The officer sees the field names and the new alert.
    const officerBody = await s.view('officer');
    expect(officerBody.steps[0].check).toEqual({ result: 'mismatch', fields: ['weight_mg'] });
    expect(officerBody.steps[0].alerts).toEqual([{ id: expect.any(String), type: 'record_tampered', status: 'open' }]);

    // The next step is accepted by sync, but the worker leaves it while the alert is open.
    const handoff = await s.sync('transporter', 'handoff');
    expect(handoff).toMatchObject({ outcome: 'created' });
    expect(await s.anchor()).toEqual(['idle']);
    const { rows: [{ anchor_status: handoffStatus }] } = await t.db.query('SELECT anchor_status FROM transactions WHERE id = $1', [handoff.transactionId]);
    expect(handoffStatus).toBe('pending');

    // Viewing again adds no second alert.
    await s.view('buyer');
    expect(await allTamperedAlerts()).toHaveLength(1);
  });

  it('captured_at edited by one microsecond: caught, and still shown as ISO', async () => {
    const s = await setup();
    const registration = await s.sync('miner', 'registration');
    await s.anchor();
    await t.db.query("UPDATE transactions SET captured_at = captured_at + interval '1 microsecond' WHERE id = $1", [registration.transactionId]);

    const body = await s.view('officer');

    expect(body.steps[0].check).toEqual({ result: 'mismatch', fields: ['captured_at'] });
    expect(body.steps[0].capturedAt).toBe('2026-11-10T08:00:00.000Z');
    expect(body.consignment.held).toBe(true);
    expect((await tamperedAlerts(registration.transactionId)).map((a) => a.details.fields)).toEqual([['captured_at']]);
  });
});

describe('the consignment view: the chain unavailable', () => {
  it('reader down: chain_unavailable for confirmed steps, and no alert', async () => {
    const s = await setup();
    await s.sync('miner', 'registration');
    await s.anchor();
    s.fakeReader.control.failRpc();

    const body = await s.view('officer');

    expect(body.steps[0].check).toEqual({ result: 'chain_unavailable' });
    expect(body.consignment.held).toBe(false);
    expect(await allTamperedAlerts()).toEqual([]);
  });

  it('no reader configured: chain_unavailable, and no alert', async () => {
    const s = await setup({ reader: null });
    await s.sync('miner', 'registration');
    await s.anchor();

    const body = await s.view('officer');

    expect(body.steps[0].check).toEqual({ result: 'chain_unavailable' });
    expect(await allTamperedAlerts()).toEqual([]);
  });
});
