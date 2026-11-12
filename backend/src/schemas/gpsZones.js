import { z } from 'zod';
import { zoneBoundarySchema } from './geo.js';
import { LIST_LIMIT_DEFAULT, LIST_LIMIT_MAX, LIST_OFFSET_MAX, wholeNumber } from './adminUsers.js';

// The two statuses, exactly as the gps_zones_status_valid CHECK in the migration allows.
export const ZONE_STATUSES = Object.freeze(['active', 'inactive']);

export const ZONE_NAME_MIN_LENGTH = 3;
// The database only refuses a blank name, so this is the only length limit. 100 matches a
// person's full name: room for "Kasempa North (until Nov 2026)", short enough for a report.
export const ZONE_NAME_MAX_LENGTH = 100;

// :id in /admin/zones/:id/rename and the like. Checked before any SQL, as for users: a
// malformed uuid would otherwise be PostgreSQL error 22P02 and surface as a 500.
export const zoneIdParamsSchema = z
  .object({
    id: z.uuid({ error: 'must be a valid zone id' }),
  })
  .strict();

// Trimmed, so " Kasempa " and "Kasempa" cannot both exist. Uniqueness ignoring letter case
// is left to the gps_zones_name_lower_key index, which also sees inactive zones.
const zoneNameSchema = z
  .string()
  .trim()
  .min(ZONE_NAME_MIN_LENGTH, `must be at least ${ZONE_NAME_MIN_LENGTH} characters`)
  .max(ZONE_NAME_MAX_LENGTH, `must be at most ${ZONE_NAME_MAX_LENGTH} characters`);

// POST /admin/zones. The boundary is fixed once created (decisions.md, GPS zones): a new
// shape means a new zone, so this is the only place a boundary is ever accepted. The
// licence number follows the same rule as at registration (schemas/auth.js) and is also
// fixed. .strict(): a stray field such as status or createdBy is refused, not ignored.
export const createZoneBodySchema = z
  .object({
    name: zoneNameSchema,
    licenceNumber: z.string().trim().min(1, 'must not be blank').max(50, 'must be at most 50 characters').optional(),
    boundary: zoneBoundarySchema,
  })
  .strict();

// POST /admin/zones/:id/rename. Only the name: the boundary and licence number cannot be
// sent here, so they cannot change by accident.
export const renameZoneBodySchema = z
  .object({
    name: zoneNameSchema,
  })
  .strict();

// GET /admin/zones. With no query at all, it lists the first page of active zones, the
// ones registrations are checked against. Paging follows GET /admin/users.
export const listZonesQuerySchema = z
  .object({
    status: z.enum(ZONE_STATUSES, { error: 'must be active or inactive' }).default('active'),
    limit: wholeNumber({ min: 1, max: LIST_LIMIT_MAX, defaultValue: LIST_LIMIT_DEFAULT }),
    offset: wholeNumber({ min: 0, max: LIST_OFFSET_MAX, defaultValue: 0 }),
  })
  .strict();

// Deactivate takes a reason and reactivate takes nothing, exactly as suspend and
// reactivate do for accounts, so the same schemas are used: reasonBodySchema and
// emptyBodySchema in adminUsers.js.
