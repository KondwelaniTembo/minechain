// Stores signed custody steps synced from the phone's offline queue (FR-03, FR-07):
// POST /sync/steps. The rules are in docs/signing-spec.md (sections 5-7) and the step 7
// decisions in docs/decisions.md.
//
// Each item goes through the same pipeline, in its own database transaction, strictly in
// the order sent, so one bad item never blocks the rest and nothing is half-saved. Every
// item gets one result:
//   created    stored, all checks passed
//   duplicate  already stored (a retry); nothing written
//   flagged    stored, but a check failed: an alert is open and the consignment is held
//   rejected   not stored; resending it unchanged will never work
//   deferred   not stored yet; resend the same item later, unchanged
//
// Rejected and deferred items are not audited: they are entirely client-controlled, and
// recording them would let anyone fill the append-only audit log (the 5 Nov reasoning for
// refused tokens).
//
// A database fault throws out of syncSteps (the route answers 500). Items already committed
// stay committed, and resending the batch is safe: they come back as duplicate.
import { parsePayload } from './stepPayload.js';
import { spkiFingerprint } from './signatureService.js';
import { SigningError, SIGNING_ERROR_CODES } from './signingError.js';
import { CHECKS, FLAGGED_MESSAGES, flaggedCodeFor, runChecks, reviewStatusFor } from './anomalyChecks.js';
import { matchZone, pointFromText } from './zoneMatch.js';

// Who may sign each step type (the role check the database cannot make).
const ROLE_FOR_TYPE = Object.freeze({ registration: 'miner', handoff: 'transporter', purchase: 'buyer' });

// Where a handoff or purchase may happen, and where it moves the consignment (the
// contract's stage rules, contract spec section 5). A handoff is allowed from in_transit
// too, because one journey can have several transporters (a relay). A purchase needs a
// handoff first: there is no direct miner-to-buyer sale in the prototype.
const CUSTODY_RULES = Object.freeze({
  handoff: Object.freeze({ allowedFrom: Object.freeze(['registered', 'in_transit']), to: 'in_transit' }),
  purchase: Object.freeze({ allowedFrom: Object.freeze(['in_transit']), to: 'purchased' }),
});

// The anchor hash scheme of every row written here (signing-spec section 7).
const HASH_VERSION = 1;

// Plain-language messages, one per code, so the app can show them as they are. The flagged
// codes come from the anomaly checks, so a new check brings its own message.
const MESSAGES = Object.freeze({
  PAYLOAD_MALFORMED: 'This record is not in the signed format the server expects.',
  PAYLOAD_UNSUPPORTED_VERSION: 'This record uses a format version the server does not read. Update the app.',
  SIGNATURE_MALFORMED: 'The signature on this record is not in the expected form.',
  ACTOR_MISMATCH: 'This record was signed for a different account.',
  STEP_NOT_ALLOWED_FOR_ROLE: 'Your role cannot record this kind of step.',
  NO_DEVICE_KEY: 'This account has no registered device key yet. Register the key, then sync again.',
  STEP_ID_CONFLICT: 'A different record with the same step id was already received.',
  CONSIGNMENT_NOT_FOUND: 'This consignment has not reached the server yet. Keep the record and sync again later.',
  STAGE_NOT_READY:
    "This consignment is not ready for this step yet. An earlier step has not reached the server, or is waiting for an officer's review. Keep the record and sync again later.",
  ...FLAGGED_MESSAGES,
});

// The record's own SigningError codes, as the sync result codes. PAYLOAD_NOT_CANONICAL is a
// malformed payload as far as the app is concerned.
function payloadCode(err) {
  return err.code === SIGNING_ERROR_CODES.PAYLOAD_UNSUPPORTED_VERSION ? 'PAYLOAD_UNSUPPORTED_VERSION' : 'PAYLOAD_MALFORMED';
}

function result(index, stepId, outcome, code, extra = {}) {
  return { index, stepId, outcome, ...(code && { code, message: MESSAGES[code] }), ...extra };
}

// Thrown inside an item's transaction to end it with a result instead of a stored step. The
// transaction is rolled back, so anything written before (such as a new consignment) is
// undone, and the result is returned to the app. Never escapes processItem.
class ItemOutcome extends Error {
  constructor(outcome) {
    super('sync item ended without being stored');
    this.outcome = outcome;
  }
}

// The user's key, as registered. FOR SHARE: an administrator's key reset on this row waits
// until this item's transaction ends, so the step is checked and stored against one key.
const SELECT_DEVICE_KEY = 'SELECT public_key FROM users WHERE id = $1 FOR SHARE';

// A step already received from this user with this step id.
const SELECT_BY_STEP_ID = `
  SELECT id, data_hash, review_status
    FROM transactions
   WHERE actor_id = $1 AND idempotency_key = $2`;

// A new consignment for a new custody record. stage takes its default ('registered').
// DO NOTHING when the code exists: the caller then decides whether this is a retry or a
// second registration of the same document.
const INSERT_CONSIGNMENT = `
  INSERT INTO consignments (qr_code, mineral_type, miner_id)
  VALUES ($1, $2, $3)
  ON CONFLICT (qr_code) DO NOTHING
  RETURNING id`;

// The consignment a handoff or purchase names, locked until the item's transaction ends.
// Two steps for one consignment arriving at once are then decided one after the other, each
// seeing the stage the other left (the 4 Nov consignments.stage decision).
const LOCK_CONSIGNMENT = 'SELECT id, stage, mineral_type FROM consignments WHERE qr_code = $1 FOR UPDATE';

const UPDATE_STAGE = 'UPDATE consignments SET stage = $2 WHERE id = $1';

// The consignment's original registration, for a duplicate: the accepted one if there is
// one, otherwise the earliest. Read under the consignment lock taken just before.
const SELECT_ORIGINAL_REGISTRATION = `
  SELECT id, actor_id, review_status
    FROM transactions
   WHERE consignment_id = $1 AND type = 'registration'
   ORDER BY (review_status IN ('passed', 'cleared')) DESC, received_at, id
   LIMIT 1`;

// The quantity check's two baselines, in one round trip. Both indexed: the latest accepted
// step by transactions_consignment_received_idx, the accepted registration by the partial
// unique index on accepted registrations. Weights as text, so they are never JS numbers.
// The step being synced is not stored yet, so "latest" means latest before it.
const SELECT_BASELINES = `
  SELECT
    (SELECT json_build_object('stepId', id, 'weightMg', weight_mg::text)
       FROM transactions
      WHERE consignment_id = $1 AND review_status IN ('passed', 'cleared')
      ORDER BY received_at DESC, id DESC
      LIMIT 1) AS previous,
    (SELECT json_build_object('stepId', id, 'weightMg', weight_mg::text)
       FROM transactions
      WHERE consignment_id = $1 AND type = 'registration' AND review_status IN ('passed', 'cleared')) AS registration`;

// The licensed zones a step may fall in. Read once per sync call (see syncSteps).
const SELECT_ACTIVE_ZONES = `SELECT id, name, boundary FROM gps_zones WHERE status = 'active' ORDER BY name, id`;

// The step itself. Every value comes from the signed payload or the server:
//   - weight_mg, latitude, longitude and captured_at go in as the payload's text, so
//     PostgreSQL reads them into bigint, numeric(9,6) and timestamptz exactly, with no
//     JavaScript number in between;
//   - received_at is clock_timestamp(), the database's time at this INSERT, never a value
//     from the request. Not the column's default now(): that is when the *transaction*
//     started, so a handoff whose transaction began just before its registration's
//     committed could get the earlier time, and the anchoring worker, which sends a
//     consignment's steps in received_at order, would wait forever or send a purchase
//     before its handoff. The time at INSERT follows custody order within one consignment:
//     a handoff is inserted only after this transaction has seen the registration's
//     committed consignment, and a purchase only after taking the consignment lock that
//     the handoff held until it committed. (decisions.md, 9 Nov)
//   - zone_id is the active zone the point falls in (within the 25 m tolerance), for every
//     step type; NULL means outside every active zone;
//   - anchor_status takes its default ('pending'); a flagged step can never leave it
//     (transactions_anchor_only_if_approved).
// ON CONFLICT: if a second copy of the same step won a race since the lookup above, nothing
// is inserted and the caller compares hashes again.
const INSERT_STEP = `
  INSERT INTO transactions (
    consignment_id, actor_id, type, idempotency_key, weight_mg, latitude, longitude, zone_id,
    captured_at, signed_payload, signature, signer_public_key, data_hash, hash_version,
    review_status, received_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $15, $8, $9, $10, $11, $12, $13, $14, clock_timestamp())
  ON CONFLICT ON CONSTRAINT transactions_idempotency_key_unique DO NOTHING
  RETURNING id`;

const INSERT_ALERT = `
  INSERT INTO alerts (transaction_id, type, severity, details)
  VALUES ($1, $2, $3, $4)`;

// Dependencies are passed in, so DB tests can give a failing audit service.
//   db:         the app's db object
//   signatures: the signature service (decodeSignature, verify, anchorHash)
//   audit:      the audit service (record)
//   checks:     the anomaly checks to run; the real list unless a test gives another
export function createSyncService({ db, signatures, audit, checks = CHECKS }) {
  // Compares a step already stored under this step id with the one just received. The same
  // anchor hash means the same payload, key and signature: a genuine retry. Anything else is
  // a different record reusing the id (signing-spec section 6).
  function compareWithStored(index, stepId, stored, dataHash) {
    if (stored.data_hash.equals(dataHash)) {
      return result(index, stepId, 'duplicate', null, { transactionId: stored.id, reviewStatus: stored.review_status });
    }
    return result(index, stepId, 'rejected', 'STEP_ID_CONFLICT');
  }

  // ---------- the consignment, per step type ----------
  // Each returns { consignmentId, nextStage, context }, or ends the item with an
  // ItemOutcome. nextStage is where a passed step moves the consignment (null: it stays).
  // context is this type's part of what the anomaly checks read.

  // A registration creates the consignment for its custody record, or, when the code is
  // already registered, is stored as a flagged duplicate on the existing one.
  async function registrationConsignment(tx, { index, user, step, dataHash }) {
    const { rows } = await tx.query(INSERT_CONSIGNMENT, [step.qrCode, step.mineral, user.id]);
    if (rows.length === 1) return { consignmentId: rows[0].id, nextStage: null, context: { existingRegistration: null } };

    // The code exists. ON CONFLICT also covers two registrations of a NEW code at the same
    // moment: the second waits on the unique index until the first commits, then lands
    // here, so it becomes a duplicate like any other rather than an error.
    // If an identical copy of THIS step was what got committed, it is a retry after all.
    const { rows: raced } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
    if (raced.length === 1) throw new ItemOutcome(compareWithStored(index, step.stepId, raced[0], dataHash));

    // Locked like any step on an existing consignment, so its stage and its registration
    // are read as they stand. The consignment itself is not changed: its miner_id and stage
    // stay the original's.
    const { rows: existing } = await tx.query(LOCK_CONSIGNMENT, [step.qrCode]);
    const consignment = existing[0];
    const { rows: originals } = await tx.query(SELECT_ORIGINAL_REGISTRATION, [consignment.id]);
    if (originals.length === 0) {
      // A consignment is only ever created together with its registration, in one
      // transaction, so this would be a broken database rather than a user's mistake.
      throw new Error('A consignment exists without a registration step');
    }
    const original = originals[0];
    return {
      consignmentId: consignment.id,
      nextStage: null,
      context: {
        existingRegistration: {
          transactionId: original.id,
          actorId: original.actor_id,
          mineral: consignment.mineral_type,
          reviewStatus: original.review_status,
        },
      },
    };
  }

  // A handoff or purchase needs its consignment, at a stage that allows it. After the final
  // stage it is still stored, as a flagged handoff_order step.
  async function custodyConsignment(tx, { index, step }) {
    const { rows } = await tx.query(LOCK_CONSIGNMENT, [step.qrCode]);
    const consignment = rows[0];

    // Out of order: the miner's registration has not been synced yet. A step cannot be
    // stored without its consignment (transactions.consignment_id is NOT NULL), and a
    // signed record stays valid however late it arrives, so the app resends it later.
    if (!consignment) throw new ItemOutcome(result(index, step.stepId, 'deferred', 'CONSIGNMENT_NOT_FOUND'));

    const rule = CUSTODY_RULES[step.type];
    const afterPurchase = consignment.stage === 'purchased';
    // Not yet: a purchase while the consignment is still registered. Most likely the
    // transporter's handoff has not been synced yet, so it is deferred, not refused.
    // After the purchase it is a different matter: nothing can come later, so the step is
    // kept as evidence and the handoff-order check flags it.
    if (!afterPurchase && !rule.allowedFrom.includes(consignment.stage)) {
      throw new ItemOutcome(result(index, step.stepId, 'deferred', 'STAGE_NOT_READY'));
    }

    const { rows: baselineRows } = await tx.query(SELECT_BASELINES, [consignment.id]);
    return {
      consignmentId: consignment.id,
      // A relay (handoff at in_transit) leaves the stage where it is, and nothing moves a
      // purchased consignment. (Flagged steps never move it anyway.)
      nextStage: afterPurchase || rule.to === consignment.stage ? null : rule.to,
      context: {
        consignmentStage: consignment.stage,
        baselines: { previous: baselineRows[0].previous, registration: baselineRows[0].registration },
      },
    };
  }

  const CONSIGNMENT_FOR_TYPE = {
    registration: registrationConsignment,
    handoff: custodyConsignment,
    purchase: custodyConsignment,
  };

  // ---------- the shared pipeline ----------

  // Everything that needs the database, for one item, in one transaction. zonesFor(tx)
  // gives the active zones, read once per sync call.
  async function storeStep(tx, { index, user, step, item, signatureBytes, ipAddress, zonesFor }) {
    const { rows: keyRows } = await tx.query(SELECT_DEVICE_KEY, [user.id]);
    if (keyRows.length === 0) {
      // requireAuth loaded this user a moment ago. A missing row is a server-side problem.
      throw new Error('The syncing user no longer exists');
    }
    const publicKey = keyRows[0].public_key;
    if (!publicKey) throw new ItemOutcome(result(index, step.stepId, 'deferred', 'NO_DEVICE_KEY'));

    // The hash identifies this exact record (payload, key and signature), so it is what
    // tells a retry from a different record with the same step id.
    const dataHash = signatures.anchorHash({ payload: item.payload, signature: signatureBytes, publicKey });

    // Retries are recognised first, before anything about the consignment is checked: a
    // step saved yesterday must come back as duplicate even if the consignment has moved on
    // since (a handoff resent after the purchase, for example).
    const { rows: stored } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
    if (stored.length === 1) throw new ItemOutcome(compareWithStored(index, step.stepId, stored[0], dataHash));

    // A signature that does not verify is not refused: the record is stored as evidence and
    // flagged, with an alert for an officer (anomaly check 4).
    const verified = signatures.verify({ payload: item.payload, signature: signatureBytes, publicKey });

    // The consignment, locked, and what the checks need to know about it. Deferred items
    // end here, before the zones are read.
    const { consignmentId, nextStage, context } = await CONSIGNMENT_FOR_TYPE[step.type](tx, { index, user, step, dataHash });

    // Every step gets its zone, whatever its type; only a registration is flagged for
    // being outside every zone (the check decides that).
    const zoneMatch = matchZone(pointFromText(step.latitude, step.longitude), await zonesFor(tx));

    const findings = runChecks({ step, verified, keyFingerprint: spkiFingerprint(publicKey), zoneMatch, ...context }, checks);
    const reviewStatus = reviewStatusFor(findings);

    const { rows: inserted } = await tx.query(INSERT_STEP, [
      consignmentId,
      user.id,
      step.type,
      step.stepId,
      step.weightMg,
      step.latitude,
      step.longitude,
      step.capturedAt,
      item.payload,
      signatureBytes,
      publicKey,
      dataHash,
      HASH_VERSION,
      reviewStatus,
      zoneMatch.zoneId,
    ]);
    if (inserted.length === 0) {
      // Lost a race on (actor_id, idempotency_key) after the lookup. Throwing rolls back
      // anything written above (a new consignment), then the stored row decides the answer.
      const { rows: raced } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
      throw new ItemOutcome(compareWithStored(index, step.stepId, raced[0], dataHash));
    }
    const transactionId = inserted[0].id;

    // Only a passed step moves the consignment: consignments.stage mirrors the latest
    // accepted step (4 Nov). A flagged step is kept as evidence and the consignment stays
    // where it was; if an officer later clears it, that review moves the stage.
    if (nextStage && reviewStatus === 'passed') {
      await tx.query(UPDATE_STAGE, [consignmentId, nextStage]);
    }

    // One alert per finding. An open alert holds the consignment (D3).
    for (const finding of findings) {
      await tx.query(INSERT_ALERT, [transactionId, finding.type, finding.severity, JSON.stringify(finding.details)]);
    }

    await audit.record(tx, {
      action: 'transaction.create',
      actorId: user.id,
      entityType: 'transaction',
      entityId: transactionId,
      details: { type: step.type, reviewStatus },
      ipAddress,
    });

    if (reviewStatus === 'flagged') {
      // Named after the most severe finding; alerts lists every one.
      return result(index, step.stepId, 'flagged', flaggedCodeFor(findings), {
        transactionId,
        reviewStatus,
        alerts: findings.map((f) => f.type),
      });
    }
    return result(index, step.stepId, 'created', null, { transactionId, reviewStatus });
  }

  // One item, start to finish. The checks that need no database run first, so a bad item
  // costs no transaction.
  async function processItem(index, item, user, ipAddress, zonesFor) {
    let step;
    try {
      step = parsePayload(item.payload);
    } catch (err) {
      if (err instanceof SigningError) return result(index, null, 'rejected', payloadCode(err));
      throw err;
    }

    let signatureBytes;
    try {
      signatureBytes = signatures.decodeSignature(item.signature);
    } catch (err) {
      if (err instanceof SigningError) return result(index, step.stepId, 'rejected', 'SIGNATURE_MALFORMED');
      throw err;
    }

    // The signed actor must be the logged-in user, so a record can never be submitted
    // under another account, and it is checked against the key registered to that account.
    if (step.actorId !== user.id) return result(index, step.stepId, 'rejected', 'ACTOR_MISMATCH');
    if (ROLE_FOR_TYPE[step.type] !== user.role) return result(index, step.stepId, 'rejected', 'STEP_NOT_ALLOWED_FOR_ROLE');

    try {
      return await db.transaction((tx) => storeStep(tx, { index, user, step, item, signatureBytes, ipAddress, zonesFor }));
    } catch (err) {
      if (err instanceof ItemOutcome) return err.outcome;
      throw err;
    }
  }

  return {
    // user: req.user (id and role, loaded from the database by requireAuth).
    // items: the validated body's steps, [{ payload, signature }].
    // Returns one result per item, in the same order.
    async syncSteps(user, items, { ipAddress = null } = {}) {
      // The active zones, read at most once per call: a batch of 50 steps costs one zone
      // query, not 50, and none at all if no item gets as far as needing it. Zones change
      // rarely; a zone switched off while a batch is running still counts for that batch.
      let zones = null;
      const zonesFor = async (tx) => {
        if (zones === null) zones = (await tx.query(SELECT_ACTIVE_ZONES)).rows;
        return zones;
      };

      const results = [];
      // One at a time, in order: a later item may depend on an earlier one, and the
      // database connection runs one query at a time anyway.
      for (const [index, item] of items.entries()) {
        results.push(await processItem(index, item, user, ipAddress, zonesFor));
      }
      return results;
    },
  };
}
