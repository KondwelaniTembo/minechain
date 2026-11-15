import { Router } from 'express';
import { createConsignmentsController } from '../controllers/consignmentsController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { qrCodeParamsSchema } from '../schemas/consignments.js';

// Mounted at /consignments (app endpoints plan, B2). requireAuth and the view limiter are
// made by createApp and passed in, so each app instance (and each test) has its own counter.
export function consignmentRoutes({ consignments, requireAuth, consignmentViewLimiter }) {
  const router = Router();
  const controller = createConsignmentsController({ consignments });

  // Transporters, buyers and officers only (Scope (9)): a miner has their own records on the
  // phone, and an administrator runs the system but does not judge custody records. On the
  // router, so a route added later cannot forget it, and anyone else gets the same 401 or 403
  // on a path that does not exist as on one that does. noStore: the body can carry GPS and
  // signatures, and every answer, refusals included, carries it.
  router.use(noStore, requireAuth, requireRole('transporter', 'buyer', 'officer'));

  // The limiter after the guard (keyed by the user requireAuth found) and before validation,
  // so malformed codes count too: each view can cost several RPC calls on a free plan.
  router.get('/by-qr/:qrCode', consignmentViewLimiter, validate(qrCodeParamsSchema, 'params'), controller.viewByQr);

  return router;
}
