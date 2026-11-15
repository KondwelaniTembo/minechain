import { z } from 'zod';
import { ALERT_TYPES } from '../services/anomalyChecks.js';
import {
  LIST_LIMIT_DEFAULT,
  LIST_LIMIT_MAX,
  LIST_OFFSET_MAX,
  REASON_MIN_LENGTH,
  REASON_MAX_LENGTH,
  wholeNumber,
} from './adminUsers.js';

// The three statuses, exactly as the alerts_status_valid CHECK in the alerts migration allows.
// reviewed: an officer confirmed the problem. dismissed: an officer cleared it as no problem.
export const ALERT_STATUSES = Object.freeze(['open', 'reviewed', 'dismissed']);

// Case notes follow the reason rules (plan §2, decided 15 Nov 2026): they are copied into the
// append-only audit log like a reason, so the same limits apply and are kept in one place.
export const NOTES_MIN_LENGTH = REASON_MIN_LENGTH;
export const NOTES_MAX_LENGTH = REASON_MAX_LENGTH;

// :id in /alerts/:id and the like. Checked before any SQL, as for users and zones: a malformed
// uuid would otherwise be PostgreSQL error 22P02 and surface as a 500.
export const alertIdParamsSchema = z
  .object({
    id: z.uuid({ error: 'must be a valid alert id' }),
  })
  .strict();

// GET /alerts. With no query at all, it lists the first page of open alerts, oldest first:
// the officer's review queue. The type comes from the anomaly checks' own list, so a type
// added there is accepted here without a second list to forget. Paging follows GET /admin/users.
export const listAlertsQuerySchema = z
  .object({
    status: z.enum(ALERT_STATUSES, { error: 'must be open, reviewed or dismissed' }).default('open'),
    type: z.enum(ALERT_TYPES, { error: `must be one of ${ALERT_TYPES.join(', ')}` }).optional(),
    limit: wholeNumber({ min: 1, max: LIST_LIMIT_MAX, defaultValue: LIST_LIMIT_DEFAULT }),
    offset: wholeNumber({ min: 0, max: LIST_OFFSET_MAX, defaultValue: 0 }),
  })
  .strict();

// POST /alerts/:id/review and /dismiss (B1.3). Trimmed, so notes of only spaces are refused
// here as well as by the alerts_review_fields_match_status CHECK. trim() removes surrounding
// spaces and line breaks only; line breaks inside the notes are kept. .strict(): a stray field
// such as status or reviewedBy is refused, so nothing but the notes can reach the update.
export const notesBodySchema = z
  .object({
    notes: z
      .string()
      .trim()
      .min(NOTES_MIN_LENGTH, `must be at least ${NOTES_MIN_LENGTH} characters`)
      .max(NOTES_MAX_LENGTH, `must be at most ${NOTES_MAX_LENGTH} characters`),
  })
  .strict();
