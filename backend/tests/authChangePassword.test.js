import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { AppError } from '../src/errors.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'change-password-routes-test-secret-ddddddddddddddddddd';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const OTHER_ID = '3f2b6c1e-0000-4000-8000-000000000002';

const CURRENT = 'gold river kasempa';
const NEW = 'copper hill solwezi';
const BODY = { currentPassword: CURRENT, newPassword: NEW };

const SAFE_USER = {
  id: USER_ID,
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  licenceNumber: null,
  role: 'miner',
  status: 'active',
  createdAt: '2026-11-05T09:00:00.000Z',
  publicKeyFingerprint: null,
};
const SUCCESS = { user: SAFE_USER, token: 'fresh.token.signature', expiresIn: 3600 };

const currentIncorrect = () =>
  new AppError(400, 'CURRENT_PASSWORD_INCORRECT', 'Your current password is not correct.', [
    { field: 'currentPassword', message: 'is not correct' },
  ]);

// The real app and real token checks, with a fake users service. getAuthenticatedUser stands
// in for the database: every token belongs to an active user with the token's role.
function setup({ changePassword = vi.fn().mockResolvedValue(SUCCESS), ...options } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ ...SAFE_USER, id: userId, role })),
    changePassword,
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens }, ...options });
  const tokenFor = async (role = 'miner', userId = USER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, users, tokenFor };
}

// Passed as the body to send none at all. A sentinel, not undefined: JavaScript applies the
// default parameter when undefined is passed explicitly, so undefined would quietly send BODY.
const NO_BODY = Symbol('no body');

const change = (app, token, body = BODY) => {
  let req = request(app).post('/auth/me/password');
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === NO_BODY ? req : req.send(body);
};

// Successful requests are given back to the counter when the response finishes. One
// event-loop turn makes sure that has happened before the next request is sent.
const settle = () => new Promise((resolve) => setImmediate(resolve));

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /auth/me/password', () => {
  describe('success', () => {
    it('answers 200 with the fresh token, its type and lifetime, and the user, exactly like login, with no-store', async () => {
      const { app, tokenFor } = setup();

      const res = await change(app, await tokenFor());

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ token: 'fresh.token.signature', tokenType: 'Bearer', expiresIn: 3600, user: SAFE_USER });
      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('passes the logged-in user from the token, the untouched passwords and the client IP', async () => {
      const { app, users, tokenFor } = setup();

      await change(app, await tokenFor(), { currentPassword: ' gold river kasempa ', newPassword: ' copper hill solwezi ' });

      expect(users.changePassword).toHaveBeenCalledWith({
        userId: USER_ID,
        currentPassword: ' gold river kasempa ',
        newPassword: ' copper hill solwezi ',
        ipAddress: expect.any(String),
      });
    });

    it.each(['miner', 'transporter', 'buyer', 'officer', 'admin'])('is open to a %s', async (role) => {
      const { app, tokenFor } = setup();

      expect((await change(app, await tokenFor(role))).status).toBe(200);
    });
  });

  it('refuses a request with no token (401), with no-store, before the service', async () => {
    const { app, users } = setup();

    const res = await change(app, undefined);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(users.changePassword).not.toHaveBeenCalled();
  });

  describe('400 VALIDATION_FAILED, before changePassword is called', () => {
    it.each([
      ['a missing current password', { newPassword: NEW }, 'currentPassword'],
      ['a missing new password', { currentPassword: CURRENT }, 'newPassword'],
      ['an empty current password', { ...BODY, currentPassword: '' }, 'currentPassword'],
      ['a 1025-character new password', { ...BODY, newPassword: 'a'.repeat(1025) }, 'newPassword'],
      ['another account named in the body', { ...BODY, userId: OTHER_ID }, 'userId'],
      ['no body at all', NO_BODY, 'body'],
    ])('refuses %s, with no-store', async (_label, body, field) => {
      const { app, users, tokenFor } = setup();

      const res = await change(app, await tokenFor(), body);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(users.changePassword).not.toHaveBeenCalled();
    });
  });

  describe('400 answers from changePassword, passed through unchanged', () => {
    it.each([
      ['CURRENT_PASSWORD_INCORRECT', currentIncorrect()],
      [
        'PASSWORD_UNCHANGED',
        new AppError(400, 'PASSWORD_UNCHANGED', 'Choose a password different from your current one.', [
          { field: 'newPassword', message: 'must be different from your current password' },
        ]),
      ],
      [
        'WEAK_PASSWORD',
        new AppError(400, 'WEAK_PASSWORD', 'Choose a stronger password.', [
          { field: 'newPassword', code: 'PASSWORD_TOO_SHORT', message: 'Use at least 12 characters. A few words with spaces works well.' },
        ]),
      ],
    ])('%s', async (_code, error) => {
      const { app, tokenFor } = setup({ changePassword: vi.fn().mockRejectedValue(error) });

      const res = await change(app, await tokenFor());

      // 400, never 401: a 401 would make the app throw the session away.
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ error: { code: error.code, message: error.message, details: error.details } });
      expect(res.headers['cache-control']).toBe('no-store');
    });
  });

  describe('per-user limit (failed attempts only)', () => {
    const LIMIT_429 = {
      error: { code: 'TOO_MANY_REQUESTS', message: 'Too many failed password changes. Please wait 15 minutes and try again.' },
    };

    it('answers 429 after 10 failures by default, without calling the service again', async () => {
      const { app, users, tokenFor } = setup({ changePassword: vi.fn().mockRejectedValue(currentIncorrect()) });
      const token = await tokenFor();
      for (let i = 0; i < 10; i += 1) expect((await change(app, token)).status).toBe(400);

      const res = await change(app, token);

      expect(res.status).toBe(429);
      expect(res.body).toEqual(LIMIT_429);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(users.changePassword).toHaveBeenCalledTimes(10);
    });

    it('does not count successful changes', async () => {
      const { app, tokenFor } = setup({ rateLimits: { passwordChangePerUser: 2 } });
      const token = await tokenFor();

      for (let i = 0; i < 5; i += 1) {
        expect((await change(app, token)).status).toBe(200);
        await settle();
      }
    });

    it('counts per user: one user blocked leaves another unaffected', async () => {
      const { app, tokenFor } = setup({ changePassword: vi.fn().mockRejectedValue(currentIncorrect()), rateLimits: { passwordChangePerUser: 1 } });
      const blocked = await tokenFor('miner', USER_ID);
      await change(app, blocked);
      expect((await change(app, blocked)).status).toBe(429);

      expect((await change(app, await tokenFor('miner', OTHER_ID))).status).toBe(400);
    });
  });

  it('never puts either password in a response body or a log', async () => {
    const logs = ['log', 'warn', 'error'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
    const { app, tokenFor } = setup({ changePassword: vi.fn().mockRejectedValue(currentIncorrect()), rateLimits: { passwordChangePerUser: 1 } });
    const token = await tokenFor();

    // A refusal, then the limit.
    const bodies = [(await change(app, token)).text, (await change(app, token)).text];

    expect(bodies.map((b) => JSON.parse(b).error.code)).toEqual(['CURRENT_PASSWORD_INCORRECT', 'TOO_MANY_REQUESTS']);
    const everything = [...bodies, ...logs.flatMap((spy) => spy.mock.calls.map((call) => String(call)))].join('\n');
    expect(everything).not.toContain(CURRENT);
    expect(everything).not.toContain(NEW);
  });
});
