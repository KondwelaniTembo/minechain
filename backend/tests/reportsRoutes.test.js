import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createReportLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { AppError } from '../src/errors.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'reports-routes-test-secret-rrrrrrrrrrrrrrrrrrrrrrrrrrrrrr';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const OTHER_USER_ID = '3f2b6c1e-0000-4000-8000-000000000002';
const CONSIGNMENT_ID = '5c0d7e21-0000-4000-8000-000000000001';

const TRANSACTIONS_PATH = '/reports/transactions?from=2026-11-01&to=2026-11-30';
const AUDIT_TRAIL_PATH = `/reports/audit-trail?consignmentId=${CONSIGNMENT_ID}`;

// A small report in the shape the service returns: two columns, one row.
const REPORT = Object.freeze({
  columns: [
    { header: 'qr_code', kind: 'text', key: 'qr_code' },
    { header: 'weight_mg', kind: 'number', key: 'weight_mg' },
  ],
  rows: [{ qr_code: 'MC-2026-000001', weight_mg: '1500000' }],
  filename: 'minechain-transactions-2026-11-01-to-2026-11-30.csv',
});
const TRAIL = Object.freeze({ ...REPORT, filename: `minechain-audit-trail-consignment-${CONSIGNMENT_ID}.csv` });
const EXPECTED_BODY = '\uFEFF"qr_code","weight_mg"\r\n"MC-2026-000001","1500000"\r\n';

// The real app and real token checks, with fake services behind them. getAuthenticatedUser
// stands in for the database: every token belongs to an active user with the token's role.
function setup({ reportsPerUser } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const reports = {
    transactions: vi.fn().mockResolvedValue(REPORT),
    auditTrail: vi.fn().mockResolvedValue(TRAIL),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, reports }, rateLimits: { reportsPerUser } });
  const tokenFor = async (role, userId = USER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, reports, tokenFor };
}

// Reads the body as raw bytes, so the test sees exactly what was sent, BOM included.
const asBytes = (res, callback) => {
  const chunks = [];
  res.on('data', (chunk) => chunks.push(chunk));
  res.on('end', () => callback(null, Buffer.concat(chunks)));
};

function get(app, path, token, { raw = false } = {}) {
  let req = request(app).get(path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return raw ? req.buffer(true).parse(asBytes) : req;
}

const ROUTES = [
  ['transactions', TRANSACTIONS_PATH],
  ['audit-trail', AUDIT_TRAIL_PATH],
];

afterEach(() => {
  vi.restoreAllMocks();
});

describe('report routes: who may call them', () => {
  it.each(ROUTES)('%s refuses a request with no token (401)', async (_name, path) => {
    const { app, reports } = setup();

    const res = await get(app, path);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(reports.transactions).not.toHaveBeenCalled();
    expect(reports.auditTrail).not.toHaveBeenCalled();
  });

  const refused = [
    ['transactions', 'miner', TRANSACTIONS_PATH],
    ['transactions', 'transporter', TRANSACTIONS_PATH],
    ['audit-trail', 'miner', AUDIT_TRAIL_PATH],
    ['audit-trail', 'transporter', AUDIT_TRAIL_PATH],
    ['audit-trail', 'buyer', AUDIT_TRAIL_PATH],
    ['audit-trail', 'admin', AUDIT_TRAIL_PATH],
  ];

  it.each(refused)('%s refuses a %s (403 FORBIDDEN)', async (_name, role, path) => {
    const { app, reports, tokenFor } = setup();

    const res = await get(app, path, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    expect(reports.transactions).not.toHaveBeenCalled();
    expect(reports.auditTrail).not.toHaveBeenCalled();
  });

  it.each([
    ['transactions', 'officer', TRANSACTIONS_PATH],
    ['transactions', 'buyer', TRANSACTIONS_PATH],
    ['transactions', 'admin', TRANSACTIONS_PATH],
    ['audit-trail', 'officer', AUDIT_TRAIL_PATH],
  ])('%s lets a %s download (200)', async (_name, role, path) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, await tokenFor(role));

    expect(res.status).toBe(200);
  });

  it('refuses a miner on a path that does not exist exactly as on one that does', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/reports/everything', await tokenFor('miner'));

    // 403, not 404: a miner cannot find out which report paths exist.
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('gives an officer the normal 404 for a path that does not exist', async () => {
    const { app, tokenFor } = setup();

    const res = await get(app, '/reports/everything', await tokenFor('officer'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('report routes: what reaches the service', () => {
  it('transactions passes the parsed query, the user from the token and the client IP', async () => {
    const { app, reports, tokenFor } = setup();

    await get(app, `${TRANSACTIONS_PATH}&mineral=gold`, await tokenFor('buyer'));

    expect(reports.transactions).toHaveBeenCalledWith(
      { from: '2026-11-01', to: '2026-11-30', mineral: 'gold' },
      expect.objectContaining({ id: USER_ID, role: 'buyer' }),
      { ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/) },
    );
  });

  it('audit-trail passes the parsed query, the user from the token and the client IP', async () => {
    const { app, reports, tokenFor } = setup();

    await get(app, AUDIT_TRAIL_PATH, await tokenFor('officer'));

    expect(reports.auditTrail).toHaveBeenCalledWith(
      { consignmentId: CONSIGNMENT_ID },
      expect.objectContaining({ id: USER_ID, role: 'officer' }),
      { ipAddress: expect.any(String) },
    );
  });
});

describe('report routes: the CSV response', () => {
  it.each(ROUTES)('%s sends the file as bytes: the BOM, the header row, then the rows', async (_name, path) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'), { raw: true });

    expect(res.body.subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
    expect(res.body.toString('utf8')).toBe(EXPECTED_BODY);
  });

  it.each(ROUTES)('%s sends Content-Type text/csv in UTF-8', async (_name, path) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'), { raw: true });

    expect(res.headers['content-type']).toBe('text/csv; charset=utf-8');
  });

  it.each([
    ['transactions', TRANSACTIONS_PATH, REPORT.filename],
    ['audit-trail', AUDIT_TRAIL_PATH, TRAIL.filename],
  ])("%s sends it as an attachment with the service's filename", async (_name, path, filename) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'), { raw: true });

    expect(res.headers['content-disposition']).toBe(`attachment; filename="${filename}"`);
  });

  it.each([
    ['a quote that would end the header value', 'report".csv'],
    ['a line break that would start another header', 'report.csv\r\nSet-Cookie: x=1'],
    ['capital letters', 'Report.csv'],
    ['a path', '../report.csv'],
  ])('refuses a filename with %s, with a generic 500 that does not repeat it', async (_label, filename) => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, reports, tokenFor } = setup();
    reports.transactions.mockResolvedValue({ ...REPORT, filename });

    const res = await get(app, TRANSACTIONS_PATH, await tokenFor('officer'));

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(res.headers['content-disposition']).toBeUndefined();
    expect(consoleError).toHaveBeenCalledWith('Unhandled error:', expect.objectContaining({ message: 'Report filename is not in the safe form' }));
  });

  it('answers a cell toCsv refuses with a generic 500, and neither the response nor the log holds the value', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, reports, tokenFor } = setup();
    // A formula in a number column: toCsv refuses it rather than write it out.
    reports.transactions.mockResolvedValue({ ...REPORT, rows: [{ qr_code: 'MC-1', weight_mg: '=SECRET-CELL-VALUE' }] });

    const res = await get(app, TRANSACTIONS_PATH, await tokenFor('officer'));

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(res.headers['content-type']).toMatch(/^application\/json/);
    expect(res.text).not.toContain('SECRET-CELL-VALUE');
    const logged = consoleError.mock.calls.flat().map((part) => (part instanceof Error ? part.message : String(part))).join(' ');
    expect(logged).toContain('CSV column "weight_mg" (number), row 1');
    expect(logged).not.toContain('SECRET-CELL-VALUE');
  });
});

describe('report routes: Cache-Control', () => {
  it.each(ROUTES)('%s sends no-store on success', async (_name, path) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'), { raw: true });

    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['a 401', TRANSACTIONS_PATH, undefined, 401],
    ['a 403', TRANSACTIONS_PATH, 'miner', 403],
    ['a 400', '/reports/transactions', 'officer', 400],
  ])('sends no-store on %s too', async (_label, path, role, status) => {
    const { app, tokenFor } = setup();

    const res = await get(app, path, role && (await tokenFor(role)));

    expect(res.status).toBe(status);
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('report routes: validation', () => {
  it.each([
    ['transactions with no dates', '/reports/transactions', ['from', 'to']],
    ['transactions with an unknown mineral', `${TRANSACTIONS_PATH}&mineral=silver`, ['mineral']],
    ['transactions with to before from', '/reports/transactions?from=2026-11-30&to=2026-11-01', ['to']],
    ['transactions with an unknown parameter', `${TRANSACTIONS_PATH}&fullName=x`, ['fullName']],
    ['audit-trail with neither id', '/reports/audit-trail', ['query']],
    ['audit-trail with dates for a consignment', `${AUDIT_TRAIL_PATH}&from=2026-11-01`, ['from']],
    ['audit-trail for an actor with no dates', `/reports/audit-trail?actorId=${OTHER_USER_ID}`, ['from', 'to']],
  ])('refuses %s with 400, naming the fields', async (_label, path, fields) => {
    const { app, reports, tokenFor } = setup();

    const res = await get(app, path, await tokenFor('officer'));

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details.map((d) => d.field)).toEqual(fields);
    expect(reports.transactions).not.toHaveBeenCalled();
    expect(reports.auditTrail).not.toHaveBeenCalled();
  });
});

describe('report routes: service refusals', () => {
  it.each([
    ['transactions', TRANSACTIONS_PATH, 422, 'REPORT_TOO_LARGE', 'This report has more than 10,000 rows. Choose a shorter date range or add a filter.'],
    ['audit-trail', AUDIT_TRAIL_PATH, 404, 'CONSIGNMENT_NOT_FOUND', 'No consignment has this id.'],
  ])('%s passes a %i %s through as JSON, with no-store', async (name, path, status, code, message) => {
    const { app, reports, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service,
    // so it never sits unhandled.
    reports[name === 'transactions' ? 'transactions' : 'auditTrail'].mockRejectedValue(new AppError(status, code, message));

    const res = await get(app, path, await tokenFor('officer'));

    expect(res.status).toBe(status);
    expect(res.headers['content-type']).toMatch(/^application\/json/);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.headers['content-disposition']).toBeUndefined();
  });
});

describe('report routes: the per-user limit', () => {
  it('answers 429 TOO_MANY_REQUESTS with Retry-After and no-store once the limit is reached', async () => {
    const { app, reports, tokenFor } = setup({ reportsPerUser: 2 });
    const token = await tokenFor('officer');
    await get(app, TRANSACTIONS_PATH, token);
    await get(app, TRANSACTIONS_PATH, token);

    const res = await get(app, TRANSACTIONS_PATH, token);

    expect(res.status).toBe(429);
    expect(res.body.error).toEqual({ code: 'TOO_MANY_REQUESTS', message: 'Too many report downloads. Please wait a few minutes and try again.' });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(reports.transactions).toHaveBeenCalledTimes(2);
  });

  it('counts both reports and malformed requests against one limit per user', async () => {
    const { app, tokenFor } = setup({ reportsPerUser: 2 });
    const token = await tokenFor('officer');
    expect((await get(app, '/reports/transactions', token)).status).toBe(400);
    expect((await get(app, AUDIT_TRAIL_PATH, token)).status).toBe(200);

    expect((await get(app, TRANSACTIONS_PATH, token)).status).toBe(429);
  });

  it('gives each user their own count', async () => {
    const { app, tokenFor } = setup({ reportsPerUser: 1 });
    await get(app, TRANSACTIONS_PATH, await tokenFor('officer', USER_ID));

    expect((await get(app, TRANSACTIONS_PATH, await tokenFor('officer', OTHER_USER_ID))).status).toBe(200);
  });

  it('does not count a miner, who is refused before the limiter', async () => {
    const { app, tokenFor } = setup({ reportsPerUser: 1 });
    // Same user id, but as a miner: refused by the role check, so nothing is counted.
    await get(app, TRANSACTIONS_PATH, await tokenFor('miner'));

    expect((await get(app, TRANSACTIONS_PATH, await tokenFor('officer'))).status).toBe(200);
  });
});

describe('createReportLimiter', () => {
  it('defaults to 20 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: USER_ID };
      next();
    });
    app.get('/r', createReportLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).get('/r');

    expect(res.headers['ratelimit-policy']).toMatch(/q=20; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.get('/r', createReportLimiter(), (req, res) => res.json({ ok: true }));
    app.use(errorHandler);

    const res = await request(app).get('/r');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createReportLimiter ran without requireAuth before it on this route' }),
    );
  });
});
