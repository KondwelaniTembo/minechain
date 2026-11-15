import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createAlertActionLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { AppError } from '../src/errors.js';

// The alert routes with the real app and token checks, and a fake service behind them. The
// service's own rules are tested in tests/db/alertService.test.js and tests/db/alertClose.test.js.

// Fake secret, long enough for the 43-character rule.
const SECRET = 'alerts-routes-test-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const OFFICER_ID = '3f2b6c1e-0000-4000-8000-0000000000f0';
const OTHER_OFFICER_ID = '3f2b6c1e-0000-4000-8000-0000000000f1';
const OTHER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const ALERT_ID = '7a3e9b10-0000-4000-8000-000000000001';

const NOTES = 'Weighed again at the depot: the scale was faulty';
const PAGE = Object.freeze({ alerts: [], total: 0, limit: 20, offset: 0 });
const ALERT = Object.freeze({ id: ALERT_ID, type: 'gps_zone', status: 'open', otherAlerts: [] });
const CLOSED = Object.freeze({
  alert: { id: ALERT_ID, status: 'dismissed' },
  step: { id: '9d4e5f60-0000-4000-8000-000000000001', reviewStatus: 'cleared' },
  consignment: { id: '5c0d7e21-0000-4000-8000-000000000001', stage: 'in_transit', held: false },
});

function setup({ alertActionsPerOfficer } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const alerts = {
    list: vi.fn().mockResolvedValue(PAGE),
    get: vi.fn().mockResolvedValue(ALERT),
    review: vi.fn().mockResolvedValue(CLOSED),
    dismiss: vi.fn().mockResolvedValue(CLOSED),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, alerts }, rateLimits: { alertActionsPerOfficer } });
  const tokenFor = async (role, userId = role === 'officer' ? OFFICER_ID : OTHER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, alerts, tokenFor };
}

// Each route with input that passes validation, so a refusal can only come from the token or
// the role.
const ROUTES = [
  { name: 'list', method: 'get', path: '/alerts' },
  { name: 'get', method: 'get', path: `/alerts/${ALERT_ID}` },
  { name: 'review', method: 'post', path: `/alerts/${ALERT_ID}/review`, body: { notes: NOTES } },
  { name: 'dismiss', method: 'post', path: `/alerts/${ALERT_ID}/dismiss`, body: { notes: NOTES } },
];
const route = (name, overrides = {}) => ({ ...ROUTES.find((r) => r.name === name), ...overrides });

function send(app, { method, path, body }, token) {
  let req = request(app)[method](path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

const noServiceCalled = (alerts) => {
  for (const fn of Object.values(alerts)) expect(fn).not.toHaveBeenCalled();
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('alert routes: who may call them', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s refuses a request with no token (401)', async (_name, r) => {
    const { app, alerts } = setup();

    const res = await send(app, r);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    noServiceCalled(alerts);
  });

  // Administrators included: they run the system but never close alerts (Scope (5)).
  const nonOfficerCases = ROUTES.flatMap((r) => ['miner', 'transporter', 'buyer', 'admin'].map((role) => [r.name, role, r]));

  it.each(nonOfficerCases)('%s refuses a %s (403 FORBIDDEN)', async (_name, role, r) => {
    const { app, alerts, tokenFor } = setup();

    const res = await send(app, r, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    noServiceCalled(alerts);
  });

  it.each(['miner', 'transporter', 'buyer', 'admin'])('refuses a %s on a path that does not exist exactly as on one that does', async (role) => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/alerts/${ALERT_ID}/reopen` }, await tokenFor(role));

    // 403, not 404: nobody but an officer can find out which alert paths exist.
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('gives an officer the normal 404 for a path that does not exist, such as reopening an alert', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/alerts/${ALERT_ID}/reopen` }, await tokenFor('officer'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('alert routes: what reaches the service', () => {
  it('list: the defaults when the query is empty, the page sent as it is', async () => {
    const { app, alerts, tokenFor } = setup();

    const res = await send(app, route('list'), await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual(PAGE);
    expect(alerts.list).toHaveBeenCalledWith({ status: 'open', limit: 20, offset: 0 });
  });

  it('list: the parsed filters and paging', async () => {
    const { app, alerts, tokenFor } = setup();

    await send(app, route('list', { path: '/alerts?status=dismissed&type=gps_zone&limit=5&offset=10' }), await tokenFor('officer'));

    expect(alerts.list).toHaveBeenCalledWith({ status: 'dismissed', type: 'gps_zone', limit: 5, offset: 10 });
  });

  it('get: the id, the alert under "alert"', async () => {
    const { app, alerts, tokenFor } = setup();

    const res = await send(app, route('get'), await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ alert: ALERT });
    expect(alerts.get).toHaveBeenCalledWith(ALERT_ID);
  });

  it.each(['review', 'dismiss'])('%s: the id, the trimmed notes, the officer from the token and the client IP', async (name) => {
    const { app, alerts, tokenFor } = setup();

    const res = await send(app, route(name, { body: { notes: `  ${NOTES}  ` } }), await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual(CLOSED);
    expect(alerts[name]).toHaveBeenCalledWith({ alertId: ALERT_ID, notes: NOTES, officerId: OFFICER_ID, ipAddress: expect.any(String) });
  });
});

describe('alert routes: validation', () => {
  it.each([
    ['the list with an unknown status', route('list', { path: '/alerts?status=closed' }), ['status']],
    ['the list with an unknown parameter', route('list', { path: '/alerts?severity=high' }), ['severity']],
    ['the list with a limit in hex', route('list', { path: '/alerts?limit=0x10' }), ['limit']],
    ['get with a malformed id', route('get', { path: '/alerts/not-a-uuid' }), ['id']],
    ['review with no notes', route('review', { body: {} }), ['notes']],
    ['dismiss with blank notes', route('dismiss', { body: { notes: '   \n ' } }), ['notes']],
    ['dismiss with a stray field', route('dismiss', { body: { notes: NOTES, status: 'reviewed' } }), ['status']],
    // Both the id and the body are wrong: only the id is named, because params come first.
    ['review with a malformed id (before the body)', route('review', { path: '/alerts/not-a-uuid/review', body: {} }), ['id']],
    ['dismiss with a malformed id (before the body)', route('dismiss', { path: '/alerts/not-a-uuid/dismiss', body: {} }), ['id']],
  ])('refuses %s with 400, naming the fields', async (_label, r, fields) => {
    const { app, alerts, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('officer'));

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toEqual(fields);
    noServiceCalled(alerts);
  });
});

describe('alert routes: Cache-Control', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s sends no-store on success', async (_name, r) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['a 401', route('list'), undefined, 401],
    ['a 403', route('list'), 'admin', 403],
    ['a 400', route('review', { body: {} }), 'officer', 400],
  ])('sends no-store on %s too', async (_label, r, role, status) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, role && (await tokenFor(role)));

    expect(res.status).toBe(status);
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('alert routes: service errors pass through', () => {
  it.each([
    ['get', 404, 'ALERT_NOT_FOUND', 'No alert has this id.'],
    ['review', 404, 'ALERT_NOT_FOUND', 'No alert has this id.'],
    ['dismiss', 404, 'ALERT_NOT_FOUND', 'No alert has this id.'],
    ['review', 403, 'FORBIDDEN', 'You do not have permission to do this.'],
    ['review', 409, 'INVALID_STATUS_TRANSITION', 'Only an open alert can be reviewed. This alert is dismissed.'],
    ['dismiss', 409, 'INVALID_STATUS_TRANSITION', 'Only an open alert can be dismissed. This alert is reviewed.'],
    [
      'dismiss',
      409,
      'STEP_CANNOT_BE_CLEARED',
      'This step cannot be cleared: the consignment already has an accepted registration. Confirm the problem instead.',
    ],
  ])('%s passes a %i %s through as JSON, with no-store', async (name, status, code, message) => {
    const { app, alerts, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service.
    alerts[name].mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, route(name), await tokenFor('officer'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('alert routes: the per-officer decision limit', () => {
  it('counts review and dismiss together, then answers 429 with Retry-After and no-store', async () => {
    const { app, alerts, tokenFor } = setup({ alertActionsPerOfficer: 2 });
    const token = await tokenFor('officer');
    expect((await send(app, route('review'), token)).status).toBe(200);
    expect((await send(app, route('dismiss'), token)).status).toBe(200);

    const res = await send(app, route('review'), token);

    expect(res.status).toBe(429);
    expect(res.body.error).toEqual({ code: 'TOO_MANY_REQUESTS', message: 'Too many alert decisions. Please wait a few minutes and try again.' });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(alerts.review).toHaveBeenCalledTimes(1);
  });

  it('counts malformed requests too', async () => {
    const { app, tokenFor } = setup({ alertActionsPerOfficer: 1 });
    const token = await tokenFor('officer');
    expect((await send(app, route('dismiss', { body: {} }), token)).status).toBe(400);

    expect((await send(app, route('dismiss'), token)).status).toBe(429);
  });

  it('never counts or limits the two lists, and gives each officer their own count', async () => {
    const { app, tokenFor } = setup({ alertActionsPerOfficer: 1 });
    const token = await tokenFor('officer');
    for (let i = 0; i < 3; i += 1) {
      expect((await send(app, route('list'), token)).status).toBe(200);
      expect((await send(app, route('get'), token)).status).toBe(200);
    }
    // The lists used none of the count: the one decision allowed still goes through.
    expect((await send(app, route('review'), token)).status).toBe(200);
    expect((await send(app, route('list'), token)).status).toBe(200);

    expect((await send(app, route('review'), await tokenFor('officer', OTHER_OFFICER_ID))).status).toBe(200);
  });

  it('does not count a non-officer, who is refused before the limiter', async () => {
    const { app, tokenFor } = setup({ alertActionsPerOfficer: 1 });
    // The same user id, but as an admin: refused by the role check, so nothing is counted.
    await send(app, route('review'), await tokenFor('admin', OFFICER_ID));

    expect((await send(app, route('review'), await tokenFor('officer'))).status).toBe(200);
  });
});

describe('createAlertActionLimiter', () => {
  it('defaults to 60 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: OFFICER_ID };
      next();
    });
    app.post('/r', createAlertActionLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).post('/r');

    expect(res.headers['ratelimit-policy']).toMatch(/q=60; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.post('/r', createAlertActionLimiter(), (req, res) => res.json({ ok: true }));
    app.use(errorHandler);

    const res = await request(app).post('/r');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createAlertActionLimiter ran without requireAuth before it on this route' }),
    );
  });
});
