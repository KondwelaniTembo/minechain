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
import { CHECKS, runChecks, reviewStatusFor } from './anomalyChecks.js';

// Who may sign each step type (the role check the database cannot make).
const ROLE_FOR_TYPE = Object.freeze({ registration: 'miner', handoff: 'transporter', purchase: 'buyer' });

// The anchor hash scheme of every row written here (signing-spec section 7).
const HASH_VERSION = 1;

// Plain-language messages, one per code, so the app can show them as they are.
const MESSAGES = Object.freeze({
  PAYLOAD_MALFORMED: 'This record is not in the signed format the server expects.',
  PAYLOAD_UNSUPPORTED_VERSION: 'This record uses a format version the server does not read. Update the app.',
  SIGNATURE_MALFORMED: 'The signature on this record is not in the expected form.',
  ACTOR_MISMATCH: 'This record was signed for a different account.',
  STEP_NOT_ALLOWED_FOR_ROLE: 'Your role cannot record this kind of step.',
  NO_DEVICE_KEY: 'This account has no registered device key yet. Register the key, then sync again.',
  STEP_ID_CONFLICT: 'A different record with the same step id was already received.',
  QR_CODE_ALREADY_REGISTERED: 'This custody record is already registered to a consignment.',
  STEP_TYPE_NOT_YET_SUPPORTED: 'The server does not accept this kind of step yet. Keep it and sync again later.',
  INVALID_SIGNATURE: 'The record was saved, but its signature did not match your device key. An officer will review it.',
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

// The step itself. Every value comes from the signed payload or the server:
//   - weight_mg, latitude, longitude and captured_at go in as the payload's text, so
//     PostgreSQL reads them into bigint, numeric(9,6) and timestamptz exactly, with no
//     JavaScript number in between;
//   - received_at is not listed, so the database sets it: the server's own receipt time is
//     never taken from the request;
//   - zone_id is NULL until the GPS zone check exists (a known gap until then: NULL is
//     meant to say "outside every zone");
//   - anchor_status takes its default ('pending'); a flagged step can never leave it
//     (transactions_anchor_only_if_approved).
// ON CONFLICT: if a second copy of the same step won a race since the lookup above, nothing
// is inserted and the caller compares hashes again.
const INSERT_STEP = `
  INSERT INTO transactions (
    consignment_id, actor_id, type, idempotency_key, weight_mg, latitude, longitude, zone_id,
    captured_at, signed_payload, signature, signer_public_key, data_hash, hash_version,
    review_status)
  VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, $8, $9, $10, $11, $12, $13, $14)
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

  // Everything that needs the database, for one item, in one transaction.
  async function storeRegistration(tx, { index, user, step, item, signatureBytes, ipAddress }) {
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
    // registration saved yesterday must come back as duplicate even if the consignment has
    // moved on since.
    const { rows: stored } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
    if (stored.length === 1) throw new ItemOutcome(compareWithStored(index, step.stepId, stored[0], dataHash));

    // A signature that does not verify is not refused: the record is stored as evidence and
    // flagged, with an alert for an officer (anomaly check 4).
    const verified = signatures.verify({ payload: item.payload, signature: signatureBytes, publicKey });
    const findings = runChecks({ step, verified, keyFingerprint: spkiFingerprint(publicKey) }, checks);
    const reviewStatus = reviewStatusFor(findings);

    const { rows: created } = await tx.query(INSERT_CONSIGNMENT, [step.qrCode, step.mineral, user.id]);
    if (created.length === 0) {
      // The code exists. If an identical copy of this step was committed by another
      // request while this one waited on the code's lock, it is a retry after all;
      // otherwise this custody record was already registered. (Recording that as a flagged
      // step with a duplicate_consignment alert comes with the duplicate rule.)
      const { rows: raced } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
      if (raced.length === 1) throw new ItemOutcome(compareWithStored(index, step.stepId, raced[0], dataHash));
      throw new ItemOutcome(result(index, step.stepId, 'rejected', 'QR_CODE_ALREADY_REGISTERED'));
    }
    const consignmentId = created[0].id;

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
    ]);
    if (inserted.length === 0) {
      // Lost a race on (actor_id, idempotency_key) after the lookup. Throwing rolls back the
      // consignment created above, then the stored row decides the answer.
      const { rows: raced } = await tx.query(SELECT_BY_STEP_ID, [user.id, step.stepId]);
      throw new ItemOutcome(compareWithStored(index, step.stepId, raced[0], dataHash));
    }
    const transactionId = inserted[0].id;

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
      return result(index, step.stepId, 'flagged', findings[0].type.toUpperCase(), {
        transactionId,
        reviewStatus,
        alerts: findings.map((f) => f.type),
      });
    }
    return result(index, step.stepId, 'created', null, { transactionId, reviewStatus });
  }

  // One item, start to finish. The checks that need no database run first, so a bad item
  // costs no transaction.
  async function processItem(index, item, user, ipAddress) {
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

    // Placeholder until handoffs and purchases are built: deferred, because the record is
    // valid and will be accepted unchanged once they are. Nothing is stored, so the app
    // keeps it in its queue and loses nothing.
    if (step.type !== 'registration') return result(index, step.stepId, 'deferred', 'STEP_TYPE_NOT_YET_SUPPORTED');

    try {
      return await db.transaction((tx) => storeRegistration(tx, { index, user, step, item, signatureBytes, ipAddress }));
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
      const results = [];
      // One at a time, in order: a later item may depend on an earlier one, and the
      // database connection runs one query at a time anyway.
      for (const [index, item] of items.entries()) {
        results.push(await processItem(index, item, user, ipAddress));
      }
      return results;
    },
  };
}
