import { Router } from 'express';
import { createReportsController } from '../controllers/reportsController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { transactionsReportQuerySchema, auditTrailQuerySchema } from '../schemas/reports.js';

// Mounted at /reports (FR-09, FR-13). requireAuth and the report limiter are made by
// createApp and passed in, so each app instance (and each test) has its own counter.
export function reportRoutes({ reports, requireAuth, reportLimiter }) {
  const router = Router();
  const controller = createReportsController({ reports });

  // On the router, so a route added later cannot forget any of it, and so a miner or
  // transporter gets the same 403 on a path that does not exist as on one that does.
  // Order matters:
  //   noStore first, so every answer, refusals included, carries it (reports hold custody
  //     records and names);
  //   then who, then the roles that may use any report;
  //   then the limiter, keyed by the user requireAuth found, and before validation, so that
  //     malformed requests count too. A miner or transporter is refused before it and not
  //     counted; a buyer or admin asking for the audit trail is counted, then refused.
  router.use(noStore, requireAuth, requireRole('officer', 'buyer', 'admin'), reportLimiter);

  router.get('/transactions', validate(transactionsReportQuerySchema, 'query'), controller.transactions);
  // The audit trail is for officers only (FR-13). The service checks the role again.
  router.get('/audit-trail', requireRole('officer'), validate(auditTrailQuerySchema, 'query'), controller.auditTrail);

  return router;
}
