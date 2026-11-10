import { describe, it, expect, beforeEach } from 'vitest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser, insertCampusZone } from './fixtures.js';
import { anchorUntilIdle, bindRealStack, freeLock, loggedInSigner, silentLog, stepItem, syncSteps } from './realStackHelpers.js';
import { createAnchorService } from '../../src/services/anchorService.js';
import { isConsignmentHeld, nextEligibleStep } from '../../src/services/anchorQueue.js';
import { FLAGGED_MESSAGES } from '../../src/services/anomalyChecks.js';
import { DEPLOY_BLOCK } from '../../src/chain/mineChainAbi.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';

// A flagged step end to end (Step 9.5): real accounts made through the API, real P-256
// signatures over HTTP, the anomaly rules in sync, and the anchoring worker against the
// in-memory chain. It proves the flagged step is caught, stored as evidence, holds its
// consignment, and never reaches the chain. No test here touches Sepolia.
//
// test:db runs files in parallel, and nextId() restarts at 1 in every file, so every item
// here gets a random step id instead.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const GWEI = 1_000_000_000n;
const ANCHOR_CONFIG = Object.freeze({ confirmations: 2, maxAttempts: 5, maxFeePerGasWei: 50n * GWEI });

// Weights in whole milligrams, as signed. The handoff is 20% lighter than the registration,
// twice the 10% the quantity rule allows.
const REGISTERED_MG = '1500000';
const HANDOFF_MG = '1200000';
const PURCHASE_MG = '1195000';

// The current STAGE_NOT_READY text, copied exactly so a change to it is a deliberate test
// change.
const STAGE_NOT_READY_MESSAGE =
  "This consignment is not ready for this step yet. An earlier step has not reached the server, or is waiting for an officer's review. Keep the record and sync again later.";

// The campus zone holds the test coordinates; its id is what every step's zone_id must be.
let zone;
beforeEach(async () => {
  zone = await insertCampusZone(t.db);
});

const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

// The stack, an administrator to approve the accounts, the three parties made through the
// API, a worker on a fresh fake chain, and a QR code no other test uses.
async function setup() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const miner = await loggedInSigner(app, adminToken, 'miner');
  const transporter = await loggedInSigner(app, adminToken, 'transporter');
  const buyer = await loggedInSigner(app, adminToken, 'buyer');

  const fake = createFakeChainClient();
  const worker = createAnchorService({ db: t.db, chain: fake.client, config: ANCHOR_CONFIG, lock: freeLock, log: silentLog() });
  const anchor = () => anchorUntilIdle(worker, fake, { confirmations: ANCHOR_CONFIG.confirmations });

  return { app, miner, transporter, buyer, fake, anchor, qrCode: `MC-FLAG-${randomUUID()}` };
}

async function consignmentOf(qrCode) {
  const { rows } = await t.db.query('SELECT id, stage, chain_id FROM consignments WHERE qr_code = $1', [qrCode]);
  return rows[0];
}

async function stepRow(transactionId) {
  const { rows } = await t.db.query(
    `SELECT type, review_status, anchor_status, zone_id, chain_tx_hash, block_number
       FROM transactions WHERE id = $1`,
    [transactionId],
  );
  return rows[0];
}

const hex = (bytes) => `0x${bytes.toString('hex')}`;

describe('a flagged step through the real stack and the anchoring worker', () => {
  it('stores a 20% lighter handoff as flagged, holds the consignment, and keeps it off the chain', async () => {
    const { app, miner, transporter, buyer, fake, anchor, qrCode } = await setup();

    // ---------- the registration, anchored before anything else happens ----------
    const registered = await syncSteps(app, miner, [item(miner, 'registration', qrCode, { weightMg: REGISTERED_MG })]);

    expect(registered.status).toBe(200);
    expect(registered.headers['cache-control']).toBe('no-store');
    const registration = registered.body.results[0];
    expect(registered.body.results).toEqual([
      { index: 0, stepId: expect.any(String), outcome: 'created', transactionId: expect.any(String), reviewStatus: 'passed' },
    ]);
    const consignment = await consignmentOf(qrCode);
    expect(consignment.stage).toBe('registered');
    expect((await stepRow(registration.transactionId)).zone_id).toBe(zone.id);

    expect((await nextEligibleStep(t.db))?.id).toBe(registration.transactionId);
    expect(await anchor()).toEqual(['sent', 'idle']);

    const anchoredRegistration = await stepRow(registration.transactionId);
    expect(anchoredRegistration).toMatchObject({ review_status: 'passed', anchor_status: 'confirmed' });
    expect(anchoredRegistration.block_number).not.toBeNull();
    expect(fake.control.records.signed.map((s) => s.functionName)).toEqual(['registerConsignment']);
    expect(hex(anchoredRegistration.chain_tx_hash)).toBe(fake.control.records.signed[0].hash);
    const chainId = hex(consignment.chain_id);
    expect((await fake.client.getConsignment(chainId)).stage).toBe('Registered');

    // ---------- the handoff, 20% lighter: flagged ----------
    const handedOff = await syncSteps(app, transporter, [item(transporter, 'handoff', qrCode, { weightMg: HANDOFF_MG })]);

    expect(handedOff.status).toBe(200);
    const handoff = handedOff.body.results[0];
    expect(handedOff.body.results).toEqual([
      {
        index: 0,
        stepId: expect.any(String),
        outcome: 'flagged',
        code: 'QUANTITY_DISCREPANCY',
        message: FLAGGED_MESSAGES.QUANTITY_DISCREPANCY,
        transactionId: expect.any(String),
        reviewStatus: 'flagged',
        alerts: ['quantity_discrepancy'],
      },
    ]);

    const { rows: alerts } = await t.db.query('SELECT type, severity, status, details FROM alerts WHERE transaction_id = $1', [
      handoff.transactionId,
    ]);
    // The previous accepted step IS the registration, so it is compared once, as the
    // registration, and there is no "previous" entry.
    expect(alerts).toEqual([
      {
        type: 'quantity_discrepancy',
        severity: 'medium',
        status: 'open',
        details: {
          weightMg: HANDOFF_MG,
          thresholdPercent: 10,
          failedBaselines: ['registration'],
          registration: { stepId: registration.transactionId, weightMg: REGISTERED_MG, differenceMg: '-300000', exceeded: true },
        },
      },
    ]);

    expect(await stepRow(handoff.transactionId)).toMatchObject({
      type: 'handoff',
      review_status: 'flagged',
      anchor_status: 'pending',
      zone_id: zone.id,
      chain_tx_hash: null,
    });
    // A flagged step never moves the stage.
    expect((await consignmentOf(qrCode)).stage).toBe('registered');

    const { rows: audits } = await t.db.query(
      `SELECT actor_id, details FROM audit_logs
        WHERE action = 'transaction.create' AND entity_type = 'transaction' AND entity_id = $1`,
      [handoff.transactionId],
    );
    expect(audits).toEqual([{ actor_id: transporter.user.id, details: { type: 'handoff', reviewStatus: 'flagged' } }]);

    // ---------- the hold ----------
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(true);
    expect(await nextEligibleStep(t.db)).toBeNull();

    // ---------- the purchase: deferred, because the flagged handoff did not move the stage ----------
    const purchased = await syncSteps(app, buyer, [item(buyer, 'purchase', qrCode, { weightMg: PURCHASE_MG })]);

    expect(purchased.status).toBe(200);
    expect(purchased.body.results).toEqual([
      { index: 0, stepId: expect.any(String), outcome: 'deferred', code: 'STAGE_NOT_READY', message: STAGE_NOT_READY_MESSAGE },
    ]);
    const { rows: buyerSteps } = await t.db.query('SELECT count(*)::int AS n FROM transactions WHERE actor_id = $1', [buyer.user.id]);
    expect(buyerSteps[0].n).toBe(0);
    const { rows: buyerAudits } = await t.db.query(
      "SELECT count(*)::int AS n FROM audit_logs WHERE action = 'transaction.create' AND actor_id = $1",
      [buyer.user.id],
    );
    expect(buyerAudits[0].n).toBe(0);
    expect((await consignmentOf(qrCode)).stage).toBe('registered');

    // ---------- the worker again: nothing more reaches the chain ----------
    expect(await anchor()).toEqual(['idle']);

    expect(await stepRow(handoff.transactionId)).toMatchObject({ anchor_status: 'pending', chain_tx_hash: null });
    expect(fake.control.records.signed).toHaveLength(1);
    expect(fake.control.records.mined).toEqual([expect.objectContaining({ status: 1 })]);
    expect((await fake.client.getConsignment(chainId)).stage).toBe('Registered');
    const events = await fake.client.getLogs(chainId, DEPLOY_BLOCK, await fake.client.getBlockNumber());
    expect(events.map((e) => e.name)).toEqual(['ConsignmentRegistered']);
  });

  it('holds a registration that was not anchored yet when a flagged handoff arrives', async () => {
    const { app, miner, transporter, fake, anchor, qrCode } = await setup();

    const registered = await syncSteps(app, miner, [item(miner, 'registration', qrCode, { weightMg: REGISTERED_MG })]);
    const handedOff = await syncSteps(app, transporter, [item(transporter, 'handoff', qrCode, { weightMg: HANDOFF_MG })]);

    expect(registered.body.results[0]).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect(handedOff.body.results[0]).toMatchObject({ outcome: 'flagged', code: 'QUANTITY_DISCREPANCY' });

    // The handoff's open alert holds the whole consignment (D3), the passed registration too.
    const consignment = await consignmentOf(qrCode);
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(true);
    expect(await nextEligibleStep(t.db)).toBeNull();
    expect(await anchor()).toEqual(['idle']);

    expect(fake.control.records.signed).toEqual([]);
    expect((await stepRow(registered.body.results[0].transactionId)).anchor_status).toBe('pending');
    expect((await stepRow(handedOff.body.results[0].transactionId)).anchor_status).toBe('pending');
  });
});
