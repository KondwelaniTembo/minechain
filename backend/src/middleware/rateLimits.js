import { createHmac, randomBytes } from 'node:crypto';
import { rateLimit } from 'express-rate-limit';
import { AppError } from '../errors.js';

const ONE_HOUR_MS = 60 * 60 * 1000;
const FIFTEEN_MINUTES_MS = 15 * 60 * 1000;

// DEV-SHORTCUT: in-memory rate-limit stores (register, login IP, login username and sync) | reset on restart and count per server instance; replace with a shared store (for example PostgreSQL or Redis) before running more than one instance, and give the login username limiter a configured HMAC key instead of a per-process random one
//
// Shared settings for every limiter. Each limiter is made by a function rather than created
// once at import, so each createApp call, and so each test, gets its own counter.
function createLimiter({ limit, windowMs, message, keyGenerator, skipSuccessfulRequests = false }) {
  return rateLimit({
    windowMs,
    limit,
    // RateLimit headers tell the client its limit and what is left, and the library sets
    // Retry-After when the limit is reached.
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    // Left out, keyGenerator defaults to req.ip, with IPv6 addresses grouped into /56
    // blocks so one device cannot escape the limit by rotating through its own addresses.
    ...(keyGenerator && { keyGenerator }),
    skipSuccessfulRequests,
    // Hand over to errorHandler instead of writing a response here, so a 429 looks like
    // every other error. The message is fixed text: nothing the client typed goes in it.
    handler: (req, res, next) => {
      next(new AppError(429, 'TOO_MANY_REQUESTS', message));
    },
  });
}

// Registration attempts per client IP. 30 per hour, not lower, because Zambian mobile
// networks use carrier-grade NAT: a whole mining site can share one public IP.
export function createRegisterLimiter({ limit = 30, windowMs = ONE_HOUR_MS } = {}) {
  return createLimiter({
    limit,
    windowMs,
    message: 'Too many registration attempts from this network. Please try again later.',
  });
}

// Login attempts per client IP, counting everything. High for the same carrier-grade NAT
// reason; it only slows one source trying many usernames. The username limiter below is
// what stops password guessing against one account.
export function createLoginIpLimiter({ limit = 100, windowMs = FIFTEEN_MINUTES_MS } = {}) {
  return createLimiter({
    limit,
    windowMs,
    message: 'Too many login attempts from this network. Please try again later.',
  });
}

// The rate-limit key for a username. The store keeps its keys in memory, and a plain
// username there would be a list of everything people typed, including passwords typed
// into the username box by mistake. An HMAC is a keyed hash: the same username always gives
// the same key, but the key cannot be turned back into the username. Trimmed and lower-cased
// first, so "Mutale_Banda" and " mutale_banda " share one counter, as they share one account.
export function loginUsernameKey(limiterKey, username) {
  return createHmac('sha256', limiterKey).update(username.trim().toLowerCase()).digest('hex');
}

// Failed login attempts per username, from anywhere. Successful logins are given back
// (skipSuccessfulRequests), so an owner's own logins never add to the count, which limits
// how easily someone else can lock them out. It applies the same way to usernames that do
// not exist, with the same message, so the 429 does not reveal which accounts are real.
// Must run after validate(loginSchema), because it reads the cleaned-up username.
export function createLoginUsernameLimiter({ limit = 10, windowMs = FIFTEEN_MINUTES_MS } = {}) {
  // Random per limiter: the in-memory store is lost on restart anyway (see DEV-SHORTCUT).
  const limiterKey = randomBytes(32);
  return createLimiter({
    limit,
    windowMs,
    message: 'Too many failed login attempts for this username. Please try again in 15 minutes.',
    keyGenerator: (req) => loginUsernameKey(limiterKey, req.validated.body.username),
    skipSuccessfulRequests: true,
  });
}

// Sync requests per logged-in user (POST /sync/steps). Keyed by user id, not by IP: many
// phones at one mining site share an IP (carrier-grade NAT), and every sync request is
// already authenticated. 60 per 15 minutes, each with up to 50 steps, is far beyond real
// use; the limit is there to stop a runaway retry loop in the app, not normal syncing.
//
// The key is the user id, a random UUID, so unlike the login limiter there is nothing
// sensitive to hide behind an HMAC. Must run after requireAuth.
export function createSyncLimiter({ limit = 60, windowMs = FIFTEEN_MINUTES_MS } = {}) {
  return createLimiter({
    limit,
    windowMs,
    message: 'Too many sync requests. Please wait a few minutes and try again.',
    keyGenerator: (req) => {
      // Fail closed. Without requireAuth there is no user to count, and falling back to a
      // shared key would let one client use up everyone's limit. A plain Error becomes a
      // logged 500, as in requireRole.
      if (!req.user?.id) throw new Error('createSyncLimiter ran without requireAuth before it on this route');
      return `user:${req.user.id}`;
    },
  });
}
