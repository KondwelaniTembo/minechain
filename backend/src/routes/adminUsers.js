import { Router } from 'express';
import { createAdminUsersController } from '../controllers/adminUsersController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import {
  userIdParamsSchema,
  listUsersQuerySchema,
  reasonBodySchema,
  emptyBodySchema,
  createUserBodySchema,
} from '../schemas/adminUsers.js';

// Mounted at /admin/users. requireAuth is made by createApp and passed in, like the auth
// routes.
export function adminUserRoutes({ accounts, requireAuth }) {
  const router = Router();
  const controller = createAdminUsersController({ accounts });

  // Every response here, errors included, holds or concerns personal data, so noStore comes
  // first and even a 401 or 403 carries it.
  // On the router, not on each route, so a route added later cannot forget it. It also
  // runs before routing inside this router, so a non-admin gets the same 401 or 403 for a
  // path that does not exist as for one that does, and cannot map what is here.
  router.use(noStore, requireAuth, requireRole('admin'));

  router.get('/', validate(listUsersQuerySchema, 'query'), controller.list);

  // FR-10: an officer or administrator account, invited until its owner activates it. The
  // response holds the activation code, the only time it is ever shown; noStore above keeps
  // it out of every cache.
  router.post('/', validate(createUserBodySchema), controller.create);

  // Params before body: a malformed id is the more basic mistake, and is refused before
  // PostgreSQL could see it (it would raise 22P02 and become a 500).
  const id = validate(userIdParamsSchema, 'params');
  router.post('/:id/approve', id, validate(emptyBodySchema), controller.approve);
  router.post('/:id/reject', id, validate(reasonBodySchema), controller.reject);
  router.post('/:id/suspend', id, validate(reasonBodySchema), controller.suspend);
  router.post('/:id/reactivate', id, validate(emptyBodySchema), controller.reactivate);
  // Lost or replaced phone: only on a suspended account (signing-spec section 2).
  router.post('/:id/reset-key', id, validate(reasonBodySchema), controller.resetKey);
  // A new code for an invited account: lost, expired or erased. The old one stops working.
  router.post('/:id/activation-code', id, validate(emptyBodySchema), controller.reissueActivation);

  return router;
}
