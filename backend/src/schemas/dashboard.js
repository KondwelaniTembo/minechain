import { z } from 'zod';
import { MINERALS } from '../services/stepPayload.js';
import { daySchema, checkRange } from './reports.js';

// Query parameters for GET /dashboard (FR-14). The period follows the report rules exactly
// (UTC days, both included, at most MAX_REPORT_DAYS), so an officer who sees a figure here
// can download the same period as a transactions report and find the same steps.
// A repeated parameter arrives as an array and is refused as not being a string, as in the
// reports; any other parameter is refused by .strict().
export const dashboardQuerySchema = z
  .object({
    from: daySchema,
    to: daySchema,
    mineral: z.enum(MINERALS, { error: `must be one of ${MINERALS.join(', ')}` }).optional(),
  })
  .strict()
  .pipe(z.unknown().superRefine(checkRange));
