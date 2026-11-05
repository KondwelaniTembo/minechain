import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { requireRole } from '../src/middleware/requireRole.js';
import { createRequireAuth } from '../src/middleware/requireAuth.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createUserService } from '../src/services/userService.js';
import { ROLES } from '../src/roles.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'require-role-test-secret-dddddddddddddddddddddddddddd';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// An in-memory users table: one row per role, plus whatever a test changes.
const userRow = (id, role) => ({
  id,
  username: `${role}_user`,
  full_name: `Test ${role}`,
  licence_number: null,
  role,
  status: 'active',
  created_at: new Date('2026-11-05T09:00:00Z'),
});

// A test-only app: the real requireAuth (real tokens, the real userService over the
// in-memory table) in front of routes that exist only here, because no production route
// uses requireRole yet.
function setup() {
  const rows = new Map(ROLES.map((role, i) => [`user-${i}`, userRow(`user-${i}`, role)]));
  const db = {
    query: vi.fn(async (text, [id]) => {
      const row = rows.get(id);
      return { rows: row ? [row] : [], rowCount: row ? 1 : 0 };
    }),
  };
  const users = createUserService({ db, passwords: {}, passwordPolicy: () => [], audit: {}, tokens });
  const requireAuth = createRequireAuth({ tokens, users });
  const handler = vi.fn((req, res) => res.json({ ok: true, role: req.user.role }));

  const app = express();
  app.get('/miner-only', requireAuth, requireRole('miner'), handler);
  app.get('/officer-or-admin', requireAuth, requireRole('officer', 'admin'), handler);
  // The mistake under test: requireAuth left off the route.
  app.get('/forgot-require-auth', requireRole('admin'), handler);
  app.use(errorHandler);

  const idFor = (role) => [...rows.values()].find((r) => r.role === role).id;
  const tokenFor = async (role) => (await tokens.sign({ userId: idFor(role), role })).token;
  return { app, rows, handler, idFor, tokenFor };
}

const get = (app, path, token) => {
  const req = request(app).get(path);
  return token ? req.set('Authorization', `Bearer ${token}`) : req;
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('requireRole', () => {
  describe('when the route is built', () => {
    it('throws for an empty role list', () => {
      expect(() => requireRole()).toThrow(new TypeError('requireRole needs at least one role'));
    });

    it.each(['officr', 'administrator', 'Admin', '', 'regulator'])('throws for the unknown role %j', (role) => {
      expect(() => requireRole(role)).toThrow(TypeError);
    });

    it('names the bad role in the error, so the typo is easy to find', () => {
      expect(() => requireRole('miner', 'officr')).toThrow(/"officr"/);
    });

    it('throws for a list passed as one array instead of separate names', () => {
      expect(() => requireRole(['miner', 'buyer'])).toThrow(TypeError);
    });

    it.each(ROLES)('accepts %s', (role) => {
      expect(() => requireRole(role)).not.toThrow();
    });
  });

  describe('one allowed role', () => {
    it('lets the allowed role through', async () => {
      const { app, tokenFor, handler } = setup();

      const res = await get(app, '/miner-only', await tokenFor('miner'));

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ ok: true, role: 'miner' });
      expect(handler).toHaveBeenCalledOnce();
    });

    it.each(['transporter', 'buyer', 'officer', 'admin'])('refuses %s with 403 FORBIDDEN', async (role) => {
      const { app, tokenFor, handler } = setup();

      const res = await get(app, '/miner-only', await tokenFor(role));

      expect(res.status).toBe(403);
      expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
      expect(handler).not.toHaveBeenCalled();
    });

    it('never names the allowed roles in the refusal', async () => {
      const { app, tokenFor } = setup();

      const res = await get(app, '/miner-only', await tokenFor('buyer'));

      expect(res.text).not.toMatch(/miner/i);
    });

    it('sends no WWW-Authenticate header with a 403, because the login itself was fine', async () => {
      const { app, tokenFor } = setup();

      const res = await get(app, '/miner-only', await tokenFor('buyer'));

      expect(res.headers['www-authenticate']).toBeUndefined();
    });

    it('leaves a request with no token to requireAuth, which answers 401 first', async () => {
      const { app, handler } = setup();

      const res = await get(app, '/miner-only');

      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_MISSING');
      expect(handler).not.toHaveBeenCalled();
    });
  });

  describe('several allowed roles', () => {
    it.each(['officer', 'admin'])('lets %s through', async (role) => {
      const { app, tokenFor } = setup();

      const res = await get(app, '/officer-or-admin', await tokenFor(role));

      expect(res.status).toBe(200);
      expect(res.body.role).toBe(role);
    });

    it.each(['miner', 'transporter', 'buyer'])('refuses %s', async (role) => {
      const { app, tokenFor } = setup();

      expect((await get(app, '/officer-or-admin', await tokenFor(role))).status).toBe(403);
    });
  });

  describe('the role comes from the database, never from the token', () => {
    it('refuses an old token once the role changes, even if the new role would be allowed', async () => {
      const { app, rows, idFor, tokenFor, handler } = setup();
      const token = await tokenFor('miner');
      // Promoted to officer after the token was issued. The token still says "miner".
      rows.get(idFor('miner')).role = 'officer';

      const res = await get(app, '/officer-or-admin', token);

      // requireAuth spots the mismatch first: log in again for a token with the new role.
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe('TOKEN_INVALID');
      expect(handler).not.toHaveBeenCalled();
    });

    it('applies the new role with a fresh token, including losing the old one', async () => {
      const { app, rows, idFor } = setup();
      const minerId = idFor('miner');
      rows.get(minerId).role = 'officer';
      const freshToken = (await tokens.sign({ userId: minerId, role: 'officer' })).token;

      expect((await get(app, '/officer-or-admin', freshToken)).status).toBe(200);
      expect((await get(app, '/miner-only', freshToken)).status).toBe(403);
    });

    it('reads only req.user, whatever else is on the request', () => {
      const middleware = requireRole('officer');
      const next = vi.fn();
      // A request whose user (as requireAuth would set it) is a miner, carrying a header
      // that claims otherwise. Only req.user counts.
      const req = { user: { id: 'user-0', role: 'miner' }, headers: { 'x-role': 'officer' }, body: { role: 'officer' } };

      middleware(req, {}, next);

      expect(next).toHaveBeenCalledWith(expect.objectContaining({ status: 403, code: 'FORBIDDEN' }));
    });
  });

  describe('fails closed when requireAuth is missing', () => {
    it('refuses with a 500 and logs the mistake, instead of letting the request through', async () => {
      const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
      const { app, tokenFor, handler } = setup();

      // Even a genuine admin token does not help: nothing on this route checked it.
      const res = await get(app, '/forgot-require-auth', await tokenFor('admin'));

      expect(res.status).toBe(500);
      expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
      expect(handler).not.toHaveBeenCalled();
      // Visible to the developer in the server log, never to the client.
      expect(consoleError).toHaveBeenCalledWith(
        'Unhandled error:',
        expect.objectContaining({ message: 'requireRole ran without requireAuth before it on this route' }),
      );
      expect(res.text).not.toContain('requireAuth');
    });

    it.each([
      ['no req.user', {}],
      ['a req.user without a role', { user: { id: 'user-0' } }],
    ])('passes an error on for %s', (_label, req) => {
      const next = vi.fn();

      requireRole('admin')(req, {}, next);

      expect(next).toHaveBeenCalledWith(expect.any(Error));
      expect(next.mock.calls[0][0].status).toBeUndefined(); // not an AppError, so a 500
    });
  });
});
