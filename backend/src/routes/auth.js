import { Router } from 'express';
import { createAuthController } from '../controllers/authController.js';
import { validate } from '../middleware/validate.js';
import { registerSchema, loginSchema } from '../schemas/auth.js';

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

  return router;
}
