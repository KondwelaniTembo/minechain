import { Router } from 'express';
import { createDashboardController } from '../controllers/dashboardController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { dashboardQuerySchema } from '../schemas/dashboard.js';

// Mounted at /dashboard (FR-14, dashboard plan T2). Officers only (plan Q2): it is the
// regulatory officer's view of the supply chain. On the router, not on the route, so anyone
// else gets the same 401 or 403 on a path that does not exist as on one that does.
// noStore: the figures change with every sync, and every answer, refusals included, carries
// it. Not rate-limited, like GET /alerts: it only reads counts.
export function dashboardRoutes({ dashboard, requireAuth }) {
  const router = Router();
  const controller = createDashboardController({ dashboard });

  router.use(noStore, requireAuth, requireRole('officer'));
  router.get('/', validate(dashboardQuerySchema, 'query'), controller.summary);

  return router;
}
