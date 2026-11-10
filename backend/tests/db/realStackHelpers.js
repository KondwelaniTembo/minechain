// Shared helpers for the DB tests that drive the whole stack: a phone's key and signatures,
// signed sync items, HTTP calls, and the anchoring worker's test doubles. Moved here from
// syncChain.test.js and anchorService.test.js so later chain tests reuse them instead of
// copying them.
import { expect } from 'vitest';
import request from 'supertest';
import { generateKeyPairSync, sign } from 'node:crypto';
import { FAKE_CONFIG, insertUser } from './fixtures.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';
import { canonicalise } from '../../src/services/stepPayload.js';

export const auth = (req, token) => req.set('Authorization', `Bearer ${token}`);

// A phone: a throwaway P-256 key pair in memory, like the one in the Android Keystore.
export function newPhone() {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { spkiBase64: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'), privateKey };
}
// SHA256withECDSA over the payload bytes, DER, base64: what the app sends.
export const signWith = (phone, payload) => sign('sha256', Buffer.from(payload, 'utf8'), phone.privateKey).toString('base64');

let counter = 0;
export const nextId = () => {
  counter += 1;
  return `6f1d2c3a-0000-4000-8000-${String(counter).padStart(12, '0')}`;
};

// One signed item for a party. All values fake; coordinates inside the ZCAS demo campus.
export function stepItem(party, type, qrCode, overrides = {}) {
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

export const syncSteps = (app, party, steps) => auth(request(app).post('/sync/steps'), party.token).send({ steps });

// The helpers that need the test's database, bound to the handle from useTestDb(). t.db is
// read at each call, not here, because useTestDb sets it fresh in every beforeEach.
export function bindRealStack(t) {
  // The whole stack as server.js wires it, on the test's own connection, so the test's
  // ROLLBACK undoes everything. Requests go one at a time: one connection, one query at once.
  // Fixture users cannot log in (fake hash), so tokens are signed as a login would issue them.
  function realStack() {
    const services = createServices({ db: t.db, config: FAKE_CONFIG });
    const app = createApp({ db: t.db, services });
    const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;
    return { app, tokenFor };
  }

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

  async function stageOf(qrCode) {
    const { rows } = await t.db.query('SELECT stage FROM consignments WHERE qr_code = $1', [qrCode]);
    return rows[0]?.stage;
  }

  return { realStack, signer, stageOf };
}

// ---------- the anchoring worker's test doubles ----------

// Most tests do not care about the advisory lock (its own test is in anchorService.test.js),
// so they get one that is always free.
export const freeLock = async () => ({ acquired: true, isLost: () => false, release: async () => {} });

export const silentLog = () => ({ warn: () => {}, error: () => {} });
