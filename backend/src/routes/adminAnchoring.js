import { Router } from 'express';
import { createAdminAnchoringController } from '../controllers/adminAnchoringController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { reasonBodySchema, emptyBodySchema } from '../schemas/adminUsers.js';
import { anchoringStatusQuerySchema, stepIdParamsSchema } from '../schemas/adminAnchoring.js';

// Mounted at /admin/anchoring (anchoring admin plan §5). requireAuth and the action limiter
// are made by createApp and passed in, so each app instance (and each test) has its own
// counter.
export function adminAnchoringRoutes({ anchoring, requireAuth, anchoringActionLimiter }) {
  const router = Router();
  const controller = createAdminAnchoringController({ anchoring });

  // The same guard as the other admin routers, on the router, so a route added later cannot
  // forget it, and a non-admin gets the same 401 or 403 on a path that does not exist as on
  // one that does. noStore: the status names steps, consignments and the recorder wallet,
  // and every answer, refusals included, carries it.
  router.use(noStore, requireAuth, requireRole('admin'));

  // Unlimited: it only reads, and an admin may watch it while fixing something.
  router.get('/', validate(anchoringStatusQuerySchema, 'query'), controller.status);

  // The two actions share one limiter, after the guard (so it is keyed by the admin
  // requireAuth found) and before validation, so malformed requests count too.
  router.post('/run', anchoringActionLimiter, validate(emptyBodySchema), controller.run);
  // Params before body: a malformed id is the more basic mistake.
  router.post(
    '/steps/:id/retry',
    anchoringActionLimiter,
    validate(stepIdParamsSchema, 'params'),
    validate(reasonBodySchema),
    controller.retry,
  );

  return router;
}
