import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createConsignmentViewLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { qrCodeParamsSchema } from '../src/schemas/consignments.js';
import { AppError } from '../src/errors.js';

// The consignment view route with the real app and token checks, and a fake service behind
// it. The service's own rules are tested in tests/consignmentService.test.js and
// tests/db/consignmentView.test.js.

// Fake secret, long enough for the 43-character rule.
const SECRET = 'consignments-routes-test-secret-aaaaaaaaaaaaaaaaaaaaaaaaa';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const USER_ID = '3f2b6c1e-0000-4000-8000-0000000000e0';
const OTHER_USER_ID = '3f2b6c1e-0000-4000-8000-0000000000e1';

const QR = 'MC-DEMO-000001';
const BODY = Object.freeze({ consignment: { qrCode: QR, stage: 'in_transit', held: false }, steps: [] });
const PATH = (code) => `/consignments/by-qr/${code}`;

function setup({ consignmentViewsPerUser } = {}) {
  const users = {
    // As requireAuth loads it: more than id and role, so the test can show only those two
    // reach the service.
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active', fullName: 'Not For The Service' })),
  };
  const consignments = { viewByQr: vi.fn().mockResolvedValue(BODY) };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, consignments }, rateLimits: { consignmentViewsPerUser } });
  const tokenFor = async (role, userId = USER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, consignments, tokenFor };
}

function get(app, path, token) {
  const req = request(app).get(path);
  return token ? req.set('Authorization', `Bearer ${token}`) : req;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('consignment view route: who may call it', () => {
  it('refuses a request with no token (401)', async () => {
    const { app, consignments } = setup();

    const res = await get(app, PATH(QR));

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(consignments.viewByQr).not.toHaveBeenCalled();
  });

  it.each(['miner', 'admin'])('refuses a %s (403 FORBIDDEN)', async (role) => {
    const { app, consignments, tokenFor } = setup();

    const res = await get(app, PATH(QR), await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    expect(consignments.viewByQr).not.toHaveBeenCalled();
  });

  it.each(['miner', 'admin'])('refuses a %s on a made-up path exactly as on the real one', async (role) => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/consignments/mine', await tokenFor(role));

    // 403, not 404: nobody but the three roles can find out which paths exist.
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it.each(['transporter', 'buyer', 'officer'])('lets a %s in, and gives a made-up path the normal 404', async (role) => {
    const { app, tokenFor } = setup();
    const token = await tokenFor(role);

    expect((await get(app, PATH(QR), token)).status).toBe(200);
    const missing = await get(app, '/consignments/mine', token);
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('NOT_FOUND');
  });
});

describe('consignment view route: what reaches the service', () => {
  it('the viewer from the token as { id, role } only, and the code; the body sent as it is', async () => {
    const { app, consignments, tokenFor } = setup();

    const res = await get(app, PATH(QR), await tokenFor('buyer'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual(BODY);
    expect(consignments.viewByQr).toHaveBeenCalledWith({ id: USER_ID, role: 'buyer' }, QR);
  });

  it('a viewer named in the query or headers changes nothing: the token decides', async () => {
    const { app, consignments, tokenFor } = setup();

    await get(app, `${PATH(QR)}`, await tokenFor('transporter')).set('X-User-Id', OTHER_USER_ID).set('X-Role', 'officer');

    expect(consignments.viewByQr).toHaveBeenCalledWith({ id: USER_ID, role: 'transporter' }, QR);
  });

  it('a percent-encoded "/" reaches the service decoded (Express 5 decodes route params)', async () => {
    const { app, consignments, tokenFor } = setup();

    const res = await get(app, PATH('MC%2F2026%2F001'), await tokenFor('officer'));

    expect(res.status).toBe(200);
    expect(consignments.viewByQr).toHaveBeenCalledWith({ id: USER_ID, role: 'officer' }, 'MC/2026/001');
  });

  it('a raw "/" makes another path, which is a 404 NOT_FOUND, not a lookup', async () => {
    const { app, consignments, tokenFor } = setup();

    const res = await get(app, PATH('MC/2026/001'), await tokenFor('officer'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
    expect(consignments.viewByQr).not.toHaveBeenCalled();
  });

  it('every allowed character arrives exactly', async () => {
    const { app, consignments, tokenFor } = setup();
    const code = 'Az09._:-%2Fz';

    await get(app, PATH(code), await tokenFor('officer'));

    expect(consignments.viewByQr).toHaveBeenCalledWith(expect.anything(), 'Az09._:-/z');
  });
});

describe('consignment view route: validation', () => {
  it.each([
    ['too short (3 characters)', 'MC1'],
    ['too long (129 characters)', 'M'.repeat(129)],
    ['a space (encoded)', 'MC%20DEMO'],
    ['an equals sign', 'MC=DEMO1'],
    ['a non-ASCII letter (encoded)', 'MC-%C3%A9-0001'],
    ['a percent sign itself (encoded)', 'MC%25DEMO'],
    ['a line feed (encoded)', 'MC-DEMO%0A1'],
  ])('refuses a code %s with 400, before the service', async (_label, code) => {
    const { app, consignments, tokenFor } = setup();

    const res = await get(app, PATH(code), await tokenFor('officer'));

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toEqual(['qrCode']);
    expect(consignments.viewByQr).not.toHaveBeenCalled();
  });

  it('accepts exactly 4 and exactly 128 characters', async () => {
    const { app, tokenFor } = setup();
    const token = await tokenFor('officer');

    expect((await get(app, PATH('MC01'), token)).status).toBe(200);
    expect((await get(app, PATH('M'.repeat(128)), token)).status).toBe(200);
  });

  it('the schema is strict: an extra param is refused', () => {
    expect(qrCodeParamsSchema.safeParse({ qrCode: QR, other: 'x' }).success).toBe(false);
    expect(qrCodeParamsSchema.safeParse({ qrCode: QR }).success).toBe(true);
  });
});

describe('consignment view route: Cache-Control', () => {
  it('sends no-store on success', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, PATH(QR), await tokenFor('buyer'));

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['a 401', PATH(QR), undefined, 401],
    ['a 403', PATH(QR), 'miner', 403],
    ['a 403 on a made-up path', '/consignments/mine', 'admin', 403],
    ['a 400', PATH('MC1'), 'officer', 400],
  ])('sends no-store on %s too', async (_label, path, role, status) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, role && (await tokenFor(role)));

    expect(res.status).toBe(status);
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('consignment view route: service errors pass through', () => {
  it('passes 404 CONSIGNMENT_NOT_FOUND through as JSON, with no-store', async () => {
    const { app, consignments, tokenFor } = setup();
    consignments.viewByQr.mockRejectedValue(new AppError(404, 'CONSIGNMENT_NOT_FOUND', 'No consignment has this QR code.'));

    const res = await get(app, PATH(QR), await tokenFor('buyer'));

    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: { code: 'CONSIGNMENT_NOT_FOUND', message: 'No consignment has this QR code.' } });
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('consignment view route: the per-user view limit', () => {
  it('answers 429 with Retry-After and no-store once the limit is reached', async () => {
    const { app, consignments, tokenFor } = setup({ consignmentViewsPerUser: 2 });
    const token = await tokenFor('transporter');
    expect((await get(app, PATH(QR), token)).status).toBe(200);
    expect((await get(app, PATH(QR), token)).status).toBe(200);

    const res = await get(app, PATH(QR), token);

    expect(res.status).toBe(429);
    expect(res.body.error).toEqual({ code: 'TOO_MANY_REQUESTS', message: 'Too many consignment scans. Please wait a few minutes and try again.' });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(consignments.viewByQr).toHaveBeenCalledTimes(2);
  });

  it('counts malformed codes too', async () => {
    const { app, tokenFor } = setup({ consignmentViewsPerUser: 1 });
    const token = await tokenFor('buyer');
    expect((await get(app, PATH('MC1'), token)).status).toBe(400);

    expect((await get(app, PATH(QR), token)).status).toBe(429);
  });

  it('gives each user their own count', async () => {
    const { app, tokenFor } = setup({ consignmentViewsPerUser: 1 });
    expect((await get(app, PATH(QR), await tokenFor('buyer'))).status).toBe(200);
    expect((await get(app, PATH(QR), await tokenFor('buyer'))).status).toBe(429);

    expect((await get(app, PATH(QR), await tokenFor('buyer', OTHER_USER_ID))).status).toBe(200);
  });

  it('does not count a refused role, which is stopped before the limiter', async () => {
    const { app, tokenFor } = setup({ consignmentViewsPerUser: 1 });
    // The same user id, but as a miner: refused by the role check, so nothing is counted.
    await get(app, PATH(QR), await tokenFor('miner'));

    expect((await get(app, PATH(QR), await tokenFor('buyer'))).status).toBe(200);
  });
});

describe('createConsignmentViewLimiter', () => {
  it('defaults to 60 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: USER_ID };
      next();
    });
    app.get('/r', createConsignmentViewLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).get('/r');

    expect(res.headers['ratelimit-policy']).toMatch(/q=60; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.get('/r', createConsignmentViewLimiter(), (req, res) => res.json({ ok: true }));
    app.use(errorHandler);

    const res = await request(app).get('/r');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createConsignmentViewLimiter ran without requireAuth before it on this route' }),
    );
  });
});
