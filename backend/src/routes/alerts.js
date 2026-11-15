import { Router } from 'express';
import { createAlertsController } from '../controllers/alertsController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { alertIdParamsSchema, listAlertsQuerySchema, notesBodySchema } from '../schemas/alerts.js';

// Mounted at /alerts (app endpoints plan, B1). requireAuth and the action limiter are made by
// createApp and passed in, so each app instance (and each test) has its own counter.
export function alertRoutes({ alerts, requireAuth, alertActionLimiter }) {
  const router = Router();
  const controller = createAlertsController({ alerts });

  // Officers only (Scope (5)): an administrator runs the system but does not judge custody
  // records, so one stolen administrator account cannot also clear alerts. On the router, not
  // on each route, so a route added later cannot forget it, and anyone else gets the same 401
  // or 403 on a path that does not exist as on one that does. noStore: alerts name accounts
  // and consignments, and every answer, refusals included, carries it.
  router.use(noStore, requireAuth, requireRole('officer'));

  // Unlimited: they only read, and an officer refreshes the queue often (Scope (2)).
  router.get('/', validate(listAlertsQuerySchema, 'query'), controller.list);
  router.get('/:id', validate(alertIdParamsSchema, 'params'), controller.get);

  // The two decisions share one limiter, after the guard (so it is keyed by the officer
  // requireAuth found) and before validation, so malformed requests count too. Params before
  // body: a malformed id is the more basic mistake.
  const id = validate(alertIdParamsSchema, 'params');
  router.post('/:id/review', alertActionLimiter, id, validate(notesBodySchema), controller.review);
  router.post('/:id/dismiss', alertActionLimiter, id, validate(notesBodySchema), controller.dismiss);

  return router;
}
