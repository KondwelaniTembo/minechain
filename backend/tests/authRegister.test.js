import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/errors.js';

const VALID = {
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  password: 'gold river kasempa',
  role: 'miner',
};

// What the real service returns: the safe user, with no hash and no actor_ref.
const SAFE_USER = {
  id: '3f2b6c1e-0000-4000-8000-000000000001',
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  licenceNumber: null,
  role: 'miner',
  status: 'pending',
  createdAt: '2026-11-05T09:00:00.000Z',
};

const fakeDb = () => ({ query: vi.fn() });

// A fresh app with a fake users service each time, so no test shares a rate-limit counter.
function setup({ register = vi.fn().mockResolvedValue(SAFE_USER), ...options } = {}) {
  const users = { register };
  const app = createApp({ db: fakeDb(), services: { users }, ...options });
  return { app, users };
}

const post = (app, body = VALID) => request(app).post('/auth/register').send(body);

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /auth/register', () => {
  describe('success', () => {
    it('answers 201 with the user and a message about approval', async () => {
      const { app } = setup();

      const res = await post(app);

      expect(res.status).toBe(201);
      expect(res.body).toEqual({
        user: SAFE_USER,
        message: 'Your account has been requested. An administrator must approve it before you can log in.',
      });
    });

    it('passes the validated, trimmed body and the client IP to the service', async () => {
      const { app, users } = setup();

      await post(app, { ...VALID, username: '  mutale_banda  ', fullName: ' Mutale Banda ' });

      expect(users.register).toHaveBeenCalledWith(
        { username: 'mutale_banda', fullName: 'Mutale Banda', password: 'gold river kasempa', role: 'miner' },
        { ipAddress: expect.any(String) },
      );
    });

    it('never includes a password hash or actor_ref', async () => {
      const { app } = setup();

      const res = await post(app);

      for (const key of ['password', 'passwordHash', 'password_hash', 'actorRef', 'actor_ref']) {
        expect(res.body.user).not.toHaveProperty(key);
      }
      expect(res.text).not.toContain('argon2');
    });
  });

  describe('400 VALIDATION_FAILED, before the service is called', () => {
    it.each([
      ['a missing password', { password: undefined }, 'password'],
      ['a 2-character username', { username: 'mb' }, 'username'],
      ['a blank full name', { fullName: '  ' }, 'fullName'],
      ['an unknown field (status)', { status: 'active' }, 'status'],
      ['the officer role', { role: 'officer' }, 'role'],
      ['the admin role', { role: 'admin' }, 'role'],
    ])('refuses %s', async (_label, overrides, field) => {
      const { app, users } = setup();

      const res = await post(app, { ...VALID, ...overrides });

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
      expect(users.register).not.toHaveBeenCalled();
    });

    it('refuses malformed JSON with 400 INVALID_JSON', async () => {
      const { app } = setup();

      const res = await request(app)
        .post('/auth/register')
        .set('Content-Type', 'application/json')
        .send('{"username": "mutale_banda",');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('INVALID_JSON');
    });
  });

  describe('errors from the service', () => {
    it('passes through 400 WEAK_PASSWORD with the policy codes, never the password', async () => {
      const weak = new AppError(400, 'WEAK_PASSWORD', 'Choose a stronger password.', [
        { field: 'password', code: 'PASSWORD_TOO_COMMON', message: 'This password is too common. Choose something less easy to guess.' },
      ]);
      const { app } = setup({ register: vi.fn().mockRejectedValue(weak) });

      const res = await post(app, { ...VALID, password: 'kindergarten' });

      expect(res.status).toBe(400);
      expect(res.body.error).toEqual({
        code: 'WEAK_PASSWORD',
        message: 'Choose a stronger password.',
        details: [{ field: 'password', code: 'PASSWORD_TOO_COMMON', message: 'This password is too common. Choose something less easy to guess.' }],
      });
      expect(res.text).not.toContain('kindergarten');
    });

    it('passes through 409 USERNAME_TAKEN', async () => {
      const taken = new AppError(409, 'USERNAME_TAKEN', 'That username is already taken. Please choose another.');
      const { app } = setup({ register: vi.fn().mockRejectedValue(taken) });

      const res = await post(app);

      expect(res.status).toBe(409);
      expect(res.body).toEqual({ error: { code: 'USERNAME_TAKEN', message: 'That username is already taken. Please choose another.' } });
    });
  });

  describe('rate limiting', () => {
    it('answers 429 TOO_MANY_REQUESTS in the usual error format once the limit is used up', async () => {
      const { app, users } = setup({ rateLimits: { registerPerHour: 2 } });
      await post(app);
      await post(app);

      const res = await post(app);

      expect(res.status).toBe(429);
      expect(res.body).toEqual({
        error: { code: 'TOO_MANY_REQUESTS', message: 'Too many registration attempts from this network. Please try again later.' },
      });
      // Seconds until the client may try again.
      expect(res.headers['retry-after']).toMatch(/^\d+$/);
      expect(users.register).toHaveBeenCalledTimes(2);
    });

    it('allows 30 an hour by default', async () => {
      const { app } = setup();
      for (let i = 0; i < 30; i += 1) {
        expect((await post(app)).status).toBe(201);
      }

      expect((await post(app)).status).toBe(429);
    });

    it('counts invalid requests too, because the limiter runs before validation', async () => {
      const { app, users } = setup({ rateLimits: { registerPerHour: 2 } });
      await post(app, { ...VALID, role: 'admin' });
      await post(app, { ...VALID, username: 'x' });

      const res = await post(app);

      expect(res.status).toBe(429);
      expect(users.register).not.toHaveBeenCalled();
    });

    it('gives every app instance its own counter', async () => {
      const first = setup({ rateLimits: { registerPerHour: 1 } });
      await post(first.app);
      expect((await post(first.app)).status).toBe(429);

      const second = setup({ rateLimits: { registerPerHour: 1 } });

      expect((await post(second.app)).status).toBe(201);
    });
  });

  describe('trust proxy', () => {
    const fromClient = (app, forwardedFor) =>
      request(app).post('/auth/register').set('X-Forwarded-For', forwardedFor).send(VALID);

    it('with 1 hop, treats clients behind the proxy as separate and records their real address', async () => {
      const { app, users } = setup({ trustProxyHops: 1, rateLimits: { registerPerHour: 1 } });

      const first = await fromClient(app, '41.72.100.9');
      const second = await fromClient(app, '41.72.100.10');

      expect(first.status).toBe(201);
      expect(second.status).toBe(201);
      expect(users.register.mock.calls[0][1]).toEqual({ ipAddress: '41.72.100.9' });
    });

    it('with 1 hop, ignores an address the client forged further left', async () => {
      const { app, users } = setup({ trustProxyHops: 1 });

      // The client sent "1.2.3.4"; the proxy appended the real address after it.
      await fromClient(app, '1.2.3.4, 41.72.100.9');

      expect(users.register.mock.calls[0][1]).toEqual({ ipAddress: '41.72.100.9' });
    });

    it('with 0 hops, ignores X-Forwarded-For entirely, so both requests share one limit', async () => {
      // express-rate-limit warns once when X-Forwarded-For arrives but trust proxy is off,
      // because in production that would mean TRUST_PROXY is set wrong. Expected here, so
      // it is caught and checked rather than printed. The real app keeps this check on.
      const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
      const { app, users } = setup({ rateLimits: { registerPerHour: 1 } });

      const first = await fromClient(app, '41.72.100.9');
      const second = await fromClient(app, '41.72.100.10');

      expect(first.status).toBe(201);
      expect(second.status).toBe(429);
      // The address recorded is the direct connection, not the header's.
      expect(users.register.mock.calls[0][1].ipAddress).not.toBe('41.72.100.9');
      // Only the expected warning was logged, and nothing else.
      expect(consoleError).toHaveBeenCalled();
      for (const [logged] of consoleError.mock.calls) {
        expect(logged).toMatchObject({ code: 'ERR_ERL_UNEXPECTED_X_FORWARDED_FOR' });
      }
    });
  });
});
