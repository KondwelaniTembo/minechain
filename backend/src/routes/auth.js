import { Router } from 'express';
import { createAuthController } from '../controllers/authController.js';
import { validate } from '../middleware/validate.js';
import { requireRole } from '../middleware/requireRole.js';
import { noStore } from '../middleware/noStore.js';
import { registerSchema, loginSchema, publicKeyBodySchema, activateBodySchema, changePasswordBodySchema } from '../schemas/auth.js';
import { SIGNING_ROLES } from '../roles.js';

// /register, /login and /activate are public: nobody has a token yet. /me needs one.
// The limiters and requireAuth are made by createApp and passed in, so each app instance
// has its own counters.
export function authRoutes({
  users,
  registerLimiter,
  loginIpLimiter,
  loginUsernameLimiter,
  activationLimiter,
  passwordChangeLimiter,
  requireAuth,
}) {
  const router = Router();
  const controller = createAuthController({ users });

  // Order matters. The limiter runs first, so invalid requests count too and cannot be
  // sent without limit. Validation then runs before the controller ever sees the body.
  router.post('/register', registerLimiter, validate(registerSchema), controller.register);

  // The IP limiter runs first, so even malformed requests count against the network. The
  // username limiter runs after validate, because its key needs the cleaned-up username.
  router.post('/login', loginIpLimiter, validate(loginSchema), loginUsernameLimiter, controller.login);

  // An officer or administrator created by an administrator (FR-10) sets their password with
  // the activation code, and gets a token as at login. no-store first, so every answer,
  // including a 429 or 400, carries it: the success holds a token. The limiter before
  // validation, so malformed requests count too.
  router.post('/activate', noStore, activationLimiter, validate(activateBodySchema), controller.activate);

  router.get('/me', requireAuth, controller.me);

  // The phone registers its Keystore key once, after the first login (signing-spec,
  // section 2). Only the roles that sign custody steps. PUT, because sending the same key
  // again is safe and gives the same answer. Order: no-store first (so refusals carry it
  // too), then who, then which role, then the body.
  router.put('/me/public-key', noStore, requireAuth, requireRole(...SIGNING_ROLES), validate(publicKeyBodySchema), controller.registerPublicKey);

  // Any active user, any role. The success holds a token, so no-store first. The limiter
  // after requireAuth (it counts per user) and before validate, so malformed requests count
  // as failures too.
  router.post('/me/password', noStore, requireAuth, passwordChangeLimiter, validate(changePasswordBodySchema), controller.changePassword);

  return router;
}
