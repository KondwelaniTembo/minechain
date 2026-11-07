import { Router } from 'express';
import { createSyncController } from '../controllers/syncController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { syncStepsBodySchema } from '../schemas/sync.js';
import { SIGNING_ROLES } from '../roles.js';

// Mounted at /sync. requireAuth and the sync limiter are made by createApp and passed in, so
// each app instance (and each test) has its own counter.
export function syncRoutes({ sync, requireAuth, syncLimiter }) {
  const router = Router();
  const controller = createSyncController({ sync });

  // Order matters:
  //   noStore first, so every answer, refusals included, carries it (results describe the
  //     user's own custody records);
  //   then who, then which role (only the roles that sign custody steps);
  //   then the limiter, keyed by the user requireAuth found, and before validate so that
  //     malformed requests count too and cannot be sent without limit;
  //   then the envelope; each item's content is checked by the service.
  router.post(
    '/steps',
    noStore,
    requireAuth,
    requireRole(...SIGNING_ROLES),
    syncLimiter,
    validate(syncStepsBodySchema),
    controller.syncSteps,
  );

  return router;
}
