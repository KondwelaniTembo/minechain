import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createUserService } from '../src/services/userService.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'require-auth-test-secret-cccccccccccccccccccccccccccc';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
// A users-table row. The full name is marked so a test can prove req.user came from the
// database, since the token carries only the id and role.
const row = (overrides = {}) => ({
  id: USER_ID,
  username: 'mutale_banda',
  full_name: 'Mutale Banda (from the database)',
  licence_number: null,
  role: 'miner',
  status: 'active',
  created_at: new Date('2026-11-05T09:00:00Z'),
  ...overrides,
});

// The real userService and tokenService over an in-memory users table, so suspended, role
// changed and deleted users go through the same code the app runs, without PostgreSQL.
function setup(rows = [row()]) {
  const db = {
    query: vi.fn(async (text, [id]) => {
      const found = rows.filter((r) => r.id === id);
      return { rows: found, rowCount: found.length };
    }),
  };
  const users = createUserService({ db, passwords: {}, passwordPolicy: () => [], audit: {}, tokens });
  const lookup = vi.spyOn(users, 'getAuthenticatedUser');
  const app = createApp({ db, services: { users, tokens } });
  return { app, lookup };
}

const validToken = async (role = 'miner') => (await tokens.sign({ userId: USER_ID, role })).token;
const me = (app, authorization) => {
  const req = request(app).get('/auth/me');
  return authorization === undefined ? req : req.set('Authorization', authorization);
};

const CHALLENGE = 'Bearer realm="minechain"';
const CHALLENGE_INVALID = 'Bearer realm="minechain", error="invalid_token"';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('requireAuth on GET /auth/me', () => {
  describe('no usable credentials: 401 TOKEN_MISSING', () => {
    it.each([
      ['no Authorization header', undefined],
      ['an empty header', ''],
      ['the Basic scheme', 'Basic dXNlcjpwYXNz'],
      ['"Bearer" with no token', 'Bearer'],
      ['"Bearer" followed only by spaces', 'Bearer    '],
      ['a scheme that only starts with Bearer', 'Bearerabc.def.ghi'],
    ])('for %s', async (_label, header) => {
      const { app, lookup } = setup();

      const res = await me(app, header);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_MISSING');
      expect(res.headers['www-authenticate']).toBe(CHALLENGE);
      expect(lookup).not.toHaveBeenCalled();
    });

    it('ignores a valid token in the query string, because URLs end up in logs', async () => {
      const { app } = setup();
      const token = await validToken();

      const res = await request(app).get(`/auth/me?access_token=${token}`);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_MISSING');
    });
  });

  describe('refused tokens: 401 with error="invalid_token"', () => {
    it('refuses something after "Bearer" that cannot be a token', async () => {
      const { app } = setup();

      const res = await me(app, 'Bearer abc def');

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_INVALID');
      expect(res.headers['www-authenticate']).toBe(CHALLENGE_INVALID);
    });

    it('refuses an expired token with TOKEN_EXPIRED, so the app asks for the password again', async () => {
      const { app, lookup } = setup();
      const past = createTokenService({ secret: SECRET, expiresInSeconds: 3600, now: () => Date.now() - 2 * 60 * 60 * 1000 });
      const { token } = await past.sign({ userId: USER_ID, role: 'miner' });

      const res = await me(app, `Bearer ${token}`);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_EXPIRED');
      expect(res.headers['www-authenticate']).toBe(CHALLENGE_INVALID);
      expect(lookup).not.toHaveBeenCalled();
    });

    it('refuses a tampered token before looking anyone up', async () => {
      const { app, lookup } = setup();
      const [header, , signature] = (await validToken()).split('.');
      const forgedPayload = Buffer.from(JSON.stringify({ sub: USER_ID, role: 'admin' })).toString('base64url');

      const res = await me(app, `Bearer ${header}.${forgedPayload}.${signature}`);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_INVALID');
      expect(lookup).not.toHaveBeenCalled();
    });
  });

  describe('a valid token whose account has changed since it was issued', () => {
    it.each([
      ['suspended', 'ACCOUNT_SUSPENDED'],
      ['rejected', 'ACCOUNT_REJECTED'],
      ['pending', 'ACCOUNT_PENDING'],
    ])('is refused with 403 when the user is now %s', async (status, code) => {
      const { app } = setup([row({ status })]);

      const res = await me(app, `Bearer ${await validToken()}`);

      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe(code);
      // The credentials were fine; the account is not allowed in. No challenge.
      expect(res.headers['www-authenticate']).toBeUndefined();
    });

    it('is refused with 401 when the role has changed, because logging in again fixes it', async () => {
      const { app } = setup([row({ role: 'transporter' })]);

      const res = await me(app, `Bearer ${await validToken('miner')}`);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_INVALID');
      expect(res.headers['www-authenticate']).toBe(CHALLENGE_INVALID);
    });

    it('is refused with 401 when the user no longer exists', async () => {
      const { app } = setup([]);

      const res = await me(app, `Bearer ${await validToken()}`);

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_INVALID');
    });
  });

  describe('success', () => {
    it('answers 200 with the user as the database has it, not as the token says', async () => {
      const { app, lookup } = setup();

      const res = await me(app, `Bearer ${await validToken()}`);

      expect(res.status).toBe(200);
      expect(res.body).toEqual({
        user: {
          id: USER_ID,
          username: 'mutale_banda',
          fullName: 'Mutale Banda (from the database)',
          licenceNumber: null,
          role: 'miner',
          status: 'active',
          createdAt: '2026-11-05T09:00:00.000Z',
          publicKeyFingerprint: null,
        },
      });
      expect(lookup).toHaveBeenCalledWith(USER_ID, 'miner');
    });

    it('tells every cache not to keep the response', async () => {
      const { app } = setup();

      const res = await me(app, `Bearer ${await validToken()}`);

      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('accepts the scheme in any letter case', async () => {
      const { app } = setup();

      const res = await me(app, `bearer ${await validToken()}`);

      expect(res.status).toBe(200);
    });
  });

  it('never puts the token in a response body or a log', async () => {
    const logs = ['log', 'warn', 'error'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
    const token = await validToken();
    const bodies = [];

    for (const rows of [[row()], [row({ status: 'suspended' })], [row({ role: 'buyer' })], []]) {
      const { app } = setup(rows);
      bodies.push((await me(app, `Bearer ${token}`)).text);
    }

    const everything = [...bodies, ...logs.flatMap((spy) => spy.mock.calls.map((call) => String(call)))].join('\n');
    expect(everything).not.toContain(token);
    // The signature part alone must not leak either.
    expect(everything).not.toContain(token.split('.')[2]);
  });
});
