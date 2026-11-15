import { AppError } from '../errors.js';
import { HELD, isConsignmentHeld } from './anchorQueue.js';
import { checkStep } from './chainCheck.js';
import { canSeeConsignment, discloseConsignment } from './consignmentDisclosure.js';

// The consignment view (FR-04; plan §3, B2.4): one scan by a transporter, buyer or officer
// returns the consignment, its steps and a live chain check per confirmed step, cut down to
// what that role may see (consignmentDisclosure.js).
//
// Three phases, so no database transaction is ever open while the chain is asked:
//   1. read  one REPEATABLE READ snapshot: the consignment, its steps, the facts; committed
//   2. check checkStep per step, at most CHECK_PARALLELISM at once, with no transaction open
//   3. write only when a step mismatched: one short transaction raises record_tampered
//            alerts and re-reads held
// Every statement lists its columns, so a column added to a table later cannot reach the
// disclosure function, which also copies field by field.

// Receipts asked for at once. Each view costs about one RPC call per confirmed step, and a
// free RPC plan refuses bursts; three keeps a five-step consignment well inside 10 s.
export const CHECK_PARALLELISM = 3;

// The consignment and the facts about this viewer, in one statement. $2 is the viewer's id.
// HELD is the anchoring queue's own rule, so the view and the worker agree on "held".
// has_own_handoff counts any stored handoff, whatever its review status (B2.3 reading).
const SELECT_CONSIGNMENT = `
  SELECT c.id, c.qr_code, c.mineral_type, c.stage,
         ${HELD('c.id')} AS held,
         EXISTS (SELECT 1 FROM transactions p
                  WHERE p.consignment_id = c.id AND p.type = 'purchase' AND p.actor_id = $2
                    AND p.review_status IN ('passed', 'cleared')) AS has_accepted_purchase,
         EXISTS (SELECT 1 FROM transactions h
                  WHERE h.consignment_id = c.id AND h.type = 'handoff' AND h.actor_id = $2) AS has_own_handoff
  FROM consignments c
  WHERE c.qr_code = $1`;

// captured_at as text, so the chain check compares it with the signed text exactly. pg's
// Date keeps only milliseconds, so a one-microsecond edit would be invisible. A stored time
// that is a whole millisecond prints exactly as the payload writes it; any other prints
// six fraction digits, which can never equal a payload's three.
const CAPTURED_AT_TEXT = `
  CASE WHEN date_trunc('milliseconds', t.captured_at) = t.captured_at
       THEN to_char(t.captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
       ELSE to_char(t.captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  END`;

// Every step, in custody order: received_at, then id to break a tie the same way every time
// (the order the worker anchors in). chain_id and actor_ref are joined as the anchoring queue
// joins them (anchorQueue.js STEP_COLUMNS), for the event comparison.
const SELECT_STEPS = `
  SELECT t.id, t.type, t.actor_id, u.role AS actor_role, u.username AS actor_username,
         t.idempotency_key, c.qr_code, c.mineral_type, t.weight_mg, t.latitude, t.longitude,
         z.name AS zone_name,
         ${CAPTURED_AT_TEXT} AS captured_at,
         t.received_at, t.signed_payload, t.signature, t.signer_public_key, t.data_hash,
         t.hash_version, t.review_status, t.anchor_status, t.chain_tx_hash, t.block_number,
         c.chain_id, u.actor_ref
  FROM transactions t
  JOIN consignments c ON c.id = t.consignment_id
  JOIN users u ON u.id = t.actor_id
  LEFT JOIN gps_zones z ON z.id = t.zone_id
  WHERE t.consignment_id = $1
  ORDER BY t.received_at, t.id`;

// Officers only: every alert on the consignment's steps, as id, type and status.
const SELECT_ALERTS = `
  SELECT a.id, a.type, a.status, a.transaction_id
  FROM alerts a
  JOIN transactions t ON t.id = a.transaction_id
  WHERE t.consignment_id = $1
  ORDER BY a.created_at, a.id`;

// The same lock sync and an officer's close take first, so the three wait for each other
// instead of deadlocking.
const LOCK_CONSIGNMENT = 'SELECT id FROM consignments WHERE id = $1 FOR UPDATE';

// One per mismatched step. The unique (step, type) constraint makes a second view raise
// nothing new: only one record_tampered alert per step, ever (plan §6, known limit).
// created_at is clock_timestamp(), the two-clocks rule in database-schema.md.
const INSERT_TAMPERED = `
  INSERT INTO alerts (transaction_id, type, severity, details, created_at)
  VALUES ($1, 'record_tampered', 'high', $2, clock_timestamp())
  ON CONFLICT ON CONSTRAINT alerts_one_per_rule_per_step DO NOTHING`;

// One answer for an unknown code and for a consignment this viewer may not see, so a scan
// cannot tell the two apart.
const notFound = () => new AppError(404, 'CONSIGNMENT_NOT_FOUND', 'No consignment has this QR code.');

const hex = (bytes) => `0x${Buffer.from(bytes).toString('hex')}`;

// fn over items, at most `limit` running at once, results in the items' order.
export async function mapWithLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
  return results;
}

// db: the app's db object. chainReader: the key-free reader (B2.1) or null.
// confirmations: config.anchor.confirmations, for the "missing receipt" rule (B2.2 step 4).
export function createConsignmentService({ db, chainReader = null, confirmations }) {
  async function read(viewer, qrCode) {
    return db.transaction(
      async (tx) => {
        const { rows } = await tx.query(SELECT_CONSIGNMENT, [qrCode, viewer.id]);
        if (rows.length === 0) return null;
        const consignment = rows[0];
        const { rows: steps } = await tx.query(SELECT_STEPS, [consignment.id]);
        const { rows: alerts } = viewer.role === 'officer' ? await tx.query(SELECT_ALERTS, [consignment.id]) : { rows: [] };
        return { consignment, steps, alerts };
      },
      { isolation: 'repeatable read' },
    );
  }

  // The alerts for every mismatched step, then held as it is now (and, for an officer, the
  // alerts again, so the new one shows), in one short transaction.
  async function raiseTampered(viewer, consignmentId, mismatched) {
    return db.transaction(async (tx) => {
      await tx.query(LOCK_CONSIGNMENT, [consignmentId]);
      for (const { step, check } of mismatched) {
        const details = { source: 'verification', fields: check.fields, chainTxHash: hex(step.chain_tx_hash) };
        await tx.query(INSERT_TAMPERED, [step.id, JSON.stringify(details)]);
      }
      const held = await isConsignmentHeld(tx, consignmentId);
      const alerts = viewer.role === 'officer' ? (await tx.query(SELECT_ALERTS, [consignmentId])).rows : null;
      return { held, alerts };
    });
  }

  return {
    // viewer: { id, role } from requireAuth. Returns the disclosed body, or throws 404.
    async viewByQr(viewer, qrCode) {
      const snapshot = await read(viewer, qrCode);
      if (!snapshot) throw notFound();
      const { consignment, steps } = snapshot;
      let { alerts } = snapshot;

      const facts = {
        held: consignment.held,
        hasAcceptedPurchase: consignment.has_accepted_purchase,
        hasOwnHandoff: consignment.has_own_handoff,
        checks: new Map(),
        alerts: new Map(),
      };
      // Who may see it does not depend on the chain, so a refused viewer costs no RPC call
      // and raises nothing.
      if (!canSeeConsignment(viewer, consignment, facts)) throw notFound();

      // Phase 2: the chain, with no transaction open (read() has committed).
      const checks = await mapWithLimit(steps, CHECK_PARALLELISM, (step) => checkStep(chainReader, step, { confirmations }));
      steps.forEach((step, i) => facts.checks.set(step.id, checks[i]));

      // Phase 3: whoever is viewing, a mismatch raises the alert and holds the consignment.
      const mismatched = steps.map((step, i) => ({ step, check: checks[i] })).filter(({ check }) => check.result === 'mismatch');
      if (mismatched.length > 0) {
        const raised = await raiseTampered(viewer, consignment.id, mismatched);
        facts.held = raised.held;
        if (raised.alerts) alerts = raised.alerts;
      }

      for (const a of alerts) {
        if (!facts.alerts.has(a.transaction_id)) facts.alerts.set(a.transaction_id, []);
        facts.alerts.get(a.transaction_id).push(a);
      }
      return discloseConsignment(viewer, consignment, steps, facts);
    },
  };
}
