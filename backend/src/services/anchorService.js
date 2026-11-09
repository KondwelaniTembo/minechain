// The anchoring worker's single tick (8 Nov plan, step 8; 9 Nov plan for 8.7). Each call to
// runOnce():
//   1. takes the advisory lock, or answers "busy";
//   2. reconciles every submitted row against the chain (the crash table);
//   3. if nothing is still in flight, sends at most ONE eligible step;
//   4. releases the lock and returns a small summary.
//
// One transaction in flight at a time keeps nonces simple and crash recovery provable, at
// the cost of throughput (about 1-2 steps a minute; decisions.md, 9 Nov). runOnce never
// waits for mining and never holds a database transaction open across a network call: the
// only transaction is the short one around the "submitted" UPDATE.
//
// Errors from the chain arrive as ChainClientError with an action (chainErrors.js):
//   backoff (RPC down)  the tick ends; nothing about the step changes; not an attempt
//   stop (ROLE_LOST)    this service stops for good, until restart; rows are untouched
//   pause (funds, fee)  nothing is sent this tick; not an attempt
//   fail / retry        recorded on the step, which counts as an attempt
import { ChainClientError } from '../chain/chainClient.js';
import { toAnchorError } from '../chain/chainErrors.js';
import { DEPLOY_BLOCK } from '../chain/mineChainAbi.js';
import { AnchorCallError, buildAnchorCall, receiptEventMismatches } from './anchorCall.js';
import { nextEligibleStep, submittedSteps, tryAnchorLock } from './anchorQueue.js';

// How long a submitted transaction may go unseen before it counts as dropped.
export const ANCHOR_GRACE_SECONDS = 120;
// Log searches start from the step's received_at, never from the deployment block: Sepolia
// adds about 7,200 blocks a day, so a search from deployment grows by ~15 requests of 500
// blocks every day. A step cannot be on-chain before the server received it. The margin
// covers block times slower than 12 s and a server clock that is a little off.
export const SECONDS_PER_BLOCK = 12;
export const LOG_SEARCH_MARGIN_BLOCKS = 1000;

// Our own anchor_error texts: a fixed code, then a fixed reason. Never provider text.
export const ANCHOR_ERRORS = Object.freeze({
  MINED_REVERTED: 'MINED_REVERTED: the transaction was mined but reverted; the next dry run shows why',
  MAX_ATTEMPTS: 'MAX_ATTEMPTS: the transaction was mined but reverted, and the step has used every attempt',
  PENDING_REPLACED: "PENDING_REPLACED: another transaction used this step's nonce, so the step is sent again",
  ID_ALREADY_ANCHORED: 'ID_ALREADY_ANCHORED: the consignment id is registered on-chain with another hash',
  receiptMismatch: (fields) => `RECEIPT_MISMATCH:${fields.join(',')}: the mined event does not match the step`,
});

// The first block a search for this step's event needs to look at.
export function searchStartBlock(latestBlock, receivedAt, now) {
  const elapsedSeconds = Math.max(0, Math.floor((now.getTime() - receivedAt.getTime()) / 1000));
  const start = latestBlock - Math.ceil(elapsedSeconds / SECONDS_PER_BLOCK) - LOG_SEARCH_MARGIN_BLOCKS;
  return Math.max(DEPLOY_BLOCK, start);
}

// ---------- the only statements that change a step's anchoring state ----------
// Each one names the state it expects in its WHERE, so it never overwrites a row that
// changed underneath it; rowCount 0 then means "leave it, look again next tick".

// U1: pending -> submitted. The hash and nonce are known before broadcast, so after a crash
// the worker knows what it may have sent.
const SUBMIT = `
  UPDATE transactions
     SET anchor_status = 'submitted', chain_tx_hash = $2, anchor_nonce = $3,
         anchor_submitted_at = $4, anchor_attempts = anchor_attempts + 1, anchor_error = NULL
   WHERE id = $1 AND anchor_status = 'pending'`;

// U2: -> confirmed. The hash may differ from the stored one when the transaction was found
// through the logs. anchored_at is the block's time, not the server's.
const CONFIRM_SUBMITTED = `
  UPDATE transactions
     SET anchor_status = 'confirmed', chain_tx_hash = $2, block_number = $3, anchored_at = $4,
         anchor_error = NULL
   WHERE id = $1 AND anchor_status = 'submitted' AND chain_tx_hash = $5`;
const CONFIRM_PENDING = `
  UPDATE transactions
     SET anchor_status = 'confirmed', chain_tx_hash = $2, block_number = $3, anchored_at = $4,
         anchor_error = NULL
   WHERE id = $1 AND anchor_status = 'pending'`;

// U3: the same nonce, re-signed. Also used to put the old hash back.
const RESEND = `
  UPDATE transactions
     SET chain_tx_hash = $2, anchor_submitted_at = $3
   WHERE id = $1 AND anchor_status = 'submitted' AND chain_tx_hash = $4`;

// U4: submitted -> pending, only when our transaction can never be mined (its nonce is used
// by another, or it reverted). $3 gives the attempt back when it was not the step's fault.
const BACK_TO_PENDING = `
  UPDATE transactions
     SET anchor_status = 'pending', chain_tx_hash = NULL, anchor_nonce = NULL,
         anchor_submitted_at = NULL, anchor_attempts = GREATEST(anchor_attempts - $3, 0),
         anchor_error = $4
   WHERE id = $1 AND anchor_status = 'submitted' AND chain_tx_hash = $2`;

// U5: an attempt that the dry run refused. One statement decides retry or fail, so the
// count and the decision can never disagree. In SET, anchor_attempts is the old value.
const RETRY_OR_FAIL = `
  UPDATE transactions
     SET anchor_attempts = anchor_attempts + 1, anchor_error = $2,
         anchor_status = CASE WHEN $3::boolean OR anchor_attempts + 1 >= $4 THEN 'failed' ELSE 'pending' END
   WHERE id = $1 AND anchor_status = 'pending'
  RETURNING anchor_status`;

// U6: submitted -> failed, keeping the hash as evidence of what was mined.
const FAIL_SUBMITTED = `
  UPDATE transactions
     SET anchor_status = 'failed', anchor_error = $3
   WHERE id = $1 AND anchor_status = 'submitted' AND chain_tx_hash = $2`;

const toHex = (bytes) => `0x${Buffer.from(bytes).toString('hex')}`;
const fromHex = (hex) => Buffer.from(hex.slice(2), 'hex');
const withHeadroom = (gas) => (gas * 12n) / 10n;
const isChainError = (err) => err instanceof ChainClientError;

// Thrown inside a tick to end it with an outcome. Caught by runOnce, never escapes.
class EndTick {
  constructor(outcome, details = {}) {
    this.outcome = outcome;
    this.details = details;
  }
}

// db: the app's db object. chain: a chain client (real or fake). config: config.anchor
// (confirmations, maxAttempts, maxFeePerGasWei). clock: the server's time, injectable so
// tests can pass the grace period. lock: () => a lock from tryAnchorLock; by default taken
// on `pool`. log: warnings and errors, codes only.
export function createAnchorService({ db, pool, chain, config, clock = () => new Date(), lock, log = console }) {
  const acquireLock = lock ?? (() => tryAnchorLock(pool));
  if (!lock && !pool) throw new TypeError('createAnchorService needs pool or lock');

  // Set once the wallet has lost RECORDER_ROLE. Only a person can fix that, so every later
  // tick answers at once, without touching the chain or the database.
  let stopped = false;

  async function confirmations(blockNumber) {
    const latest = await chain.getBlockNumber();
    return latest - blockNumber + 1;
  }

  // The step's own event among a list of decoded events, or null.
  function matchingEvent(events, step) {
    return events.find((e) => receiptEventMismatches(e, step, chain.contractAddress).length === 0) ?? null;
  }

  // Searches the logs for the step's event, starting near its received_at.
  async function findStepEvent(step, call) {
    const latest = await chain.getBlockNumber();
    const events = await chain.getLogs(call.args[0], searchStartBlock(latest, step.received_at, clock()), latest);
    return matchingEvent(events, step);
  }

  // Writes confirmed once the event's block is deep enough and its time is known.
  // Returns false when it has to wait.
  async function confirmFromEvent(step, { hash, blockNumber }, statement, extraParams) {
    if ((await confirmations(blockNumber)) < config.confirmations) return false;
    const seconds = await chain.getBlockTimestamp(blockNumber);
    if (seconds === null) return false; // this RPC has not seen the block yet
    const { rowCount } = await db.query(statement, [step.id, fromHex(hash), blockNumber, new Date(seconds * 1000), ...extraParams]);
    return rowCount === 1;
  }

  // ---------- reconcile: one submitted row (the crash table) ----------

  async function reconcile(row) {
    const call = buildAnchorCall(row);
    const storedHash = toHex(row.chain_tx_hash);

    // Mined, possibly before a crash stopped us marking it.
    const receipt = await chain.getReceipt(storedHash);
    if (receipt) {
      if ((await confirmations(receipt.blockNumber)) < config.confirmations) return 'waiting';
      if (receipt.status !== 1) {
        // Our nonce is used and the call reverted: retrying cannot anchor it twice.
        if (row.anchor_attempts >= config.maxAttempts) {
          await db.query(FAIL_SUBMITTED, [row.id, row.chain_tx_hash, ANCHOR_ERRORS.MAX_ATTEMPTS]);
          return 'failed';
        }
        await db.query(BACK_TO_PENDING, [row.id, row.chain_tx_hash, 0, ANCHOR_ERRORS.MINED_REVERTED]);
        return 'returnedToPending';
      }
      if (!matchingEvent(receipt.events, row)) {
        const fields = receiptEventMismatches(receipt.events[0], row, chain.contractAddress);
        await db.query(FAIL_SUBMITTED, [row.id, row.chain_tx_hash, ANCHOR_ERRORS.receiptMismatch(fields)]);
        log.error(`Anchoring: step ${row.id} was mined with a different event (${fields.join(', ')})`);
        return 'failed';
      }
      const done = await confirmFromEvent(row, { hash: receipt.hash, blockNumber: receipt.blockNumber }, CONFIRM_SUBMITTED, [
        row.chain_tx_hash,
      ]);
      return done ? 'confirmed' : 'waiting';
    }

    // Not seen yet: give the network time before deciding it is gone.
    const unseenMs = clock().getTime() - row.anchor_submitted_at.getTime();
    if (unseenMs < ANCHOR_GRACE_SECONDS * 1000) return 'waiting';

    // Never resend without first asking the contract whether the step is already there.
    // The struct holds the latest step of the consignment, and with one transaction in
    // flight that can only be this one.
    const record = await chain.getConsignment(call.args[0]);
    if (record.dataHash.toLowerCase() === call.args[3]) {
      // Anchored by a transaction this row does not know: find it for its hash and block.
      const event = await findStepEvent(row, call);
      if (!event) return 'waiting'; // the logs can lag behind the state on some RPCs
      const done = await confirmFromEvent(row, { hash: event.transactionHash, blockNumber: event.blockNumber }, CONFIRM_SUBMITTED, [
        row.chain_tx_hash,
      ]);
      return done ? 'confirmed' : 'waiting';
    }

    const nonce = Number(row.anchor_nonce);
    const latestNonce = await chain.getNonce('latest');
    if (latestNonce > nonce) {
      // Something else was mined with our nonce, so our transaction never can be.
      await db.query(BACK_TO_PENDING, [row.id, row.chain_tx_hash, 1, ANCHOR_ERRORS.PENDING_REPLACED]);
      return 'returnedToPending';
    }

    // The nonce is unused: dropped, or never broadcast before a crash. Re-sign with the SAME
    // nonce, so at most one copy can ever be mined.
    return resend(row, call, nonce, storedHash);
  }

  async function resend(row, call, nonce, storedHash) {
    let gas;
    try {
      gas = await chain.estimateGas(call);
    } catch (err) {
      if (!isChainError(err) || err.action === 'backoff' || err.code === 'ROLE_LOST') throw err;
      // The nonce is unused, so the row stays submitted rather than risk a second copy
      // later: a stuck step is safe, a double anchor is not.
      log.warn(`Anchoring: step ${row.id} cannot be resent yet: ${err.code}`);
      return 'waiting';
    }
    const fees = await chain.getFeeData();
    if (fees.maxFeePerGas > config.maxFeePerGasWei) return 'waiting';

    const signed = await chain.signTransaction({
      call,
      nonce,
      gasLimit: withHeadroom(gas),
      maxFeePerGas: fees.maxFeePerGas,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    });
    // Stored before broadcast, as with the first send. Identical fees give identical bytes
    // (signatures are deterministic), so the hash may not change at all.
    const { rowCount } = await db.query(RESEND, [row.id, fromHex(signed.hash), clock(), row.chain_tx_hash]);
    if (rowCount !== 1) return 'waiting';

    try {
      await chain.broadcast(signed.rawTx);
    } catch (err) {
      if (!isChainError(err) || err.action === 'backoff') throw err;
      if (err.action === 'inspect' && signed.hash !== storedHash) {
        // The old copy is still waiting somewhere with a fee ours does not beat: keep
        // following the old one.
        await db.query(RESEND, [row.id, row.chain_tx_hash, clock(), fromHex(signed.hash)]);
      }
      return 'waiting';
    }
    return 'resent';
  }

  // ---------- send: at most one new step ----------

  // The error table, for a step whose dry run was refused. Returns the tick's end.
  async function applyRefusal(step, call, err, counts) {
    if (err.action === 'pause') throw new EndTick('paused', { code: err.code });
    if (err.action === 'reconcile') return alreadyExists(step, call, counts);

    const final = err.action === 'fail';
    const { rows } = await db.query(RETRY_OR_FAIL, [step.id, toAnchorError(err), final, config.maxAttempts]);
    if (rows[0]?.anchor_status === 'failed') counts.failed += 1;
    return new EndTick('refused', { stepId: step.id, code: err.code });
  }

  // ConsignmentAlreadyExists: an earlier send may have succeeded without us recording it.
  async function alreadyExists(step, call, counts) {
    const event = await findStepEvent(step, call);
    if (event) {
      const done = await confirmFromEvent(step, { hash: event.transactionHash, blockNumber: event.blockNumber }, CONFIRM_PENDING, []);
      if (done) counts.confirmed += 1;
      return new EndTick(done ? 'refused' : 'waiting', { stepId: step.id, code: 'ALREADY_EXISTS' });
    }
    await db.query(RETRY_OR_FAIL, [step.id, ANCHOR_ERRORS.ID_ALREADY_ANCHORED, true, config.maxAttempts]);
    counts.failed += 1;
    return new EndTick('refused', { stepId: step.id, code: 'ID_ALREADY_ANCHORED' });
  }

  async function send(counts, heldLock) {
    const candidate = await nextEligibleStep(db);
    if (!candidate) return new EndTick('idle');

    let call;
    try {
      call = buildAnchorCall(candidate);
    } catch (err) {
      if (!(err instanceof AnchorCallError)) throw err;
      // Stored data the contract would refuse: a backend bug, so no retry.
      await db.query(RETRY_OR_FAIL, [candidate.id, `${err.code}: ${err.message}`, true, config.maxAttempts]);
      counts.failed += 1;
      return new EndTick('refused', { stepId: candidate.id, code: err.code });
    }

    let gas;
    try {
      gas = await chain.estimateGas(call); // the dry run
    } catch (err) {
      if (!isChainError(err) || err.action === 'backoff' || err.code === 'ROLE_LOST') throw err;
      return applyRefusal(candidate, call, err, counts);
    }

    // The money checks, none of which is the step's fault.
    const fees = await chain.getFeeData();
    if (fees.maxFeePerGas > config.maxFeePerGasWei) return new EndTick('paused', { code: 'FEE_TOO_HIGH' });
    const gasLimit = withHeadroom(gas);
    if ((await chain.getBalance()) < gasLimit * fees.maxFeePerGas) return new EndTick('paused', { code: 'INSUFFICIENT_FUNDS' });
    const latestNonce = await chain.getNonce('latest');
    const pendingNonce = await chain.getNonce('pending');
    // Nothing of ours is in flight, so a difference is someone else's transaction, such as
    // the wallet used by hand. Sending behind it could wait forever.
    if (pendingNonce !== latestNonce) return new EndTick('paused', { code: 'PENDING_TRANSACTIONS' });

    const signed = await chain.signTransaction({
      call,
      nonce: pendingNonce,
      gasLimit,
      maxFeePerGas: fees.maxFeePerGas,
      maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    });

    if (heldLock.isLost()) return new EndTick('busy');
    // The short transaction: is it still the step to send (an alert may have arrived while
    // we were on the network)? Then mark it submitted. No network call inside.
    const submitted = await db.transaction(async (tx) => {
      const again = await nextEligibleStep(tx);
      if (again?.id !== candidate.id) return false;
      await tx.query(SUBMIT, [candidate.id, fromHex(signed.hash), String(pendingNonce), clock()]);
      return true;
    });
    if (!submitted) return new EndTick('idle');

    try {
      await chain.broadcast(signed.rawTx);
    } catch (err) {
      if (!isChainError(err)) throw err;
      const hash = fromHex(signed.hash);
      // A definite refusal: the node did not take it, so undo, giving the attempt back.
      if (err.code === 'INSUFFICIENT_FUNDS' || err.code === 'FEE_TOO_HIGH') {
        await db.query(BACK_TO_PENDING, [candidate.id, hash, 1, toAnchorError(err)]);
        return new EndTick('paused', { stepId: candidate.id, code: err.code });
      }
      if (err.code === 'NONCE_USED') {
        await db.query(BACK_TO_PENDING, [candidate.id, hash, 1, toAnchorError(err)]);
        return new EndTick('refused', { stepId: candidate.id, code: err.code });
      }
      // Unreachable or unclear: it may have reached a node, so it stays submitted and the
      // next tick reconciles it.
      return new EndTick(err.action === 'backoff' ? 'backoff' : 'waiting', { stepId: candidate.id, code: err.code });
    }
    return new EndTick('sent', { stepId: candidate.id });
  }

  async function tick(counts, heldLock) {
    let inFlight = 0;
    for (const row of await submittedSteps(db)) {
      const result = await reconcile(row);
      counts[result] += 1;
      if (result === 'waiting' || result === 'resent') inFlight += 1;
    }
    if (inFlight > 0) return new EndTick('waiting');
    return send(counts, heldLock);
  }

  function summary(outcome, counts, { stepId = null, code = null } = {}) {
    return Object.freeze({ outcome, reconciled: Object.freeze({ ...counts }), stepId, code });
  }

  return Object.freeze({
    async runOnce() {
      const counts = { confirmed: 0, waiting: 0, resent: 0, returnedToPending: 0, failed: 0 };
      if (stopped) return summary('stopped', counts, { code: 'ROLE_LOST' });

      const heldLock = await acquireLock();
      if (!heldLock.acquired) return summary('busy', counts);
      try {
        const end = await tick(counts, heldLock);
        return summary(end.outcome, counts, end.details);
      } catch (err) {
        if (err instanceof EndTick) return summary(err.outcome, counts, err.details);
        if (!isChainError(err)) throw err; // a bug: let the caller see it
        if (err.code === 'ROLE_LOST') {
          stopped = true;
          log.error(`Anchoring stopped: ${chain.recorderAddress} no longer holds RECORDER_ROLE. Fix the role, then restart.`);
          return summary('stopped', counts, { code: err.code });
        }
        // RPC down, or any chain error not handled where it happened: nothing more is
        // changed this tick; every update already made stands on its own.
        return summary('backoff', counts, { code: err.code });
      } finally {
        await heldLock.release();
      }
    },
  });
}
