import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser, insertCampusZone } from './fixtures.js';
import { anchorUntilIdle, auth, bindRealStack, freeLock, loggedInSigner, silentLog, stepItem, syncSteps } from './realStackHelpers.js';
import { createAnchorService } from '../../src/services/anchorService.js';
import { isConsignmentHeld } from '../../src/services/anchorQueue.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';

// An officer's decision end to end (app endpoints plan, B1.3): accounts made through the
// API, real P-256 signatures over HTTP, a flagged handoff that holds its consignment, the
// officer listing and dismissing the alert over HTTP, and the anchoring worker against the
// in-memory chain. No test here touches Sepolia.
//
// The handoff is 12% light, not 20% as first planned (decided 15 Nov 2026): the quantity rule
// compares a step with the previous accepted step AND the registration, and after a 20%
// light handoff no purchase weight is within 10% of both, so the purchase could never be
// accepted. 12% is still over the rule, and 1.4 kg is within 10% of both 1.32 and 1.5 kg.
//
// test:db runs files in parallel, and nextId() restarts at 1 in every file, so every item
// here gets a random step id instead.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const GWEI = 1_000_000_000n;
const ANCHOR_CONFIG = Object.freeze({ confirmations: 2, maxAttempts: 5, maxFeePerGasWei: 50n * GWEI });

// Weights in whole milligrams, as signed.
const REGISTERED_MG = '1500000';
const HANDOFF_MG = '1320000';
const PURCHASE_MG = '1400000';

const NOTES = 'Weighed again at the depot with a checked scale: the load is complete';

beforeEach(async () => {
  await insertCampusZone(t.db);
});

const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

const get = (app, path, token) => auth(request(app).get(path), token);
const post = (app, path, token, body) => auth(request(app).post(path), token).send(body);

async function setup() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const miner = await loggedInSigner(app, adminToken, 'miner');
  const transporter = await loggedInSigner(app, adminToken, 'transporter');
  const buyer = await loggedInSigner(app, adminToken, 'buyer');
  // Officers are created by an administrator and activated (FR-10); that path has its own
  // tests, so the officer here is a fixture row with a token signed as a login would.
  const officerRow = await insertUser(t.db, { role: 'officer', status: 'active' });
  const officer = { id: officerRow.id, token: await tokenFor({ id: officerRow.id, role: 'officer' }) };

  const fake = createFakeChainClient();
  const worker = createAnchorService({ db: t.db, chain: fake.client, config: ANCHOR_CONFIG, lock: freeLock, log: silentLog() });
  const anchor = () => anchorUntilIdle(worker, fake, { confirmations: ANCHOR_CONFIG.confirmations });

  return { app, adminToken, miner, transporter, buyer, officer, fake, anchor, qrCode: `MC-ALERT-${randomUUID()}` };
}

async function consignmentOf(qrCode) {
  const { rows } = await t.db.query('SELECT id, stage, chain_id FROM consignments WHERE qr_code = $1', [qrCode]);
  return rows[0];
}

const hex = (bytes) => `0x${bytes.toString('hex')}`;

describe('an officer clears a flagged handoff through the real stack', () => {
  it('lists it, dismisses it over HTTP, and the consignment anchors through to the purchase', async () => {
    const { app, adminToken, miner, transporter, buyer, officer, fake, anchor, qrCode } = await setup();

    // ---------- registration, anchored ----------
    const registered = await syncSteps(app, miner, [item(miner, 'registration', qrCode, { weightMg: REGISTERED_MG })]);
    expect(registered.body.results[0]).toMatchObject({ outcome: 'created' });
    expect(await anchor()).toEqual(['sent', 'idle']);

    // ---------- handoff 12% light: flagged, consignment held ----------
    const handedOff = await syncSteps(app, transporter, [item(transporter, 'handoff', qrCode, { weightMg: HANDOFF_MG })]);
    const handoff = handedOff.body.results[0];
    expect(handoff).toMatchObject({ outcome: 'flagged', code: 'QUANTITY_DISCREPANCY', alerts: ['quantity_discrepancy'] });
    const consignment = await consignmentOf(qrCode);
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(true);
    expect(await anchor()).toEqual(['idle']);

    // ---------- purchase: deferred behind the flagged handoff ----------
    const purchase = item(buyer, 'purchase', qrCode, { weightMg: PURCHASE_MG });
    expect((await syncSteps(app, buyer, [purchase])).body.results[0]).toMatchObject({ outcome: 'deferred', code: 'STAGE_NOT_READY' });

    // ---------- the officer's queue ----------
    const queue = await get(app, '/alerts', officer.token);
    expect(queue.status).toBe(200);
    expect(queue.headers['cache-control']).toBe('no-store');
    expect(queue.body).toMatchObject({ total: 1, limit: 20, offset: 0 });
    const [listed] = queue.body.alerts;
    expect(listed).toMatchObject({
      type: 'quantity_discrepancy',
      severity: 'medium',
      status: 'open',
      step: { id: handoff.transactionId, type: 'handoff', reviewStatus: 'flagged', anchorStatus: 'pending' },
      consignment: { id: consignment.id, qrCode, stage: 'registered', held: true },
      actor: { id: transporter.user.id, username: transporter.username, role: 'transporter' },
      review: null,
    });
    // The account's full name was given at registration; it never reaches the alert view.
    expect(JSON.stringify(queue.body)).not.toContain('Chain test');

    const detail = await get(app, `/alerts/${listed.id}`, officer.token);
    expect(detail.status).toBe(200);
    expect(detail.body.alert).toMatchObject({ id: listed.id, otherAlerts: [] });

    // An administrator can see neither the queue nor decide (Scope (5)).
    expect((await get(app, '/alerts', adminToken)).status).toBe(403);
    expect((await post(app, `/alerts/${listed.id}/dismiss`, adminToken, { notes: NOTES })).status).toBe(403);

    // ---------- "Clear, no problem" ----------
    const dismissed = await post(app, `/alerts/${listed.id}/dismiss`, officer.token, { notes: NOTES });

    expect(dismissed.status).toBe(200);
    expect(dismissed.headers['cache-control']).toBe('no-store');
    expect(dismissed.body.step).toEqual({ id: handoff.transactionId, reviewStatus: 'cleared' });
    expect(dismissed.body.consignment).toEqual({ id: consignment.id, stage: 'in_transit', held: false });
    expect(dismissed.body.alert).toMatchObject({ status: 'dismissed', review: { by: { id: officer.id }, notes: NOTES } });

    const { rows: audits } = await t.db.query(
      "SELECT actor_id, details, host(ip_address) AS ip FROM audit_logs WHERE action = 'alert.dismiss' AND entity_id = $1",
      [listed.id],
    );
    expect(audits).toEqual([
      {
        actor_id: officer.id,
        details: {
          notes: NOTES,
          alertType: 'quantity_discrepancy',
          transactionId: handoff.transactionId,
          stepStatus: { from: 'flagged', to: 'cleared' },
          stage: { from: 'registered', to: 'in_transit' },
        },
        // Supertest connects over loopback; the address is whatever Express resolved.
        ip: expect.any(String),
      },
    ]);

    // The queue is empty; the decision is in the closed list.
    expect((await get(app, '/alerts', officer.token)).body).toMatchObject({ alerts: [], total: 0 });
    const closed = await get(app, '/alerts?status=dismissed', officer.token);
    expect(closed.body.alerts.map((a) => a.id)).toEqual([listed.id]);

    // A second decision on the same alert is refused.
    const again = await post(app, `/alerts/${listed.id}/review`, officer.token, { notes: NOTES });
    expect(again.status).toBe(409);
    expect(again.body.error).toEqual({
      code: 'INVALID_STATUS_TRANSITION',
      message: 'Only an open alert can be reviewed. This alert is dismissed.',
    });

    // ---------- the hold is gone: the handoff anchors ----------
    expect(await isConsignmentHeld(t.db, consignment.id)).toBe(false);
    expect(await anchor()).toEqual(['sent', 'idle']);
    const chainId = hex(consignment.chain_id);
    expect((await fake.client.getConsignment(chainId)).stage).toBe('InTransit');

    // ---------- the same signed purchase, sent again, is now accepted ----------
    const resent = await syncSteps(app, buyer, [purchase]);
    expect(resent.body.results[0]).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect((await consignmentOf(qrCode)).stage).toBe('purchased');
    expect(await anchor()).toEqual(['sent', 'idle']);

    expect(fake.control.records.signed.map((s) => s.functionName)).toEqual(['registerConsignment', 'recordHandoff', 'recordPurchase']);
    expect((await fake.client.getConsignment(chainId)).stage).toBe('Purchased');
  });
});
