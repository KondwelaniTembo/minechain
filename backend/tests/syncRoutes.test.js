import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { SYNC_MAX_STEPS } from '../src/schemas/sync.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'sync-routes-test-secret-gggggggggggggggggggggggggggggggggg';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';

// Shapes only: the fake service never parses them.
const STEP = Object.freeze({ payload: 'minechain-step/1/handoff\nstep_id=fake\n', signature: 'MEUCIQ-FAKE-SIGNATURE==' });
const steps = (n) => Array.from({ length: n }, () => ({ ...STEP }));

const RESULTS = [
  { index: 0, stepId: '6f1d2c3a-0000-4000-8000-000000000001', outcome: 'created', transactionId: 'tx-1', reviewStatus: 'passed' },
  { index: 1, stepId: null, outcome: 'rejected', code: 'PAYLOAD_MALFORMED', message: 'This record is not in the signed format the server expects.' },
];

// The real app and real token checks, with fake services. getAuthenticatedUser stands in
// for the database: every token belongs to an active user with the token's role.
function setup({ syncPerUser } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const sync = { syncSteps: vi.fn().mockResolvedValue(RESULTS) };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, sync }, rateLimits: { syncPerUser } });
  const tokenFor = async (role) => (await tokens.sign({ userId: USER_ID, role })).token;
  return { app, sync, tokenFor };
}

function post(app, token, body) {
  let req = request(app).post('/sync/steps');
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('POST /sync/steps: who may call it', () => {
  it('refuses a request with no token (401), with no-store', async () => {
    const { app, sync } = setup();

    const res = await post(app, undefined, { steps: [STEP] });

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(sync.syncSteps).not.toHaveBeenCalled();
  });

  it.each(['officer', 'admin'])('refuses an active %s (403 FORBIDDEN), who never signs a step', async (role) => {
    const { app, sync, tokenFor } = setup();

    const res = await post(app, await tokenFor(role), { steps: [STEP] });

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(sync.syncSteps).not.toHaveBeenCalled();
  });

  it.each(['miner', 'transporter', 'buyer'])('lets an active %s through', async (role) => {
    const { app, tokenFor } = setup();

    expect((await post(app, await tokenFor(role), { steps: [STEP] })).status).toBe(200);
  });
});

describe('POST /sync/steps: the envelope', () => {
  it.each([
    ['an empty batch', { steps: [] }, 'steps'],
    [`${SYNC_MAX_STEPS + 1} steps`, { steps: steps(SYNC_MAX_STEPS + 1) }, 'steps'],
    ['an extra top-level field', { steps: [STEP], deviceId: 'abc' }, 'deviceId'],
    ['an extra field on an item', { steps: [{ ...STEP, actorId: USER_ID }] }, 'actorId'],
  ])('refuses %s with 400 VALIDATION_FAILED', async (_label, body, field) => {
    const { app, sync, tokenFor } = setup();

    const res = await post(app, await tokenFor('miner'), body);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toContain(field);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(sync.syncSteps).not.toHaveBeenCalled();
  });

  it(`accepts ${SYNC_MAX_STEPS} steps, the most in one batch`, async () => {
    const { app, tokenFor } = setup();

    expect((await post(app, await tokenFor('miner'), { steps: steps(SYNC_MAX_STEPS) })).status).toBe(200);
  });

  it('refuses a request with no body at all', async () => {
    const { app, sync, tokenFor } = setup();

    const res = await post(app, await tokenFor('miner'));

    expect(res.status).toBe(400);
    expect(sync.syncSteps).not.toHaveBeenCalled();
  });
});

describe('POST /sync/steps: what reaches the service, and what comes back', () => {
  it('passes the logged-in user, the steps exactly as sent and the client IP', async () => {
    const { app, sync, tokenFor } = setup();
    const batch = [STEP, { payload: ' untrimmed ', signature: 'AAAA' }];

    await post(app, await tokenFor('transporter'), { steps: batch });

    expect(sync.syncSteps).toHaveBeenCalledOnce();
    const [user, items, options] = sync.syncSteps.mock.calls[0];
    expect(user).toMatchObject({ id: USER_ID, role: 'transporter', status: 'active' });
    expect(items).toEqual(batch);
    expect(options).toEqual({ ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/) });
  });

  it('answers 200 { results } with the service results unchanged, and no-store', async () => {
    const { app, tokenFor } = setup();

    const res = await post(app, await tokenFor('miner'), { steps: [STEP, STEP] });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ results: RESULTS });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('answers a service fault with a generic 500 that reveals nothing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, sync, tokenFor } = setup();
    // Created only when the route calls the fake, so it is never left unhandled.
    sync.syncSteps.mockRejectedValue(new Error('connection to PostgreSQL lost'));

    const res = await post(app, await tokenFor('miner'), { steps: [STEP] });

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(res.text).not.toContain('PostgreSQL');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(consoleError).toHaveBeenCalled();
  });

  it('answers only POST: GET on the same path is not a route', async () => {
    const { app, tokenFor } = setup();

    const res = await request(app).get('/sync/steps').set('Authorization', `Bearer ${await tokenFor('miner')}`);

    expect(res.status).toBe(404);
  });
});

describe('POST /sync/steps: the per-user limit', () => {
  it('answers 429 TOO_MANY_REQUESTS with Retry-After once the limit is reached', async () => {
    const { app, sync, tokenFor } = setup({ syncPerUser: 2 });
    const token = await tokenFor('miner');
    await post(app, token, { steps: [STEP] });
    await post(app, token, { steps: [STEP] });

    const res = await post(app, token, { steps: [STEP] });

    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe('TOO_MANY_REQUESTS');
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(sync.syncSteps).toHaveBeenCalledTimes(2);
  });

  it('counts malformed requests too, because the limiter runs before validation', async () => {
    const { app, tokenFor } = setup({ syncPerUser: 1 });
    const token = await tokenFor('miner');
    expect((await post(app, token, { steps: [] })).status).toBe(400);

    expect((await post(app, token, { steps: [STEP] })).status).toBe(429);
  });

  it('does not count refused roles, because the limiter runs after the role check', async () => {
    const { app, tokenFor } = setup({ syncPerUser: 1 });
    // Same user id, but as an officer: refused before the limiter, so nothing is counted.
    await post(app, await tokenFor('officer'), { steps: [STEP] });

    expect((await post(app, await tokenFor('miner'), { steps: [STEP] })).status).toBe(200);
  });
});
