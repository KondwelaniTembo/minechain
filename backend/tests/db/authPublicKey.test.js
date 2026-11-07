import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser } from './fixtures.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';

const t = useTestDb();

// The whole stack as server.js wires it, on the test's own connection, so the test's
// ROLLBACK undoes everything. Requests go one at a time: one connection, one query at once.
// Fixture users have a fake password hash and cannot log in, so tokens are signed directly,
// exactly as a login would issue them.
function realStack() {
  const services = createServices({ db: t.db, config: FAKE_CONFIG });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;
  return { app, tokenFor };
}

// Throwaway keys, in memory only.
const newKey = (namedCurve = 'prime256v1') => {
  const der = generateKeyPairSync('ec', { namedCurve }).publicKey.export({ type: 'spki', format: 'der' });
  return { der, base64: der.toString('base64') };
};
const KEY = newKey();
const OTHER_KEY = newKey();
// Computed here, not with the service's code.
const fingerprintOf = (der) => createHash('sha256').update(der).digest('hex');

const putKey = (app, token, publicKey) =>
  request(app).put('/auth/me/public-key').set('Authorization', `Bearer ${token}`).send({ publicKey });
const me = (app, token) => request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);

const activeUser = (overrides = {}) => insertUser(t.db, { role: 'miner', status: 'active', ...overrides });

async function storedKey(id) {
  const { rows } = await t.db.query('SELECT public_key FROM users WHERE id = $1', [id]);
  return rows[0].public_key;
}

async function keyEntryCount(id) {
  const { rows } = await t.db.query(
    "SELECT count(*)::int AS n FROM audit_logs WHERE action = 'user.key_register' AND entity_id = $1",
    [id],
  );
  return rows[0].n;
}

describe('PUT /auth/me/public-key through the real stack', () => {
  it('registers the key, and /auth/me then shows its fingerprint', async () => {
    const { app, tokenFor } = realStack();
    const miner = await activeUser();
    const token = await tokenFor(miner);
    expect((await me(app, token)).body.user.publicKeyFingerprint).toBeNull();

    const res = await putKey(app, token, KEY.base64);

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.user).toMatchObject({ id: miner.id, publicKeyFingerprint: fingerprintOf(KEY.der) });
    expect(res.text).not.toContain(KEY.base64);
    expect((await storedKey(miner.id)).equals(KEY.der)).toBe(true);
    expect(await keyEntryCount(miner.id)).toBe(1);

    const after = await me(app, token);
    expect(after.body.user.publicKeyFingerprint).toBe(fingerprintOf(KEY.der));
  });

  it('answers a repeat of the same key with the same 200 and writes nothing more', async () => {
    const { app, tokenFor } = realStack();
    const miner = await activeUser();
    const token = await tokenFor(miner);
    const first = await putKey(app, token, KEY.base64);

    const again = await putKey(app, token, KEY.base64);

    expect(again.status).toBe(200);
    expect(again.body).toEqual(first.body);
    expect(await keyEntryCount(miner.id)).toBe(1);
  });

  it('refuses a different key with 409 PUBLIC_KEY_ALREADY_REGISTERED and keeps the first', async () => {
    const { app, tokenFor } = realStack();
    const miner = await activeUser();
    const token = await tokenFor(miner);
    await putKey(app, token, KEY.base64);

    const res = await putKey(app, token, OTHER_KEY.base64);

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('PUBLIC_KEY_ALREADY_REGISTERED');
    expect(res.headers['cache-control']).toBe('no-store');
    expect((await storedKey(miner.id)).equals(KEY.der)).toBe(true);
    expect(await keyEntryCount(miner.id)).toBe(1);
  });

  it('refuses a secp256k1 key with 400 INVALID_PUBLIC_KEY and stores nothing', async () => {
    const { app, tokenFor } = realStack();
    const miner = await activeUser();

    const res = await putKey(app, await tokenFor(miner), newKey('secp256k1').base64);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('INVALID_PUBLIC_KEY');
    expect(await storedKey(miner.id)).toBeNull();
    expect(await keyEntryCount(miner.id)).toBe(0);
  });

  it('refuses a key already on another account with 409 PUBLIC_KEY_IN_USE', async () => {
    const { app, tokenFor } = realStack();
    const owner = await activeUser();
    const buyer = await activeUser({ role: 'buyer' });
    await putKey(app, await tokenFor(owner), KEY.base64);

    const res = await putKey(app, await tokenFor(buyer), KEY.base64);

    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('PUBLIC_KEY_IN_USE');
    expect(await storedKey(buyer.id)).toBeNull();
  });

  it('refuses an officer with 403 before the key is even looked at', async () => {
    const { app, tokenFor } = realStack();
    const officer = await activeUser({ role: 'officer' });

    const res = await putKey(app, await tokenFor(officer), KEY.base64);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(await storedKey(officer.id)).toBeNull();
  });

  it('refuses a suspended user with 403 ACCOUNT_SUSPENDED', async () => {
    const { app, tokenFor } = realStack();
    const miner = await insertUser(t.db, { role: 'miner', status: 'suspended', status_reason: 'Lost device reported' });

    const res = await putKey(app, await tokenFor(miner), KEY.base64);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('ACCOUNT_SUSPENDED');
    expect(await storedKey(miner.id)).toBeNull();
  });
});
