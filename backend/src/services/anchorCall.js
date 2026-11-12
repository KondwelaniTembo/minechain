// Turns one stored custody step into the contract call that anchors it, and checks that a
// receipt's event really belongs to that step (docs/contract-spec.md, sections 5 and 6).
//
// Pure: no network, no database. The worker reads the row, this module decides what to
// send, and the chain client sends it. Keeping the mapping here means every rule about
// bytes and weights can be tested without a chain.

export class AnchorCallError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AnchorCallError';
    this.code = code;
  }
}

export const ANCHOR_CALL_ERROR_CODES = Object.freeze({
  STEP_TYPE_UNKNOWN: 'STEP_TYPE_UNKNOWN',
  BYTES32_INVALID: 'BYTES32_INVALID',
  WEIGHT_INVALID: 'WEIGHT_INVALID',
});

// One entry per transactions.type. actorArg is the event's name for the actor reference,
// which differs per event although it is always the second argument.
const STEP_CALLS = Object.freeze({
  registration: Object.freeze({ functionName: 'registerConsignment', eventName: 'ConsignmentRegistered', actorArg: 'minerRef' }),
  handoff: Object.freeze({ functionName: 'recordHandoff', eventName: 'HandoffRecorded', actorArg: 'transporterRef' }),
  purchase: Object.freeze({ functionName: 'recordPurchase', eventName: 'PurchaseRecorded', actorArg: 'buyerRef' }),
});

// The contract's weightMilligrams is a uint64.
const UINT64_MAX = 2n ** 64n - 1n;

function callFor(type) {
  // Object.hasOwn, not STEP_CALLS[type]: a type such as "constructor" or "__proto__" must
  // not find something inherited from Object.prototype.
  if (typeof type !== 'string' || !Object.hasOwn(STEP_CALLS, type)) {
    throw new AnchorCallError(ANCHOR_CALL_ERROR_CODES.STEP_TYPE_UNKNOWN, 'step type must be registration, handoff or purchase');
  }
  return STEP_CALLS[type];
}

// pg returns bytea as a Buffer. A hex string is refused on purpose: it would mean the
// caller already converted the value somewhere, and the two conversions could disagree.
function toBytes32(value, field) {
  if (!(value instanceof Uint8Array) || value.length !== 32) {
    throw new AnchorCallError(ANCHOR_CALL_ERROR_CODES.BYTES32_INVALID, `${field} must be exactly 32 bytes`);
  }
  // The contract refuses a zero id, actor reference or hash (InvalidInput). Catching it
  // here saves a transaction that could only revert.
  if (value.every((byte) => byte === 0)) {
    throw new AnchorCallError(ANCHOR_CALL_ERROR_CODES.BYTES32_INVALID, `${field} must not be all zero`);
  }
  return `0x${Buffer.from(value).toString('hex')}`;
}

// weight_mg arrives from pg as text, because bigint can exceed what a JavaScript number
// holds exactly (2^53). It goes straight from text to BigInt, never through Number().
function toWeight(value) {
  // Digits only, no leading zero: "1.5", "1e3", "-1", "0" and "01" are all refused.
  // "01" is not wrong as a number, but the column never produces it, so seeing it would
  // mean the value came from somewhere else.
  if (typeof value !== 'string' || !/^[1-9]\d*$/.test(value)) {
    throw new AnchorCallError(ANCHOR_CALL_ERROR_CODES.WEIGHT_INVALID, 'weight_mg must be a whole number of milligrams above 0, as text');
  }
  const weight = BigInt(value);
  if (weight > UINT64_MAX) {
    throw new AnchorCallError(ANCHOR_CALL_ERROR_CODES.WEIGHT_INVALID, 'weight_mg does not fit the contract (uint64)');
  }
  return weight;
}

// step: { type, chain_id, actor_ref, weight_mg, data_hash }, column names as the worker's
// query returns them. The arguments are in the contract's order, which is the same for all
// three functions: (id, actorRef, weightMilligrams, dataHash).
export function buildAnchorCall(step) {
  const { functionName } = callFor(step.type);
  return Object.freeze({
    functionName,
    args: Object.freeze([
      toBytes32(step.chain_id, 'chain_id'),
      toBytes32(step.actor_ref, 'actor_ref'),
      toWeight(step.weight_mg),
      toBytes32(step.data_hash, 'data_hash'),
    ]),
  });
}

function sameHex(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

// Compares a decoded receipt event with the step it should anchor, and returns the names of
// the fields that differ (an empty array means it matches). The names, not just true or
// false, so a mismatch can be logged precisely without logging any values.
//
// event: { address, name, args } where args can be read by name, as ethers' parseLog gives
// them. contractAddress: the configured MineChain address.
export function receiptEventMismatches(event, step, contractAddress) {
  const { eventName, actorArg } = callFor(step.type);
  const [id, actorRef, weight, dataHash] = buildAnchorCall(step).args;
  const args = event?.args ?? {};

  const mismatches = [];
  // Addresses compared ignoring case: checksum case is presentation, not identity. Without
  // this check, any contract emitting an event with the same shape would count.
  if (!sameHex(event?.address, contractAddress)) mismatches.push('address');
  if (event?.name !== eventName) mismatches.push('name');
  if (!sameHex(args.id, id)) mismatches.push('id');
  if (!sameHex(args[actorArg], actorRef)) mismatches.push(actorArg);
  // ethers decodes uint64 as bigint; a number here would mean a different decoder.
  if (typeof args.weightMilligrams !== 'bigint' || args.weightMilligrams !== weight) {
    mismatches.push('weightMilligrams');
  }
  if (!sameHex(args.dataHash, dataHash)) mismatches.push('dataHash');
  return Object.freeze(mismatches);
}
