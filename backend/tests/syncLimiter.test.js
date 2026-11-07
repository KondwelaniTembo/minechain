import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createSyncLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';

const USER_A = '3f2b6c1e-0000-4000-8000-000000000001';
const USER_B = '3f2b6c1e-0000-4000-8000-000000000002';

// A test-only app: a stand-in for requireAuth that takes the user id from a header, then the
// limiter, then a handler. The real requireAuth is tested on its own; here only the
// limiter's counting and its 429 matter.
function setup({ limit = 2, withAuth = true } = {}) {
  const app = express();
  if (withAuth) {
    app.use((req, res, next) => {
      req.user = { id: req.get('X-Test-User') };
      next();
    });
  }
  app.post('/sync/steps', createSyncLimiter({ limit }), (req, res) => res.json({ ok: true }));
  app.use(errorHandler);
  return app;
}

const sync = (app, userId) => request(app).post('/sync/steps').set('X-Test-User', userId);

afterEach(() => {
  vi.restoreAllMocks();
});

describe('createSyncLimiter', () => {
  it('lets requests through up to the limit', async () => {
    const app = setup({ limit: 2 });

    expect((await sync(app, USER_A)).status).toBe(200);
    expect((await sync(app, USER_A)).status).toBe(200);
  });

  it('answers 429 TOO_MANY_REQUESTS in the normal error format, with Retry-After', async () => {
    const app = setup({ limit: 2 });
    await sync(app, USER_A);
    await sync(app, USER_A);

    const res = await sync(app, USER_A);

    expect(res.status).toBe(429);
    expect(res.body).toEqual({
      error: { code: 'TOO_MANY_REQUESTS', message: 'Too many sync requests. Please wait a few minutes and try again.' },
    });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
  });

  it('sends the draft-8 RateLimit headers', async () => {
    const res = await sync(setup({ limit: 2 }), USER_A);

    expect(res.headers.ratelimit).toMatch(/r=1/);
    expect(res.headers['ratelimit-policy']).toMatch(/q=2/);
  });

  it('counts each user separately, so one phone cannot use up another', async () => {
    const app = setup({ limit: 1 });
    await sync(app, USER_A);

    expect((await sync(app, USER_A)).status).toBe(429);
    expect((await sync(app, USER_B)).status).toBe(200);
  });

  it('counts by user, not IP: two users behind the same address each get their own limit', async () => {
    // Supertest sends every request from the same loopback address, like phones behind
    // carrier-grade NAT.
    const app = setup({ limit: 1 });

    expect((await sync(app, USER_A)).status).toBe(200);
    expect((await sync(app, USER_B)).status).toBe(200);
  });

  it('uses the default of 60 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: USER_A };
      next();
    });
    app.post('/sync/steps', createSyncLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).post('/sync/steps');

    expect(res.headers['ratelimit-policy']).toMatch(/q=60; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = setup({ withAuth: false });

    const res = await request(app).post('/sync/steps');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createSyncLimiter ran without requireAuth before it on this route' }),
    );
  });

  it('gives each limiter its own counter', async () => {
    const first = setup({ limit: 1 });
    const second = setup({ limit: 1 });
    await sync(first, USER_A);

    expect((await sync(second, USER_A)).status).toBe(200);
  });
});
