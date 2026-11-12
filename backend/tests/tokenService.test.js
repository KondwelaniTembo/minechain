import { createHmac } from 'node:crypto';
import { describe, it, expect, afterEach } from 'vitest';
import { decodeJwt, decodeProtectedHeader } from 'jose';
import { createTokenService, TOKEN_ISSUER, TOKEN_AUDIENCE } from '../src/services/tokenService.js';
import { AppError } from '../src/errors.js';

// Fake secrets, long enough for the 43-character rule.
const SECRET = 'unit-test-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const OTHER_SECRET = 'another-unit-test-secret-bbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';

const service = (overrides = {}) => createTokenService({ secret: SECRET, expiresInSeconds: 3600, ...overrides });
const nowSeconds = () => Math.floor(Date.now() / 1000);

// Builds a token by hand, the way an attacker would: base64url header and payload, then an
// HMAC made with node:crypto. hmac: null leaves the signature empty.
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
function forge(header, payload, { secret = SECRET, hmac = 'sha256' } = {}) {
  const signingInput = `${b64(header)}.${b64(payload)}`;
  const signature = hmac ? createHmac(hmac, secret).update(signingInput).digest('base64url') : '';
  return `${signingInput}.${signature}`;
}
const validClaims = (overrides = {}) => ({
  sub: USER_ID,
  role: 'miner',
  iss: TOKEN_ISSUER,
  aud: TOKEN_AUDIENCE,
  iat: nowSeconds(),
  exp: nowSeconds() + 3600,
  ...overrides,
});
const HS256 = { alg: 'HS256', typ: 'JWT' };

async function expectRefused(token, code = 'TOKEN_INVALID') {
  const err = await service().verify(token).catch((e) => e);
  expect(err).toBeInstanceOf(AppError);
  expect(err).toMatchObject({ status: 401, code });
  return err;
}

describe('tokenService', () => {
  describe('sign and verify', () => {
    it('gives back the user id, role and issue time from a token it signed', async () => {
      const tokens = service();
      const { token } = await tokens.sign({ userId: USER_ID, role: 'miner' });

      expect(await tokens.verify(token)).toEqual({ userId: USER_ID, role: 'miner', iat: decodeJwt(token).iat });
    });

    it('takes iat from its own clock, in whole seconds, and reports it from sign', async () => {
      // A fixed clock half a second into a second: iat is rounded down.
      const fixedMs = Date.UTC(2026, 10, 11, 9, 0, 0) + 500;
      const tokens = service({ now: () => fixedMs });

      const { token, issuedAt } = await tokens.sign({ userId: USER_ID, role: 'officer' });

      expect(issuedAt).toBe(Math.floor(fixedMs / 1000));
      expect(decodeJwt(token).iat).toBe(issuedAt);
      expect((await tokens.verify(token)).iat).toBe(issuedAt);
    });

    it('lets tests sign a token that is exactly a minute older, with no waiting', async () => {
      const older = service({ now: () => Date.now() - 60 * 1000 });
      const { issuedAt: olderIat } = await older.sign({ userId: USER_ID, role: 'miner' });
      const { issuedAt: nowIat } = await service().sign({ userId: USER_ID, role: 'miner' });

      // 59 or 60, depending on where the second boundary falls between the two calls.
      expect(nowIat - olderIat).toBeGreaterThanOrEqual(59);
    });

    it('uses an HS256 header and only the agreed claims, with no personal data', async () => {
      const { token } = await service().sign({ userId: USER_ID, role: 'buyer' });

      expect(decodeProtectedHeader(token)).toEqual({ alg: 'HS256', typ: 'JWT' });
      expect(Object.keys(decodeJwt(token)).sort()).toEqual(['aud', 'exp', 'iat', 'iss', 'role', 'sub']);
      expect(decodeJwt(token)).toMatchObject({ sub: USER_ID, role: 'buyer', iss: 'minechain-api', aud: 'minechain-app' });
    });

    it('expires after the configured lifetime and reports it', async () => {
      const { token, expiresIn } = await service({ expiresInSeconds: 900 }).sign({ userId: USER_ID, role: 'miner' });
      const { iat, exp } = decodeJwt(token);

      expect(exp - iat).toBe(900);
      expect(expiresIn).toBe(900);
    });

    it('accepts a correct token built by hand (control: the forging helper itself is right)', async () => {
      const token = forge(HS256, validClaims());

      expect(await service().verify(token)).toEqual({ userId: USER_ID, role: 'miner', iat: decodeJwt(token).iat });
    });
  });

  describe('refused tokens', () => {
    it('an expired token, with its own code so the app can ask for the password again', async () => {
      // Signed two hours ago with a one-hour lifetime.
      const past = service({ now: () => Date.now() - 2 * 60 * 60 * 1000 });
      const { token } = await past.sign({ userId: USER_ID, role: 'miner' });

      const err = await expectRefused(token, 'TOKEN_EXPIRED');
      expect(err.message).toBe('Your session has expired. Please log in again.');
    });

    it('a tampered payload (role changed to admin, original signature kept)', async () => {
      const { token } = await service().sign({ userId: USER_ID, role: 'miner' });
      const [header, , signature] = token.split('.');

      await expectRefused(`${header}.${b64(validClaims({ role: 'admin' }))}.${signature}`);
    });

    it('a token signed with a different secret', async () => {
      const { token } = await service({ secret: OTHER_SECRET }).sign({ userId: USER_ID, role: 'miner' });

      await expectRefused(token);
    });

    it('the wrong issuer', async () => {
      await expectRefused(forge(HS256, validClaims({ iss: 'someone-else' })));
    });

    it('the wrong audience', async () => {
      await expectRefused(forge(HS256, validClaims({ aud: 'some-other-app' })));
    });

    it('an "alg: none" token with no signature', async () => {
      await expectRefused(forge({ alg: 'none', typ: 'JWT' }, validClaims(), { hmac: null }));
    });

    it('an RS256-labelled token whose signature is an HMAC of our secret (algorithm confusion)', async () => {
      await expectRefused(forge({ alg: 'RS256', typ: 'JWT' }, validClaims()));
    });

    it('an HS512 token made with the right secret, because only HS256 is allowed', async () => {
      await expectRefused(forge({ alg: 'HS512', typ: 'JWT' }, validClaims(), { hmac: 'sha512' }));
    });

    it('a token without a subject', async () => {
      const { sub: _removed, ...noSubject } = validClaims();

      await expectRefused(forge(HS256, noSubject));
    });

    it('a token whose role is not text', async () => {
      await expectRefused(forge(HS256, validClaims({ role: 1 })));
    });

    it('a token whose iat is not a whole number, which sign never writes', async () => {
      await expectRefused(forge(HS256, validClaims({ iat: nowSeconds() + 0.5 })));
    });

    it.each(['not-a-token', 'a.b.c', '', 'eyJhbGciOiJIUzI1NiJ9'])('the string %j', async (token) => {
      await expectRefused(token);
    });

    it('all with one generic message that does not explain what was wrong', async () => {
      const err = await expectRefused(forge({ alg: 'none', typ: 'JWT' }, validClaims(), { hmac: null }));

      expect(err.message).toBe('Your session is not valid. Please log in again.');
      expect(err.message).not.toMatch(/alg|signature|claim/i);
    });
  });

  describe('construction', () => {
    const originalSecret = process.env.JWT_SECRET;
    afterEach(() => {
      if (originalSecret === undefined) delete process.env.JWT_SECRET;
      else process.env.JWT_SECRET = originalSecret;
    });

    it('refuses a secret shorter than 43 characters', () => {
      expect(() => service({ secret: 'x'.repeat(42) })).toThrow(TypeError);
    });

    it.each([0, 3601, 1.5])('refuses a lifetime of %s seconds', (expiresInSeconds) => {
      expect(() => service({ expiresInSeconds })).toThrow(TypeError);
    });

    it('accepts exactly 60 minutes', () => {
      expect(() => service({ expiresInSeconds: 3600 })).not.toThrow();
    });

    it('never falls back to process.env.JWT_SECRET', () => {
      process.env.JWT_SECRET = SECRET;

      expect(() => createTokenService({ expiresInSeconds: 3600 })).toThrow(TypeError);
    });
  });
});
