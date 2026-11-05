import { Router } from 'express';
import { createAuthController } from '../controllers/authController.js';
import { validate } from '../middleware/validate.js';
import { registerSchema } from '../schemas/auth.js';

// Public routes: nobody has a token yet when they register or log in.
// The limiter is made by createApp and passed in, so each app instance has its own counter.
export function authRoutes({ users, registerLimiter }) {
  const router = Router();
  const controller = createAuthController({ users });

  // Order matters. The limiter runs first, so invalid requests count too and cannot be
  // sent without limit. Validation then runs before the controller ever sees the body.
  router.post('/register', registerLimiter, validate(registerSchema), controller.register);

  return router;
}
