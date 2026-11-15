import { AppError } from '../errors.js';
import { HELD } from './anchorQueue.js';
import { stageAfter } from './custodyRules.js';
import { withArticle } from './wording.js';

// The officer's view of anomaly alerts (FR-08; decisions.md Scope (2) and (5)), and the two
// ways an officer closes one: "Confirm problem" (review) and "Clear, no problem" (dismiss).
// Alerts are created by sync and, later, by verification; nothing here changes how they are
// raised.
//
// What an officer sees is limited on purpose: ids, the step's type, states and times, the
// consignment's identity and whether it is held, the actor's username and role, and the
// review. Never a full name, a key, a signature, a signed payload or GPS coordinates: those
// belong to the consignment view, which has its own rules. Each statement lists its columns,
// so a column added to a table later cannot reach this view by accident.

// The columns of one alert row with its step, consignment, actor and reviewer, written out
// once. `held` is the queue's own rule (HELD in anchorQueue.js), not a copy, so this view and
// the anchoring worker always agree on which consignments wait for an officer. HELD uses its
// own aliases (a, held) inside its subquery, so the outer aliases here are kept different.
const ALERT_COLUMNS = `
  al.id, al.type, al.severity, al.status, al.details, al.created_at,
  al.reviewed_by, al.review_notes, al.reviewed_at,
  t.id AS step_id, t.type AS step_type, t.review_status, t.anchor_status,
  t.captured_at, t.received_at,
  c.id AS consignment_id, c.qr_code, c.mineral_type, c.stage,
  ${HELD('c.id')} AS held,
  u.id AS actor_id, u.username AS actor_username, u.role AS actor_role,
  ru.username AS reviewer_username`;

const ALERT_FROM = `
  FROM alerts al
  JOIN transactions t ON t.id = al.transaction_id
  JOIN consignments c ON c.id = t.consignment_id
  JOIN users u ON u.id = t.actor_id
  LEFT JOIN users ru ON ru.id = al.reviewed_by`;

// $2 is the optional type filter: NULL matches every type. A parameter, never text joined
// into the SQL.
const FILTER = 'al.status = $1 AND ($2::text IS NULL OR al.type = $2)';

// Two fixed statements, chosen by the status, because the order differs:
//   open: oldest first, the queue an officer works through. (created_at, id) matches
//         alerts_open_queue_idx, the partial index on created_at for open alerts; id only
//         breaks a tie in time, the same way every time.
//   reviewed or dismissed: newest decision first, what an officer looks back at.
const LIST_OPEN = `
  SELECT ${ALERT_COLUMNS}
  ${ALERT_FROM}
  WHERE ${FILTER}
  ORDER BY al.created_at, al.id
  LIMIT $3 OFFSET $4`;

const LIST_CLOSED = `
  SELECT ${ALERT_COLUMNS}
  ${ALERT_FROM}
  WHERE ${FILTER}
  ORDER BY al.reviewed_at DESC, al.id
  LIMIT $3 OFFSET $4`;

const COUNT_ALERTS = `SELECT count(*)::int AS total FROM alerts al WHERE ${FILTER}`;

const GET_ALERT = `
  SELECT ${ALERT_COLUMNS}
  ${ALERT_FROM}
  WHERE al.id = $1`;

// The other alerts on the same consignment, on any of its steps, so an officer deciding one
// alert sees what else is waiting (closing one does not release the hold while another is
// open). The same order as the open queue.
const OTHER_ALERTS = `
  SELECT o.id, o.type, o.severity, o.status, o.transaction_id, o.created_at
  FROM alerts o
  JOIN transactions ot ON ot.id = o.transaction_id
  WHERE ot.consignment_id = $1 AND o.id <> $2
  ORDER BY o.created_at, o.id`;

// ---------- closing an alert (plan B1.2) ----------

// Which consignment the alert belongs to, read without a lock, only to know which consignment
// to lock first. Everything that decides is read again under the locks below.
const FIND_CONSIGNMENT = `
  SELECT t.consignment_id
  FROM alerts al
  JOIN transactions t ON t.id = al.transaction_id
  WHERE al.id = $1`;

// The lock order, always the same: consignment, then the alert, then the step's alerts and
// the step. Sync takes the consignment lock first too (LOCK_CONSIGNMENT in syncService), so
// a close and a sync on one consignment wait for each other instead of deadlocking.
const LOCK_CONSIGNMENT = 'SELECT id, stage FROM consignments WHERE id = $1 FOR UPDATE';

// The reviewer, read in the closing transaction. FOR SHARE: an administrator suspending this
// officer at the same moment waits until the decision is saved, so a decision is never made
// by an account that was already suspended when it was written. Taken before the consignment
// lock, the same order sync uses (the user's key FOR SHARE, then the consignment).
const LOCK_REVIEWER = 'SELECT role, status FROM users WHERE id = $1 FOR SHARE';
const LOCK_ALERT = 'SELECT id, transaction_id, type, status FROM alerts WHERE id = $1 FOR UPDATE';
// ORDER BY id: two closes on one step take these locks in the same order. The alert being
// closed is already locked by this transaction, so locking it again here never waits.
const LOCK_STEP_ALERTS = 'SELECT id, type, status FROM alerts WHERE transaction_id = $1 ORDER BY id FOR UPDATE';
const LOCK_STEP = 'SELECT id, consignment_id, type, review_status FROM transactions WHERE id = $1 FOR UPDATE';

// Another accepted step of this type on the consignment. Only one accepted registration and
// one accepted purchase are allowed (the partial unique indexes on transactions), so clearing
// a second one would fail; it is refused with a clear answer first. Read under the
// consignment lock, which every step insert also takes, so no new step can appear meanwhile.
const OTHER_ACCEPTED = `
  SELECT EXISTS (
    SELECT 1 FROM transactions
     WHERE consignment_id = $1 AND type = $2 AND id <> $3
       AND review_status IN ('passed', 'cleared')) AS found`;

// The decision itself. reviewed_at is clock_timestamp(), the time of this statement: now()
// would be when the transaction began, which can be earlier than the alert's own created_at
// (database-schema.md, two clocks). WHERE status = 'open' repeats the check made under the
// lock, so the statement can never close an alert twice.
const CLOSE_ALERT = `
  UPDATE alerts
     SET status = $2, reviewed_by = $3, review_notes = $4, reviewed_at = clock_timestamp()
   WHERE id = $1 AND status = 'open'`;

// Only a flagged step changes: one already rejected stays rejected, and the CHECK
// transactions_anchor_only_if_approved would refuse rejecting a step that was sent.
const SET_STEP_STATUS = `
  UPDATE transactions SET review_status = $2
   WHERE id = $1 AND review_status = 'flagged'`;

const SET_STAGE = 'UPDATE consignments SET stage = $2 WHERE id = $1';

// The two actions. status: what the alert becomes. verb: for the 409 message, "Only an open
// alert can be reviewed."
const CLOSE_ACTIONS = Object.freeze({
  review: Object.freeze({ status: 'reviewed', verb: 'reviewed', audit: 'alert.review' }),
  dismiss: Object.freeze({ status: 'dismissed', verb: 'dismissed', audit: 'alert.dismiss' }),
});

// The step's review status worked out from the statuses of ALL its alerts (plan §1, decided
// 15 Nov 2026): any reviewed -> rejected; every one dismissed -> cleared; otherwise (some
// still open, none reviewed) it stays flagged. A rejection is final, so dismissing another
// alert on the same step later cannot overturn it. For a step with one alert this is exactly
// Scope (5): review -> rejected, dismiss -> cleared.
// Pure, so every combination can be tested without a database.
export function stepStatusFromAlerts(statuses) {
  if (!Array.isArray(statuses) || statuses.length === 0) {
    throw new TypeError('statuses must list the status of every alert on the step');
  }
  if (statuses.includes('reviewed')) return 'rejected';
  if (statuses.every((status) => status === 'dismissed')) return 'cleared';
  return 'flagged';
}

// The three steps that can never be cleared (plan §1, decided 15 Nov 2026), one fixed message
// each. The officer can still confirm the problem.
export const NOT_CLEARABLE_MESSAGES = Object.freeze({
  duplicateRegistration:
    'This step cannot be cleared: the consignment already has an accepted registration. Confirm the problem instead.',
  secondPurchase:
    'This step cannot be cleared: the consignment already has an accepted purchase. Confirm the problem instead.',
  afterPurchase:
    'This step cannot be cleared: it was recorded after the consignment was purchased, and nothing can follow a purchase on the blockchain. Confirm the problem instead.',
});

// The same answer requireRole gives, so a caller cannot tell which check refused it.
function forbidden() {
  return new AppError(403, 'FORBIDDEN', 'You do not have permission to do this.');
}

function notClearable(message) {
  return new AppError(409, 'STEP_CANNOT_BE_CLEARED', message);
}

// snake_case columns to the API's camelCase, built field by field.
function toAlert(row) {
  return {
    id: row.id,
    type: row.type,
    severity: row.severity,
    status: row.status,
    // As stored by the anomaly checks: ids, weights as text, a zone name, never a person's
    // name (database-schema.md, details per alert type).
    details: row.details,
    createdAt: row.created_at,
    step: {
      id: row.step_id,
      type: row.step_type,
      reviewStatus: row.review_status,
      anchorStatus: row.anchor_status,
      capturedAt: row.captured_at,
      receivedAt: row.received_at,
    },
    consignment: {
      id: row.consignment_id,
      qrCode: row.qr_code,
      mineral: row.mineral_type,
      stage: row.stage,
      held: row.held,
    },
    actor: { id: row.actor_id, username: row.actor_username, role: row.actor_role },
    // An open alert has no review fields (alerts_review_fields_match_status), so null.
    review:
      row.status === 'open'
        ? null
        : { by: { id: row.reviewed_by, username: row.reviewer_username }, notes: row.review_notes, at: row.reviewed_at },
  };
}

function toOtherAlert(row) {
  return {
    id: row.id,
    type: row.type,
    severity: row.severity,
    status: row.status,
    stepId: row.transaction_id,
    createdAt: row.created_at,
  };
}

// PostgreSQL compares uuids ignoring letter case; one spelling keeps later comparisons and
// audit entries simple.
const normalizeId = (id) => id.toLowerCase();

function alertNotFound() {
  return new AppError(404, 'ALERT_NOT_FOUND', 'No alert has this id.');
}

// Dependencies are passed in, so DB tests can give a failing audit service to prove the
// decision and its entry are saved together. Reads are not audited.
//   db:    the app's db object
//   audit: the audit service (record)
export function createAlertService({ db, audit }) {
  // Why a dismissal would leave a step that can never be accepted, or null. Checked before
  // anything is written; the transaction then rolls back with nothing changed.
  async function clearRefusal(tx, alert, step) {
    if (alert.type === 'handoff_order') return notClearable(NOT_CLEARABLE_MESSAGES.afterPurchase);
    if (step.type === 'registration' || step.type === 'purchase') {
      const { rows } = await tx.query(OTHER_ACCEPTED, [step.consignment_id, step.type, step.id]);
      if (rows[0].found) {
        return notClearable(
          step.type === 'registration' ? NOT_CLEARABLE_MESSAGES.duplicateRegistration : NOT_CLEARABLE_MESSAGES.secondPurchase,
        );
      }
    }
    return null;
  }

  // One function for both actions (plan §2, "The close transaction"). The decision, the step
  // and stage it changes, and the audit entry are saved together or not at all.
  function close(action, { alertId, officerId, notes, ipAddress = null }) {
    const id = normalizeId(alertId);
    const { status: newStatus, verb, audit: auditAction } = CLOSE_ACTIONS[action];

    return db.transaction(async (tx) => {
      // 1. Which consignment to lock.
      const { rows: found } = await tx.query(FIND_CONSIGNMENT, [id]);
      if (found.length === 0) throw alertNotFound();

      // Only an active officer may decide an alert (database-schema.md, rules enforced by the
      // service; Scope (5): administrators never close alerts). The route's guard checks this
      // too; repeating it here covers every other caller. After the 404, so an unknown alert
      // is reported as unknown whoever asks, and before any write.
      const { rows: reviewers } = await tx.query(LOCK_REVIEWER, [officerId]);
      const reviewer = reviewers[0];
      if (!reviewer || reviewer.role !== 'officer' || reviewer.status !== 'active') throw forbidden();

      // 2-3. The locks, in the fixed order. An alert's step never changes, so the
      // consignment found above is still the right one.
      const { rows: consignments } = await tx.query(LOCK_CONSIGNMENT, [found[0].consignment_id]);
      const consignment = consignments[0];
      const { rows: alertRows } = await tx.query(LOCK_ALERT, [id]);
      const alert = alertRows[0];
      // A second officer who waited for the lock now sees the first one's decision.
      if (alert.status !== 'open') {
        throw new AppError(
          409,
          'INVALID_STATUS_TRANSITION',
          `Only ${withArticle('open')} alert can be ${verb}. This alert is ${alert.status}.`,
        );
      }
      const { rows: stepAlerts } = await tx.query(LOCK_STEP_ALERTS, [alert.transaction_id]);
      const { rows: steps } = await tx.query(LOCK_STEP, [alert.transaction_id]);
      const step = steps[0];

      // 4. Dismiss only: a step that could never be accepted is refused before any write.
      if (action === 'dismiss') {
        const refusal = await clearRefusal(tx, alert, step);
        if (refusal) throw refusal;
      }

      // 5. The decision.
      await tx.query(CLOSE_ALERT, [id, newStatus, officerId, notes]);

      // 6. The step's status from all its sync-time alerts, and the stage if it was cleared.
      // A record_tampered alert sits on a step that is already on the blockchain: its
      // review_status cannot change (transactions_anchor_only_if_approved), so it is left
      // alone, and the alert's own status is the whole decision (plan §6, Q3).
      let stepStatus = null;
      let stage = null;
      if (alert.type !== 'record_tampered') {
        const statuses = stepAlerts
          .filter((a) => a.type !== 'record_tampered')
          .map((a) => (a.id === id ? newStatus : a.status));
        const derived = stepStatusFromAlerts(statuses);
        if (derived !== step.review_status) {
          const { rowCount } = await tx.query(SET_STEP_STATUS, [step.id, derived]);
          if (rowCount === 1) stepStatus = { from: step.review_status, to: derived };
        }
        // A cleared step counts as accepted from now on, so it moves the consignment as a
        // passed step would have at sync: forward only, a relay leaves it alone.
        if (stepStatus?.to === 'cleared') {
          const next = stageAfter(step.type, consignment.stage);
          if (next !== null) {
            await tx.query(SET_STAGE, [consignment.id, next]);
            stage = { from: consignment.stage, to: next };
          }
        }
      }

      // 7. The audit entry, in the same transaction. The notes are copied into the
      // append-only log, where they can never be changed or removed.
      await audit.record(tx, {
        action: auditAction,
        actorId: officerId,
        entityType: 'alert',
        entityId: id,
        details: { notes, alertType: alert.type, transactionId: step.id, stepStatus, stage },
        ipAddress,
      });

      // The answer, read after the writes in this transaction, so held already reflects them.
      const { rows: viewRows } = await tx.query(GET_ALERT, [id]);
      const view = toAlert(viewRows[0]);
      return {
        alert: view,
        step: { id: view.step.id, reviewStatus: view.step.reviewStatus },
        consignment: { id: view.consignment.id, stage: view.consignment.stage, held: view.consignment.held },
      };
    });
  }

  return {
    // "Confirm problem": the alert becomes reviewed and its step rejected.
    review(input) {
      return close('review', input);
    },

    // "Clear, no problem": the alert becomes dismissed, and its step cleared once none of the
    // step's alerts is open or reviewed. The hold is released when no other alert on the
    // consignment is open (HELD is worked out, never stored).
    dismiss(input) {
      return close('dismiss', input);
    },

    // input has already passed listAlertsQuerySchema, so status is one of the three, type is
    // one of the six or absent, and limit and offset are capped.
    // The page and its total are read in one REPEATABLE READ snapshot, so the total always
    // counts the same alerts the page was taken from, even while sync adds new ones.
    list({ status, type = null, limit, offset }) {
      const sql = status === 'open' ? LIST_OPEN : LIST_CLOSED;
      return db.transaction(
        async (tx) => {
          const { rows } = await tx.query(sql, [status, type, limit, offset]);
          const { rows: countRows } = await tx.query(COUNT_ALERTS, [status, type]);
          return { alerts: rows.map(toAlert), total: countRows[0].total, limit, offset };
        },
        { isolation: 'repeatable read' },
      );
    },

    // One alert with the consignment's other alerts, from one snapshot. id has passed
    // alertIdParamsSchema, so it is a uuid.
    get(alertId) {
      const id = normalizeId(alertId);
      return db.transaction(
        async (tx) => {
          const { rows } = await tx.query(GET_ALERT, [id]);
          if (rows.length === 0) throw alertNotFound();
          const alert = toAlert(rows[0]);
          const { rows: others } = await tx.query(OTHER_ALERTS, [alert.consignment.id, id]);
          return { ...alert, otherAlerts: others.map(toOtherAlert) };
        },
        { isolation: 'repeatable read' },
      );
    },
  };
}
