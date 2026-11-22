// The chain check behind the consignment view (FR-04; plan Â§3, "The chain check, per
// confirmed step"). For one stored step it answers one of four results:
//   match              the stored evidence, the row's columns and the anchored event agree
//   mismatch           something differs; `fields` names what (names only, never values)
//   not_anchored_yet   the step is not confirmed, so there is nothing on-chain to compare
//   chain_unavailable  the chain could not be asked, or not trusted, this time
//
// The rule that shapes it: a chain failure is never shown as tampering. Every reader error
// (a ChainClientError, including the reader's network-check refusals) and a missing reader
// give chain_unavailable. A mismatch is only ever declared from evidence: the stored bytes
// themselves, a receipt that says something else, or a receipt that is missing although
// the node is past its block AND does not hold the transaction in that block either (a
// node that prunes old receipts still keeps the transactions; see step 4).
//
// Steps 1 and 2 are pure and need no network, so a row whose own evidence disagrees is a
// mismatch before, and without, any chain call. No database here: B2.4 reads the row and
// raises the alert.
//
// Why the signature is verified again, although sync verified it on arrival: the threat
// here is tampering AFTER sync. The anchor hash is a public function, so someone who edits
// signed_payload and the columns together can also recompute data_hash, and every other
// local comparison then agrees. Only the signature cannot be forged without the phone's
// private key. Without this check, such a forgery would depend on the chain to be caught,
// and while the chain is unavailable it would show as chain_unavailable, hiding behind an
// outage. Verifying the stored signature over the stored payload with the stored key
// catches it with no chain at all.
import { anchorHash, verify } from './signatureService.js';
import { parsePayload } from './stepPayload.js';
import { SigningError, SIGNING_ERROR_CODES } from './signingError.js';
import { AnchorCallError, receiptEventMismatches } from './anchorCall.js';
import { ChainClientError } from '../chain/rpc.js';

export const CHECK_RESULTS = Object.freeze({
  MATCH: 'match',
  MISMATCH: 'mismatch',
  NOT_ANCHORED_YET: 'not_anchored_yet',
  CHAIN_UNAVAILABLE: 'chain_unavailable',
});

// The only anchor hash scheme ever written (signing-spec Â§7).
const SUPPORTED_HASH_VERSION = 1;

const EMPTY = Object.freeze([]);
const outcome = (result) => Object.freeze({ result, fields: EMPTY });
const MATCH = outcome(CHECK_RESULTS.MATCH);
const NOT_ANCHORED_YET = outcome(CHECK_RESULTS.NOT_ANCHORED_YET);
const CHAIN_UNAVAILABLE = outcome(CHECK_RESULTS.CHAIN_UNAVAILABLE);

function mismatch(fields, reason) {
  const body = { result: CHECK_RESULTS.MISMATCH, fields: Object.freeze([...new Set(fields)]) };
  if (reason) body.reason = reason;
  return Object.freeze(body);
}

// Which stored column a SigningError points at. Its message is not kept: the field name is
// all an officer is shown.
const SIGNING_FIELD = Object.freeze({
  [SIGNING_ERROR_CODES.KEY_INVALID]: 'signer_public_key',
  [SIGNING_ERROR_CODES.SIGNATURE_MALFORMED]: 'signature',
});
const signingField = (err) => SIGNING_FIELD[err.code] ?? 'signed_payload';

// A column value as text, the way pg returns it: bigint and numeric already arrive as
// text, timestamptz as a Date. Anything else (a JavaScript number above all) gives null,
// which equals no payload text: a float here would mean a caller broke the "text only" rule.
function columnText(value) {
  if (typeof value === 'string') return value;
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value.toISOString();
  return null;
}

// The payload field, and the row column it must equal. Mineral is a registration's only.
const COMPARED = Object.freeze([
  ['type', 'type'],
  ['stepId', 'idempotency_key'],
  ['actorId', 'actor_id'],
  ['qrCode', 'qr_code'],
  ['mineral', 'mineral_type'],
  ['weightMg', 'weight_mg'],
  ['latitude', 'latitude'],
  ['longitude', 'longitude'],
  ['capturedAt', 'captured_at'],
]);

// Steps 1 and 2: the stored evidence against itself and against the row. Returns the names
// of what differs and the recomputed anchor hash (null when it cannot be recomputed).
//
// row: { type, idempotency_key, actor_id, qr_code, mineral_type, weight_mg, latitude,
//        longitude, captured_at, signed_payload, signature, signer_public_key, data_hash,
//        hash_version }, as pg returns them (bytea as Buffer).
export function evidenceMismatches(row) {
  const fields = [];
  // A version this code does not know was not written by it, so it cannot be re-hashed and
  // trusted; nothing else is worth comparing.
  if (row.hash_version !== SUPPORTED_HASH_VERSION) {
    return Object.freeze({ fields: Object.freeze(['hash_version']), recomputedHash: null });
  }

  let recomputedHash = null;
  try {
    const evidence = { payload: row.signed_payload, signature: row.signature, publicKey: row.signer_public_key };
    recomputedHash = anchorHash(evidence);
    // The same verify sync uses. Reached only when the key and signature are well formed
    // (anchorHash checked them), so a false here means the signature does not cover these
    // bytes: see the header for why this is repeated.
    if (!verify(evidence)) fields.push('signature');
  } catch (err) {
    // Stored bytes that are no longer a valid key, signature or payload were altered.
    if (!(err instanceof SigningError)) throw err;
    fields.push(signingField(err));
  }

  let step = null;
  try {
    step = parsePayload(row.signed_payload);
  } catch (err) {
    if (!(err instanceof SigningError)) throw err;
    fields.push('signed_payload');
  }

  if (step) {
    for (const [payloadField, column] of COMPARED) {
      if (payloadField === 'mineral' && step.type !== 'registration') continue;
      if (step[payloadField] !== columnText(row[column])) fields.push(column);
    }
  }

  if (recomputedHash && !(Buffer.isBuffer(row.data_hash) && recomputedHash.equals(row.data_hash))) {
    fields.push('data_hash');
  }
  return Object.freeze({ fields: Object.freeze([...new Set(fields)]), recomputedHash });
}

// Step 3: a receipt against the step, with the RECOMPUTED hash in place of the stored one,
// so the chain is compared with the evidence, not with a column that could have been
// edited together with it. Returns the names of what differs.
//
// row also needs chain_id, actor_ref (as for buildAnchorCall) and block_number.
export function receiptMismatches(receipt, row, recomputedHash, contractAddress) {
  const fields = [];
  if (receipt.status !== 1) fields.push('receipt.status');
  if (String(receipt.blockNumber) !== columnText(row.block_number)) fields.push('receipt.blockNumber');

  const step = {
    type: row.type,
    chain_id: row.chain_id,
    actor_ref: row.actor_ref,
    weight_mg: row.weight_mg,
    data_hash: recomputedHash,
  };
  let eventFields;
  try {
    const each = receipt.events.map((event) => receiptEventMismatches(event, step, contractAddress));
    if (each.some((m) => m.length === 0)) {
      eventFields = EMPTY;
    } else {
      // No event matches: report the closest one, or every field when there is none.
      eventFields = each.length > 0
        ? each.reduce((best, m) => (m.length < best.length ? m : best))
        : receiptEventMismatches(null, step, contractAddress);
    }
  } catch (err) {
    // chain_id or actor_ref is not 32 non-zero bytes: the row cannot describe any event.
    if (!(err instanceof AnchorCallError)) throw err;
    eventFields = ['anchorCall'];
  }
  for (const name of eventFields) fields.push(`event.${name}`);
  return Object.freeze(fields);
}

// Step 4: no receipt for the stored hash. Missing is only evidence once the node has
// reached the block (plus the confirmations); before that, the node is behind. This is the
// first of step 4's two conditions; receiptPruned below is the second.
export function missingReceiptIsMismatch(latestBlock, blockNumber, confirmations) {
  return BigInt(latestBlock) >= BigInt(columnText(blockNumber)) + BigInt(confirmations);
}

// Step 4, second condition: the receipt is gone but the transaction is still in the stored
// block, sent to MineChain. Nodes that prune history (PublicNode kept receipts and logs for
// only about the last 10,000 blocks, Reports T5) still answer for the transaction, so this
// is a node that threw the receipt away, not a step that was never anchored. Without the
// receipt there is no event to compare, so the caller answers chain_unavailable, never a
// match. A transaction in another block, still pending, or sent anywhere else could not
// be this step's anchoring, and stays evidence.
//
// transaction: getTransaction's answer, { hash, blockNumber, to } or null.
export function receiptPruned(transaction, blockNumber, contractAddress) {
  if (transaction === null) return false;
  if (transaction.blockNumber === null || String(transaction.blockNumber) !== columnText(blockNumber)) return false;
  return typeof transaction.to === 'string' && transaction.to.toLowerCase() === contractAddress.toLowerCase();
}

const toHex = (bytes) => `0x${Buffer.from(bytes).toString('hex')}`;

// One step, steps 1 to 5. reader: a chain reader (src/chain/chainReader.js) or null.
// row: the columns listed at evidenceMismatches and receiptMismatches, plus anchor_status
// and chain_tx_hash. confirmations: config.anchor.confirmations.
export async function checkStep(reader, row, { confirmations }) {
  if (!Number.isSafeInteger(confirmations) || confirmations < 1) {
    throw new TypeError('confirmations must be a whole number of at least 1');
  }
  if (row.anchor_status !== 'confirmed') return NOT_ANCHORED_YET;

  const evidence = evidenceMismatches(row);
  if (evidence.fields.length > 0) return mismatch(evidence.fields);

  if (!reader) return CHAIN_UNAVAILABLE;

  const txHash = toHex(row.chain_tx_hash);
  let receipt;
  let nodeIsPast = false;
  let transaction = null;
  try {
    receipt = await reader.getReceipt(txHash);
    if (receipt === null) {
      nodeIsPast = missingReceiptIsMismatch(await reader.getBlockNumber(), row.block_number, confirmations);
      // Asked only when the missing receipt would otherwise accuse someone, so a healthy
      // check still costs one request per step.
      if (nodeIsPast) transaction = await reader.getTransaction(txHash);
    }
  } catch (err) {
    // Only chain errors are "unavailable". Anything else is a bug, and hiding it as an
    // unavailable chain would hide it for good.
    if (err instanceof ChainClientError) return CHAIN_UNAVAILABLE;
    throw err;
  }

  if (receipt === null) {
    if (!nodeIsPast || receiptPruned(transaction, row.block_number, reader.contractAddress)) {
      return CHAIN_UNAVAILABLE;
    }
    return mismatch(['chain_tx_hash'], 'TX_NOT_FOUND');
  }

  const fields = receiptMismatches(receipt, row, evidence.recomputedHash, reader.contractAddress);
  return fields.length > 0 ? mismatch(fields) : MATCH;
}
