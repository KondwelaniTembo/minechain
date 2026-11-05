import { randomBytes } from 'node:crypto';
import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/errors.js';
import { loginUsernameKey } from '../src/middleware/rateLimits.js';

const PASSWORD = 'gold river kasempa';
const LOGIN = { username: 'mutale_banda', password: PASSWORD };

const SAFE_USER = {
  id: '3f2b6c1e-0000-4000-8000-000000000001',
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  licenceNumber: null,
  role: 'miner',
  status: 'active',
  createdAt: '2026-11-05T09:00:00.000Z',
};
const SUCCESS = { user: SAFE_USER, token: 'header.payload.signature', expiresIn: 3600 };

const invalidCredentials = () => new AppError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.');
const accountPending = () => new AppError(403, 'ACCOUNT_PENDING', 'Your account is waiting for approval by an administrator.');

const fakeDb = () => ({ query: vi.fn() });

// A fresh app each time, so no test shares a rate-limit counter.
function setup({ authenticate = vi.fn().mockResolvedValue(SUCCESS), ...options } = {}) {
  const users = { register: vi.fn(), authenticate };
  const app = createApp({ db: fakeDb(), services: { users }, ...options });
  return { app, users };
}

const login = (app, body = LOGIN) => request(app).post('/auth/login').send(body);

// Successful requests are given back to the username counter when the response finishes.
// One event-loop turn makes sure that has happened before the next request is sent.
const settle = () => new Promise((resolve) => setImmediate(resolve));

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /auth/login', () => {
  describe('success', () => {
    it('answers 200 with the token, its type and lifetime, and the user', async () => {
      const { app } = setup();

      const res = await login(app);

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ token: 'header.payload.signature', tokenType: 'Bearer', expiresIn: 3600, user: SAFE_USER });
    });

    it('tells every cache not to keep the response', async () => {
      const { app } = setup();

      const res = await login(app);

      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('passes the trimmed username, the untouched password and the client IP to authenticate', async () => {
      const { app, users } = setup();

      await login(app, { username: '  mutale_banda ', password: ' gold river kasempa ' });

      expect(users.authenticate).toHaveBeenCalledWith('mutale_banda', ' gold river kasempa ', { ipAddress: expect.any(String) });
    });

    it('does not apply the password policy at login', async () => {
      const { app, users } = setup();

      const res = await login(app, { username: 'mutale_banda', password: 'short' });

      expect(res.status).toBe(200);
      expect(users.authenticate).toHaveBeenCalledWith('mutale_banda', 'short', expect.anything());
    });
  });

  describe('400 VALIDATION_FAILED, before authenticate is called', () => {
    it.each([
      ['a missing username', { password: PASSWORD }, 'username'],
      ['a missing password', { username: 'mutale_banda' }, 'password'],
      ['an empty username', { username: '   ', password: PASSWORD }, 'username'],
      ['an empty password', { username: 'mutale_banda', password: '' }, 'password'],
      ['an unknown field', { ...LOGIN, role: 'admin' }, 'role'],
    ])('refuses %s', async (_label, body, field) => {
      const { app, users } = setup();

      const res = await login(app, body);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
      expect(users.authenticate).not.toHaveBeenCalled();
    });

    it('refuses a 1025-character password before it reaches Argon2', async () => {
      const { app, users } = setup();

      const res = await login(app, { username: 'mutale_banda', password: 'a'.repeat(1025) });

      expect(res.status).toBe(400);
      expect(res.body.error.details).toEqual([{ field: 'password', message: 'must be at most 1024 characters' }]);
      expect(users.authenticate).not.toHaveBeenCalled();
    });

    it('accepts a password of exactly 1024 characters', async () => {
      const { app, users } = setup();

      await login(app, { username: 'mutale_banda', password: 'a'.repeat(1024) });

      expect(users.authenticate).toHaveBeenCalledOnce();
    });
  });

  describe('errors from authenticate', () => {
    it('passes through 401 INVALID_CREDENTIALS', async () => {
      const { app } = setup({ authenticate: vi.fn().mockRejectedValue(invalidCredentials()) });

      const res = await login(app);

      expect(res.status).toBe(401);
      expect(res.body).toEqual({ error: { code: 'INVALID_CREDENTIALS', message: 'Username or password is incorrect.' } });
    });

    it('passes through 403 ACCOUNT_PENDING', async () => {
      const { app } = setup({ authenticate: vi.fn().mockRejectedValue(accountPending()) });

      const res = await login(app);

      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe('ACCOUNT_PENDING');
    });
  });

  describe('per-IP limit', () => {
    it('answers 429 in the usual format once the limit is used up', async () => {
      const { app } = setup({ rateLimits: { loginPerIp: 3 } });
      for (let i = 0; i < 3; i += 1) await login(app, { username: `user_${i}`, password: PASSWORD });

      const res = await login(app, { username: 'user_99', password: PASSWORD });

      expect(res.status).toBe(429);
      expect(res.body).toEqual({
        error: { code: 'TOO_MANY_REQUESTS', message: 'Too many login attempts from this network. Please try again later.' },
      });
      expect(res.headers['retry-after']).toMatch(/^\d+$/);
    });

    it('counts invalid requests too, because it runs before validation', async () => {
      const { app, users } = setup({ rateLimits: { loginPerIp: 2 } });
      await login(app, {});
      await login(app, { username: 'mutale_banda' });

      const res = await login(app);

      expect(res.status).toBe(429);
      expect(users.authenticate).not.toHaveBeenCalled();
    });

    it('allows 100 per 15 minutes by default', async () => {
      // Different usernames, so only the IP limit is in play.
      const { app } = setup();
      for (let i = 0; i < 100; i += 1) {
        expect((await login(app, { username: `user_${i}`, password: PASSWORD })).status).toBe(200);
      }

      expect((await login(app, { username: 'user_100', password: PASSWORD })).status).toBe(429);
    });
  });

  describe('per-username limit (failed attempts only)', () => {
    const failing = () => vi.fn().mockRejectedValue(invalidCredentials());
    const USERNAME_429 = {
      error: { code: 'TOO_MANY_REQUESTS', message: 'Too many failed login attempts for this username. Please try again in 15 minutes.' },
    };

    it('blocks a username after the limit of failed attempts, without calling authenticate', async () => {
      const { app, users } = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 2 } });
      await login(app);
      await login(app);

      const res = await login(app);

      expect(res.status).toBe(429);
      expect(res.body).toEqual(USERNAME_429);
      expect(users.authenticate).toHaveBeenCalledTimes(2);
    });

    it('treats different letter case and spacing as the same username', async () => {
      const { app } = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 2 } });
      await login(app, { username: 'Mutale_Banda', password: 'x' });
      await login(app, { username: ' mutale_banda ', password: 'x' });

      const res = await login(app, { username: 'MUTALE_BANDA', password: 'x' });

      expect(res.status).toBe(429);
    });

    it('does not count successful logins', async () => {
      const { app } = setup({ rateLimits: { loginPerUsername: 2 } });

      for (let i = 0; i < 5; i += 1) {
        expect((await login(app)).status).toBe(200);
        await settle();
      }
    });

    it('gives back only the successes: fail, success, fail is allowed, and the next fail is not', async () => {
      const authenticate = vi
        .fn()
        .mockRejectedValueOnce(invalidCredentials())
        .mockResolvedValueOnce(SUCCESS)
        .mockRejectedValue(invalidCredentials());
      const { app } = setup({ authenticate, rateLimits: { loginPerUsername: 2 } });

      expect((await login(app)).status).toBe(401);
      expect((await login(app)).status).toBe(200);
      await settle();
      expect((await login(app)).status).toBe(401);

      expect((await login(app)).status).toBe(429);
    });

    it('counts a 403 pending answer as a failed attempt', async () => {
      const { app } = setup({ authenticate: vi.fn().mockRejectedValue(accountPending()), rateLimits: { loginPerUsername: 1 } });
      await login(app);

      expect((await login(app)).status).toBe(429);
    });

    it('leaves other usernames unaffected while one is blocked', async () => {
      const { app } = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 1 } });
      await login(app);
      expect((await login(app)).status).toBe(429);

      const res = await login(app, { username: 'chanda_mwila', password: PASSWORD });

      expect(res.status).toBe(401);
    });

    it('answers identically for a username that does not exist, so the 429 reveals nothing', async () => {
      const { app } = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 1 } });
      await login(app, { username: 'mutale_banda', password: 'x' });
      await login(app, { username: 'nobody_here', password: 'x' });

      const real = await login(app, { username: 'mutale_banda', password: 'x' });
      const unknown = await login(app, { username: 'nobody_here', password: 'x' });

      expect(real.status).toBe(429);
      expect(unknown.body).toEqual(real.body);
    });

    it('gives every app instance its own counters', async () => {
      const first = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 1 } });
      await login(first.app);
      expect((await login(first.app)).status).toBe(429);

      const second = setup({ authenticate: failing(), rateLimits: { loginPerUsername: 1 } });

      expect((await login(second.app)).status).toBe(401);
    });
  });

  it('never puts the typed username or password in a response body or a log', async () => {
    const typedUsername = 'gold_river_kasempa_typed';
    const typedPassword = 'a passphrase that must stay private';
    const logs = ['log', 'warn', 'error'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
    const { app } = setup({
      authenticate: vi.fn().mockRejectedValue(invalidCredentials()),
      rateLimits: { loginPerUsername: 1, loginPerIp: 3 },
    });

    // A failure, then the username limit, then the IP limit.
    const bodies = [];
    for (let i = 0; i < 4; i += 1) {
      bodies.push((await login(app, { username: typedUsername, password: typedPassword })).text);
    }

    expect(bodies.map((b) => JSON.parse(b).error.code)).toEqual([
      'INVALID_CREDENTIALS',
      'TOO_MANY_REQUESTS',
      'TOO_MANY_REQUESTS',
      'TOO_MANY_REQUESTS',
    ]);
    const everything = [...bodies, ...logs.flatMap((spy) => spy.mock.calls.map((call) => String(call)))].join('\n');
    expect(everything).not.toContain(typedUsername);
    expect(everything).not.toContain(typedPassword);
  });
});

describe('loginUsernameKey', () => {
  const key = randomBytes(32);

  it('gives the same key whatever the letter case or surrounding spaces', () => {
    expect(loginUsernameKey(key, ' Mutale_Banda ')).toBe(loginUsernameKey(key, 'mutale_banda'));
  });

  it('gives a different key for a different username', () => {
    expect(loginUsernameKey(key, 'chanda_mwila')).not.toBe(loginUsernameKey(key, 'mutale_banda'));
  });

  it('gives a different key with a different limiter key, so it cannot be precomputed', () => {
    expect(loginUsernameKey(randomBytes(32), 'mutale_banda')).not.toBe(loginUsernameKey(key, 'mutale_banda'));
  });

  it('is 64 hex characters that do not contain the username', () => {
    const result = loginUsernameKey(key, 'mutale_banda');

    expect(result).toMatch(/^[0-9a-f]{64}$/);
    expect(result).not.toContain('mutale');
  });
});
