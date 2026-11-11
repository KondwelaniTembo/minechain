import { AppError } from '../errors.js';

// RFC 6750 (Bearer tokens). The realm names the protected area; error="invalid_token"
// tells the client that the credentials it sent were refused, not simply missing.
const CHALLENGE = 'Bearer realm="minechain"';
const CHALLENGE_INVALID = 'Bearer realm="minechain", error="invalid_token"';

// "Bearer", case-insensitive (RFC 7235), then one token made only of RFC 6750 b64token
// characters. Anything else after "Bearer " (spaces inside, two headers joined by a
// comma) cannot be a token we issued.
const BEARER = /^Bearer[ ]+([A-Za-z0-9\-._~+/]+=*)$/i;
const BEARER_SCHEME = /^Bearer(?:[ ]|$)/i;

// Protects a route. Reads the token from the Authorization header only, never from the
// query string or body: URLs are written to access logs, proxy logs and browser history,
// so a token there leaks. The token itself is never logged.
//
// On success, req.user is the safe user read fresh from the database, not the token's
// claims, so routes always see the current role and status.
export function createRequireAuth({ tokens, users }) {
  return async function requireAuth(req, res, next) {
    const header = (req.get('Authorization') ?? '').trim();

    // No header, another scheme (for example Basic), or "Bearer" with nothing after it:
    // no usable credentials were sent.
    if (!BEARER_SCHEME.test(header) || /^Bearer$/i.test(header)) {
      res.set('WWW-Authenticate', CHALLENGE);
      return next(new AppError(401, 'TOKEN_MISSING', 'Please log in to continue.'));
    }

    const match = BEARER.exec(header);
    if (!match) {
      res.set('WWW-Authenticate', CHALLENGE_INVALID);
      return next(new AppError(401, 'TOKEN_INVALID', 'Your session is not valid. Please log in again.'));
    }

    try {
      // Signature, algorithm, issuer, audience and expiry: TOKEN_EXPIRED or TOKEN_INVALID.
      const { userId, role, iat } = await tokens.verify(match[1]);
      // The account as it is now: refused if gone, no longer active, with another role, or if
      // this token was issued before the account's last password change.
      req.user = await users.getAuthenticatedUser(userId, role, iat);
      return next();
    } catch (err) {
      // Only refused credentials get the challenge. A 403 (the account is not allowed in)
      // does not, because the credentials themselves were fine.
      if (err instanceof AppError && err.status === 401) {
        res.set('WWW-Authenticate', CHALLENGE_INVALID);
      }
      return next(err);
    }
  };
}
