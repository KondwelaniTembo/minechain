import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG } from './fixtures.js';
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

describe('POST /auth/login through the real stack', () => {
  it('refuses a pending account, then logs in once it is active, with a token that verifies', async () => {
    const { app, services } = realStack();

    const registered = await request(app).post('/auth/register').send(REGISTRATION);
    expect(registered.status).toBe(201);
    const userId = registered.body.user.id;

    // Not approved yet.
    const pending = await request(app).post('/auth/login').send({ username: 'mutale_banda', password: REGISTRATION.password });
    expect(pending.status).toBe(403);
    expect(pending.body.error.code).toBe('ACCOUNT_PENDING');

    // Approval is an SQL update until the admin endpoint exists (FR-10).
    await t.db.query("UPDATE users SET status = 'active' WHERE id = $1", [userId]);

    const res = await request(app).post('/auth/login').send({ username: 'Mutale_Banda', password: REGISTRATION.password });

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ tokenType: 'Bearer', expiresIn: 3600, user: { id: userId, status: 'active' } });
    expect(await services.tokens.verify(res.body.token)).toEqual({ userId, role: 'miner', iat: expect.any(Number) });
    expect(res.text).not.toContain('argon2');
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('answers a wrong password with 401 and keeps the user.login_failed entry', async () => {
    const { app } = realStack();
    const registered = await request(app).post('/auth/register').send(REGISTRATION);
    await t.db.query("UPDATE users SET status = 'active' WHERE id = $1", [registered.body.user.id]);

    const res = await request(app).post('/auth/login').send({ username: 'mutale_banda', password: 'not the password' });

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('INVALID_CREDENTIALS');
    const { rows } = await t.db.query("SELECT details FROM audit_logs WHERE action = 'user.login_failed' AND actor_id = $1", [
      registered.body.user.id,
    ]);
    expect(rows).toEqual([{ details: { reason: 'wrong_password' } }]);
  });
});
