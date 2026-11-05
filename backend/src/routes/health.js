import { Router } from 'express';
import { createHealthController } from '../controllers/healthController.js';

// Public on purpose: Render's health checks and uptime monitors cannot log in. It reveals
// only up or down, never versions, configuration or error details.
export function healthRoutes({ db }) {
  const router = Router();
  const controller = createHealthController({ db });

  router.get('/', controller.check);

  return router;
}
