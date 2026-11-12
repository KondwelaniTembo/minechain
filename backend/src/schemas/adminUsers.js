import { z } from 'zod';
import { usernameSchema, fullNameSchema } from './auth.js';

// The five statuses, exactly as the users_status_valid CHECK allows since the
// users-activation migration. 'invited': created by an administrator, not activated yet.
export const ACCOUNT_STATUSES = Object.freeze(['pending', 'active', 'suspended', 'rejected', 'invited']);

// The roles an administrator creates (FR-10). Miners, transporters and buyers request their
// own accounts (FR-12, SELF_REGISTER_ROLES), so they are never created here.
export const CREATABLE_ROLES = Object.freeze(['officer', 'admin']);

export const LIST_LIMIT_DEFAULT = 20;
// One page stays small however many users exist (NFR-05 plans for 500 or more).
export const LIST_LIMIT_MAX = 100;
// Far beyond any real list; stops a request asking the database to skip millions of rows.
export const LIST_OFFSET_MAX = 10_000;

export const REASON_MIN_LENGTH = 3;
// The database has no limit on status_reason, so this is the only one (a CHECK is possible
// future hardening). 500 is a few sentences: enough to explain, short enough to read in a list.
export const REASON_MAX_LENGTH = 500;

// :id in /admin/users/:id/approve and the like. Checked before any SQL: PostgreSQL would
// refuse a malformed uuid with error 22P02, which would surface as a 500 instead of a 400.
export const userIdParamsSchema = z
  .object({
    id: z.uuid({ error: 'must be a valid user id' }),
  })
  .strict();

// Query values always arrive as strings. z.coerce.number() would also accept "0x10" (16),
// "1e2" (100) and " 5 ", because it uses Number(); only plain digits are allowed here, so
// what the admin's app sends is exactly what is used. A repeated parameter
// (?limit=1&limit=2) arrives as an array and is refused as not being a string.
// Exported for the other admin lists (schemas/gpsZones.js), so paging works the same way.
export function wholeNumber({ min, max, defaultValue }) {
  return z
    .string()
    .regex(/^\d{1,6}$/, 'must be a whole number')
    .transform(Number)
    .pipe(z.number().min(min, `must be at least ${min}`).max(max, `must be at most ${max}`))
    // Used as it is when the parameter is absent, without being parsed again.
    .default(defaultValue);
}

// GET /admin/users. With no query at all, it lists the first page of pending requests,
// which is what an admin opens the screen to do (FR-12).
export const listUsersQuerySchema = z
  .object({
    status: z.enum(ACCOUNT_STATUSES, { error: 'must be pending, active, suspended, rejected or invited' }).default('pending'),
    limit: wholeNumber({ min: 1, max: LIST_LIMIT_MAX, defaultValue: LIST_LIMIT_DEFAULT }),
    offset: wholeNumber({ min: 0, max: LIST_OFFSET_MAX, defaultValue: 0 }),
  })
  .strict();

// Reject and suspend. The reason is shown to administrators and copied into the
// append-only audit log, so it is trimmed and must say something. Length is counted as
// JavaScript does (UTF-16 units), so an emoji counts as 2; that only matters at the limit.
// .strict(): a stray field such as status or role is refused, so nothing but the reason
// can reach the update.
export const reasonBodySchema = z
  .object({
    reason: z
      .string()
      .trim()
      .min(REASON_MIN_LENGTH, `must be at least ${REASON_MIN_LENGTH} characters`)
      .max(REASON_MAX_LENGTH, `must be at most ${REASON_MAX_LENGTH} characters`),
  })
  .strict();

// POST /admin/users: an administrator creates an officer or administrator account (FR-10).
// The same username and full-name rules as registration. No password: the person chooses
// their own with the activation code. No licence number: officers and administrators hold
// none. .strict(): a stray field such as status or password is refused, not ignored.
export const createUserBodySchema = z
  .object({
    username: usernameSchema,
    fullName: fullNameSchema,
    role: z.enum(CREATABLE_ROLES, { error: 'must be officer or admin' }),
  })
  .strict();

// Approve and reactivate take no input. .optional(): Express 5 leaves req.body undefined
// when no body is sent, and a plain POST with no body is the normal way to call these.
// A body that is sent must be empty, so a field like reason or status is refused rather
// than silently ignored.
export const emptyBodySchema = z.object({}).strict().optional();
