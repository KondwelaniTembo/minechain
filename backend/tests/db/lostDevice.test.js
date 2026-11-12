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
// Fixture users cannot log in (fake hash), so tokens are signed as a login would issue them.
function realStack() {
  const services = createServices({ db: t.db, config: FAKE_CONFIG });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;
  return { app, tokenFor };
}

// Throwaway keys, in memory only: the lost phone's and the new phone's.
const newKey = () => {
  const der = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).publicKey.export({ type: 'spki', format: 'der' });
  return { der, base64: der.toString('base64'), fingerprint: createHash('sha256').update(der).digest('hex') };
};
const OLD_PHONE = newKey();
const NEW_PHONE = newKey();

const auth = (req, token) => req.set('Authorization', `Bearer ${token}`);
const me = (app, token) => auth(request(app).get('/auth/me'), token);
const putKey = (app, token, key) => auth(request(app).put('/auth/me/public-key'), token).send({ publicKey: key.base64 });
const adminAct = (app, token, id, action, body) => {
  const req = auth(request(app).post(`/admin/users/${id}/${action}`), token);
  return body === undefined ? req : req.send(body);
};

async function actionsFor(id) {
  const { rows } = await t.db.query('SELECT action FROM audit_logs WHERE entity_id = $1 ORDER BY id', [id]);
  return rows.map((r) => r.action);
}

describe('the lost-device procedure through the real stack (signing-spec, section 2)', () => {
  it('register, suspend, reset, reactivate, then register the new phone', async () => {
    const { app, tokenFor } = realStack();
    const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
    const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
    const adminToken = await tokenFor(admin);
    // A real user would log in again on the new phone; the token says the same thing.
    const minerToken = await tokenFor(miner);

    // 1. The first phone registers its key.
    expect((await putKey(app, minerToken, OLD_PHONE)).status).toBe(200);

    // The phone is lost. A reset is refused while the account is still active.
    const tooEarly = await adminAct(app, adminToken, miner.id, 'reset-key', { reason: 'Lost device reported' });
    expect(tooEarly.status).toBe(409);
    expect(tooEarly.body.error.code).toBe('INVALID_STATUS_TRANSITION');

    // 2. Suspend: every request with the old phone's token is refused at once.
    expect((await adminAct(app, adminToken, miner.id, 'suspend', { reason: 'Lost device reported' })).status).toBe(200);
    expect((await me(app, minerToken)).body.error.code).toBe('ACCOUNT_SUSPENDED');

    // 3. Reset the key.
    const reset = await adminAct(app, adminToken, miner.id, 'reset-key', { reason: 'Lost device reported' });
    expect(reset.status).toBe(200);
    expect(reset.headers['cache-control']).toBe('no-store');
    expect(reset.body.user).toMatchObject({ status: 'suspended', publicKeyFingerprint: null });

    // A second reset finds nothing to remove.
    const again = await adminAct(app, adminToken, miner.id, 'reset-key', { reason: 'Lost device reported' });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('NO_PUBLIC_KEY');

    // 4. Reactivate, once the real user is confirmed. The account now has no key.
    expect((await adminAct(app, adminToken, miner.id, 'reactivate')).status).toBe(200);
    const between = await me(app, minerToken);
    expect(between.status).toBe(200);
    expect(between.body.user.publicKeyFingerprint).toBeNull();

    // 5. The new phone registers its own key.
    const registered = await putKey(app, minerToken, NEW_PHONE);
    expect(registered.status).toBe(200);
    expect(registered.body.user.publicKeyFingerprint).toBe(NEW_PHONE.fingerprint);

    // /auth/me shows the new phone's key, not the old one.
    const after = await me(app, minerToken);
    expect(after.body.user.publicKeyFingerprint).toBe(NEW_PHONE.fingerprint);
    expect(after.body.user.publicKeyFingerprint).not.toBe(OLD_PHONE.fingerprint);

    // The old phone's key can no longer replace it: changing keys needs another reset.
    const oldAgain = await putKey(app, minerToken, OLD_PHONE);
    expect(oldAgain.status).toBe(409);
    expect(oldAgain.body.error.code).toBe('PUBLIC_KEY_ALREADY_REGISTERED');

    // The whole story is in the audit log, in order. The refused requests left no entries.
    expect(await actionsFor(miner.id)).toEqual([
      'user.key_register',
      'user.suspend',
      'user.key_reset',
      'user.reactivate',
      'user.key_register',
    ]);
  });

  it('refuses a reset-key from a non-admin, even the account owner', async () => {
    const { app, tokenFor } = realStack();
    const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
    const minerToken = await tokenFor(miner);
    await putKey(app, minerToken, OLD_PHONE);

    const res = await adminAct(app, minerToken, miner.id, 'reset-key', { reason: 'I lost my phone' });

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
});
