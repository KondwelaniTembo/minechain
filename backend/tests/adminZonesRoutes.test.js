import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { AppError } from '../src/errors.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'admin-zones-routes-test-secret-zzzzzzzzzzzzzzzzzzzzzzzz';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const ADMIN_ID = '3f2b6c1e-0000-4000-8000-0000000000ad';
const OTHER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const ZONE_ID = '7a1c2d3e-0000-4000-8000-0000000000aa';

// A small triangle near Lusaka, as [lat, lng] corners. Fake, not a real licence boundary.
const TRIANGLE = [
  [-15.39, 28.32],
  [-15.4, 28.33],
  [-15.41, 28.31],
];

const SAMPLE_ZONE = {
  id: ZONE_ID,
  name: 'Kasempa North',
  licenceNumber: null,
  status: 'active',
  boundary: TRIANGLE,
  createdBy: ADMIN_ID,
  createdAt: '2026-11-10T09:00:00.000Z',
  updatedAt: '2026-11-10T09:00:00.000Z',
};
const INACTIVE_ZONE = { ...SAMPLE_ZONE, status: 'inactive' };
const WARNING = { code: 'NO_ACTIVE_ZONES', message: 'No GPS zone is active now.' };

// The real app and real token checks, with fake services behind them. getAuthenticatedUser
// stands in for the database: every token belongs to an active user with the token's role.
function setup() {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const zones = {
    list: vi.fn().mockResolvedValue({ zones: [SAMPLE_ZONE], total: 1, limit: 20, offset: 0 }),
    create: vi.fn().mockResolvedValue(SAMPLE_ZONE),
    rename: vi.fn().mockResolvedValue({ ...SAMPLE_ZONE, name: 'Kasempa North (old)' }),
    deactivate: vi.fn().mockResolvedValue({ zone: INACTIVE_ZONE, warning: null }),
    reactivate: vi.fn().mockResolvedValue(SAMPLE_ZONE),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, zones } });
  const tokenFor = async (role, userId = role === 'admin' ? ADMIN_ID : OTHER_ID) => (await tokens.sign({ userId, role })).token;
  return { app, zones, tokenFor };
}

// Each route with a body that would pass validation, so a refusal can only come from the
// token or the role. success: the status an admin gets.
const ROUTES = [
  { name: 'list', method: 'get', path: '/admin/zones', success: 200 },
  { name: 'create', method: 'post', path: '/admin/zones', body: { name: 'Kasempa North', boundary: TRIANGLE }, success: 201 },
  { name: 'rename', method: 'post', path: `/admin/zones/${ZONE_ID}/rename`, body: { name: 'Kasempa North (old)' }, success: 200 },
  { name: 'deactivate', method: 'post', path: `/admin/zones/${ZONE_ID}/deactivate`, body: { reason: 'Licence revoked' }, success: 200 },
  { name: 'reactivate', method: 'post', path: `/admin/zones/${ZONE_ID}/reactivate`, success: 200 },
];
const ID_ROUTES = ROUTES.filter((r) => r.path.includes(ZONE_ID));
const route = (name, overrides = {}) => ({ ...ROUTES.find((r) => r.name === name), ...overrides });

function send(app, { method, path, body }, token) {
  let req = request(app)[method](path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

const noServiceCalled = (zones) => {
  for (const fn of Object.values(zones)) expect(fn).not.toHaveBeenCalled();
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('admin zone routes: who may call them', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s refuses a request with no token (401)', async (_name, r) => {
    const { app, zones } = setup();

    const res = await send(app, r);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['www-authenticate']).toBe('Bearer realm="minechain"');
    noServiceCalled(zones);
  });

  const nonAdminCases = ROUTES.flatMap((r) => ['miner', 'transporter', 'buyer', 'officer'].map((role) => [r.name, role, r]));

  it.each(nonAdminCases)('%s refuses a %s (403 FORBIDDEN)', async (_name, role, r) => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, r, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    noServiceCalled(zones);
  });

  it('refuses a non-admin on a path that does not exist exactly as on one that does', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/admin/zones/${ZONE_ID}/delete` }, await tokenFor('officer'));

    // 403, not 404: a non-admin cannot find out which admin paths exist.
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('gives an admin the normal 404 for a path that does not exist, such as an edit of the boundary', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, { method: 'post', path: `/admin/zones/${ZONE_ID}/boundary`, body: { boundary: TRIANGLE } }, await tokenFor('admin'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('admin zone routes: Cache-Control', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s sends no-store on success', async (_name, r) => {
    const { app, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('admin'));

    expect(res.status).toBe(r.success);
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['a 401', undefined],
    ['a 403', 'miner'],
  ])('sends no-store on %s too', async (_label, role) => {
    const { app, tokenFor } = setup();

    const res = await send(app, ROUTES[0], role && (await tokenFor(role)));

    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('admin zone routes: what reaches the service, and what comes back', () => {
  it('list passes the parsed query, with defaults applied', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, { method: 'get', path: '/admin/zones?status=inactive&limit=50' }, await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(zones.list).toHaveBeenCalledWith({ status: 'inactive', limit: 50, offset: 0 });
    expect(res.body).toEqual({ zones: [SAMPLE_ZONE], total: 1, limit: 20, offset: 0 });
  });

  it('create passes the trimmed name, licence number and boundary, the admin and the client IP, and answers 201', async () => {
    const { app, zones, tokenFor } = setup();
    const body = { name: '  Kasempa North ', licenceNumber: ' DEMO-LML-0001 ', boundary: TRIANGLE };

    const res = await send(app, route('create', { body }), await tokenFor('admin'));

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ zone: SAMPLE_ZONE });
    expect(zones.create).toHaveBeenCalledWith({
      name: 'Kasempa North',
      licenceNumber: 'DEMO-LML-0001',
      boundary: TRIANGLE,
      actorId: ADMIN_ID,
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it('rename passes the zone, the trimmed name and the admin', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('rename', { body: { name: ' Kasempa North (old) ' } }), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ zone: expect.objectContaining({ id: ZONE_ID, name: 'Kasempa North (old)' }) });
    expect(zones.rename).toHaveBeenCalledWith({ zoneId: ZONE_ID, name: 'Kasempa North (old)', actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });

  it('deactivate passes the trimmed reason and answers with the zone and a null warning', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('deactivate', { body: { reason: '  Licence revoked  ' } }), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ zone: INACTIVE_ZONE, warning: null });
    expect(zones.deactivate).toHaveBeenCalledWith({ zoneId: ZONE_ID, reason: 'Licence revoked', actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });

  it('deactivate passes the NO_ACTIVE_ZONES warning through in a 200', async () => {
    const { app, zones, tokenFor } = setup();
    zones.deactivate.mockResolvedValue({ zone: INACTIVE_ZONE, warning: WARNING });

    const res = await send(app, route('deactivate'), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ zone: INACTIVE_ZONE, warning: WARNING });
  });

  it('reactivate passes the zone and the admin', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('reactivate'), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ zone: SAMPLE_ZONE });
    expect(zones.reactivate).toHaveBeenCalledWith({ zoneId: ZONE_ID, actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });

  it('takes the acting admin from the token, never from the body', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('create', { body: { name: 'Kasempa North', boundary: TRIANGLE, createdBy: OTHER_ID } }), await tokenFor('admin'));

    // The extra field is refused outright, so it never gets near the service.
    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'createdBy', message: 'is not allowed' }]);
    expect(zones.create).not.toHaveBeenCalled();
  });
});

describe('admin zone routes: validation', () => {
  it.each(ID_ROUTES.map((r) => [r.name, r]))('%s refuses a malformed id with 400, before the body', async (_name, r) => {
    const { app, zones, tokenFor } = setup();

    // The body is also wrong; only the id is reported, because params are checked first.
    const res = await send(app, { ...r, path: r.path.replace(ZONE_ID, 'not-a-uuid'), body: { unexpected: true } }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({ code: 'VALIDATION_FAILED', details: [{ field: 'id', message: 'must be a valid zone id' }] });
    noServiceCalled(zones);
  });

  it.each([
    [
      'a closed ring, naming the repeated corner',
      [...TRIANGLE, TRIANGLE[0]],
      'boundary.3',
      'repeats the first corner; list each corner once, without repeating the first corner at the end',
    ],
    ['corners in [lng, lat] order, naming the first corner', TRIANGLE.map(([lat, lng]) => [lng, lat]), 'boundary.0', expect.stringContaining('latitude first')],
    ['a corner with 7 decimal places, naming the latitude', [TRIANGLE[0], [-15.4000001, 28.33], TRIANGLE[2]], 'boundary.1.0', 'must have at most 6 decimal places'],
    ['corners on one line, naming the boundary as a whole', [[-15.4, 28.3], [-15.401, 28.301], [-15.402, 28.302]], 'boundary', expect.stringContaining('must enclose at least')],
  ])('create refuses %s', async (_label, boundary, field, message) => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('create', { body: { name: 'Kasempa North', boundary } }), await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field, message }]);
    expect(zones.create).not.toHaveBeenCalled();
  });

  it('create refuses a request with no body at all', async () => {
    const { app, tokenFor } = setup();

    const res = await send(app, route('create', { body: undefined }), await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details[0].field).toBe('body');
  });

  it('rename refuses a boundary sent with the name', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('rename', { body: { name: 'Kasempa North', boundary: TRIANGLE } }), await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'boundary', message: 'is not allowed' }]);
    expect(zones.rename).not.toHaveBeenCalled();
  });

  it('deactivate refuses a missing reason', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('deactivate', { body: {} }), await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'reason', message: expect.any(String) }]);
    expect(zones.deactivate).not.toHaveBeenCalled();
  });

  it('reactivate refuses a body with a field in it', async () => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, route('reactivate', { body: { status: 'active' } }), await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'status', message: 'is not allowed' }]);
    expect(zones.reactivate).not.toHaveBeenCalled();
  });

  it.each([
    ['an unknown status', '?status=deleted', 'status'],
    ['a limit over the cap', '?limit=101', 'limit'],
    ['an unknown parameter', '?sort=boundary', 'sort'],
  ])('list refuses %s', async (_label, query, field) => {
    const { app, zones, tokenFor } = setup();

    const res = await send(app, { method: 'get', path: `/admin/zones${query}` }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
    expect(zones.list).not.toHaveBeenCalled();
  });
});

describe('admin zone routes: service refusals', () => {
  it.each([
    ['rename', 404, 'ZONE_NOT_FOUND', 'No GPS zone has this id.'],
    ['create', 409, 'ZONE_NAME_TAKEN', 'A GPS zone with this name already exists.'],
    ['deactivate', 409, 'INVALID_STATUS_TRANSITION', 'Only an active zone can be deactivated. This zone is inactive.'],
  ])('passes a %s %i %s from the service through unchanged', async (name, status, code, message) => {
    const { app, zones, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service,
    // so it never sits unhandled.
    zones[name].mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, route(name), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('answers an unexpected service fault with a generic 500', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, zones, tokenFor } = setup();
    zones.list.mockRejectedValue(new Error('connection lost'));

    const res = await send(app, ROUTES[0], await tokenFor('admin'));

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalled();
  });
});
