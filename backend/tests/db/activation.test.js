// FR-10 end to end: an administrator creates an officer through the API, and the officer
// activates the account with the code and their own password. The whole stack as server.js
// wires it (real services, real Argon2, real audit), on the test's own connection.
import { randomBytes } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { insertUser } from './fixtures.js';
import { auth, bindRealStack, TEST_PASSPHRASE } from './realStackHelpers.js';

const t = useTestDb();
const { realStack } = bindRealStack(t);

// Right shape, and astronomically unlikely to be the real code (1 in 2^60).
const WRONG_CODE = 'ZZZZ-ZZZZ-ZZZZ';

const ACTIVATION_INVALID = {
  error: { code: 'ACTIVATION_INVALID', message: 'This activation code is not valid. Ask an administrator for a new one.' },
};

// The stack, plus a token for an active administrator. The admin is a fixture row (it cannot
// log in), so its token is signed as a login would issue it.
async function stackWithAdmin() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  return { app, admin, adminToken: await tokenFor({ id: admin.id, role: 'admin' }) };
}

// An officer account made through POST /admin/users, as an administrator would.
async function createOfficer(app, adminToken) {
  const username = `officer_${randomBytes(3).toString('hex')}`;
  const res = await auth(request(app).post('/admin/users'), adminToken).send({ username, fullName: 'Chanda Mwale', role: 'officer' });
  expect(res.status).toBe(201);
  expect(res.body.user).toMatchObject({ username, role: 'officer', status: 'invited' });
  expect(res.body.activation.code).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
  return { id: res.body.user.id, username, code: res.body.activation.code };
}

const activate = (app, body) => request(app).post('/auth/activate').send(body);
const login = (app, username, password = TEST_PASSPHRASE) => request(app).post('/auth/login').send({ username, password });

// The code as someone might type it: lower case, no hyphens.
const typedLoosely = (code) => code.replaceAll('-', '').toLowerCase();

async function stateOf(id) {
  const { rows } = await t.db.query(
    `SELECT status, password_hash IS NULL AS no_password, activation_code_hash IS NULL AS no_code,
            activation_expires_at IS NULL AS no_expiry, activation_failed_attempts AS attempts
       FROM users WHERE id = $1`,
    [id],
  );
  return rows[0];
}

// Every entry this test wrote: each test starts with an empty log (the fixture admin writes none).
async function auditLog() {
  const { rows } = await t.db.query('SELECT actor_id, action, entity_type, entity_id, details FROM audit_logs ORDER BY id');
  return rows;
}

const activationFailures = async () => (await auditLog()).filter((e) => e.action === 'user.activation_failed');

// Neither the code (in any form) nor the password may appear in any audit entry.
async function expectNoSecretsInAudit(codes, password = TEST_PASSPHRASE) {
  const text = JSON.stringify(await auditLog());
  for (const code of codes) {
    expect(text).not.toContain(code);
    expect(text).not.toContain(code.replaceAll('-', ''));
    expect(text.toLowerCase()).not.toContain(typedLoosely(code));
  }
  expect(text).not.toContain(password);
}

describe('activation through the API (FR-10)', () => {
  it('an officer created by an admin cannot log in, activates with the code, and can then log in', async () => {
    const { app, admin, adminToken } = await stackWithAdmin();
    const officer = await createOfficer(app, adminToken);

    // Invited: no password yet, so a login gets the same answer as an unknown username.
    const before = await login(app, officer.username);
    expect(before.status).toBe(401);
    expect(before.body.error.code).toBe('INVALID_CREDENTIALS');

    // The admin list shows the account, never its code.
    const listed = await auth(request(app).get('/admin/users?status=invited'), adminToken);
    expect(listed.text).toContain(officer.id);
    expect(listed.text).not.toContain(officer.code);

    const res = await activate(app, { username: officer.username, code: typedLoosely(officer.code), password: TEST_PASSPHRASE });
    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body).toMatchObject({ tokenType: 'Bearer', expiresIn: 3600, user: { id: officer.id, role: 'officer', status: 'active' } });
    expect(await stateOf(officer.id)).toEqual({ status: 'active', no_password: false, no_code: true, no_expiry: true, attempts: 0 });

    // The token from activation works at once.
    const me = await auth(request(app).get('/auth/me'), res.body.token);
    expect(me.status).toBe(200);
    expect(me.body.user).toMatchObject({ id: officer.id, status: 'active' });

    // And so does a normal login with the password chosen at activation.
    const after = await login(app, officer.username);
    expect(after.status).toBe(200);

    // The code is single-use: the account is no longer invited, so it is refused.
    const again = await activate(app, { username: officer.username, code: officer.code, password: 'a different passphrase here' });
    expect(again.status).toBe(401);
    expect(again.body).toEqual(ACTIVATION_INVALID);

    expect((await auditLog()).map(({ action, actor_id: actorId, details }) => ({ action, actorId, details }))).toEqual([
      { action: 'user.create', actorId: admin.id, details: { source: 'admin', role: 'officer', activationExpiresAt: expect.any(String) } },
      { action: 'user.login_failed', actorId: officer.id, details: { reason: 'account_invited' } },
      { action: 'user.activate', actorId: officer.id, details: {} },
      { action: 'user.login', actorId: officer.id, details: { rehashed: false } },
      { action: 'user.activation_failed', actorId: null, details: { reason: 'unknown_username' } },
    ]);
    await expectNoSecretsInAudit([officer.code]);
  });

  it('refuses a weak password before the code is looked at, so it uses up no guess', async () => {
    const { app, adminToken } = await stackWithAdmin();
    const officer = await createOfficer(app, adminToken);

    // With the right code and with a wrong one: the same 400, and nothing counted.
    for (const code of [officer.code, WRONG_CODE]) {
      const res = await activate(app, { username: officer.username, code, password: 'short' });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('WEAK_PASSWORD');
      expect(res.body.error.details.map((d) => d.code)).toContain('PASSWORD_TOO_SHORT');
    }
    // The username rule applies too, as at registration.
    const withUsername = await activate(app, { username: officer.username, code: officer.code, password: `${officer.username} is my password` });
    expect(withUsername.body.error.details.map((d) => d.code)).toContain('PASSWORD_CONTAINS_USERNAME');

    expect(await stateOf(officer.id)).toMatchObject({ status: 'invited', no_code: false, attempts: 0 });
    expect(await activationFailures()).toEqual([]);
  });

  it('erases the code on the fifth wrong one; a reissue through the API gives a code that works', async () => {
    const { app, adminToken } = await stackWithAdmin();
    const officer = await createOfficer(app, adminToken);
    const wrong = (code) => activate(app, { username: officer.username, code, password: TEST_PASSPHRASE });

    // Four wrong codes, one of them not even shaped like a code: each counts, the code stays.
    const bodies = [];
    for (const code of [WRONG_CODE, 'not a code', WRONG_CODE, WRONG_CODE]) {
      const res = await wrong(code);
      expect(res.status).toBe(401);
      bodies.push(res.body);
    }
    expect(await stateOf(officer.id)).toMatchObject({ no_code: false, attempts: 4 });

    // The fifth erases the code and its expiry in the same statement.
    const fifth = await wrong(WRONG_CODE);
    expect(fifth.status).toBe(401);
    expect(await stateOf(officer.id)).toEqual({ status: 'invited', no_password: true, no_code: true, no_expiry: true, attempts: 5 });

    // Now even the right code is refused: there is nothing left to match.
    const right = await wrong(officer.code);
    expect(right.status).toBe(401);
    // Every refusal looks the same to the client.
    for (const body of [...bodies, fifth.body, right.body]) expect(body).toEqual(ACTIVATION_INVALID);

    expect((await activationFailures()).map((e) => ({ actorId: e.actor_id, details: e.details }))).toEqual([
      ...Array.from({ length: 4 }, () => ({ actorId: officer.id, details: { reason: 'wrong_code' } })),
      { actorId: officer.id, details: { reason: 'wrong_code', codeErased: true } },
      { actorId: officer.id, details: { reason: 'no_code' } },
    ]);

    // The administrator issues a new code; the counter starts again.
    const reissued = await auth(request(app).post(`/admin/users/${officer.id}/activation-code`), adminToken);
    expect(reissued.status).toBe(200);
    const newCode = reissued.body.activation.code;
    expect(newCode).not.toBe(officer.code);
    expect(await stateOf(officer.id)).toMatchObject({ no_code: false, attempts: 0 });

    const res = await activate(app, { username: officer.username, code: newCode, password: TEST_PASSPHRASE });
    expect(res.status).toBe(200);
    expect(res.body.user.status).toBe('active');

    await expectNoSecretsInAudit([officer.code, newCode]);
  });

  it('refuses an expired code without counting it as a guess', async () => {
    const { app, adminToken } = await stackWithAdmin();
    const officer = await createOfficer(app, adminToken);
    await t.db.query("UPDATE users SET activation_expires_at = clock_timestamp() - interval '1 minute' WHERE id = $1", [officer.id]);

    const res = await activate(app, { username: officer.username, code: officer.code, password: TEST_PASSPHRASE });

    expect(res.status).toBe(401);
    expect(res.body).toEqual(ACTIVATION_INVALID);
    expect(await stateOf(officer.id)).toMatchObject({ status: 'invited', no_password: true, no_code: false, attempts: 0 });
    expect((await activationFailures()).map((e) => e.details)).toEqual([{ reason: 'expired' }]);
  });

  it('answers an unknown username with exactly the body a wrong code gets', async () => {
    const { app, adminToken } = await stackWithAdmin();
    const officer = await createOfficer(app, adminToken);

    const wrongCode = await activate(app, { username: officer.username, code: WRONG_CODE, password: TEST_PASSPHRASE });
    const unknown = await activate(app, { username: 'nobody_invited_here', code: WRONG_CODE, password: TEST_PASSPHRASE });

    expect(unknown.status).toBe(wrongCode.status);
    expect(unknown.body).toEqual(wrongCode.body);
    expect(unknown.body).toEqual(ACTIVATION_INVALID);
    // The unknown attempt names no account; the typed username is not stored either.
    const failures = await activationFailures();
    expect(failures[1]).toEqual({
      actor_id: null,
      action: 'user.activation_failed',
      entity_type: null,
      entity_id: null,
      details: { reason: 'unknown_username' },
    });
    expect(JSON.stringify(failures)).not.toContain('nobody_invited_here');
  });
});
