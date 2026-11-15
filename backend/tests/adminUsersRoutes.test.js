import { describe, it, expect, vi, afterEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { createAccountEditLimiter } from '../src/middleware/rateLimits.js';
import { errorHandler } from '../src/middleware/errorHandler.js';
import { AppError } from '../src/errors.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'admin-users-routes-test-secret-eeeeeeeeeeeeeeeeeeeeeeee';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

// Fake, well-formed ids (version 4, variant 8).
const ADMIN_ID = '3f2b6c1e-0000-4000-8000-0000000000ad';
const OTHER_ADMIN_ID = '3f2b6c1e-0000-4000-8000-0000000000ae';
const TARGET_ID = '3f2b6c1e-0000-4000-8000-000000000001';

const SAMPLE_USER = {
  id: TARGET_ID,
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  licenceNumber: null,
  role: 'miner',
  status: 'active',
  statusReason: null,
  approvedBy: ADMIN_ID,
  approvedAt: '2026-11-06T09:00:00.000Z',
  createdAt: '2026-11-05T09:00:00.000Z',
  updatedAt: '2026-11-06T09:00:00.000Z',
};

// What createAccount and reissueActivation return. The code is fake, in display form.
const INVITED_USER = {
  ...SAMPLE_USER,
  username: 'chanda_mwale',
  fullName: 'Chanda Mwale',
  role: 'officer',
  status: 'invited',
  approvedBy: null,
  approvedAt: null,
  activationExpiresAt: '2026-11-14T09:00:00.000Z',
};
const ACTIVATION = { code: '7KQ4-M2XD-9TNE', expiresAt: '2026-11-14T09:00:00.000Z' };
const CREATE_BODY = { username: 'chanda_mwale', fullName: 'Chanda Mwale', role: 'officer' };

// The real app and real token checks, with fake services behind them. getAuthenticatedUser
// stands in for the database: every token belongs to an active user with the token's role.
function setup({ accountEditsPerAdmin } = {}) {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ id: userId, username: `${role}_user`, role, status: 'active' })),
  };
  const accounts = {
    list: vi.fn().mockResolvedValue({ users: [SAMPLE_USER], total: 1, limit: 20, offset: 0 }),
    approve: vi.fn().mockResolvedValue(SAMPLE_USER),
    reject: vi.fn().mockResolvedValue({ ...SAMPLE_USER, status: 'rejected', statusReason: 'Duplicate request' }),
    suspend: vi.fn().mockResolvedValue({ ...SAMPLE_USER, status: 'suspended', statusReason: 'Lost device reported' }),
    reactivate: vi.fn().mockResolvedValue(SAMPLE_USER),
    resetKey: vi.fn().mockResolvedValue({ ...SAMPLE_USER, status: 'suspended', statusReason: 'Lost device reported' }),
    createAccount: vi.fn().mockResolvedValue({ user: INVITED_USER, activation: ACTIVATION }),
    reissueActivation: vi.fn().mockResolvedValue({ user: INVITED_USER, activation: ACTIVATION }),
    rename: vi.fn().mockResolvedValue({ ...SAMPLE_USER, fullName: 'Chanda Mwila' }),
    deleteAccount: vi.fn().mockResolvedValue({ ...SAMPLE_USER, status: 'deleted', statusReason: 'Left the cooperative' }),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens, accounts }, rateLimits: { accountEditsPerAdmin } });
  const tokenFor = async (role, userId = role === 'admin' ? ADMIN_ID : TARGET_ID) =>
    (await tokens.sign({ userId, role })).token;
  return { app, accounts, tokenFor };
}

// Each route with a body that would pass validation, so a refusal can only come from the
// token or the role.
const ROUTES = [
  { name: 'list', method: 'get', path: '/admin/users' },
  { name: 'approve', method: 'post', path: `/admin/users/${TARGET_ID}/approve` },
  { name: 'reject', method: 'post', path: `/admin/users/${TARGET_ID}/reject`, body: { reason: 'Duplicate request' } },
  { name: 'suspend', method: 'post', path: `/admin/users/${TARGET_ID}/suspend`, body: { reason: 'Lost device reported' } },
  { name: 'reactivate', method: 'post', path: `/admin/users/${TARGET_ID}/reactivate` },
  // In this table, so the 401, 4-role 403, no-store and malformed-id rows all cover it.
  { name: 'resetKey', method: 'post', path: `/admin/users/${TARGET_ID}/reset-key`, body: { reason: 'Lost device reported' } },
  // FR-10 creation answers 201 (ok), every other route 200.
  { name: 'create', method: 'post', path: '/admin/users', body: CREATE_BODY, ok: 201 },
  { name: 'reissueActivation', method: 'post', path: `/admin/users/${TARGET_ID}/activation-code` },
  // B3 edits, POST like the actions above (decision of 15 Nov 2026).
  { name: 'rename', method: 'post', path: `/admin/users/${TARGET_ID}/rename`, body: { fullName: 'Chanda Mwila' } },
  { name: 'deleteAccount', method: 'post', path: `/admin/users/${TARGET_ID}/delete`, body: { reason: 'Left the cooperative' } },
];
const route = (name, overrides = {}) => ({ ...ROUTES.find((r) => r.name === name), ...overrides });
// The routes that take a user id in the path.
const ID_ROUTES = ROUTES.filter((r) => r.method === 'post' && r.path.includes(TARGET_ID));

function send(app, { method, path, body }, token) {
  let req = request(app)[method](path);
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

const noServiceCalled = (accounts) => {
  for (const fn of Object.values(accounts)) expect(fn).not.toHaveBeenCalled();
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe('admin user routes: who may call them', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s refuses a request with no token (401)', async (_name, route) => {
    const { app, accounts } = setup();

    const res = await send(app, route);

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['www-authenticate']).toBe('Bearer realm="minechain"');
    noServiceCalled(accounts);
  });

  const nonAdminCases = ROUTES.flatMap((route) =>
    ['miner', 'transporter', 'buyer', 'officer'].map((role) => [route.name, role, route]),
  );

  it.each(nonAdminCases)('%s refuses a %s (403 FORBIDDEN)', async (_name, role, route) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, route, await tokenFor(role));

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    noServiceCalled(accounts);
  });

  it('refuses a non-admin on a path that does not exist exactly as on one that does', async () => {
    const { app, tokenFor } = setup();

    // Not /delete, which became a real route in B3.3.
    const res = await send(app, { method: 'post', path: `/admin/users/${TARGET_ID}/restore` }, await tokenFor('officer'));

    // 403, not 404: a non-admin cannot find out which admin paths exist.
    expect(res.status).toBe(403);
  });

  it('gives an admin the normal 404 for a path that does not exist', async () => {
    const { app, tokenFor } = setup();

    // Not /delete, which became a real route in B3.3.
    const res = await send(app, { method: 'post', path: `/admin/users/${TARGET_ID}/restore` }, await tokenFor('admin'));

    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('admin user routes: Cache-Control', () => {
  it.each(ROUTES.map((r) => [r.name, r]))('%s sends no-store on success', async (_name, route) => {
    const { app, tokenFor } = setup();

    const res = await send(app, route, await tokenFor('admin'));

    expect(res.status).toBe(route.ok ?? 200);
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

describe('admin user routes: what reaches the service', () => {
  it('list passes the parsed query, with defaults applied', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { method: 'get', path: '/admin/users?status=suspended&limit=50' }, await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(accounts.list).toHaveBeenCalledWith({ status: 'suspended', limit: 50, offset: 0 });
    expect(res.body).toEqual({ users: [SAMPLE_USER], total: 1, limit: 20, offset: 0 });
  });

  it.each(['approve', 'reactivate'])('%s passes the target, the acting admin from the token and the client IP', async (name) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, ROUTES.find((r) => r.name === name), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ user: expect.objectContaining({ id: TARGET_ID }) });
    expect(accounts[name]).toHaveBeenCalledWith({
      targetId: TARGET_ID,
      actorId: ADMIN_ID,
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it.each(['reject', 'suspend', 'resetKey'])('%s also passes the trimmed reason', async (name) => {
    const { app, accounts, tokenFor } = setup();
    const route = { ...ROUTES.find((r) => r.name === name), body: { reason: '  Under investigation  ' } };

    await send(app, route, await tokenFor('admin'));

    expect(accounts[name]).toHaveBeenCalledWith({
      targetId: TARGET_ID,
      actorId: ADMIN_ID,
      reason: 'Under investigation',
      ipAddress: expect.any(String),
    });
  });

  it('takes the acting admin from the token, never from the body', async () => {
    const { app, accounts, tokenFor } = setup();
    const route = { ...ROUTES.find((r) => r.name === 'suspend'), body: { reason: 'Testing', actorId: TARGET_ID } };

    const res = await send(app, route, await tokenFor('admin'));

    // The extra field is refused outright, so it never gets near the service.
    expect(res.status).toBe(400);
    expect(accounts.suspend).not.toHaveBeenCalled();
  });
});

describe('admin user routes: validation', () => {
  it.each(ID_ROUTES.map((r) => [r.name, r]))('%s refuses a malformed id with 400', async (_name, route) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...route, path: route.path.replace(TARGET_ID, 'not-a-uuid') }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({
      code: 'VALIDATION_FAILED',
      details: [{ field: 'id', message: 'must be a valid user id' }],
    });
    noServiceCalled(accounts);
  });

  it.each(['reject', 'suspend', 'resetKey'])('%s refuses a missing reason', async (name) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...ROUTES.find((r) => r.name === name), body: {} }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'reason', message: expect.any(String) }]);
    expect(accounts[name]).not.toHaveBeenCalled();
  });

  it.each(['reject', 'suspend', 'resetKey'])('%s refuses a request with no body at all', async (name) => {
    const { app, tokenFor } = setup();

    const res = await send(app, { ...ROUTES.find((r) => r.name === name), body: undefined }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details[0].field).toBe('body');
  });

  it.each(['approve', 'reactivate'])('%s refuses a body with a field in it', async (name) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...ROUTES.find((r) => r.name === name), body: { status: 'active' } }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'status', message: 'is not allowed' }]);
    expect(accounts[name]).not.toHaveBeenCalled();
  });

  it.each([
    // Not 'deleted': that became a real status in the users-deleted migration (B3).
    ['an unknown status', '?status=archived', 'status'],
    ['a limit over the cap', '?limit=101', 'limit'],
    ['an unknown parameter', '?sort=password_hash', 'sort'],
  ])('list refuses %s', async (_label, query, field) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { method: 'get', path: `/admin/users${query}` }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details.map((d) => d.field)).toEqual([field]);
    expect(accounts.list).not.toHaveBeenCalled();
  });
});

describe('admin user routes: service refusals', () => {
  it.each([
    [404, 'USER_NOT_FOUND', 'No user has this id.'],
    [409, 'INVALID_STATUS_TRANSITION', 'Only a pending account can be approved. This account is active.'],
    [409, 'ROLE_NOT_APPROVABLE', 'Officer and administrator accounts are created by an administrator, not approved or rejected.'],
  ])('passes a %i %s from the service through unchanged', async (status, code, message) => {
    const { app, accounts, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service,
    // so it never sits unhandled.
    accounts.approve.mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, ROUTES.find((r) => r.name === 'approve'), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    [409, 'NO_PUBLIC_KEY', 'This account has no device key to reset.'],
    [409, 'INVALID_STATUS_TRANSITION', 'Only a suspended account can have its device key reset. This account is active.'],
  ])('passes a reset-key %i %s through unchanged', async (status, code, message) => {
    const { app, accounts, tokenFor } = setup();
    accounts.resetKey.mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, ROUTES.find((r) => r.name === 'resetKey'), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each([
    ['create', 409, 'USERNAME_TAKEN', 'That username is already taken. Please choose another.'],
    ['create', 400, 'ROLE_NOT_CREATABLE', 'Only officer and administrator accounts are created by an administrator. Miners, transporters and buyers register themselves.'],
    ['reissueActivation', 404, 'USER_NOT_FOUND', 'No user has this id.'],
    ['reissueActivation', 409, 'INVALID_STATUS_TRANSITION', 'Only an invited account can get a new activation code. This account is active.'],
  ])('passes a %s %i %s through unchanged', async (name, status, code, message) => {
    const { app, accounts, tokenFor } = setup();
    accounts[name === 'create' ? 'createAccount' : name].mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, ROUTES.find((r) => r.name === name), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('answers an unexpected service fault with a generic 500', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, accounts, tokenFor } = setup();
    accounts.list.mockRejectedValue(new Error('connection lost'));

    const res = await send(app, ROUTES[0], await tokenFor('admin'));

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalled();
  });
});

describe('admin user routes: account creation and activation codes (FR-10)', () => {
  const route = (name) => ROUTES.find((r) => r.name === name);

  it('create passes the trimmed fields and the acting admin, and answers 201 with the user and the code', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(
      app,
      { ...route('create'), body: { username: ' chanda_mwale ', fullName: ' Chanda Mwale ', role: 'officer' } },
      await tokenFor('admin'),
    );

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ user: INVITED_USER, activation: ACTIVATION });
    expect(accounts.createAccount).toHaveBeenCalledWith({
      username: 'chanda_mwale',
      fullName: 'Chanda Mwale',
      role: 'officer',
      actorId: ADMIN_ID,
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it('reissue passes the target and the acting admin, and answers 200 with the user and the new code', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, route('reissueActivation'), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ user: INVITED_USER, activation: ACTIVATION });
    expect(accounts.reissueActivation).toHaveBeenCalledWith({ userId: TARGET_ID, actorId: ADMIN_ID, ipAddress: expect.any(String) });
  });

  it.each([
    ['a self-registered role', { ...CREATE_BODY, role: 'miner' }, [{ field: 'role', message: 'must be officer or admin' }]],
    ['a password chosen by the admin', { ...CREATE_BODY, password: 'gold river kasempa' }, [{ field: 'password', message: 'is not allowed' }]],
    ['a status', { ...CREATE_BODY, status: 'active' }, [{ field: 'status', message: 'is not allowed' }]],
    ['a missing full name', { username: 'chanda_mwale', role: 'officer' }, [{ field: 'fullName', message: expect.any(String) }]],
  ])('create refuses %s with 400, before the service', async (_label, body, details) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...route('create'), body }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({ code: 'VALIDATION_FAILED', details });
    expect(accounts.createAccount).not.toHaveBeenCalled();
  });

  it('create refuses a request with no body at all', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...route('create'), body: undefined }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details[0].field).toBe('body');
    expect(accounts.createAccount).not.toHaveBeenCalled();
  });

  it('reissue refuses a body with a field in it', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, { ...route('reissueActivation'), body: { code: 'AAAA-BBBB-CCCC' } }, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error.details).toEqual([{ field: 'code', message: 'is not allowed' }]);
    expect(accounts.reissueActivation).not.toHaveBeenCalled();
  });

  it('puts the code in the create and reissue bodies only, never in another route or a refusal', async () => {
    const { app, accounts, tokenFor } = setup();
    const token = await tokenFor('admin');
    const bodies = {};
    for (const r of ROUTES) bodies[r.name] = (await send(app, r, token)).text;
    accounts.createAccount.mockRejectedValue(new AppError(409, 'USERNAME_TAKEN', 'That username is already taken. Please choose another.'));
    const refused = (await send(app, route('create'), token)).text;

    const withCode = Object.keys(bodies).filter((name) => bodies[name].includes(ACTIVATION.code));
    expect(withCode.sort()).toEqual(['create', 'reissueActivation']);
    expect(refused).not.toContain(ACTIVATION.code);
  });
});

// B3: rename and soft delete. The 401, the 403 for every other role, no-store on success and
// the malformed id are covered by the ROUTES rows above.
describe('admin user routes: rename and delete (B3)', () => {
  it('rename passes the target, the trimmed name, the admin from the token and the client IP', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, route('rename', { body: { fullName: '  Chanda Mwila  ' } }), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ user: { ...SAMPLE_USER, fullName: 'Chanda Mwila' } });
    expect(accounts.rename).toHaveBeenCalledWith({
      userId: TARGET_ID,
      fullName: 'Chanda Mwila',
      adminId: ADMIN_ID,
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it('delete passes the target, the trimmed reason, the admin from the token and the client IP', async () => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, route('deleteAccount', { body: { reason: '  Left the cooperative  ' } }), await tokenFor('admin'));

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ user: expect.objectContaining({ id: TARGET_ID, status: 'deleted' }) });
    expect(accounts.deleteAccount).toHaveBeenCalledWith({
      userId: TARGET_ID,
      reason: 'Left the cooperative',
      adminId: ADMIN_ID,
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it.each([
    // Strict body: only the name can change through a rename.
    ['rename with a role', route('rename', { body: { fullName: 'Chanda Mwila', role: 'admin' } }), [{ field: 'role', message: 'is not allowed' }]],
    ['rename with a username', route('rename', { body: { fullName: 'Chanda Mwila', username: 'chanda' } }), [{ field: 'username', message: 'is not allowed' }]],
    ['rename with a licence number', route('rename', { body: { fullName: 'Chanda Mwila', licenceNumber: 'DEMO-ASM-0002' } }), [{ field: 'licenceNumber', message: 'is not allowed' }]],
    ['rename with a status', route('rename', { body: { fullName: 'Chanda Mwila', status: 'active' } }), [{ field: 'status', message: 'is not allowed' }]],
    ['rename with no name', route('rename', { body: {} }), [{ field: 'fullName', message: expect.any(String) }]],
    ['rename with a blank name', route('rename', { body: { fullName: '   ' } }), [{ field: 'fullName', message: 'is required' }]],
    ['rename with a 101-character name', route('rename', { body: { fullName: 'a'.repeat(101) } }), [{ field: 'fullName', message: 'must be at most 100 characters' }]],
    ['rename with no body at all', route('rename', { body: undefined }), [{ field: 'body', message: expect.any(String) }]],
    // The same reason rules as suspend.
    ['delete with no reason', route('deleteAccount', { body: {} }), [{ field: 'reason', message: expect.any(String) }]],
    ['delete with a 2-character reason', route('deleteAccount', { body: { reason: ' ab ' } }), [{ field: 'reason', message: 'must be at least 3 characters' }]],
    ['delete with a stray field', route('deleteAccount', { body: { reason: 'Left the cooperative', status: 'active' } }), [{ field: 'status', message: 'is not allowed' }]],
    ['delete with no body at all', route('deleteAccount', { body: undefined }), [{ field: 'body', message: expect.any(String) }]],
    // Both the id and the body are wrong: only the id is named, because params come first.
    ['rename with a malformed id (before the body)', route('rename', { path: '/admin/users/not-a-uuid/rename', body: {} }), [{ field: 'id', message: 'must be a valid user id' }]],
    ['delete with a malformed id (before the body)', route('deleteAccount', { path: '/admin/users/not-a-uuid/delete', body: {} }), [{ field: 'id', message: 'must be a valid user id' }]],
  ])('refuses %s with 400, before the service, with no-store', async (_label, r, details) => {
    const { app, accounts, tokenFor } = setup();

    const res = await send(app, r, await tokenFor('admin'));

    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({ code: 'VALIDATION_FAILED', details });
    expect(res.headers['cache-control']).toBe('no-store');
    noServiceCalled(accounts);
  });

  it.each([
    ['rename', 404, 'USER_NOT_FOUND', 'No user has this id.'],
    ['rename', 409, 'INVALID_STATUS_TRANSITION', 'A deleted account cannot be changed.'],
    ['deleteAccount', 403, 'CANNOT_DELETE_SELF', 'You cannot delete your own account.'],
    ['deleteAccount', 404, 'USER_NOT_FOUND', 'No user has this id.'],
    ['deleteAccount', 409, 'INVALID_STATUS_TRANSITION', 'This account has already been deleted.'],
    ['deleteAccount', 409, 'LAST_ACTIVE_ADMIN', 'At least one other active administrator must remain, so this account cannot be deleted.'],
  ])('%s passes a %i %s through unchanged, with no-store', async (name, status, code, message) => {
    const { app, accounts, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the service.
    accounts[name].mockRejectedValue(new AppError(status, code, message));

    const res = await send(app, route(name), await tokenFor('admin'));

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('admin user routes: the per-admin account edit limit', () => {
  it('counts rename and delete together, then answers 429 with Retry-After and no-store', async () => {
    const { app, accounts, tokenFor } = setup({ accountEditsPerAdmin: 2 });
    const token = await tokenFor('admin');
    expect((await send(app, route('rename'), token)).status).toBe(200);
    expect((await send(app, route('deleteAccount'), token)).status).toBe(200);

    const res = await send(app, route('rename'), token);

    expect(res.status).toBe(429);
    expect(res.body.error).toEqual({ code: 'TOO_MANY_REQUESTS', message: 'Too many account changes. Please wait a few minutes and try again.' });
    expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(accounts.rename).toHaveBeenCalledTimes(1);
  });

  it('counts malformed requests too, a bad id as much as a bad body', async () => {
    const { app, tokenFor } = setup({ accountEditsPerAdmin: 2 });
    const token = await tokenFor('admin');
    expect((await send(app, route('rename', { body: {} }), token)).status).toBe(400);
    expect((await send(app, route('deleteAccount', { path: '/admin/users/not-a-uuid/delete' }), token)).status).toBe(400);

    expect((await send(app, route('deleteAccount'), token)).status).toBe(429);
  });

  it('never counts or limits the other admin account routes, and gives each admin their own count', async () => {
    const { app, tokenFor } = setup({ accountEditsPerAdmin: 1 });
    const token = await tokenFor('admin');
    const others = ROUTES.filter((r) => r.name !== 'rename' && r.name !== 'deleteAccount');
    for (let i = 0; i < 2; i += 1) {
      for (const r of others) expect((await send(app, r, token)).status).toBe(r.ok ?? 200);
    }
    // The other routes used none of the count: the one edit allowed still goes through.
    expect((await send(app, route('rename'), token)).status).toBe(200);
    expect((await send(app, route('reject'), token)).status).toBe(200);
    expect((await send(app, route('deleteAccount'), token)).status).toBe(429);

    expect((await send(app, route('deleteAccount'), await tokenFor('admin', OTHER_ADMIN_ID))).status).toBe(200);
  });

  it('does not count a non-admin, who is refused before the limiter', async () => {
    const { app, tokenFor } = setup({ accountEditsPerAdmin: 1 });
    // The same user id, but as an officer: refused by the role check, so nothing is counted.
    expect((await send(app, route('deleteAccount'), await tokenFor('officer', ADMIN_ID))).status).toBe(403);

    expect((await send(app, route('deleteAccount'), await tokenFor('admin'))).status).toBe(200);
  });
});

describe('createAccountEditLimiter', () => {
  it('defaults to 20 per 15 minutes', async () => {
    const app = express();
    app.use((req, res, next) => {
      req.user = { id: ADMIN_ID };
      next();
    });
    app.post('/r', createAccountEditLimiter(), (req, res) => res.json({ ok: true }));

    const res = await request(app).post('/r');

    expect(res.headers['ratelimit-policy']).toMatch(/q=20; w=900/);
  });

  it('fails closed with a logged 500 when requireAuth is missing', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.post('/r', createAccountEditLimiter(), (req, res) => res.json({ ok: true }));
    app.use(errorHandler);

    const res = await request(app).post('/r');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalledWith(
      'Unhandled error:',
      expect.objectContaining({ message: 'createAccountEditLimiter ran without requireAuth before it on this route' }),
    );
  });
});
