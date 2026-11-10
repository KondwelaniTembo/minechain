import { z } from 'zod';
import { MINERALS, STEP_TYPES } from '../services/stepPayload.js';

// Query parameters for the spreadsheet reports: GET /reports/transactions (FR-09) and
// GET /reports/audit-trail (FR-13). Query values always arrive as strings; a repeated
// parameter (?mineral=gold&mineral=copper) arrives as an array and is refused as not being
// a string, so each filter has exactly one value.

// Exactly as the transactions_review_status_valid and transactions_anchor_status_valid
// CHECKs in the transactions migration allow.
export const REVIEW_STATUSES = Object.freeze(['passed', 'flagged', 'cleared', 'rejected']);
export const ANCHOR_STATUSES = Object.freeze(['pending', 'submitted', 'confirmed', 'failed']);

// The longest date range a report may cover, counting both the first and the last day. A
// report for the regulator states its period, and the limit also keeps the query bounded
// (the row cap is the other limit).
export const MAX_REPORT_DAYS = 366;

const MS_PER_DAY = 86_400_000;
const DAY_FORMAT = /^\d{4}-\d{2}-\d{2}$/;

// The start of a UTC day, or null when the text is not a real calendar date. Date.UTC would
// quietly turn 2026-02-30 into 2 March, so the result is printed again and compared.
function utcDayStart(text) {
  const start = new Date(`${text}T00:00:00.000Z`);
  return !Number.isNaN(start.getTime()) && start.toISOString().slice(0, 10) === text ? start : null;
}

// One day, as YYYY-MM-DD in UTC. Both ends of a range are included, so from=2026-11-01 and
// to=2026-11-30 cover the whole of November.
// One superRefine rather than .regex().refine(): Zod runs every check on a string even after
// one fails, so '01/11/2026' would get both messages. Here it gets exactly one.
const daySchema = z.string().superRefine((text, ctx) => {
  if (!DAY_FORMAT.test(text)) {
    ctx.addIssue({ code: 'custom', message: 'must be a date such as 2026-11-01' });
  } else if (utcDayStart(text) === null) {
    ctx.addIssue({ code: 'custom', message: 'must be a real calendar date' });
  }
});

const uuid = (what) => z.uuid({ error: `must be a valid ${what} id` });

// The time range a validated from/to covers: from the start of `from` up to, but not
// including, the start of the day after `to`, both in UTC. The report service filters with
// start <= captured_at < endExclusive, which never depends on the database's time zone
// setting the way casting a date would.
export function utcDayRange({ from, to }) {
  const start = utcDayStart(from);
  const lastDay = utcDayStart(to);
  if (!start || !lastDay) throw new TypeError('utcDayRange needs two valid YYYY-MM-DD days');
  return { start, endExclusive: new Date(lastDay.getTime() + MS_PER_DAY) };
}

// Adds the range problems, if any, to the issues. Runs only once both days are valid (see the
// .pipe() calls below), so it never has to cope with a malformed date.
function checkRange({ from, to }, ctx) {
  const days = (utcDayStart(to).getTime() - utcDayStart(from).getTime()) / MS_PER_DAY + 1;
  if (days < 1) {
    ctx.addIssue({ code: 'custom', path: ['to'], message: 'must be the same day as from or later' });
  } else if (days > MAX_REPORT_DAYS) {
    ctx.addIssue({
      code: 'custom',
      path: ['to'],
      message: `must be at most ${MAX_REPORT_DAYS} days after from, counting both days`,
    });
  }
}

// GET /reports/transactions. from and to are required: a report always states its period.
// The other filters are optional, and every given filter must match (AND). FR-09 names date
// range, mineral, actor and zone; type and the two statuses help an officer narrow a report
// without exporting everything.
//
// Two stages, as for zone boundaries: .pipe() runs the range check only when every field
// passed, so a malformed date is reported on its own. (An unknown parameter does not stop
// the pipe, so it is reported together with any range problem.)
export const transactionsReportQuerySchema = z
  .object({
    from: daySchema,
    to: daySchema,
    mineral: z.enum(MINERALS, { error: `must be one of ${MINERALS.join(', ')}` }).optional(),
    actorId: uuid('user').optional(),
    zoneId: uuid('zone').optional(),
    type: z.enum(STEP_TYPES, { error: `must be one of ${STEP_TYPES.join(', ')}` }).optional(),
    reviewStatus: z.enum(REVIEW_STATUSES, { error: `must be one of ${REVIEW_STATUSES.join(', ')}` }).optional(),
    anchorStatus: z.enum(ANCHOR_STATUSES, { error: `must be one of ${ANCHOR_STATUSES.join(', ')}` }).optional(),
  })
  .strict()
  .pipe(z.unknown().superRefine(checkRange));

// GET /reports/audit-trail: the full trail of ONE consignment or ONE actor (FR-13), so
// exactly one of consignmentId and actorId. A consignment's trail is always complete, so it
// takes no dates. An actor's trail covers a period, so from and to are required with it.
export const auditTrailQuerySchema = z
  .object({
    consignmentId: uuid('consignment').optional(),
    actorId: uuid('user').optional(),
    from: daySchema.optional(),
    to: daySchema.optional(),
  })
  .strict()
  .pipe(
    z.unknown().superRefine((query, ctx) => {
      const hasConsignment = query.consignmentId !== undefined;
      const hasActor = query.actorId !== undefined;
      if (hasConsignment === hasActor) {
        // An empty path is reported by validate() as the field "query".
        ctx.addIssue({
          code: 'custom',
          path: [],
          message: hasConsignment ? 'give consignmentId or actorId, not both' : 'give consignmentId or actorId',
        });
        return;
      }

      if (hasConsignment) {
        for (const field of ['from', 'to']) {
          if (query[field] !== undefined) {
            ctx.addIssue({ code: 'custom', path: [field], message: "is not used with consignmentId: a consignment's trail is always complete" });
          }
        }
        return;
      }

      const missing = ['from', 'to'].filter((field) => query[field] === undefined);
      for (const field of missing) {
        ctx.addIssue({ code: 'custom', path: [field], message: 'is required with actorId' });
      }
      if (missing.length === 0) checkRange(query, ctx);
    }),
  );
