import { Router } from 'express';
import { createAdminZonesController } from '../controllers/adminZonesController.js';
import { requireRole } from '../middleware/requireRole.js';
import { validate } from '../middleware/validate.js';
import { noStore } from '../middleware/noStore.js';
import { reasonBodySchema, emptyBodySchema } from '../schemas/adminUsers.js';
import {
  zoneIdParamsSchema,
  createZoneBodySchema,
  renameZoneBodySchema,
  listZonesQuerySchema,
} from '../schemas/gpsZones.js';

// Mounted at /admin/zones (FR-11). requireAuth is made by createApp and passed in, like the
// other routes.
export function adminZoneRoutes({ zones, requireAuth }) {
  const router = Router();
  const controller = createAdminZonesController({ zones });

  // The same guard as /admin/users, on the router rather than on each route, so a route
  // added later cannot forget it. It runs before routing inside this router, so a non-admin
  // gets the same 401 or 403 for a path that does not exist as for one that does.
  // noStore: zone boundaries are licence locations, and every answer names who created
  // them, so no response is kept by a cache.
  router.use(noStore, requireAuth, requireRole('admin'));

  router.get('/', validate(listZonesQuerySchema, 'query'), controller.list);
  // The only place a boundary is ever accepted: boundaries are fixed once created.
  router.post('/', validate(createZoneBodySchema), controller.create);

  // Params before body: a malformed id is the more basic mistake, and is refused before
  // PostgreSQL could see it (it would raise 22P02 and become a 500).
  const id = validate(zoneIdParamsSchema, 'params');
  router.post('/:id/rename', id, validate(renameZoneBodySchema), controller.rename);
  router.post('/:id/deactivate', id, validate(reasonBodySchema), controller.deactivate);
  router.post('/:id/reactivate', id, validate(emptyBodySchema), controller.reactivate);

  return router;
}
