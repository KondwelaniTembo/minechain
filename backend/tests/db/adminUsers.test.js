import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, MISSING_ID, insertUser } from './fixtures.js';
import { createApp } from '../../src/app.js';
import { createServices } from '../../src/services/index.js';

const t = useTestDb();

// The whole stack as server.js wires it, on the test's own connection, so the test's
// ROLLBACK undoes everything. Requests go one at a time: one connection, one query at once.
// Fixture users have a fake password hash and cannot log in, so tokens are signed directly
// with the real token service, exactly as a login would issue them.
function realStack() {
  const services = createServices({ db: t.db, config: FAKE_CONFIG });
  const app = createApp({ db: t.db, services });
  const tokenFor = async (user) => (await services.tokens.sign({ userId: user.id, role: user.role })).token;
  return { app, tokenFor };
}

const asUser = (token) => (req) => req.set('Authorization', `Bearer ${token}`);
const me = (app, token) => asUser(token)(request(app).get('/auth/me'));
const listUsers = (app, token, query = '') => asUser(token)(request(app).get(`/admin/users${query}`));
const act = (app, token, id, action, body) => {
  const req = asUser(token)(request(app).post(`/admin/users/${id}/${action}`));
  return body === undefined ? req : req.send(body);
};

const activeAdmin = () => insertUser(t.db, { role: 'admin', status: 'active' });

async function status(id) {
  const { rows } = await t.db.query('SELECT status, status_reason FROM users WHERE id = $1', [id]);
  return rows[0];
}

describe('admin user routes through the real stack', () => {
  it.each(['miner', 'transporter', 'buyer', 'officer'])('refuses an active %s with 403', async (role) => {
    const { app, tokenFor } = realStack();
    const user = await insertUser(t.db, { role, status: 'active' });

    const res = await listUsers(app, await tokenFor(user));

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('lists pending requests with the admin view only, never the hash or on-chain identity', async () => {
    const { app, tokenFor } = realStack();
    const admin = await activeAdmin();
    const pending = await insertUser(t.db, { role: 'miner', status: 'pending', public_key: Buffer.alloc(91, 1) });

    const res = await listUsers(app, await tokenFor(admin));

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body).toMatchObject({ total: 1, limit: 20, offset: 0 });
    expect(res.body.users).toEqual([expect.objectContaining({ id: pending.id, status: 'pending' })]);
    expect(res.text).not.toContain('argon2');
    expect(res.text).not.toMatch(/password|actor_?ref|public_?key/i);
  });

  it('approves a request, after which the new user is let in', async () => {
    const { app, tokenFor } = realStack();
    const admin = await activeAdmin();
    const miner = await insertUser(t.db, { role: 'miner', status: 'pending' });
    const minerToken = await tokenFor(miner);
    // In real use a pending user cannot even log in; here the token exists to show the
    // account itself is what was refused.
    expect((await me(app, minerToken)).body.error.code).toBe('ACCOUNT_PENDING');

    const res = await act(app, await tokenFor(admin), miner.id, 'approve');

    expect(res.status).toBe(200);
    expect(res.body.user).toMatchObject({ id: miner.id, status: 'active', approvedBy: admin.id });
    expect((await me(app, minerToken)).status).toBe(200);
  });

  it("refuses a suspended user's next request at once, and lets them in again after reactivation", async () => {
    const { app, tokenFor } = realStack();
    const admin = await activeAdmin();
    const adminToken = await tokenFor(admin);
    const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
    const minerToken = await tokenFor(miner);
    expect((await me(app, minerToken)).status).toBe(200);

    const suspended = await act(app, adminToken, miner.id, 'suspend', { reason: 'Lost device reported' });
    expect(suspended.status).toBe(200);

    // The same genuine, unexpired token is refused on the very next request.
    const refused = await me(app, minerToken);
    expect(refused.status).toBe(403);
    expect(refused.body.error.code).toBe('ACCOUNT_SUSPENDED');
    // The reason is for administrators only, never sent to the suspended user.
    expect(refused.text).not.toContain('Lost device');

    const reactivated = await act(app, adminToken, miner.id, 'reactivate');
    expect(reactivated.body.user).toMatchObject({ status: 'active', statusReason: null });
    expect((await me(app, minerToken)).status).toBe(200);
  });

  it("refuses a suspended admin's next admin request", async () => {
    const { app, tokenFor } = realStack();
    const first = await activeAdmin();
    const second = await activeAdmin();
    const secondToken = await tokenFor(second);

    await act(app, await tokenFor(first), second.id, 'suspend', { reason: 'Left the project' });

    const res = await listUsers(app, secondToken);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('ACCOUNT_SUSPENDED');
  });

  it('rejects a request with its reason, and records who did it and from where', async () => {
    const { app, tokenFor } = realStack();
    const admin = await activeAdmin();
    const buyer = await insertUser(t.db, { role: 'buyer', status: 'pending' });

    const res = await act(app, await tokenFor(admin), buyer.id, 'reject', { reason: '  Licence number could not be verified ' });

    expect(res.status).toBe(200);
    expect(await status(buyer.id)).toEqual({ status: 'rejected', status_reason: 'Licence number could not be verified' });
    const { rows } = await t.db.query(
      'SELECT actor_id, action, details, ip_address FROM audit_logs WHERE entity_id = $1',
      [buyer.id],
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      actor_id: admin.id,
      action: 'user.reject',
      details: { from: 'pending', to: 'rejected', reason: 'Licence number could not be verified' },
    });
    // Supertest connects over loopback; the address Express resolved is what is stored.
    expect(rows[0].ip_address).toMatch(/127\.0\.0\.1|::1/);
  });

  describe('refusals', () => {
    it('refuses an admin suspending themselves, even with their id in capitals', async () => {
      const { app, tokenFor } = realStack();
      const admin = await activeAdmin();
      await activeAdmin();
      const token = await tokenFor(admin);

      for (const id of [admin.id, admin.id.toUpperCase()]) {
        const res = await act(app, token, id, 'suspend', { reason: 'Testing' });

        expect(res.status).toBe(403);
        expect(res.body.error.code).toBe('CANNOT_SUSPEND_SELF');
      }
      expect((await status(admin.id)).status).toBe('active');
    });

    it('answers a second approval with 409', async () => {
      const { app, tokenFor } = realStack();
      const admin = await activeAdmin();
      const miner = await insertUser(t.db, { role: 'miner', status: 'pending' });
      const token = await tokenFor(admin);

      expect((await act(app, token, miner.id, 'approve')).status).toBe(200);
      const res = await act(app, token, miner.id, 'approve');

      expect(res.status).toBe(409);
      expect(res.body.error).toEqual({
        code: 'INVALID_STATUS_TRANSITION',
        message: 'Only a pending account can be approved. This account is active.',
      });
    });

    it('answers approving a pending officer with 409 ROLE_NOT_APPROVABLE', async () => {
      const { app, tokenFor } = realStack();
      const admin = await activeAdmin();
      const officer = await insertUser(t.db, { role: 'officer', status: 'pending' });

      const res = await act(app, await tokenFor(admin), officer.id, 'approve');

      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('ROLE_NOT_APPROVABLE');
      expect((await status(officer.id)).status).toBe('pending');
    });

    it('answers an id that matches no user with 404', async () => {
      const { app, tokenFor } = realStack();
      const admin = await activeAdmin();

      const res = await act(app, await tokenFor(admin), MISSING_ID, 'reactivate');

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('USER_NOT_FOUND');
    });

    it('answers a malformed id with 400 before PostgreSQL sees it, not a 500', async () => {
      const { app, tokenFor } = realStack();
      const admin = await activeAdmin();

      const res = await act(app, await tokenFor(admin), 'not-a-uuid', 'approve');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
    });
  });
});
