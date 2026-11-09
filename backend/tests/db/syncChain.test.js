import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { generateKeyPairSync, sign } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser, insertCampusZone } from './fixtures.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';
import { canonicalise } from '../../src/services/stepPayload.js';

const t = useTestDb();

// The active campus zone, which holds the coordinates below, as a real deployment has.
beforeEach(async () => {
  await insertCampusZone(t.db);
});

// The whole stack as server.js wires it, on the test's own connection, so the test's
// ROLLBACK undoes everything. Requests go one at a time: one connection, one query at once.
// Fixture users cannot log in (fake hash), so tokens are signed as a login would issue them.
function realStack() {
  const services = createServices({ db: t.db, config: FAKE_CONFIG });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;
  return { app, tokenFor };
}

const auth = (req, token) => req.set('Authorization', `Bearer ${token}`);

// A phone: a throwaway P-256 key pair in memory, like the one in the Android Keystore.
function newPhone() {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { spkiBase64: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'), privateKey };
}
// SHA256withECDSA over the payload bytes, DER, base64: what the app sends.
const signWith = (phone, payload) => sign('sha256', Buffer.from(payload, 'utf8'), phone.privateKey).toString('base64');

// An active user who has registered their phone's key through the real endpoint.
async function signer(app, tokenFor, role) {
  const row = await insertUser(t.db, { role, status: 'active' });
  const user = { id: row.id, role };
  const token = await tokenFor(user);
  const phone = newPhone();
  const res = await auth(request(app).put('/auth/me/public-key'), token).send({ publicKey: phone.spkiBase64 });
  expect(res.status).toBe(200);
  return { user, token, phone };
}

let counter = 0;
const nextId = () => {
  counter += 1;
  return `6f1d2c3a-0000-4000-8000-${String(counter).padStart(12, '0')}`;
};

// One signed item for a party. All values fake; coordinates inside the ZCAS demo campus.
function stepItem(party, type, qrCode, overrides = {}) {
  const fields = {
    type,
    stepId: nextId(),
    actorId: party.user.id,
    qrCode,
    ...(type === 'registration' && { mineral: 'gold' }),
    weightMg: '1500000',
    latitude: '-15.419012',
    longitude: '28.288105',
    capturedAt: '2026-11-10T08:00:00.000Z',
    ...overrides,
  };
  const payload = canonicalise(fields);
  return { payload, signature: signWith(party.phone, payload) };
}

const syncSteps = (app, party, steps) => auth(request(app).post('/sync/steps'), party.token).send({ steps });

async function stageOf(qrCode) {
  const { rows } = await t.db.query('SELECT stage FROM consignments WHERE qr_code = $1', [qrCode]);
  return rows[0]?.stage;
}

describe('POST /sync/steps through the real stack', () => {
  it('records the full chain: miner registers, transporter hands off, buyer purchases', async () => {
    const { app, tokenFor } = realStack();
    const miner = await signer(app, tokenFor, 'miner');
    const transporter = await signer(app, tokenFor, 'transporter');
    const buyer = await signer(app, tokenFor, 'buyer');
    const qrCode = 'MC-CHAIN-000001';

    const registered = await syncSteps(app, miner, [stepItem(miner, 'registration', qrCode)]);
    const handedOff = await syncSteps(app, transporter, [stepItem(transporter, 'handoff', qrCode, { weightMg: '1495000' })]);
    const purchased = await syncSteps(app, buyer, [stepItem(buyer, 'purchase', qrCode, { weightMg: '1494500' })]);

    for (const res of [registered, handedOff, purchased]) {
      expect(res.status).toBe(200);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.body.results).toEqual([expect.objectContaining({ index: 0, outcome: 'created', reviewStatus: 'passed' })]);
    }
    expect(await stageOf(qrCode)).toBe('purchased');
    const { rows } = await t.db.query(
      `SELECT s.type, s.review_status, s.anchor_status FROM transactions s
         JOIN consignments c ON c.id = s.consignment_id WHERE c.qr_code = $1
        ORDER BY CASE s.type WHEN 'registration' THEN 1 WHEN 'handoff' THEN 2 ELSE 3 END`,
      [qrCode],
    );
    expect(rows).toEqual([
      { type: 'registration', review_status: 'passed', anchor_status: 'pending' },
      { type: 'handoff', review_status: 'passed', anchor_status: 'pending' },
      { type: 'purchase', review_status: 'passed', anchor_status: 'pending' },
    ]);
  });

  it('answers a resent batch with duplicate for every item and stores nothing new', async () => {
    const { app, tokenFor } = realStack();
    const miner = await signer(app, tokenFor, 'miner');
    const batch = [stepItem(miner, 'registration', 'MC-CHAIN-000101'), stepItem(miner, 'registration', 'MC-CHAIN-000102')];
    const first = await syncSteps(app, miner, batch);
    const { rows: before } = await t.db.query('SELECT count(*)::int AS n FROM transactions');

    // The response to the first sync was lost, so the app sends the same batch again.
    const again = await syncSteps(app, miner, batch);

    expect(again.status).toBe(200);
    expect(again.body.results.map((r) => r.outcome)).toEqual(['duplicate', 'duplicate']);
    expect(again.body.results.map((r) => r.transactionId)).toEqual(first.body.results.map((r) => r.transactionId));
    const { rows: after } = await t.db.query('SELECT count(*)::int AS n FROM transactions');
    expect(after[0].n).toBe(before[0].n);
  });

  it('defers a handoff that arrives before the registration, then accepts it unchanged', async () => {
    const { app, tokenFor } = realStack();
    const miner = await signer(app, tokenFor, 'miner');
    const transporter = await signer(app, tokenFor, 'transporter');
    const qrCode = 'MC-CHAIN-000201';
    const handoff = stepItem(transporter, 'handoff', qrCode);

    // The transporter's phone reaches a network first.
    const early = await syncSteps(app, transporter, [handoff]);
    expect(early.body.results[0]).toMatchObject({ outcome: 'deferred', code: 'CONSIGNMENT_NOT_FOUND' });

    await syncSteps(app, miner, [stepItem(miner, 'registration', qrCode)]);
    const later = await syncSteps(app, transporter, [handoff]);

    expect(later.body.results[0]).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect(await stageOf(qrCode)).toBe('in_transit');
  });

  it('stores a step with a bad signature as flagged, with an open alert, without moving the stage', async () => {
    const { app, tokenFor } = realStack();
    const miner = await signer(app, tokenFor, 'miner');
    const transporter = await signer(app, tokenFor, 'transporter');
    const qrCode = 'MC-CHAIN-000301';
    await syncSteps(app, miner, [stepItem(miner, 'registration', qrCode)]);
    // Signed by a phone that is not the transporter's registered one.
    const forged = stepItem({ ...transporter, phone: newPhone() }, 'handoff', qrCode);

    const res = await syncSteps(app, transporter, [forged]);

    expect(res.body.results[0]).toMatchObject({ outcome: 'flagged', code: 'INVALID_SIGNATURE', reviewStatus: 'flagged' });
    const { rows } = await t.db.query('SELECT type, severity, status FROM alerts WHERE transaction_id = $1', [
      res.body.results[0].transactionId,
    ]);
    expect(rows).toEqual([{ type: 'invalid_signature', severity: 'high', status: 'open' }]);
    expect(await stageOf(qrCode)).toBe('registered');
  });

  it('gives every outcome in one mixed batch, in order', async () => {
    const { app, tokenFor } = realStack();
    const miner = await signer(app, tokenFor, 'miner');
    const transporter = await signer(app, tokenFor, 'transporter');
    await syncSteps(app, miner, [stepItem(miner, 'registration', 'MC-CHAIN-000401'), stepItem(miner, 'registration', 'MC-CHAIN-000402')]);
    const good = stepItem(transporter, 'handoff', 'MC-CHAIN-000401');

    const res = await syncSteps(app, transporter, [
      good,
      good, // the same item again within the batch
      stepItem({ ...transporter, phone: newPhone() }, 'handoff', 'MC-CHAIN-000402'),
      { payload: 'not a signed record', signature: good.signature },
      stepItem(transporter, 'handoff', 'MC-CHAIN-NOT-YET'),
    ]);

    expect(res.status).toBe(200);
    expect(res.body.results.map((r) => [r.index, r.outcome, r.code ?? null])).toEqual([
      [0, 'created', null],
      [1, 'duplicate', null],
      [2, 'flagged', 'INVALID_SIGNATURE'],
      [3, 'rejected', 'PAYLOAD_MALFORMED'],
      [4, 'deferred', 'CONSIGNMENT_NOT_FOUND'],
    ]);
    expect(res.body.results[1].transactionId).toBe(res.body.results[0].transactionId);
    // Every refusal and deferral says why, in plain language.
    for (const r of res.body.results.filter((x) => x.code)) expect(r.message).toEqual(expect.any(String));
  });

  it('refuses the batch from an account that signs nothing, before any item is looked at', async () => {
    const { app, tokenFor } = realStack();
    const officerRow = await insertUser(t.db, { role: 'officer', status: 'active' });
    const officer = { user: { id: officerRow.id, role: 'officer' }, token: await tokenFor({ id: officerRow.id, role: 'officer' }) };

    const res = await syncSteps(app, officer, [{ payload: 'anything', signature: 'AAAA' }]);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('defers everything from a user whose key is not registered yet, and accepts it after registering', async () => {
    const { app, tokenFor } = realStack();
    const row = await insertUser(t.db, { role: 'miner', status: 'active' });
    const miner = { user: { id: row.id, role: 'miner' }, token: await tokenFor({ id: row.id, role: 'miner' }), phone: newPhone() };
    const item = stepItem(miner, 'registration', 'MC-CHAIN-000501');

    const early = await syncSteps(app, miner, [item]);
    expect(early.body.results[0]).toMatchObject({ outcome: 'deferred', code: 'NO_DEVICE_KEY' });

    await auth(request(app).put('/auth/me/public-key'), miner.token).send({ publicKey: miner.phone.spkiBase64 });
    const later = await syncSteps(app, miner, [item]);

    expect(later.body.results[0].outcome).toBe('created');
  });
});
