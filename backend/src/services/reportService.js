import { AppError } from '../errors.js';
import { utcDayRange } from '../schemas/reports.js';
import { mgToKg } from './units.js';

// Spreadsheet reports: the transactions report (FR-09) and the audit trail (FR-13). This
// service reads the rows and records the export; it returns { columns, rows, filename },
// and the route turns that into CSV with toCsv (csv.js).
//
// Rules shared by both reports:
//   - Fixed SQL with every value as a $n parameter. An optional filter is a fixed fragment
//     "($n::type IS NULL OR column = $n)", so one statement covers every combination and
//     no SQL is ever built from strings.
//   - Never selected: password_hash, public_key, signer_public_key, signature,
//     signed_payload, actor_ref, full_name, ip_address, and the internal anchoring columns
//     (anchor_error, anchor_nonce, anchor_attempts). Each SELECT lists its columns, so a
//     column added to a table later cannot appear in a report by accident.
//   - The rows and the audit entry are read and written in ONE transaction at REPEATABLE
//     READ: every query sees the same snapshot, and if the audit entry cannot be written,
//     nothing is returned, so an export is never sent without its record.
//   - At most rowLimit rows. The query asks for one more; if it comes back, the export is
//     refused with 422 REPORT_TOO_LARGE rather than cut short, because a truncated report
//     handed to the regulator would look complete. Refused exports are not audited.

export const REPORT_ROW_LIMIT = 10_000;

// Who may export each report. The routes check the same (R3); this is the second line.
const TRANSACTION_REPORT_ROLES = Object.freeze(['officer', 'admin', 'buyer']);
const AUDIT_TRAIL_ROLES = Object.freeze(['officer']);

// An actor's account events in their audit trail: status and key changes. Logins and failed
// logins are left out: they are frequent session events, not changes to the account, and
// without their IP addresses (never exported) they say little.
export const ACCOUNT_EVENT_ACTIONS = Object.freeze([
  'user.create',
  'user.register',
  'user.approve',
  'user.reject',
  'user.suspend',
  'user.reactivate',
  'user.key_register',
  'user.key_reset',
]);

// Steps a buyer may see: accepted ones only (passed, cleared). Flagged and rejected steps
// are unreviewed or refused evidence, for officers.
const ACCEPTED = "('passed', 'cleared')";

// ---------- transactions report (FR-09) ----------

// One row per custody step, in the order the steps were recorded: by captured_at, the
// phone's time. Equal capture times happen (phone clocks set by hand, two steps in the same
// millisecond), and then received_at decides, which follows custody order since sync sets it
// with clock_timestamp() (decisions log, 9 Nov). id, a random uuid, is only the last resort,
// so the order is still fixed when both times are equal.
//   $1, $2  captured_at range [start, endExclusive), from utcDayRange
//   $3..$8  optional filters: mineral, actor, zone, step type, review status, anchor status
//   $9      the buyer's id for the buyer limit, or NULL for officers and admins
//   $10     rowLimit + 1
// The chain columns are shown only for confirmed steps: a submitted step's hash is not final
// (it can still be dropped and replaced). Hashes are written as 0x-prefixed hex in SQL.
const TRANSACTIONS_REPORT = `
  SELECT t.id AS step_id,
         c.id AS consignment_id,
         c.qr_code,
         c.mineral_type AS mineral,
         c.stage AS consignment_stage,
         t.type AS step_type,
         u.username AS actor_username,
         u.role AS actor_role,
         u.licence_number AS actor_licence_number,
         t.weight_mg,
         t.latitude,
         t.longitude,
         z.name AS zone_name,
         z.licence_number AS zone_licence_number,
         t.captured_at AS captured_at_utc,
         t.received_at AS received_at_utc,
         t.review_status,
         t.anchor_status,
         CASE WHEN t.anchor_status = 'confirmed' THEN '0x' || encode(t.chain_tx_hash, 'hex') END AS chain_tx_hash,
         CASE WHEN t.anchor_status = 'confirmed' THEN t.block_number END AS block_number,
         CASE WHEN t.anchor_status = 'confirmed' THEN t.anchored_at END AS anchored_at_utc,
         '0x' || encode(t.data_hash, 'hex') AS data_hash
    FROM transactions t
    JOIN consignments c ON c.id = t.consignment_id
    JOIN users u ON u.id = t.actor_id
    LEFT JOIN gps_zones z ON z.id = t.zone_id
   WHERE t.captured_at >= $1 AND t.captured_at < $2
     AND ($3::text IS NULL OR c.mineral_type = $3)
     AND ($4::uuid IS NULL OR t.actor_id = $4)
     AND ($5::uuid IS NULL OR t.zone_id = $5)
     AND ($6::text IS NULL OR t.type = $6)
     AND ($7::text IS NULL OR t.review_status = $7)
     AND ($8::text IS NULL OR t.anchor_status = $8)
     -- The buyer limit: only accepted steps of consignments this buyer has an accepted
     -- purchase of. A buyer never sees another buyer's trade.
     AND ($9::uuid IS NULL OR (
           t.review_status IN ${ACCEPTED}
           AND EXISTS (SELECT 1
                         FROM transactions p
                        WHERE p.consignment_id = t.consignment_id
                          AND p.type = 'purchase'
                          AND p.actor_id = $9
                          AND p.review_status IN ${ACCEPTED})))
   ORDER BY t.captured_at, t.received_at, t.id
   LIMIT $10`;

// The file's columns, in order. key is the property each row carries (the same name).
export const TRANSACTION_COLUMNS = Object.freeze(
  [
    ['step_id', 'text'],
    ['consignment_id', 'text'],
    ['qr_code', 'text'],
    ['mineral', 'text'],
    ['consignment_stage', 'text'],
    ['step_type', 'text'],
    ['actor_username', 'text'],
    ['actor_role', 'text'],
    ['actor_licence_number', 'text'],
    ['weight_mg', 'number'],
    ['weight_kg', 'number'],
    ['latitude', 'number'],
    ['longitude', 'number'],
    ['zone_name', 'text'],
    ['zone_licence_number', 'text'],
    ['captured_at_utc', 'time'],
    ['received_at_utc', 'time'],
    ['review_status', 'text'],
    ['anchor_status', 'text'],
    ['chain_tx_hash', 'text'],
    ['block_number', 'number'],
    ['anchored_at_utc', 'time'],
    ['data_hash', 'text'],
  ].map(([header, kind]) => Object.freeze({ header, kind, key: header })),
);

// ---------- audit trail (FR-13) ----------

// One row per event, in time order, for one consignment ($1) or one actor ($2); the other is
// NULL and matches nothing. Events:
//   step_recorded    when the server received a step (received_at)
//   alert_raised     when an anomaly check raised an alert on it
//   step_anchored    when its anchoring transaction was mined (anchored_at, the block time)
//   alert_reviewed / alert_dismissed
//                    when an officer closed the alert (officer review is still to be built;
//                    the rows appear as soon as alerts are closed)
//   account_event    an actor's trail only: a status or key change from audit_logs ($5),
//                    never its IP address
// $3, $4: the event-time range [start, endExclusive) for an actor's trail, NULL for a
// consignment's. $6: rowLimit + 1.
// Ties in time are broken by a fixed event order, then by ids, so the order never varies.
const AUDIT_TRAIL = `
  WITH steps AS (
    SELECT t.id, t.consignment_id, t.actor_id, t.type, t.weight_mg, t.latitude, t.longitude,
           t.zone_id, t.captured_at, t.received_at, t.review_status, t.anchor_status,
           t.chain_tx_hash, t.block_number, t.anchored_at, t.data_hash
      FROM transactions t
     WHERE t.consignment_id = $1::uuid OR t.actor_id = $2::uuid
  ),
  events AS (
    SELECT s.received_at AS event_time, 'step_recorded' AS event, 1 AS event_rank,
           s.id AS step_id, NULL::uuid AS alert_id, NULL::bigint AS audit_id
      FROM steps s
    UNION ALL
    SELECT a.created_at, 'alert_raised', 2, a.transaction_id, a.id, NULL
      FROM alerts a JOIN steps s ON s.id = a.transaction_id
    UNION ALL
    SELECT s.anchored_at, 'step_anchored', 3, s.id, NULL, NULL
      FROM steps s
     WHERE s.anchor_status = 'confirmed'
    UNION ALL
    SELECT a.reviewed_at, CASE a.status WHEN 'reviewed' THEN 'alert_reviewed' ELSE 'alert_dismissed' END, 4,
           a.transaction_id, a.id, NULL
      FROM alerts a JOIN steps s ON s.id = a.transaction_id
     WHERE a.status <> 'open'
    UNION ALL
    SELECT l.occurred_at, 'account_event', 5, NULL, NULL, l.id
      FROM audit_logs l
     WHERE $2::uuid IS NOT NULL
       AND l.entity_type = 'user'
       AND l.entity_id = $2::uuid
       AND l.action = ANY ($5::text[])
  )
  SELECT e.event_time AS event_time_utc,
         e.event,
         c.id AS consignment_id,
         c.qr_code,
         c.mineral_type AS mineral,
         s.id AS step_id,
         s.type AS step_type,
         -- Who did it: the step's actor, or for an account event the person who made the
         -- change (an administrator, the user, or nobody for the seed).
         COALESCE(su.username, lu.username) AS actor_username,
         COALESCE(su.role, lu.role) AS actor_role,
         COALESCE(su.licence_number, lu.licence_number) AS actor_licence_number,
         s.weight_mg,
         s.latitude,
         s.longitude,
         z.name AS zone_name,
         s.captured_at AS captured_at_utc,
         s.review_status,
         a.id AS alert_id,
         a.type AS alert_type,
         a.severity AS alert_severity,
         a.status AS alert_status,
         a.details::text AS alert_details,
         ru.username AS reviewer_username,
         a.review_notes,
         CASE WHEN e.event = 'step_anchored' THEN '0x' || encode(s.chain_tx_hash, 'hex') END AS chain_tx_hash,
         CASE WHEN e.event = 'step_anchored' THEN s.block_number END AS block_number,
         CASE WHEN s.id IS NOT NULL THEN '0x' || encode(s.data_hash, 'hex') END AS data_hash,
         l.action AS account_action,
         l.details::text AS account_details
    FROM events e
    LEFT JOIN steps s ON s.id = e.step_id
    LEFT JOIN consignments c ON c.id = s.consignment_id
    LEFT JOIN users su ON su.id = s.actor_id
    LEFT JOIN gps_zones z ON z.id = s.zone_id
    LEFT JOIN alerts a ON a.id = e.alert_id
    LEFT JOIN users ru ON ru.id = a.reviewed_by
    LEFT JOIN audit_logs l ON l.id = e.audit_id
    LEFT JOIN users lu ON lu.id = l.actor_id
   WHERE $3::timestamptz IS NULL OR (e.event_time >= $3 AND e.event_time < $4::timestamptz)
   ORDER BY e.event_time, e.event_rank, e.step_id, e.alert_id, e.audit_id
   LIMIT $6`;

export const AUDIT_TRAIL_COLUMNS = Object.freeze(
  [
    ['event_time_utc', 'time'],
    ['event', 'text'],
    ['consignment_id', 'text'],
    ['qr_code', 'text'],
    ['mineral', 'text'],
    ['step_id', 'text'],
    ['step_type', 'text'],
    ['actor_username', 'text'],
    ['actor_role', 'text'],
    ['actor_licence_number', 'text'],
    ['weight_mg', 'number'],
    ['weight_kg', 'number'],
    ['latitude', 'number'],
    ['longitude', 'number'],
    ['zone_name', 'text'],
    ['captured_at_utc', 'time'],
    ['review_status', 'text'],
    ['alert_id', 'text'],
    ['alert_type', 'text'],
    ['alert_severity', 'text'],
    ['alert_status', 'text'],
    ['alert_details', 'text'],
    ['reviewer_username', 'text'],
    ['review_notes', 'text'],
    ['chain_tx_hash', 'text'],
    ['block_number', 'number'],
    ['data_hash', 'text'],
    ['account_action', 'text'],
    ['account_details', 'text'],
  ].map(([header, kind]) => Object.freeze({ header, kind, key: header })),
);

// A trail for something that does not exist is refused rather than given as an empty file,
// which would look like "nothing happened".
const CONSIGNMENT_EXISTS = 'SELECT 1 FROM consignments WHERE id = $1';
const USER_EXISTS = 'SELECT 1 FROM users WHERE id = $1';

// ---------- helpers ----------

const forbidden = () => new AppError(403, 'FORBIDDEN', 'You do not have permission to do this.');

// 10000 -> "10,000", without depending on the server's locale data.
const withThousands = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

// The SELECTed rows plus weight_kg, worked out from the exact milligram text (units.js).
const withKg = (row) => ({ ...row, weight_kg: row.weight_mg === null ? null : mgToKg(row.weight_mg) });

// Lower case, as PostgreSQL prints uuids, so filenames and audit entries use one spelling.
const normalizeId = (id) => (id === undefined ? undefined : id.toLowerCase());

// The validated query with ids in lower case, keeping only the filters that were given.
function normalizedFilters(query) {
  const filters = { ...query };
  for (const key of ['actorId', 'zoneId', 'consignmentId']) {
    if (filters[key] !== undefined) filters[key] = normalizeId(filters[key]);
  }
  return filters;
}

// Dependencies are passed in, so DB tests can give a failing audit service and a small row
// limit.
//   db:       the app's db object
//   audit:    the audit service (record)
//   rowLimit: the most rows an export may have
export function createReportService({ db, audit, rowLimit = REPORT_ROW_LIMIT }) {
  if (!Number.isSafeInteger(rowLimit) || rowLimit < 1) {
    throw new TypeError('rowLimit must be a whole number of 1 or more');
  }

  function tooLarge() {
    return new AppError(
      422,
      'REPORT_TOO_LARGE',
      `This report has more than ${withThousands(rowLimit)} rows. Choose a shorter date range or add a filter.`,
    );
  }

  // Runs one export: the SELECTs (inside read), the cap, then the audit entry, all in one
  // REPEATABLE READ transaction. Throwing anywhere rolls it all back and returns nothing.
  function exportRows({ read, auditEntry }) {
    return db.transaction(
      async (tx) => {
        const rows = await read(tx);
        if (rows.length > rowLimit) throw tooLarge();
        await audit.record(tx, auditEntry(rows.length));
        return rows;
      },
      { isolation: 'repeatable read' },
    );
  }

  return {
    // query: already passed transactionsReportQuerySchema. requester: req.user ({ id, role }).
    async transactions(query, requester, { ipAddress = null } = {}) {
      if (!TRANSACTION_REPORT_ROLES.includes(requester.role)) throw forbidden();

      const filters = normalizedFilters(query);
      const { start, endExclusive } = utcDayRange(filters);
      const buyerId = requester.role === 'buyer' ? requester.id : null;
      const params = [
        start,
        endExclusive,
        filters.mineral ?? null,
        filters.actorId ?? null,
        filters.zoneId ?? null,
        filters.type ?? null,
        filters.reviewStatus ?? null,
        filters.anchorStatus ?? null,
        buyerId,
        rowLimit + 1,
      ];

      const rows = await exportRows({
        read: async (tx) => (await tx.query(TRANSACTIONS_REPORT, params)).rows,
        auditEntry: (rowCount) => ({
          action: 'report.transactions_export',
          actorId: requester.id,
          // scope says whether the buyer limit applied, so the entry alone tells what the
          // requester could see.
          details: { filters, scope: buyerId ? 'own_purchases' : 'all', rowCount },
          ipAddress,
        }),
      });

      return {
        columns: TRANSACTION_COLUMNS,
        rows: rows.map(withKg),
        filename: `minechain-transactions-${filters.from}-to-${filters.to}.csv`,
      };
    },

    // query: already passed auditTrailQuerySchema (exactly one of consignmentId, actorId).
    // Officers only (FR-13).
    async auditTrail(query, requester, { ipAddress = null } = {}) {
      if (!AUDIT_TRAIL_ROLES.includes(requester.role)) throw forbidden();

      const filters = normalizedFilters(query);
      const byConsignment = filters.consignmentId !== undefined;
      const range = byConsignment ? null : utcDayRange(filters);
      const params = [
        filters.consignmentId ?? null,
        filters.actorId ?? null,
        range?.start ?? null,
        range?.endExclusive ?? null,
        ACCOUNT_EVENT_ACTIONS,
        rowLimit + 1,
      ];

      const rows = await exportRows({
        read: async (tx) => {
          const { rows: found } = byConsignment
            ? await tx.query(CONSIGNMENT_EXISTS, [filters.consignmentId])
            : await tx.query(USER_EXISTS, [filters.actorId]);
          if (found.length === 0) {
            throw byConsignment
              ? new AppError(404, 'CONSIGNMENT_NOT_FOUND', 'No consignment has this id.')
              : new AppError(404, 'USER_NOT_FOUND', 'No user has this id.');
          }
          return (await tx.query(AUDIT_TRAIL, params)).rows;
        },
        auditEntry: (rowCount) => ({
          action: 'report.audit_trail_export',
          actorId: requester.id,
          entityType: byConsignment ? 'consignment' : 'user',
          entityId: byConsignment ? filters.consignmentId : filters.actorId,
          details: { filters, rowCount },
          ipAddress,
        }),
      });

      return {
        columns: AUDIT_TRAIL_COLUMNS,
        rows: rows.map(withKg),
        filename: byConsignment
          ? `minechain-audit-trail-consignment-${filters.consignmentId}.csv`
          : `minechain-audit-trail-user-${filters.actorId}-${filters.from}-to-${filters.to}.csv`,
      };
    },
  };
}
