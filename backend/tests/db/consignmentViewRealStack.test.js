import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertCampusZone, insertUser } from './fixtures.js';
import { anchorUntilIdle, auth, freeLock, loggedInSigner, silentLog, stepItem, syncSteps } from './realStackHelpers.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';
import { createAnchorService } from '../../src/services/anchorService.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';
import { createFakeChainReader } from '../fakes/fakeChainReader.js';

// The consignment view end to end (app endpoints plan, B2.5): accounts made through the API,
// real P-256 signatures over HTTP, the anchoring worker on the in-memory chain, the fake
// reader over that same chain wired into createServices as server.js wires the real one, and
// scans over HTTP. No test here touches Sepolia.
//
// test:db runs files in parallel, so every step id and QR code here is random.

const t = useTestDb();

const GWEI = 1_000_000_000n;
const CONFIRMATIONS = 2;
const ANCHOR_CONFIG = Object.freeze({ confirmations: CONFIRMATIONS, maxAttempts: 5, maxFeePerGasWei: 50n * GWEI });

beforeEach(async () => {
  await insertCampusZone(t.db);
});

const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

async function setup() {
  const fake = createFakeChainClient();
  const reader = createFakeChainReader({ chain: fake.client });
  const services = createServices({
    db: t.db,
    config: { ...FAKE_CONFIG, anchor: { confirmations: CONFIRMATIONS } },
    chainReader: reader.reader,
  });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;

  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const miner = await loggedInSigner(app, adminToken, 'miner');
  const transporter = await loggedInSigner(app, adminToken, 'transporter');
  const otherTransporter = await loggedInSigner(app, adminToken, 'transporter');
  const buyer = await loggedInSigner(app, adminToken, 'buyer');
  // Officers are created by an administrator and activated (FR-10); that path has its own
  // tests, so the officer here is a fixture row with a token signed as a login would.
  const officerRow = await insertUser(t.db, { role: 'officer', status: 'active' });
  const officer = { token: await tokenFor({ id: officerRow.id, role: 'officer' }) };

  const worker = createAnchorService({ db: t.db, chain: fake.client, config: ANCHOR_CONFIG, lock: freeLock, log: silentLog() });
  const anchor = () => anchorUntilIdle(worker, fake, { confirmations: CONFIRMATIONS });

  return { app, adminToken, miner, transporter, otherTransporter, buyer, officer, anchor, reader };
}

const scan = (app, qrCode, token) => auth(request(app).get(`/consignments/by-qr/${encodeURIComponent(qrCode)}`), token);

async function synced(app, party, type, qrCode) {
  const signed = item(party, type, qrCode);
  const res = await syncSteps(app, party, [signed]);
  expect(res.body.results[0]).toMatchObject({ outcome: 'created' });
  return signed;
}

describe('the consignment view through the real stack', () => {
  it('register, hand off and purchase over HTTP, anchor, then scan as each role', async () => {
    const s = await setup();
    const qrCode = `MC-SCAN-${randomUUID()}`;

    const registration = await synced(s.app, s.miner, 'registration', qrCode);
    await synced(s.app, s.transporter, 'handoff', qrCode);
    await synced(s.app, s.buyer, 'purchase', qrCode);
    expect((await s.anchor()).at(-1)).toBe('idle');

    // ---------- officer: everything, every step matching the chain ----------
    const asOfficer = await scan(s.app, qrCode, s.officer.token);
    expect(asOfficer.status).toBe(200);
    expect(asOfficer.headers['cache-control']).toBe('no-store');
    expect(asOfficer.body.consignment).toMatchObject({ qrCode, stage: 'purchased', held: false, weightsHidden: false });
    expect(asOfficer.body.steps.map((step) => [step.type, step.check.result, step.reviewStatus])).toEqual([
      ['registration', 'match', 'passed'],
      ['handoff', 'match', 'passed'],
      ['purchase', 'match', 'passed'],
    ]);
    expect(asOfficer.body.steps[0].evidence).toEqual({
      signedPayload: registration.payload,
      signature: registration.signature,
      signerPublicKey: s.miner.phone.spkiBase64,
    });
    expect(asOfficer.body.steps[0].actor).toEqual({ role: 'miner', username: s.miner.username });

    // ---------- the transporter who weighed: weights, no GPS, no names, no evidence ----------
    const asTransporter = await scan(s.app, qrCode, s.transporter.token);
    expect(asTransporter.status).toBe(200);
    expect(asTransporter.body.steps.map((step) => step.check.result)).toEqual(['match', 'match', 'match']);
    expect(asTransporter.body.steps.map((step) => step.weightMg)).toEqual(['1500000', '1500000', '1500000']);
    expect(asTransporter.body.steps.map((step) => step.byYou)).toEqual([false, true, false]);
    for (const step of asTransporter.body.steps) {
      expect(step).not.toHaveProperty('location');
      expect(step).not.toHaveProperty('evidence');
      expect(Object.keys(step.actor)).toEqual(['role']);
    }

    // ---------- a transporter who has not weighed: blind ----------
    const blind = await scan(s.app, qrCode, s.otherTransporter.token);
    expect(blind.status).toBe(200);
    expect(blind.body.consignment.weightsHidden).toBe(true);
    for (const step of blind.body.steps) {
      expect(step).not.toHaveProperty('weightMg');
      expect(step.anchor).not.toHaveProperty('chainTxHash');
    }

    // ---------- the owning buyer: GPS and evidence ----------
    const asBuyer = await scan(s.app, qrCode, s.buyer.token);
    expect(asBuyer.status).toBe(200);
    expect(asBuyer.body.steps.map((step) => step.check.result)).toEqual(['match', 'match', 'match']);
    expect(asBuyer.body.steps[0].location).toEqual({ latitude: '-15.419012', longitude: '28.288105' });
    expect(asBuyer.body.steps[0].evidence.signedPayload).toBe(registration.payload);
    expect(asBuyer.body.steps[0]).not.toHaveProperty('reviewStatus');

    // No full name given at registration reaches any body.
    for (const res of [asOfficer, asTransporter, blind, asBuyer]) expect(JSON.stringify(res.body)).not.toContain('Chain test');
  });

  it('an unknown code gets exactly the 404 a buyer gets for a consignment still at registered', async () => {
    const s = await setup();
    const qrCode = `MC-SCAN-${randomUUID()}`;
    await synced(s.app, s.miner, 'registration', qrCode);

    const unknown = await scan(s.app, `MC-NONE-${randomUUID()}`, s.buyer.token);
    const registered = await scan(s.app, qrCode, s.buyer.token);

    expect(unknown.status).toBe(404);
    expect(unknown.body).toEqual({ error: { code: 'CONSIGNMENT_NOT_FOUND', message: 'No consignment has this QR code.' } });
    expect(registered.status).toBe(404);
    expect(registered.body).toEqual(unknown.body);
    expect(registered.headers['cache-control']).toBe('no-store');
    // Refused before any chain call.
    expect(s.reader.control.calls).toEqual([]);
  });

  it('a miner and an administrator are refused', async () => {
    const s = await setup();

    expect((await scan(s.app, 'MC-DEMO-000001', s.miner.token)).status).toBe(403);
    expect((await scan(s.app, 'MC-DEMO-000001', s.adminToken)).status).toBe(403);
  });
});
