import { rateLimit } from 'express-rate-limit';
import { AppError } from '../errors.js';

const ONE_HOUR_MS = 60 * 60 * 1000;

// Registration attempts per client IP. 30 per hour, not lower, because Zambian mobile
// networks use carrier-grade NAT: a whole mining site can share one public IP, and a tight
// limit would lock everyone out because of one person.
//
// Made by a function rather than created once at import, so each createApp call, and so
// each test, gets its own counter.
//
// DEV-SHORTCUT: in-memory rate-limit store | resets on restart and counts per server instance; replace with a shared store (for example PostgreSQL or Redis) before running more than one instance
export function createRegisterLimiter({ limit = 30, windowMs = ONE_HOUR_MS } = {}) {
  return rateLimit({
    windowMs,
    limit,
    // RateLimit headers tell the client its limit and what is left, and the library sets
    // Retry-After when the limit is reached.
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    // The key is the default: req.ip, with IPv6 addresses grouped into /56 blocks so one
    // device cannot escape the limit by rotating through the addresses it owns.
    //
    // Hand over to errorHandler instead of writing a response here, so a 429 looks like
    // every other error: { error: { code, message } }.
    handler: (req, res, next) => {
      next(new AppError(429, 'TOO_MANY_REQUESTS', 'Too many registration attempts from this network. Please try again later.'));
    },
  });
}
