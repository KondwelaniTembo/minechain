import { describe, it, expect, vi, afterEach } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createTokenService } from '../src/services/tokenService.js';
import { AppError } from '../src/errors.js';

// Fake secret, long enough for the 43-character rule.
const SECRET = 'auth-public-key-test-secret-ffffffffffffffffffffffffffff';
const tokens = createTokenService({ secret: SECRET, expiresInSeconds: 3600 });

const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
// Shaped like a base64 P-256 SPKI (124 characters). Not a real key: the fake service never
// decodes it.
const KEY_TEXT = `MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE${'A'.repeat(86)}==`;
const FINGERPRINT = 'ab'.repeat(32);

const SAFE_USER = {
  id: USER_ID,
  username: 'mutale_banda',
  fullName: 'Mutale Banda',
  licenceNumber: null,
  role: 'miner',
  status: 'active',
  createdAt: '2026-11-05T09:00:00.000Z',
  publicKeyFingerprint: FINGERPRINT,
};

// The real app and real token checks, with a fake users service: getAuthenticatedUser
// stands in for the database and accepts every token as an active user with its own role.
function setup() {
  const users = {
    getAuthenticatedUser: vi.fn(async (userId, role) => ({ ...SAFE_USER, id: userId, role, publicKeyFingerprint: null })),
    registerPublicKey: vi.fn().mockResolvedValue(SAFE_USER),
  };
  const app = createApp({ db: { query: vi.fn() }, services: { users, tokens } });
  const tokenFor = async (role) => (await tokens.sign({ userId: USER_ID, role })).token;
  return { app, users, tokenFor };
}

function put(app, token, body) {
  let req = request(app).put('/auth/me/public-key');
  if (token) req = req.set('Authorization', `Bearer ${token}`);
  return body === undefined ? req : req.send(body);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('PUT /auth/me/public-key: who may call it', () => {
  it('refuses a request with no token (401), with no-store and the Bearer challenge', async () => {
    const { app, users } = setup();

    const res = await put(app, undefined, { publicKey: KEY_TEXT });

    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('TOKEN_MISSING');
    expect(res.headers['www-authenticate']).toBe('Bearer realm="minechain"');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(users.registerPublicKey).not.toHaveBeenCalled();
  });

  it.each(['officer', 'admin'])('refuses an active %s (403 FORBIDDEN), who never signs a step', async (role) => {
    const { app, users, tokenFor } = setup();

    const res = await put(app, await tokenFor(role), { publicKey: KEY_TEXT });

    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: { code: 'FORBIDDEN', message: 'You do not have permission to do this.' } });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(users.registerPublicKey).not.toHaveBeenCalled();
  });

  it.each(['miner', 'transporter', 'buyer'])('lets an active %s through', async (role) => {
    const { app, tokenFor } = setup();

    const res = await put(app, await tokenFor(role), { publicKey: KEY_TEXT });

    expect(res.status).toBe(200);
  });

  it('answers only PUT: POST to the same path is not a route', async () => {
    const { app, tokenFor } = setup();

    const res = await request(app)
      .post('/auth/me/public-key')
      .set('Authorization', `Bearer ${await tokenFor('miner')}`)
      .send({ publicKey: KEY_TEXT });

    expect(res.status).toBe(404);
  });
});

describe('PUT /auth/me/public-key: what reaches the service', () => {
  it('passes the user id from the token, the exact key text and the client IP', async () => {
    const { app, users, tokenFor } = setup();

    await put(app, await tokenFor('miner'), { publicKey: KEY_TEXT });

    expect(users.registerPublicKey).toHaveBeenCalledOnce();
    expect(users.registerPublicKey).toHaveBeenCalledWith(USER_ID, KEY_TEXT, {
      ipAddress: expect.stringMatching(/127\.0\.0\.1|::1/),
    });
  });

  it('answers 200 { user } with no-store', async () => {
    const { app, tokenFor } = setup();

    const res = await put(app, await tokenFor('miner'), { publicKey: KEY_TEXT });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ user: SAFE_USER });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('never echoes the key back', async () => {
    const { app, tokenFor } = setup();

    const res = await put(app, await tokenFor('miner'), { publicKey: KEY_TEXT });

    expect(res.text).not.toContain(KEY_TEXT);
  });
});

describe('PUT /auth/me/public-key: validation', () => {
  it.each([
    // A missing field gets Zod's own type message; "is required" is for an empty string.
    ['no publicKey', {}, 'publicKey', undefined],
    ['an empty publicKey', { publicKey: '' }, 'publicKey', 'is required'],
    ['a publicKey over 200 characters', { publicKey: 'A'.repeat(201) }, 'publicKey', 'must be at most 200 characters'],
    ['a publicKey that is not text', { publicKey: 12345 }, 'publicKey', undefined],
    ['an extra userId field', { publicKey: KEY_TEXT, userId: '3f2b6c1e-0000-4000-8000-000000000002' }, 'userId', 'is not allowed'],
  ])('refuses %s with 400', async (_label, body, field, message) => {
    const { app, users, tokenFor } = setup();

    const res = await put(app, await tokenFor('miner'), body);

    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(res.body.error.details).toEqual([{ field, message: message ?? expect.any(String) }]);
    expect(users.registerPublicKey).not.toHaveBeenCalled();
  });

  it('refuses a request with no body at all', async () => {
    const { app, users, tokenFor } = setup();

    const res = await put(app, await tokenFor('miner'));

    expect(res.status).toBe(400);
    expect(res.body.error.details[0].field).toBe('body');
    expect(users.registerPublicKey).not.toHaveBeenCalled();
  });

  it('checks the role before the body, so a non-signer learns nothing about the body rules', async () => {
    const { app, tokenFor } = setup();

    const res = await put(app, await tokenFor('officer'), {});

    expect(res.status).toBe(403);
  });
});

describe('PUT /auth/me/public-key: service refusals', () => {
  it.each([
    [400, 'INVALID_PUBLIC_KEY', 'The device key must be a P-256 public key in SPKI DER form, sent as standard base64.'],
    [409, 'PUBLIC_KEY_ALREADY_REGISTERED', 'This account already has a different device key. Ask an administrator to reset it.'],
    [409, 'PUBLIC_KEY_IN_USE', 'This device key is already registered to another account.'],
  ])('passes a %i %s through unchanged, with no-store', async (status, code, message) => {
    const { app, users, tokenFor } = setup();
    // mockRejectedValue makes the rejected promise only when the route calls the fake, so it
    // is never left unhandled.
    users.registerPublicKey.mockRejectedValue(new AppError(status, code, message));

    const res = await put(app, await tokenFor('miner'), { publicKey: KEY_TEXT });

    expect(res.status).toBe(status);
    expect(res.body).toEqual({ error: { code, message } });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('answers an unexpected fault with a generic 500', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    const { app, users, tokenFor } = setup();
    users.registerPublicKey.mockRejectedValue(new Error('connection lost'));

    const res = await put(app, await tokenFor('miner'), { publicKey: KEY_TEXT });

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    expect(consoleError).toHaveBeenCalled();
  });
});
