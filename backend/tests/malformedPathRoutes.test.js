import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';

// A malformed percent-escape in a route parameter (B2.5a), through the real app: Express 5's
// router fails to decode it while matching the route, and errorHandler answers a fixed 400.
// The router-level guards run before the route is matched, so the token is still checked
// first. Fake services: none may be called.

// Fake secret, long enough for the 43-character rule.
const SECRET = 'malformed-path-routes-test-secret-aaaaaaaaaaaaaaaaaaaaaaa';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });
const USER_ID = '3f2b6c1e-0000-4000-8000-0000000000a0';

// Text a client typed in front of the bad escape: it must never come back or reach the log.
const TYPED = 'TYPED-BY-CLIENT';
const BAD = `${TYPED}%E0%A4`;

const ROUTES = [
  { label: 'GET /alerts/:id', role: 'officer', method: 'get', path: `/alerts/${BAD}` },
  { label: 'POST /admin/users/:id/suspend', role: 'admin', method: 'post', path: `/admin/users/${BAD}/suspend`, body: { reason: 'Left the company' } },
  { label: 'POST /admin/zones/:id/rename', role: 'admin', method: 'post', path: `/admin/zones/${BAD}/rename`, body: { name: 'New name' } },
  { label: 'GET /consignments/by-qr/:qrCode', role: 'buyer', method: 'get', path: `/consignments/by-qr/${BAD}` },
];

const FIXED_BODY = { error: { code: 'VALIDATION_FAILED', message: 'The request path is not valid.' } };

let consoleError;

beforeEach(() => {
  consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

function setup({ consignmentViewsPerUser } = {}) {
  const users = { getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })) };
  // Every method any of the four routes could reach; each must stay uncalled.
  const fn = () => vi.fn().mockResolvedValue({});
  const services = {
    users,
    tokens,
    alerts: { list: fn(), get: fn(), review: fn(), dismiss: fn() },
    accounts: { list: fn(), suspend: fn(), rename: fn() },
    zones: { list: fn(), rename: fn() },
    consignments: { viewByQr: vi.fn().mockResolvedValue({ consignment: {}, steps: [] }) },
  };
  const app = createApp({ db: { query: vi.fn() }, services, rateLimits: { consignmentViewsPerUser } });
  const tokenFor = async (role) => (await tokens.sign({ userId: USER_ID, role })).token;
  return { app, services, tokenFor };
}

function send(app, { method, path, body }, token) {
  let req = request(app)[method](path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

function expectNoServiceCalled(services) {
  for (const [name, service] of Object.entries(services)) {
    if (name === 'users' || name === 'tokens') continue;
    for (const method of Object.values(service)) expect(method).not.toHaveBeenCalled();
  }
}

describe('a malformed percent-escape in a route parameter', () => {
  it.each(ROUTES.map((r) => [r.label, r]))('%s: 400 with the fixed body and no-store, for an allowed role', async (_label, r) => {
    const { app, services, tokenFor } = setup();

    const res = await send(app, r, await tokenFor(r.role));

    expect(res.status).toBe(400);
    expect(res.body).toEqual(FIXED_BODY);
    expect(res.headers['cache-control']).toBe('no-store');
    expectNoServiceCalled(services);
  });

  it.each(ROUTES.map((r) => [r.label, r]))('%s: the typed value appears in neither the body nor the console', async (_label, r) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, await tokenFor(r.role));

    expect(res.text).not.toContain(TYPED);
    expect(res.text).not.toContain('%E0');
    expect(consoleError).not.toHaveBeenCalled();
  });

  it.each(ROUTES.map((r) => [r.label, r]))('%s: with no token, the 401 still comes first', async (_label, r) => {
    const { app, services } = setup();

    const res = await send(app, r);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expectNoServiceCalled(services);
  });

  it('a role the router refuses still gets its 403 first', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, ROUTES[3], await tokenFor('miner'));

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  // Known and accepted (B2.5a): the decode fails while the route is being matched, before the
  // route's own limiter runs, so these requests are not counted. Pinned here so a later change
  // to that is made on purpose.
  it('is not counted by the per-user consignment view limiter', async () => {
    const { app, tokenFor } = setup({ consignmentViewsPerUser: 1 });
    const token = await tokenFor('buyer');
    for (let i = 0; i < 3; i += 1) expect((await send(app, ROUTES[3], token)).status).toBe(400);

    expect((await send(app, { method: 'get', path: '/consignments/by-qr/MC-DEMO-000001' }, token)).status).toBe(200);
  });
});
