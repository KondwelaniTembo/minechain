// Password change through the whole stack (POST /auth/me/password): the fresh token works at
// once, every older token is refused, and nothing secret is written anywhere.
import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { decodeJwt } from 'jose';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser } from './fixtures.js';
import { auth, bindRealStack, loggedInSigner, newPhone, TEST_PASSPHRASE } from './realStackHelpers.js';
import { createTokenService } from '../../src/services/tokenService.js';

const t = useTestDb();
const { realStack } = bindRealStack(t);

const NEW_PASSWORD = 'copper hill solwezi';

// The same secret as the app, with a clock one minute behind: a token from an earlier login,
// "phone B". Older by construction, so no sleeping and no same-second luck.
const minuteAgo = createTokenService({
  secret: FAKE_CONFIG.jwtSecret,
  expiresInSeconds: FAKE_CONFIG.jwtExpiresInSeconds,
  now: () => Date.now() - 60 * 1000,
});

const me = (app, token) => auth(request(app).get('/auth/me'), token);
const changePassword = (app, token, body) => auth(request(app).post('/auth/me/password'), token).send(body);
const login = (app, username, password) => request(app).post('/auth/login').send({ username, password });

// A miner made through the API (register, approve, log in, register a key), logged in on
// phone A (a real login) and phone B (a token one minute older).
async function minerOnTwoPhones() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const miner = await loggedInSigner(app, adminToken, 'miner');
  const phoneB = (await minuteAgo.sign({ userId: miner.user.id, role: 'miner' })).token;
  // Control: before any change, both phones are in.
  expect((await me(app, miner.token)).status).toBe(200);
  expect((await me(app, phoneB)).status).toBe(200);
  return { app, adminToken, miner, phoneA: miner.token, phoneB };
}

async function auditFor(id) {
  const { rows } = await t.db.query('SELECT actor_id, action, details FROM audit_logs WHERE entity_id = $1 ORDER BY id', [id]);
  return rows;
}

async function cutOffOf(id) {
  const { rows } = await t.db.query('SELECT extract(epoch FROM tokens_valid_after)::bigint AS seconds FROM users WHERE id = $1', [id]);
  return rows[0].seconds === null ? null : Number(rows[0].seconds);
}

// Neither password, nor any Argon2 hash, in any audit entry or in the given response bodies.
async function expectNoPasswords(texts = []) {
  const { rows } = await t.db.query('SELECT details FROM audit_logs');
  const everything = [JSON.stringify(rows), ...texts].join('\n');
  expect(everything).not.toContain(TEST_PASSPHRASE);
  expect(everything).not.toContain(NEW_PASSWORD);
  expect(everything).not.toContain('$argon2');
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /auth/me/password through the real stack', () => {
  it('gives phone A a fresh token that works at once, and refuses phone B from then on', async () => {
    const logs = ['log', 'warn', 'error'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
    const { app, miner, phoneA, phoneB } = await minerOnTwoPhones();

    const res = await changePassword(app, phoneA, { currentPassword: TEST_PASSPHRASE, newPassword: NEW_PASSWORD });

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body).toMatchObject({ tokenType: 'Bearer', expiresIn: 3600, user: { id: miner.user.id, status: 'active' } });
    // The cut-off is the fresh token's own iat: one clock, the app server's.
    expect(await cutOffOf(miner.user.id)).toBe(decodeJwt(res.body.token).iat);

    // The fresh token works at once.
    const fresh = await me(app, res.body.token);
    expect(fresh.status).toBe(200);
    expect(fresh.body.user.id).toBe(miner.user.id);

    // Phone B's older token gets the ordinary "not valid" answer: nothing says why.
    const old = await me(app, phoneB);
    expect(old.status).toBe(401);
    expect(old.body).toEqual({ error: { code: 'TOKEN_INVALID', message: 'Your session is not valid. Please log in again.' } });
    expect(old.headers['www-authenticate']).toBe('Bearer realm="minechain", error="invalid_token"');

    // The old password no longer logs in; the new one does, with a token that works.
    expect((await login(app, miner.username, TEST_PASSPHRASE)).status).toBe(401);
    const relogin = await login(app, miner.username, NEW_PASSWORD);
    expect(relogin.status).toBe(200);
    expect((await me(app, relogin.body.token)).status).toBe(200);

    const entries = await auditFor(miner.user.id);
    expect(entries.filter((e) => e.action === 'user.password_change')).toEqual([
      { actor_id: miner.user.id, action: 'user.password_change', details: { sessionsEnded: true } },
    ]);
    await expectNoPasswords([res.text, old.text, relogin.text]);
    const logged = logs.flatMap((spy) => spy.mock.calls.map((call) => String(call))).join('\n');
    expect(logged).not.toContain(TEST_PASSPHRASE);
    expect(logged).not.toContain(NEW_PASSWORD);
  });

  it('refuses a wrong current password with 400 (not 401), records it, and changes nothing', async () => {
    const { app, miner, phoneA, phoneB } = await minerOnTwoPhones();

    const res = await changePassword(app, phoneA, { currentPassword: 'not my password at all', newPassword: NEW_PASSWORD });

    expect(res.status).toBe(400);
    expect(res.body.error).toEqual({
      code: 'CURRENT_PASSWORD_INCORRECT',
      message: 'Your current password is not correct.',
      details: [{ field: 'currentPassword', message: 'is not correct' }],
    });
    // Still logged in on both phones; the password and cut-off are as they were.
    expect((await me(app, phoneA)).status).toBe(200);
    expect((await me(app, phoneB)).status).toBe(200);
    expect(await cutOffOf(miner.user.id)).toBeNull();
    expect((await login(app, miner.username, TEST_PASSPHRASE)).status).toBe(200);

    const failed = (await auditFor(miner.user.id)).filter((e) => e.action === 'user.password_change_failed');
    expect(failed).toEqual([
      { actor_id: miner.user.id, action: 'user.password_change_failed', details: { reason: 'wrong_current_password' } },
    ]);
    await expectNoPasswords([res.text]);
  });

  it('refuses a weak new password before the current one is checked, without recording a failure', async () => {
    const { app, miner, phoneA } = await minerOnTwoPhones();

    // A wrong current password too: the policy answers first, so no failure is recorded.
    const res = await changePassword(app, phoneA, { currentPassword: 'not my password at all', newPassword: 'short' });

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('WEAK_PASSWORD');
    expect(res.body.error.details).toContainEqual(expect.objectContaining({ field: 'newPassword', code: 'PASSWORD_TOO_SHORT' }));
    expect(await cutOffOf(miner.user.id)).toBeNull();
    const actions = (await auditFor(miner.user.id)).map((e) => e.action);
    expect(actions).not.toContain('user.password_change_failed');
    expect(actions).not.toContain('user.password_change');
  });

  it('refuses the current password as the new one, and leaves every session in place', async () => {
    const { app, miner, phoneA, phoneB } = await minerOnTwoPhones();

    const res = await changePassword(app, phoneA, { currentPassword: TEST_PASSPHRASE, newPassword: TEST_PASSPHRASE });

    expect(res.status).toBe(400);
    expect(res.body.error).toEqual({
      code: 'PASSWORD_UNCHANGED',
      message: 'Choose a password different from your current one.',
      details: [{ field: 'newPassword', message: 'must be different from your current password' }],
    });
    expect(await cutOffOf(miner.user.id)).toBeNull();
    expect((await me(app, phoneB)).status).toBe(200);
    expect((await auditFor(miner.user.id)).map((e) => e.action)).not.toContain('user.password_change');
    await expectNoPasswords([res.text]);
  });

  it('leaves the lost-device procedure working after a change: suspend, reset, reactivate, new key', async () => {
    const { app, adminToken, miner, phoneA, phoneB } = await minerOnTwoPhones();
    const changed = await changePassword(app, phoneA, { currentPassword: TEST_PASSPHRASE, newPassword: NEW_PASSWORD });
    expect(changed.status).toBe(200);
    const token = changed.body.token;
    const adminAct = (action, body) => auth(request(app).post(`/admin/users/${miner.user.id}/${action}`), adminToken).send(body);

    // Suspended: even the fresh token is refused, with the status answer.
    expect((await adminAct('suspend', { reason: 'Lost device reported' })).status).toBe(200);
    expect((await me(app, token)).body.error.code).toBe('ACCOUNT_SUSPENDED');
    expect((await adminAct('reset-key', { reason: 'Lost device reported' })).status).toBe(200);
    expect((await adminAct('reactivate', {})).status).toBe(200);

    // Reactivated: the fresh token works again and registers the new phone's key.
    const between = await me(app, token);
    expect(between.status).toBe(200);
    expect(between.body.user.publicKeyFingerprint).toBeNull();
    const keyed = await auth(request(app).put('/auth/me/public-key'), token).send({ publicKey: newPhone().spkiBase64 });
    expect(keyed.status).toBe(200);

    // The cut-off from the change still holds for phone B.
    expect((await me(app, phoneB)).status).toBe(401);
  });
});
