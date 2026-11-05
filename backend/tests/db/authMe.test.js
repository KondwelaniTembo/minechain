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
});
