import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createAnchoringActionLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { AppError } from '../src/errors.js';

// The anchoring admin routes with the real app and token checks, and a fake service behind
// them. The service's own rules are tested in tests/db/anchorAdminActions.test.js.

// Fake secret, long enough for the 43-character rule.
const SECRET = 'admin-anchoring-routes-test-secret-aaaaaaaaaaaaaaaaaaaa';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const ADMIN_ID = '3f2b6c1e-0000-4000-8000-0000000000ad';
const OTHER_ADMIN_ID = '3f2b6c1e-0000-4000-8000-0000000000ae';
const OTHER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const STEP_ID = '9d4e5f60-0000-4000-8000-000000000001';

const STATUS = Object.freeze({ worker: { state: 'disabled' }, counts: { pending: 0, submitted: 0, confirmed: 0, failed: 0 }, problems: [] });
const SUMMARY = Object.freeze({ outcome: 'sent', reconciled: { confirmed: 0, waiting: 0, resent: 0, returnedToPending: 0, failed: 0 }, stepId: STEP_ID, code: null });
const STEP = Object.freeze({ stepId: STEP_ID, anchorStatus: 'pending', code: 'RETRY_REQUESTED' });
const REASON = 'RPC provider was down during the first try';

function setup({ anchoringActionsPerAdmin } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const anchoring = {
    status: vi.fn().mockResolvedValue(STATUS),
    run: vi.fn().mockResolvedValue(SUMMARY),
    retry: vi.fn().mockResolvedValue(STEP),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, anchoring }, rateLimits: { anchoringActionsPerAdmin } });
  const tokenFor = async (role, userId = role === 'admin' ? ADMIN_ID : OTHER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, anchoring, tokenFor };
}

// Each route with input that passes validation, so a refusal can only come from the token
// or the role.
const ROUTES = [
  { name: 'status', method: 'get', path: '/admin/anchoring' },
  { name: 'run', method: 'post', path: '/admin/anchoring/run' },
  { name: 'retry', method: 'post', path: `/admin/anchoring/steps/${STEP_ID}/retry`, body: { reason: REASON } },
];
const route = (name, overrides = {}) => ({ ...ROUTES.find((r) => r.name === name), ...overrides });

function send(app, { method, path, body }, token) {
  let req = request(app)[method](path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

const noServiceCalled = (anchoring) => {
  for (const fn of Object.values(anchoring)) expect(fn).not.toHaveBeenCalled();
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('admin anchoring routes: who may call them', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s refuses a request with no token (401)', async (_name, r) => {
    const { app, anchoring } = setup();

    const res = await send(app, r);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    noServiceCalled(anchoring);
  });

  const nonAdminCases = ROUTES.flatMap((r) => ['miner', 'transporter', 'buyer', 'officer'].map((role) => [r.name, role, r]));

  it.each(nonAdminCases)('%s refuses a %s (403 FORBIDDEN)', async (_name, role, r) => {
    const { app, anchoring, tokenFor } = setup();

    const res = await send(app, r, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    noServiceCalled(anchoring);
  });

  it('refuses a non-admin on a path that does not exist exactly as on one that does', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/admin/anchoring/steps/${STEP_ID}/release` }, await tokenFor('officer'));

    // 403, not 404: a non-admin cannot find out which admin paths exist.
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('gives an admin the normal 404 for a path that does not exist, such as a release of a submitted step', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/admin/anchoring/steps/${STEP_ID}/release` }, await tokenFor('admin'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('admin anchoring routes: what reaches the service', () => {
  it('status: called with nothing, its answer sent as it is', async () => {
    const { app, anchoring, tokenFor } = setup();

    const res = await send(app, route('status'), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual(STATUS);
    expect(anchoring.status).toHaveBeenCalledWith();
  });

  it('run: the admin from the token and the client IP, the summary under "summary"', async () => {
    const { app, anchoring, tokenFor } = setup();

    const res = await send(app, route('run'), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ summary: SUMMARY });
    expect(anchoring.run).toHaveBeenCalledWith({ actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });

  it('retry: the step id, the trimmed reason, the admin and the IP, the step under "step"', async () => {
    const { app, anchoring, tokenFor } = setup();

    const res = await send(app, route('retry', { body: { reason: `  ${REASON}  ` } }), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ step: STEP });
    expect(anchoring.retry).toHaveBeenCalledWith({ stepId: STEP_ID, reason: REASON, actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });
});

describe('admin anchoring routes: validation', () => {
  it.each([
    ['the status with any query parameter', route('status', { path: '/admin/anchoring?limit=10' }), ['limit']],
    ['the status with an empty parameter', route('status', { path: '/admin/anchoring?state=' }), ['state']],
    ['run with a body field', route('run', { body: { untilIdle: true } }), ['untilIdle']],
    ['retry with no reason', route('retry', { body: {} }), ['reason']],
    ['retry with a reason too short once trimmed', route('retry', { body: { reason: '  ab  ' } }), ['reason']],
    ['retry with a stray field', route('retry', { body: { reason: REASON, force: true } }), ['force']],
    // Both the id and the body are wrong: only the id is named, because params come first.
    ['retry with a malformed id (before the body)', route('retry', { path: '/admin/anchoring/steps/not-a-uuid/retry', body: {} }), ['id']],
  ])('refuses %s with 400, naming the fields', async (_label, r, fields) => {
    const { app, anchoring, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toEqual(fields);
    noServiceCalled(anchoring);
  });
});

describe('admin anchoring routes: Cache-Control', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s sends no-store on success', async (_name, r) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['a 401', route('status'), undefined, 401],
    ['a 403', route('status'), 'officer', 403],
    ['a 400', route('retry', { body: {} }), 'admin', 400],
  ])('sends no-store on %s too', async (_label, r, role, status) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, role && (await tokenFor(role)));

    expect(res.status).toBe(status);
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('admin anchoring routes: service errors pass through', () => {
  it.each([
    ['retry', 404, 'STEP_NOT_FOUND', 'No step has this id.'],
    ['retry', 409, 'INVALID_STATUS_TRANSITION', 'Only a failed step can be retried. This step is pending.'],
    ['retry', 409, 'ANCHOR_NOT_RETRYABLE', 'This step failed for a reason a retry cannot fix (RECEIPT_MISMATCH). It needs investigating.'],
    ['run', 409, 'ANCHORING_DISABLED', 'Anchoring is switched off.'],
    ['run', 409, 'ANCHORING_NOT_STARTED', 'The worker has not started.'],
    ['run', 409, 'ANCHORING_STOPPED', 'The worker has stopped.'],
    ['run', 409, 'ANCHORING_BUSY', 'Anchoring is already running a tick.'],
  ])('%s passes a %i %s through as JSON, with no-store', async (name, status, code, message) => {
    const { app, anchoring, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service.
    anchoring[name].mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, route(name), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('admin anchoring routes: the per-admin action limit', () => {
  it('counts run and retry together, then answers 429 with Retry-After and no-store', async () => {
    const { app, anchoring, tokenFor } = setup({ anchoringActionsPerAdmin: 2 });
    const token = await tokenFor('admin');
    expect((await send(app, route('run'), token)).status).toBe(200);
    expect((await send(app, route('retry'), token)).status).toBe(200);

    const res = await send(app, route('run'), token);

    expect(res.status).toBe(429);
    expect(res.body.error).toEqual({ code: 'TOO_MANY_REQUESTS', message: 'Too many anchoring actions. Please wait a few minutes and try again.' });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(anchoring.run).toHaveBeenCalledTimes(1);
  });

  it('counts malformed requests too', async () => {
    const { app, tokenFor } = setup({ anchoringActionsPerAdmin: 1 });
    const token = await tokenFor('admin');
    expect((await send(app, route('retry', { body: {} }), token)).status).toBe(400);

    expect((await send(app, route('retry'), token)).status).toBe(429);
  });

  it('never limits the status, and gives each admin their own count', async () => {
    const { app, tokenFor } = setup({ anchoringActionsPerAdmin: 1 });
    const token = await tokenFor('admin');
    expect((await send(app, route('run'), token)).status).toBe(200);
    for (let i = 0; i < 3; i += 1) expect((await send(app, route('status'), token)).status).toBe(200);

    expect((await send(app, route('run'), await tokenFor('admin', OTHER_ADMIN_ID))).status).toBe(200);
  });

  it('does not count a non-admin, who is refused before the limiter', async () => {
    const { app, tokenFor } = setup({ anchoringActionsPerAdmin: 1 });
    // The same user id, but as an officer: refused by the role check, so nothing is counted.
    await send(app, route('run'), await tokenFor('officer', ADMIN_ID));

    expect((await send(app, route('run'), await tokenFor('admin'))).status).toBe(200);
  });
});

describe('createAnchoringActionLimiter', () => {
  it('defaults to 20 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: ADMIN_ID };
      next();
    });
    app.post('/r', createAnchoringActionLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).post('/r');

    expect(res.headers['ratelimit-policy']).toMatch(/q=20; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.post('/r', createAnchoringActionLimiter(), (req, res) => res.json({ ok: true }));
    app.use(errorHandler);

    const res = await request(app).post('/r');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createAnchoringActionLimiter ran without requireAuth before it on this route' }),
    );
  });
});
