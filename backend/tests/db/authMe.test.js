import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser } from './fixtures.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';

const t = useTestDb();

const REGISTRATION = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
};

// The whole stack as server.js wires it, on the test's own connection, so the test's
// ROLLBACK undoes everything. Requests go one at a time: one connection, one query at once.
function realStack() {
  const services = createServices({ db: t.db, config: FAKE_CONFIG });
  return { app: createApp({ db: t.db, services }), services };
}

const me = (app, token) => request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);

describe('GET /auth/me through the real stack', () => {
  it('works with a fresh token, then refuses the same token once the account changes', async () => {
    const { app } = realStack();

    // Register, approve with SQL (the admin endpoint comes later), log in.
    const registered = await request(app).post('/auth/register').send(REGISTRATION);
    const userId = registered.body.user.id;
    await t.db.query("UPDATE users SET status = 'active' WHERE id = $1", [userId]);
    const loggedIn = await request(app).post('/auth/login').send({ username: 'mutale_banda', password: REGISTRATION.password });
    const { token } = loggedIn.body;

    const ok = await me(app, token);
    expect(ok.status).toBe(200);
    expect(ok.body.user).toMatchObject({ id: userId, username: 'mutale_banda', role: 'miner', status: 'active' });
    expect(ok.text).not.toContain('argon2');

    // Suspended: the token is still genuine and unexpired, but refused at once.
    await t.db.query("UPDATE users SET status = 'suspended', status_reason = $1 WHERE id = $2", ['Lost device reported', userId]);
    const suspended = await me(app, token);
    expect(suspended.status).toBe(403);
    expect(suspended.body.error.code).toBe('ACCOUNT_SUSPENDED');

    // Reactivated with another role: the old token now claims the wrong role.
    await t.db.query("UPDATE users SET status = 'active', status_reason = NULL, role = 'transporter' WHERE id = $1", [userId]);
    const roleChanged = await me(app, token);
    expect(roleChanged.status).toBe(401);
    expect(roleChanged.body.error.code).toBe('TOKEN_INVALID');
  });
});

describe('userService.getAuthenticatedUser against PostgreSQL', () => {
  const service = () => createServices({ db: t.db, config: FAKE_CONFIG }).users;

  it('returns the current, safe user for an active account', async () => {
    const user = await insertUser(t.db, { role: 'buyer', status: 'active' });

    const result = await service().getAuthenticatedUser(user.id, 'buyer');

    expect(result).toMatchObject({ id: user.id, role: 'buyer', status: 'active' });
    expect(result).not.toHaveProperty('passwordHash');
  });

  it('refuses an id that matches no user', async () => {
    await expect(service().getAuthenticatedUser('00000000-0000-4000-8000-000000000000', 'miner')).rejects.toMatchObject({
      status: 401,
      code: 'TOKEN_INVALID',
    });
  });

  it('refuses a suspended account', async () => {
    const user = await insertUser(t.db, { status: 'suspended', status_reason: 'Under investigation' });

    await expect(service().getAuthenticatedUser(user.id, 'miner')).rejects.toMatchObject({ status: 403, code: 'ACCOUNT_SUSPENDED' });
  });

  it('refuses a role that no longer matches', async () => {
    const user = await insertUser(t.db, { role: 'transporter', status: 'active' });

    await expect(service().getAuthenticatedUser(user.id, 'miner')).rejects.toMatchObject({ status: 401, code: 'TOKEN_INVALID' });
  });

  // The password-change cut-off. The comparison is in SQL, so it is tested against
  // PostgreSQL rather than a fake. A fixed second, as a token iat would carry it.
  describe('the tokens_valid_after cut-off', () => {
    const CUT_OFF = 1794470400; // 2026-11-11 00:00:00 UTC

    async function userWithCutOff(seconds) {
      const user = await insertUser(t.db, { role: 'miner', status: 'active' });
      await t.db.query('UPDATE users SET tokens_valid_after = to_timestamp($1::bigint) WHERE id = $2', [seconds, user.id]);
      return user;
    }

    it('refuses a token issued one second before it, with the same 401 as a deleted account', async () => {
      const user = await userWithCutOff(CUT_OFF);

      const err = await service().getAuthenticatedUser(user.id, 'miner', CUT_OFF - 1).catch((e) => e);

      expect(err).toMatchObject({ status: 401, code: 'TOKEN_INVALID', message: 'Your session is not valid. Please log in again.' });
    });

    it('accepts a token issued in the very second of the cut-off (the fresh token from the change)', async () => {
      const user = await userWithCutOff(CUT_OFF);

      expect(await service().getAuthenticatedUser(user.id, 'miner', CUT_OFF)).toMatchObject({ id: user.id });
      expect(await service().getAuthenticatedUser(user.id, 'miner', CUT_OFF + 1)).toMatchObject({ id: user.id });
    });

    it('accepts a token of any age when there is no cut-off', async () => {
      const user = await insertUser(t.db, { role: 'miner', status: 'active' });

      expect(await service().getAuthenticatedUser(user.id, 'miner', 0)).toMatchObject({ id: user.id });
    });

    it('fails closed: with a cut-off, a lookup without an iat is refused', async () => {
      const user = await userWithCutOff(CUT_OFF);

      await expect(service().getAuthenticatedUser(user.id, 'miner')).rejects.toMatchObject({ status: 401, code: 'TOKEN_INVALID' });
    });
  });
});
