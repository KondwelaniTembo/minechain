import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/errors.js';

// All values fake. The code is in display form, as the administrator read it out.
const CODE = '7KQ4-M2XD-9TNE';
const PASSWORD = 'copper hill solwezi';
const ACTIVATE = { username: 'chanda_mwale', code: CODE, password: PASSWORD };

const SAFE_USER = {
  id: '3f2b6c1e-0000-4000-8000-000000000002',
  username: 'chanda_mwale',
  fullName: 'Chanda Mwale',
  licenceNumber: null,
  role: 'officer',
  status: 'active',
  createdAt: '2026-11-11T09:00:00.000Z',
  publicKeyFingerprint: null,
};
const SUCCESS = { user: SAFE_USER, token: 'header.payload.signature', expiresIn: 3600 };

const ACTIVATION_INVALID = {
  code: 'ACTIVATION_INVALID',
  message: 'This activation code is not valid. Ask an administrator for a new one.',
};
const activationInvalid = () => new AppError(401, ACTIVATION_INVALID.code, ACTIVATION_INVALID.message);

// A fresh app each time, so no test shares a rate-limit counter.
function setup({ activate = vi.fn().mockResolvedValue(SUCCESS), ...options } = {}) {
  const users = { register: vi.fn(), authenticate: vi.fn(), activate };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens: { verify: vi.fn() } }, ...options });
  return { app, users };
}

const activate = (app, body = ACTIVATE) => request(app).post('/auth/activate').send(body);

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /auth/activate', () => {
  describe('success', () => {
    it('answers 200 with the token, its type and lifetime, and the user, exactly like login', async () => {
      const { app } = setup();

      const res = await activate(app);

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ token: 'header.payload.signature', tokenType: 'Bearer', expiresIn: 3600, user: SAFE_USER });
    });

    it('tells every cache not to keep the response', async () => {
      const { app } = setup();

      const res = await activate(app);

      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('passes the trimmed username, the untouched code and password, and the client IP', async () => {
      const { app, users } = setup();

      await activate(app, { username: '  chanda_mwale ', code: ' 7kq4 m2xd 9tne ', password: ' copper hill solwezi ' });

      expect(users.activate).toHaveBeenCalledWith({
        username: 'chanda_mwale',
        code: ' 7kq4 m2xd 9tne ',
        password: ' copper hill solwezi ',
        ipAddress: expect.any(String),
      });
    });

    it('leaves the password policy to the service, which applies it before the code', async () => {
      const { app, users } = setup();

      await activate(app, { ...ACTIVATE, password: 'short' });

      expect(users.activate).toHaveBeenCalledWith(expect.objectContaining({ password: 'short' }));
    });

    it('passes on a 64-character code: normalise, not the schema, decides whether it can be a code', async () => {
      const { app, users } = setup();

      await activate(app, { ...ACTIVATE, code: 'a'.repeat(64) });

      expect(users.activate).toHaveBeenCalledOnce();
    });
  });

  describe('400 VALIDATION_FAILED, before activate is called', () => {
    it.each([
      ['a missing username', { code: CODE, password: PASSWORD }, 'username'],
      ['a missing code', { username: 'chanda_mwale', password: PASSWORD }, 'code'],
      ['a missing password', { username: 'chanda_mwale', code: CODE }, 'password'],
      ['a blank username', { ...ACTIVATE, username: '   ' }, 'username'],
      ['an empty code', { ...ACTIVATE, code: '' }, 'code'],
      ['a code as a number', { ...ACTIVATE, code: 123456789012 }, 'code'],
      ['a 65-character code', { ...ACTIVATE, code: 'a'.repeat(65) }, 'code'],
      ['a 1025-character password', { ...ACTIVATE, password: 'a'.repeat(1025) }, 'password'],
      ['an unknown field', { ...ACTIVATE, role: 'admin' }, 'role'],
    ])('refuses %s, with no-store', async (_label, body, field) => {
      const { app, users } = setup();

      const res = await activate(app, body);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(users.activate).not.toHaveBeenCalled();
    });
  });

  describe('errors from activate', () => {
    it('passes through 401 ACTIVATION_INVALID unchanged, with no-store', async () => {
      const { app } = setup({ activate: vi.fn().mockRejectedValue(activationInvalid()) });

      const res = await activate(app);

      expect(res.status).toBe(401);
      expect(res.body).toEqual({ error: ACTIVATION_INVALID });
      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('passes through 400 WEAK_PASSWORD with the policy details', async () => {
      const details = [{ field: 'password', code: 'PASSWORD_TOO_SHORT', message: 'Use at least 12 characters. A few words with spaces works well.' }];
      const { app } = setup({ activate: vi.fn().mockRejectedValue(new AppError(400, 'WEAK_PASSWORD', 'Choose a stronger password.', details)) });

      const res = await activate(app);

      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: { code: 'WEAK_PASSWORD', message: 'Choose a stronger password.', details } });
    });

    it('answers an unexpected fault with a generic 500', async () => {
      const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
      const { app } = setup({ activate: vi.fn().mockRejectedValue(new Error('connection lost')) });

      const res = await activate(app);

      expect(res.status).toBe(500);
      expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
      expect(consoleError).toHaveBeenCalled();
    });
  });

  describe('per-IP limit', () => {
    it('answers 429 in the usual format once the limit is used up, with no-store', async () => {
      const { app, users } = setup({ rateLimits: { activationPerIp: 3 } });
      for (let i = 0; i < 3; i += 1) await activate(app);

      const res = await activate(app);

      expect(res.status).toBe(429);
      expect(res.body).toEqual({
        error: { code: 'TOO_MANY_REQUESTS', message: 'Too many activation attempts from this network. Please try again later.' },
      });
      expect(res.headers['retry-after']).toMatch(/^\d+$/);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(users.activate).toHaveBeenCalledTimes(3);
    });

    it('counts invalid requests too, because it runs before validation', async () => {
      const { app, users } = setup({ rateLimits: { activationPerIp: 2 } });
      await activate(app, {});
      await activate(app, { username: 'chanda_mwale' });

      const res = await activate(app);

      expect(res.status).toBe(429);
      expect(users.activate).not.toHaveBeenCalled();
    });

    it('allows 30 per 15 minutes by default', async () => {
      const { app } = setup({ activate: vi.fn().mockRejectedValue(activationInvalid()) });
      for (let i = 0; i < 30; i += 1) {
        expect((await activate(app)).status).toBe(401);
      }

      expect((await activate(app)).status).toBe(429);
    });

    it('has its own counter: using it up does not block login', async () => {
      const { app, users } = setup({ rateLimits: { activationPerIp: 1 } });
      users.authenticate.mockResolvedValue(SUCCESS);
      await activate(app);
      expect((await activate(app)).status).toBe(429);

      const res = await request(app).post('/auth/login').send({ username: 'chanda_mwale', password: PASSWORD });

      expect(res.status).toBe(200);
    });
  });

  it('never puts the typed code or password in a response body or a log', async () => {
    const typedCode = 'ZZZZ-YYYY-XXXX';
    const typedPassword = 'a passphrase that must stay private';
    const logs = ['log', 'warn', 'error'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
    const { app } = setup({ activate: vi.fn().mockRejectedValue(activationInvalid()), rateLimits: { activationPerIp: 1 } });

    // A refusal, then a malformed request that meets the limit first (it runs before validation).
    const bodies = [
      (await activate(app, { username: 'chanda_mwale', code: typedCode, password: typedPassword })).text,
      (await activate(app, { username: 'chanda_mwale', code: typedCode, password: typedPassword, extra: 1 })).text,
    ];

    expect(bodies.map((b) => JSON.parse(b).error.code)).toEqual(['ACTIVATION_INVALID', 'TOO_MANY_REQUESTS']);
    const everything = [...bodies, ...logs.flatMap((spy) => spy.mock.calls.map((call) => String(call)))].join('\n');
    expect(everything).not.toContain(typedCode);
    expect(everything).not.toContain(typedPassword);
  });
});
