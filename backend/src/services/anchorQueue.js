// Which stored steps the anchoring worker may send next, and the lock that keeps it to one
// worker at a time (8 Nov plan, step 8). Database only: no chain code here.
//
// Every row returned has exactly the columns buildAnchorCall needs (type, chain_id,
// actor_ref, weight_mg, data_hash) plus the ids the worker writes back with.

// The queue index's own condition (transactions_anchor_queue_idx), repeated word for word.
// PostgreSQL only uses a partial index when it can see that the query's WHERE implies the
// index's WHERE, and repeating it makes that obvious.
const QUEUE_INDEX_PREDICATE = `
      t.anchor_status IN ('pending', 'submitted')
  AND t.review_status IN ('passed', 'cleared')`;

const STEP_COLUMNS = `
  t.id, t.consignment_id, t.actor_id, t.type, t.weight_mg, t.data_hash, t.received_at,
  t.anchor_attempts, c.chain_id, u.actor_ref`;

// "This step is a flagged duplicate of a registration that was accepted": a flagged
// registration on a consignment that has another, accepted registration. Written once and
// used by rules 1 and 2 below. step is the SQL alias of the step being tested; it is one of
// two fixed names in this file, never input, so this is not SQL built from user values.
// The accepted registration can never be the same row: it is passed or cleared, this one is
// flagged. The partial unique index on accepted registrations makes the lookup an index hit.
const DUPLICATE_OF_ACCEPTED = (step) => `(
          ${step}.type = 'registration'
          AND ${step}.review_status = 'flagged'
          AND EXISTS (
            SELECT 1
            FROM transactions accepted
            WHERE accepted.consignment_id = ${step}.consignment_id
              AND accepted.type = 'registration'
              AND accepted.review_status IN ('passed', 'cleared')))`;

// D3, "held", written once: an open alert, of any type, on any step of the consignment,
// except a step that is a flagged duplicate of an accepted registration (rule 1 below).
// consignment is a fixed SQL expression from this file, never input.
const HELD = (consignment) => `EXISTS (
      SELECT 1
      FROM alerts a
      JOIN transactions held ON held.id = a.transaction_id
      WHERE held.consignment_id = ${consignment}
        AND a.status = 'open'
        AND NOT ${DUPLICATE_OF_ACCEPTED('held')})`;

// One pending step that may be sent now. Each NOT EXISTS / EXISTS is one rule:
//
// 1. Not held: no open alert on any step of the same consignment (D3). An officer's
//    decision, either way, closes the alert and releases the hold.
//    One exception (decisions.md, 9 Nov): alerts on a flagged registration do not hold the
//    consignment while it has a DIFFERENT accepted registration, that is, alerts on a
//    duplicate. Otherwise anyone with an approved account who has seen a QR code could
//    freeze another miner's consignment by registering it again. ALL of the duplicate's
//    alerts are excused, not only duplicate_consignment: sync runs every check on it, so
//    registering the copy from off-site (gps_zone) or with a bad signature
//    (invalid_signature) would otherwise bring the same blocking attack back. The officer
//    still gets every alert. Alerts on any other step still hold, and so does a duplicate
//    when the consignment has no accepted registration (the original was flagged too, say
//    for a bad signature): then there is no genuine consignment to protect.
// 2. In order: no earlier step of the same consignment that is still on its way to the
//    chain. Earlier means (received_at, id): received_at alone can tie, and id breaks the
//    tie the same way every time. Passed, cleared and flagged steps count (a flagged one
//    may yet be cleared and then must go first); rejected steps never reach the chain, so
//    they are ignored. A failed earlier step blocks everything after it, because the
//    contract would refuse the later steps or record them out of order.
//    Same exception: a flagged registration is ignored while the consignment has a
//    different accepted registration. It is a duplicate, and can never be anchored (only
//    one registration per consignment can be accepted), so waiting for it would never end.
// 3. A handoff or purchase also needs the consignment's accepted registration confirmed.
//    Rule 2 ignores a rejected registration, so without this a handoff could be sent for
//    a consignment the chain has never heard of. Known limit: such a handoff stays pending
//    until officer review decides what happens to it.
//
// FOR UPDATE OF t SKIP LOCKED: the chosen row is locked until the caller's transaction
// ends, and a row someone else has locked is passed over instead of waited for. Only t is
// locked; the consignment and user rows are only read. The advisory lock below already
// keeps a second worker away; this also covers anything else that ever takes rows from the
// queue. LIMIT applies after locked rows are skipped, so it still returns one free row.
const NEXT_ELIGIBLE_STEP = `
  SELECT ${STEP_COLUMNS}
  FROM transactions t
  JOIN consignments c ON c.id = t.consignment_id
  JOIN users u ON u.id = t.actor_id
  WHERE ${QUEUE_INDEX_PREDICATE}
    AND t.anchor_status = 'pending'
    AND NOT ${HELD('t.consignment_id')}
    AND NOT EXISTS (
      SELECT 1
      FROM transactions earlier
      WHERE earlier.consignment_id = t.consignment_id
        AND (earlier.received_at, earlier.id) < (t.received_at, t.id)
        AND earlier.review_status IN ('passed', 'cleared', 'flagged')
        AND earlier.anchor_status <> 'confirmed'
        AND NOT ${DUPLICATE_OF_ACCEPTED('earlier')})
    AND (t.type = 'registration' OR EXISTS (
      SELECT 1
      FROM transactions reg
      WHERE reg.consignment_id = t.consignment_id
        AND reg.type = 'registration'
        AND reg.review_status IN ('passed', 'cleared')
        AND reg.anchor_status = 'confirmed'))
  ORDER BY t.received_at, t.id
  LIMIT 1
  FOR UPDATE OF t SKIP LOCKED`;

// tx: a db object inside a transaction (db.transaction's callback argument). Outside one,
// the row lock would end with the statement, before the worker has written anything back.
// Returns the row, or null when nothing may be sent now.
export async function nextEligibleStep(tx) {
  const { rows } = await tx.query(NEXT_ELIGIBLE_STEP);
  return rows[0] ?? null;
}

const IS_HELD = `SELECT ${HELD('$1::uuid')} AS held`;

// Whether a consignment is held, by exactly the rule the queue uses. For tests and, later,
// for showing officers which consignments are waiting on them.
export async function isConsignmentHeld(db, consignmentId) {
  const { rows } = await db.query(IS_HELD, [consignmentId]);
  return rows[0].held;
}

// Steps already sent but not yet confirmed or failed. The worker reconciles these before
// sending anything new, oldest nonce first, which is the order the chain mines them in.
// Holds are not applied: a transaction that has been sent may be mined whatever an alert
// says now, and reconciling only records what the chain did.
const SUBMITTED_STEPS = `
  SELECT ${STEP_COLUMNS},
         t.chain_tx_hash, t.anchor_nonce, t.anchor_submitted_at
  FROM transactions t
  JOIN consignments c ON c.id = t.consignment_id
  JOIN users u ON u.id = t.actor_id
  WHERE ${QUEUE_INDEX_PREDICATE}
    AND t.anchor_status = 'submitted'
  ORDER BY t.anchor_nonce, t.received_at, t.id`;

// anchor_nonce comes back as text (bigint), like weight_mg.
export async function submittedSteps(db) {
  const { rows } = await db.query(SUBMITTED_STEPS);
  return rows;
}

// ---------- one worker at a time ----------

// A fixed key shared by every copy of the backend: the bytes of "MCANCHOR" read as one
// 64-bit number (0x4d43414e43484f52). Any fixed bigint would do; this one can be recognised
// in pg_locks. Sent as text and cast, because a JavaScript number cannot hold it exactly.
export const ANCHOR_LOCK_KEY = '5567365368752131922';

// Tries to become the only anchoring worker. Never waits: if another process holds the
// lock, it answers at once, and this process simply does not anchor.
//
// A session lock belongs to one connection, and is held until that connection unlocks it
// or closes. So it gets its own connection, kept out of the pool until release(). Taken on
// a pooled connection and handed back, the lock would stay on a connection that any other
// query could borrow.
//
// pool: a pg Pool (createPool). Returns:
//   acquired  true if this process now holds the lock
//   isLost()  true if the lock's connection has failed since; the lock then ended with it
//   release() unlocks and hands the connection back; safe to call more than once
export async function tryAnchorLock(pool) {
  const client = await pool.connect();
  let lost = false;
  // A checked-out connection reports a failure on itself, not on the pool. Without a
  // listener, Node would treat that as an unhandled error and stop the server.
  const onError = () => {
    lost = true;
  };
  client.on('error', onError);

  let acquired;
  try {
    const { rows } = await client.query('SELECT pg_try_advisory_lock($1::bigint) AS acquired', [ANCHOR_LOCK_KEY]);
    acquired = rows[0].acquired === true;
  } catch (err) {
    client.off('error', onError);
    client.release(err);
    throw err;
  }

  if (!acquired) {
    client.off('error', onError);
    client.release();
    return Object.freeze({ acquired: false, isLost: () => false, release: async () => {} });
  }

  let released = false;
  return Object.freeze({
    acquired: true,
    isLost: () => lost,
    async release() {
      if (released) return;
      released = true;
      let broken;
      try {
        if (!lost) await client.query('SELECT pg_advisory_unlock($1::bigint)', [ANCHOR_LOCK_KEY]);
      } catch (err) {
        broken = err;
      } finally {
        client.off('error', onError);
        // A failed or broken connection is discarded rather than reused, which also ends
        // the lock, since session locks die with their connection.
        client.release(broken ?? (lost ? new Error('anchor lock connection failed') : undefined));
      }
    },
  });
}
