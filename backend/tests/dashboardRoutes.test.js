import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';

// GET /dashboard with the real app and token checks, and a fake service behind it. The
// service's own rules are tested in tests/db/dashboardService.test.js.

// Fake secret, long enough for the 43-character rule.
const SECRET = 'dashboard-routes-test-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const OFFICER_ID = '3f2b6c1e-0000-4000-8000-0000000000f0';
const OTHER_ID = '3f2b6c1e-0000-4000-8000-000000000001';

const PATH = '/dashboard?from=2026-11-17&to=2026-11-23';
const SUMMARY = Object.freeze({ period: { from: '2026-11-17', to: '2026-11-23', days: 7 }, steps: { total: 0 } });

function setup() {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const dashboard = { summary: vi.fn().mockResolvedValue(SUMMARY) };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, dashboard } });
  const tokenFor = async (role) => (await tokens.sign({ userId: role === 'officer' ? OFFICER_ID : OTHER_ID, role })).token;
  return { app, dashboard, tokenFor };
}

const get = (app, path, token) => {
  const req = request(app).get(path);
  return token ? req.set('Authorization', `Bearer ${token}`) : req;
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('dashboard route: who may call it', () => {
  it('refuses a request with no token (401), with no-store', async () => {
    const { app, dashboard } = setup();

    const res = await get(app, PATH);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(dashboard.summary).not.toHaveBeenCalled();
  });

  it.each(['admin', 'buyer', 'miner', 'transporter'])('refuses a %s (403 FORBIDDEN), with no-store', async (role) => {
    const { app, dashboard, tokenFor } = setup();

    const res = await get(app, PATH, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(dashboard.summary).not.toHaveBeenCalled();
  });

  it('refuses a non-officer before validation, so a bad query is still 403', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/dashboard?from=nonsense', await tokenFor('miner'));

    expect(res.status).toBe(403);
  });

  it('gives a non-officer 403, not 404, on a path that does not exist', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/dashboard/zones', await tokenFor('buyer'));

    expect(res.status).toBe(403);
  });
});

describe('dashboard route: an officer', () => {
  it('gets the summary as it is, with no-store, the query and the officer passed on', async () => {
    const { app, dashboard, tokenFor } = setup();

    const res = await get(app, `${PATH}&mineral=gold`, await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual(SUMMARY);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(dashboard.summary).toHaveBeenCalledWith(
      { from: '2026-11-17', to: '2026-11-23', mineral: 'gold' },
      expect.objectContaining({ id: OFFICER_ID, role: 'officer' }),
    );
  });

  it.each([
    ['no period', '/dashboard', ['from', 'to']],
    ['a bad day', '/dashboard?from=2026-11-31&to=2026-11-30', ['from']],
    ['to before from', '/dashboard?from=2026-11-23&to=2026-11-17', ['to']],
    ['an unknown mineral', `${PATH}&mineral=silver`, ['mineral']],
    ['a repeated mineral', `${PATH}&mineral=gold&mineral=copper`, ['mineral']],
    // validate() names an unknown parameter by its own name.
    ['a report filter', `${PATH}&type=handoff`, ['type']],
  ])('gets 400 VALIDATION_FAILED for %s, naming the field', async (_name, path, fields) => {
    const { app, dashboard, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'));

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toEqual(fields);
    expect(dashboard.summary).not.toHaveBeenCalled();
  });

  it('gets the normal 404 for a path that does not exist', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/dashboard/zones', await tokenFor('officer'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });

  it('is never rate-limited', async () => {
    const { app, tokenFor } = setup();
    const token = await tokenFor('officer');

    for (let i = 0; i < 70; i += 1) {
      expect((await get(app, PATH, token)).status).toBe(200);
    }
  });
});
