import { AppError } from '../errors.js';
import { HELD } from './anchorQueue.js';

// The officer's view of anomaly alerts (FR-08; decisions.md Scope (2) and (5)). This file is
// the read side (plan B1.1); closing an alert comes in B1.2. Alerts are created by sync and,
// later, by verification; nothing here changes how they are raised.
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

// db: the app's db object. The audit service is added with the close actions in B1.2, which
// write their entry in the same transaction; reads are not audited.
export function createAlertService({ db }) {
  return {
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
