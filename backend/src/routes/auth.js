import { Router } from 'express';
import { createAuthController } from '../controllers/authController.js';
import { validate } from '../middleware/validate.js';
import { requireRole } from '../middleware/requireRole.js';
import { noStore } from '../middleware/noStore.js';
import { registerSchema, loginSchema, publicKeyBodySchema } from '../schemas/auth.js';
import { SIGNING_ROLES } from '../roles.js';

// /register and /login are public: nobody has a token yet. /me needs one.
// The limiters and requireAuth are made by createApp and passed in, so each app instance
// has its own counters.
export function authRoutes({ users, registerLimiter, loginIpLimiter, loginUsernameLimiter, requireAuth }) {
  const router = Router();
  const controller = createAuthController({ users });

  // Order matters. The limiter runs first, so invalid requests count too and cannot be
  // sent without limit. Validation then runs before the controller ever sees the body.
  router.post('/register', registerLimiter, validate(registerSchema), controller.register);

  // The IP limiter runs first, so even malformed requests count against the network. The
  // username limiter runs after validate, because its key needs the cleaned-up username.
  router.post('/login', loginIpLimiter, validate(loginSchema), loginUsernameLimiter, controller.login);

  router.get('/me', requireAuth, controller.me);

  // The phone registers its Keystore key once, after the first login (signing-spec,
  // section 2). Only the roles that sign custody steps. PUT, because sending the same key
  // again is safe and gives the same answer. Order: no-store first (so refusals carry it
  // too), then who, then which role, then the body.
  router.put('/me/public-key', noStore, requireAuth, requireRole(...SIGNING_ROLES), validate(publicKeyBodySchema), controller.registerPublicKey);

  return router;
}
