import { z } from 'zod';

// The bodies come from schemas/adminUsers.js: reasonBodySchema (retry) and emptyBodySchema
// (run), so a reason means the same thing on every admin action.

// GET /admin/anchoring takes no parameters at all. .strict() on an empty object refuses any
// parameter by name, so a client that thinks it can filter or page (?limit=, ?status=) is
// told so instead of getting an answer that quietly ignored it.
export const anchoringStatusQuerySchema = z.object({}).strict();

// :id in /admin/anchoring/steps/:id/retry. Checked before the body and before any SQL: a
// malformed uuid would otherwise be PostgreSQL error 22P02 and surface as a 500.
export const stepIdParamsSchema = z
  .object({
    id: z.uuid({ error: 'must be a valid step id' }),
  })
  .strict();
