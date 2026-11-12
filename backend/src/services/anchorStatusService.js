// The administrator's view of anchoring (anchoring admin plan §1, N2): what the worker is
// doing, what is waiting, what is stuck or failed, and a list of problems. Built from the
// database and the worker's memory only: no chain call, so the page answers even while the
// RPC is down, which is exactly when an admin needs it.
//
// Nothing secret can reach the body. The worker part is copied field by field from the
// snapshot (never spread), the chain part is two public addresses, and every text is a
// fixed code or our own anchor_error format (chainErrors.js), never provider text.
import { BACKOFF_MAX_SECONDS, anchoringSnapshot } from '../anchorWorker.js';
import { EARLIER_FAILED, HELD, QUEUE_INDEX_PREDICATE, STUCK_AFTER_SECONDS, peekEligibleStep } from './anchorQueue.js';

// ---------- anchor_error: split and retry allow-list (N3's retry reuses both) ----------

// The failure codes an administrator may send back to pending (plan §2), as "CODE" or
// "CODE:detail". Each means nothing reached the chain by the worker's own rules, so a retry
// that only changes the database cannot anchor a step twice:
//   INVALID_STAGE:None  the registration may be on-chain by now; the dry run checks again
//   UNKNOWN             often transient; the dry run checks again
//   MAX_ATTEMPTS        every try was mined and reverted, and a revert changes nothing
// Anything else stays failed: the chain's stage forbids it, the data is refused (a bug), or
// something was written on-chain (RECEIPT_MISMATCH, which a retry could anchor twice).
export const RETRYABLE_ANCHOR_ERRORS = Object.freeze(['INVALID_STAGE:None', 'UNKNOWN', 'MAX_ATTEMPTS']);

// Our format: CODE, optionally :detail (a stage, a field, or a comma list of fields), then
// ": " and a fixed reason. Examples: "UNKNOWN: an unrecognised error",
// "INVALID_STAGE:None: the step is not allowed…", "RECEIPT_MISMATCH:id,dataHash: …".
const ANCHOR_ERROR_FORMAT = /^([A-Z][A-Z0-9_]*)(?::([^\s:]+))?: \S/;

// { code, detail } from a stored anchor_error, or null when there is none. Text that is not
// in our format gives code UNRECOGNISED, which is on no allow-list, so it is never retried.
export function splitAnchorError(text) {
  if (typeof text !== 'string') return null;
  const match = ANCHOR_ERROR_FORMAT.exec(text);
  if (!match) return Object.freeze({ code: 'UNRECOGNISED', detail: null });
  return Object.freeze({ code: match[1], detail: match[2] ?? null });
}

export function isRetryableAnchorError(text) {
  const split = splitAnchorError(text);
  if (split === null) return false;
  const key = split.detail === null ? split.code : `${split.code}:${split.detail}`;
  return RETRYABLE_ANCHOR_ERRORS.includes(key);
}

// ---------- problems ----------

export const FAILED_LIST_LIMIT = 50;
export const HELD_LIST_LIMIT = 50;
// A tick is overdue after this many intervals: one for the wait, the rest for a slow tick.
export const NO_RECENT_TICK_INTERVALS = 3;

// Fixed plain-language texts, in the order they are listed.
export const PROBLEMS = Object.freeze({
  WORKER_DISABLED: 'Anchoring is switched off (ANCHOR_ENABLED is not true), so no step reaches the chain.',
  WORKER_NOT_STARTED: 'The anchoring worker has not started because its startup check did not pass. Fix the configuration, then restart.',
  WORKER_STOPPED: 'The anchoring worker has stopped: the recorder wallet lost its role, or the server is shutting down.',
  WORKER_BACKOFF: 'The anchoring worker cannot reach the chain and is trying again with growing delays.',
  WORKER_PAUSED: 'The anchoring worker is paused: the wallet cannot pay, the fee is above the cap, or another transaction is waiting.',
  STUCK_SUBMITTED: `A sent step has not moved for more than ${STUCK_AFTER_SECONDS / 60} minutes. Nothing else can be anchored until it does.`,
  FAILED_STEPS: 'Some steps failed to anchor. Later steps of the same consignment wait behind them.',
  NO_RECENT_TICK: 'The anchoring worker has not finished a tick for longer than expected.',
});

const WORKER_STATE_PROBLEMS = Object.freeze({
  disabled: 'WORKER_DISABLED',
  not_started: 'WORKER_NOT_STARTED',
  stopped: 'WORKER_STOPPED',
  backoff: 'WORKER_BACKOFF',
  paused: 'WORKER_PAUSED',
});

const secondsBetween = (earlier, later) => Math.max(0, Math.floor((later.getTime() - earlier.getTime()) / 1000));

// Whether a worker that should be ticking has gone quiet. The last sign of life is the last
// tick, or the start, or (while preflight retries) the last preflight. While backing off,
// the gap between ticks can reach the backoff cap, so the cap is added to the allowance.
// A disabled, not started or stopped worker is not expected to tick: its own problem says so.
function tickOverdue(worker, now, intervalSeconds) {
  if (!['running', 'paused', 'backoff'].includes(worker.state)) return false;
  const lastSign = worker.lastTick?.at ?? worker.startedAt ?? worker.preflight?.at ?? null;
  if (lastSign === null) return false;
  const allowance = NO_RECENT_TICK_INTERVALS * intervalSeconds + (worker.state === 'backoff' ? BACKOFF_MAX_SECONDS : 0);
  return secondsBetween(lastSign, now) > allowance;
}

// Pure, so every code can be unit-tested without a database.
export function findProblems({ worker, inFlight, failedCount, now, intervalSeconds }) {
  const codes = [];
  const stateProblem = WORKER_STATE_PROBLEMS[worker.state];
  if (stateProblem) codes.push(stateProblem);
  if (inFlight.some((step) => step.stuck)) codes.push('STUCK_SUBMITTED');
  if (failedCount > 0) codes.push('FAILED_STEPS');
  if (tickOverdue(worker, now, intervalSeconds)) codes.push('NO_RECENT_TICK');
  return Object.freeze(codes.map((code) => Object.freeze({ code, message: PROBLEMS[code] })));
}

// ---------- the queries (read only) ----------

// Approved steps only (passed or cleared). A flagged step is also 'pending' in anchor_status,
// but it is waiting for an officer, not for the chain.
const COUNTS = `
  SELECT t.anchor_status, count(*)::int AS steps
  FROM transactions t
  WHERE t.review_status IN ('passed', 'cleared')
  GROUP BY t.anchor_status`;

const IN_FLIGHT = `
  SELECT t.id, t.consignment_id, t.type, t.chain_tx_hash, t.anchor_nonce, t.anchor_submitted_at, t.anchor_error
  FROM transactions t
  WHERE ${QUEUE_INDEX_PREDICATE}
    AND t.anchor_status = 'submitted'
  ORDER BY t.anchor_nonce, t.received_at, t.id`;

// Newest first by the time the row last changed (set by the updated_at trigger); id breaks
// ties the same way every time.
const FAILED = `
  SELECT t.id, t.consignment_id, t.type, t.anchor_error, t.anchor_attempts, t.chain_tx_hash, t.updated_at
  FROM transactions t
  WHERE t.anchor_status = 'failed'
    AND t.review_status IN ('passed', 'cleared')
  ORDER BY t.updated_at DESC, t.id DESC
  LIMIT ${FAILED_LIST_LIMIT}`;

// One pass over the approved pending steps, with the queue's own rules. The booleans are
// worked out in the inner query, so the aggregates only filter on plain columns.
const PENDING = `
  SELECT min(p.received_at) AS oldest_received_at,
         count(*) FILTER (WHERE p.held)::int AS on_held,
         count(*) FILTER (WHERE p.behind_failed)::int AS behind_failed
  FROM (
    SELECT t.received_at,
           ${HELD('t.consignment_id')} AS held,
           ${EARLIER_FAILED('t')} AS behind_failed
    FROM transactions t
    WHERE ${QUEUE_INDEX_PREDICATE}
      AND t.anchor_status = 'pending'
  ) p`;

// Consignments the queue will not send from because of an open alert, with how many approved
// steps wait on each. openAlerts counts every open alert on the consignment's steps, as the
// officer's list shows them, including any on an excused duplicate.
const HELD_CONSIGNMENTS = `
  SELECT c.id AS consignment_id, c.qr_code, count(*)::int AS pending_steps,
         (SELECT count(*)::int
            FROM alerts a
            JOIN transactions s ON s.id = a.transaction_id
           WHERE s.consignment_id = c.id AND a.status = 'open') AS open_alerts
  FROM transactions t
  JOIN consignments c ON c.id = t.consignment_id
  WHERE ${QUEUE_INDEX_PREDICATE}
    AND t.anchor_status = 'pending'
    AND ${HELD('c.id')}
  GROUP BY c.id, c.qr_code
  ORDER BY min(t.received_at), c.id
  LIMIT ${HELD_LIST_LIMIT}`;

// From the rows rather than the worker's memory, so ticks run by anchor:once in another
// process show here too (plan §1).
const LAST_CONFIRMED = `
  SELECT t.id, t.anchored_at
  FROM transactions t
  WHERE t.anchor_status = 'confirmed'
  ORDER BY t.anchored_at DESC, t.id DESC
  LIMIT 1`;

const LAST_SUBMITTED = `
  SELECT t.id, t.anchor_submitted_at
  FROM transactions t
  WHERE t.anchor_submitted_at IS NOT NULL
  ORDER BY t.anchor_submitted_at DESC, t.id DESC
  LIMIT 1`;

const toHex = (bytes) => (bytes ? `0x${Buffer.from(bytes).toString('hex')}` : null);

// ---------- the service ----------

// db: the app's db object. anchorWorker: the worker from createAnchorWorkerFromConfig, or
// null when ANCHOR_ENABLED is false. intervalSeconds: config.anchor.intervalSeconds, needed
// only when there is a worker. clock: the time ages are measured to, injectable for tests.
export function createAnchorStatusService({ db, anchorWorker = null, intervalSeconds, clock = () => new Date() }) {
  if (anchorWorker !== null && !(Number.isInteger(intervalSeconds) && intervalSeconds > 0)) {
    throw new TypeError('createAnchorStatusService needs intervalSeconds when there is a worker');
  }

  // Field by field: a field added to the snapshot later does not reach admins by accident.
  function workerView() {
    const snap = anchoringSnapshot(anchorWorker);
    return Object.freeze({
      state: snap.state,
      startedAt: snap.startedAt ?? null,
      preflight: snap.preflight ?? null,
      lastTick: snap.lastTick ?? null,
      recorderAddress: snap.recorderAddress ?? null,
      contractAddress: snap.contractAddress ?? null,
    });
  }

  async function readRows() {
    // One snapshot for every read, so the counts and the lists describe the same moment.
    // REPEATABLE READ takes no locks, so the worker is never held up by this page.
    return db.transaction(
      async (tx) => ({
        counts: (await tx.query(COUNTS)).rows,
        inFlight: (await tx.query(IN_FLIGHT)).rows,
        failed: (await tx.query(FAILED)).rows,
        pending: (await tx.query(PENDING)).rows[0],
        sendable: await peekEligibleStep(tx),
        held: (await tx.query(HELD_CONSIGNMENTS)).rows,
        lastConfirmed: (await tx.query(LAST_CONFIRMED)).rows[0] ?? null,
        lastSubmitted: (await tx.query(LAST_SUBMITTED)).rows[0] ?? null,
      }),
      { isolation: 'repeatable read' },
    );
  }

  return Object.freeze({
    async status() {
      const now = clock();
      const worker = workerView();
      const rows = await readRows();

      const counts = { pending: 0, submitted: 0, confirmed: 0, failed: 0 };
      for (const row of rows.counts) counts[row.anchor_status] = row.steps;

      const inFlight = rows.inFlight.map((r) => {
        const ageSeconds = secondsBetween(r.anchor_submitted_at, now);
        const refusal = splitAnchorError(r.anchor_error);
        return Object.freeze({
          stepId: r.id,
          consignmentId: r.consignment_id,
          type: r.type,
          chainTxHash: toHex(r.chain_tx_hash),
          nonce: r.anchor_nonce, // text: a bigint
          submittedAt: r.anchor_submitted_at,
          ageSeconds,
          stuck: ageSeconds > STUCK_AFTER_SECONDS,
          // On a submitted row anchor_error is only ever the last refused resend (N1).
          lastRefusal: refusal && Object.freeze({ ...refusal, error: r.anchor_error }),
        });
      });

      const failed = rows.failed.map((r) => {
        const split = splitAnchorError(r.anchor_error);
        return Object.freeze({
          stepId: r.id,
          consignmentId: r.consignment_id,
          type: r.type,
          code: split.code,
          detail: split.detail,
          error: r.anchor_error,
          attempts: r.anchor_attempts,
          chainTxHash: toHex(r.chain_tx_hash),
          updatedAt: r.updated_at,
          retryable: isRetryableAnchorError(r.anchor_error),
        });
      });

      const oldest = rows.pending.oldest_received_at;
      const pending = Object.freeze({
        oldestReceivedAt: oldest,
        oldestAgeSeconds: oldest === null ? null : secondsBetween(oldest, now),
        onHeldConsignments: rows.pending.on_held,
        behindFailedStep: rows.pending.behind_failed,
        // The step the worker would send next, or null: a hint, out of date a moment later.
        sendableNow: rows.sendable?.id ?? null,
      });

      const held = rows.held.map((r) =>
        Object.freeze({ consignmentId: r.consignment_id, qrCode: r.qr_code, pendingSteps: r.pending_steps, openAlerts: r.open_alerts }),
      );

      return Object.freeze({
        worker,
        counts: Object.freeze(counts),
        inFlight: Object.freeze(inFlight),
        failed: Object.freeze(failed),
        pending,
        held: Object.freeze(held),
        lastConfirmed: rows.lastConfirmed && Object.freeze({ stepId: rows.lastConfirmed.id, anchoredAt: rows.lastConfirmed.anchored_at }),
        lastSubmitted:
          rows.lastSubmitted && Object.freeze({ stepId: rows.lastSubmitted.id, submittedAt: rows.lastSubmitted.anchor_submitted_at }),
        problems: findProblems({ worker, inFlight, failedCount: counts.failed, now, intervalSeconds }),
      });
    },
  });
}
