import { SignJWT, jwtVerify, errors } from 'jose';
import { AppError } from '../errors.js';

export const TOKEN_ISSUER = 'minechain-api';
export const TOKEN_AUDIENCE = 'minechain-app';
// NFR-01: no token may live longer than 60 minutes.
const MAX_LIFETIME_SECONDS = 60 * 60;
// 43 base64url characters carry 256 bits, the key size HS256 needs.
const MIN_SECRET_LENGTH = 43;

// The secret and lifetime are passed in (from config), never read from process.env here,
// so the service has one clear source of settings and tests can use their own.
// `now` returns milliseconds; tests replace it to make tokens that are already expired.
export function createTokenService({ secret, expiresInSeconds, now = () => Date.now() } = {}) {
  // Already checked by loadConfig; repeated here so the service can never be built with a
  // weak key or an over-long lifetime, whoever calls it.
  if (typeof secret !== 'string' || secret.length < MIN_SECRET_LENGTH) {
    throw new TypeError(`Token secret must be a string of at least ${MIN_SECRET_LENGTH} characters`);
  }
  if (!Number.isInteger(expiresInSeconds) || expiresInSeconds < 1 || expiresInSeconds > MAX_LIFETIME_SECONDS) {
    throw new TypeError(`Token lifetime must be a whole number of seconds from 1 to ${MAX_LIFETIME_SECONDS}`);
  }

  // jose wants the HMAC key as bytes.
  const key = new TextEncoder().encode(secret);

  return {
    // Only the user id and role go in the token. The payload is signed, not encrypted, so
    // anyone holding the token can read it: no names, usernames or other personal data.
    // issuedAt (the token's iat, whole seconds from this server's clock) is returned so a
    // password change can store it as the cut-off for older tokens: one clock decides both.
    async sign({ userId, role }) {
      const issuedAt = Math.floor(now() / 1000);
      const token = await new SignJWT({ role })
        .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
        .setSubject(userId)
        .setIssuer(TOKEN_ISSUER)
        .setAudience(TOKEN_AUDIENCE)
        .setIssuedAt(issuedAt)
        .setExpirationTime(issuedAt + expiresInSeconds)
        .sign(key);
      return { token, expiresIn: expiresInSeconds, issuedAt };
    },

    // Returns { userId, role, iat }, or throws a 401 AppError. iat goes to
    // getAuthenticatedUser, which refuses a token issued before the account's last password
    // change.
    async verify(token) {
      let payload;
      try {
        ({ payload } = await jwtVerify(token, key, {
          // Only HS256. Without this list, a token could choose its own algorithm: "none"
          // (no signature at all) or RS256 (tricking a verifier into treating our secret
          // as a public key). Both are classic ways to forge a token.
          algorithms: ['HS256'],
          issuer: TOKEN_ISSUER,
          audience: TOKEN_AUDIENCE,
          requiredClaims: ['sub', 'role', 'iat', 'exp'],
          currentDate: new Date(now()),
        }));
      } catch (err) {
        // Expired gets its own code so the app knows to ask for the password again.
        if (err instanceof errors.JWTExpired) {
          throw new AppError(401, 'TOKEN_EXPIRED', 'Your session has expired. Please log in again.');
        }
        // Everything else gets one generic answer. The jose error is not passed on,
        // because it would tell a forger exactly why their token failed.
        throw new AppError(401, 'TOKEN_INVALID', 'Your session is not valid. Please log in again.');
      }

      // jose has checked that iat is a number; a whole number is what sign() writes, and what
      // the cut-off comparison in SQL expects.
      if (typeof payload.role !== 'string' || !Number.isSafeInteger(payload.iat)) {
        throw new AppError(401, 'TOKEN_INVALID', 'Your session is not valid. Please log in again.');
      }
      return { userId: payload.sub, role: payload.role, iat: payload.iat };
    },
  };
}
