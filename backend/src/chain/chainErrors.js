// Sorts any error from the chain client into a small fixed set of codes, each with what the
// anchoring worker should do about it (docs/contract-spec.md, section 6).
//
// The output is only our own code, a fixed reason and, where it matters, a decoded field or
// stage. The error's own message is read here to recognise it, and is never passed on:
// ethers and the RPC provider put request details in their messages, including the RPC URL,
// whose path carries the provider's API key.
//
// Pure: no network. Interface only decodes bytes, using the minimal ABI.
import { Interface } from 'ethers';
import { MINECHAIN_ABI } from './mineChainAbi.js';

const abi = new Interface(MINECHAIN_ABI);

// What the worker does with each result:
//   stop       stop the worker; a person has to fix the configuration
//   fail       mark the step failed; resending the same data cannot succeed
//   reconcile  read the contract to see whether the step is already anchored
//   retry      try the step again later; this counts as an attempt
//   backoff    wait and try again; not the step's fault, so not an attempt
//   pause      stop sending until the wallet or the fee changes; not an attempt
//   inspect    the transaction itself must be looked up (nonce or mempool state)
const entry = (action, reason) => Object.freeze({ action, reason });

export const CHAIN_ERRORS = Object.freeze({
  ROLE_LOST: entry('stop', 'the recorder wallet does not hold RECORDER_ROLE'),
  INVALID_INPUT: entry('fail', 'the contract refused a zero id, actor reference, weight or hash'),
  ALREADY_EXISTS: entry('reconcile', 'the consignment id is already registered on-chain'),
  INVALID_STAGE: entry('fail', 'the step is not allowed from the consignment stage on-chain'),
  RPC_UNAVAILABLE: entry('backoff', 'the RPC provider could not be reached or refused the request'),
  INSUFFICIENT_FUNDS: entry('pause', 'the recorder wallet cannot pay for the transaction'),
  FEE_TOO_HIGH: entry('pause', 'the network fee is above the configured maximum'),
  NONCE_USED: entry('inspect', 'the nonce has already been used by another transaction'),
  REPLACEMENT_UNDERPRICED: entry('inspect', 'a transaction with this nonce is already waiting with a higher fee'),
  ALREADY_KNOWN: entry('inspect', 'the node already has this exact transaction'),
  UNKNOWN: entry('retry', 'an unrecognised error'),
});

// The contract's enums, in declaration order (MineChain.sol).
const INPUT_FIELDS = Object.freeze(['id', 'actorRef', 'weightMilligrams', 'dataHash']);
const STAGES = Object.freeze(['None', 'Registered', 'InTransit', 'Purchased']);

// Errors nest: ethers wraps the provider's error, which wraps the node's. This follows the
// usual wrapper properties a few levels deep. The depth limit also stops a loop if an error
// ever refers back to itself.
const NESTED_KEYS = ['error', 'info', 'cause', 'data'];
const MAX_DEPTH = 5;

function* nestedObjects(err, depth = 0) {
  if (err === null || typeof err !== 'object' || depth > MAX_DEPTH) return;
  yield err;
  for (const key of NESTED_KEYS) {
    yield* nestedObjects(err[key], depth + 1);
  }
}

// Revert data is the 4-byte error selector plus its ABI-encoded arguments, as hex.
function findRevertData(err) {
  for (const obj of nestedObjects(err)) {
    const { data } = obj;
    if (typeof data === 'string' && /^0x([0-9a-fA-F]{2}){4,}$/.test(data)) return data;
  }
  return null;
}

// All the message text in the error and its wrappers, only for matching below. It is never
// returned, stored or logged.
function messageText(err) {
  if (typeof err === 'string') return err;
  const parts = [];
  for (const obj of nestedObjects(err)) {
    for (const key of ['message', 'shortMessage', 'reason']) {
      if (typeof obj[key] === 'string') parts.push(obj[key]);
    }
  }
  return parts.join('\n');
}

function codesOf(err) {
  const codes = new Set();
  for (const obj of nestedObjects(err)) {
    if (obj.code !== undefined) codes.add(obj.code);
  }
  return codes;
}

// The HTTP status of a failed request, wherever ethers or fetch put it.
function httpStatus(err) {
  for (const obj of nestedObjects(err)) {
    for (const value of [obj.status, obj.statusCode, obj.response?.statusCode]) {
      if (Number.isInteger(value)) return value;
    }
    // ethers' info.responseStatus is text such as "429 Too Many Requests".
    const match = typeof obj.responseStatus === 'string' ? /^(\d{3})\b/.exec(obj.responseStatus) : null;
    if (match) return Number(match[1]);
  }
  return null;
}

// Node's system error codes for a connection that failed or timed out.
const NETWORK_CODES = new Set([
  'ECONNRESET', 'ECONNREFUSED', 'ENOTFOUND', 'ETIMEDOUT', 'EAI_AGAIN', 'EPIPE', 'ENETUNREACH',
  'EHOSTUNREACH', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_SOCKET', 'UND_ERR_HEADERS_TIMEOUT',
]);
// ethers' own codes for the same situations, and BAD_DATA for a provider that answered
// with something that is not valid JSON-RPC.
const ETHERS_RPC_CODES = new Set(['NETWORK_ERROR', 'TIMEOUT', 'SERVER_ERROR', 'BAD_DATA']);
// JSON-RPC error codes that mean "busy or broken", not "your request is wrong":
// -32005 limit exceeded (rate limiting) and -32603 internal error.
const JSON_RPC_BUSY_CODES = new Set([-32005, -32603]);

function result(code, details = {}) {
  const { action, reason } = CHAIN_ERRORS[code];
  return Object.freeze({ code, action, reason, ...details });
}

function fromRevert(data) {
  let decoded;
  try {
    // null when the selector is not one of ours; throws when it is ours but the arguments
    // are cut short, which counts as unrecognised too.
    decoded = abi.parseError(data);
  } catch {
    decoded = null;
  }

  switch (decoded?.name) {
    case 'AccessControlUnauthorizedAccount':
      return result('ROLE_LOST');
    case 'InvalidInput':
      return result('INVALID_INPUT', { field: INPUT_FIELDS[Number(decoded.args.field)] ?? 'unknown' });
    case 'ConsignmentAlreadyExists':
      return result('ALREADY_EXISTS');
    case 'InvalidStage': {
      const currentStage = STAGES[Number(decoded.args.current)] ?? 'unknown';
      // Stage None means the registration has not reached the chain yet, for example a
      // fallback RPC a few blocks behind, so it is worth trying again (spec section 6).
      // Any other stage cannot change by waiting.
      return currentStage === 'None'
        ? Object.freeze({ ...result('INVALID_STAGE', { currentStage }), action: 'retry' })
        : result('INVALID_STAGE', { currentStage });
    }
    default:
      return result('UNKNOWN');
  }
}

export function classifyChainError(err) {
  const revertData = findRevertData(err);
  if (revertData) return fromRevert(revertData);

  const codes = codesOf(err);
  const text = messageText(err);

  // Checked before the RPC rules: a node refusing a transaction answers with an ordinary
  // JSON-RPC error, which must not be mistaken for the provider being down.
  if (codes.has('INSUFFICIENT_FUNDS') || /insufficient funds/i.test(text)) return result('INSUFFICIENT_FUNDS');
  if (codes.has('NONCE_EXPIRED') || /nonce too low|nonce has already been used/i.test(text)) return result('NONCE_USED');
  if (codes.has('REPLACEMENT_UNDERPRICED') || /replacement transaction underpriced/i.test(text)) {
    return result('REPLACEMENT_UNDERPRICED');
  }
  if (/already known|known transaction/i.test(text)) return result('ALREADY_KNOWN');
  // Geth's own safety cap on one transaction's total fee (RPC option txfeecap).
  if (/exceeds the configured cap/i.test(text)) return result('FEE_TOO_HIGH');

  const status = httpStatus(err);
  if (status === 429 || (status !== null && status >= 500)) return result('RPC_UNAVAILABLE');
  for (const code of codes) {
    if (NETWORK_CODES.has(code) || ETHERS_RPC_CODES.has(code) || JSON_RPC_BUSY_CODES.has(code)) {
      return result('RPC_UNAVAILABLE');
    }
  }
  // fetch() throws a bare TypeError("fetch failed") when the connection itself fails.
  if (/fetch failed|socket hang up|network error|timed? ?out/i.test(text)) return result('RPC_UNAVAILABLE');

  return result('UNKNOWN');
}

// The worker's own refusal when the fee is above ANCHOR_MAX_FEE_GWEI. Built here so it has
// the same shape as a classified error and needs no special case.
export function feeTooHigh() {
  return result('FEE_TOO_HIGH');
}

// The text stored in transactions.anchor_error: our code, the decoded detail if any, and the
// fixed reason. Never the original message, so nothing from the provider reaches the database.
export function toAnchorError(classified) {
  const detail = classified.field ?? classified.currentStage;
  return `${classified.code}${detail ? `:${detail}` : ''}: ${classified.reason}`;
}
