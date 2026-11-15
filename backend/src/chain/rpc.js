// The JSON-RPC plumbing shared by the two modules that talk to Ethereum: chainClient.js
// (the anchoring worker, which signs) and chainReader.js (verification, which never signs).
// Moved here from chainClient.js unchanged, so both use one provider set-up, one fallback
// rule and one event decoder.
//
// Secrets: an RPC URL carries the provider's API key in its path. A URL is only ever passed
// to makeProvider and hostOf; callers keep it in their own closures. Provider errors are
// never passed on: ethers puts the request URL into its error messages, so every error is
// classified first and replaced by a ChainClientError built from fixed codes and reasons.
import { FetchRequest, Interface, JsonRpcProvider } from 'ethers';
import { classifyChainError, toAnchorError } from './chainErrors.js';
import { MINECHAIN_ABI } from './mineChainAbi.js';

const abi = new Interface(MINECHAIN_ABI);

// A request that has not answered by then is treated as unavailable, so the worker can move
// on to the fallback instead of waiting for ethers' default of five minutes.
export const DEFAULT_TIMEOUT_MS = 15_000;

// The only error the chain modules throw for chain problems. It carries a code, the action
// the worker should take, a fixed reason, and which endpoint answered. Deliberately no
// `cause`: util.inspect prints an error's cause, and the original error contains the URL.
export class ChainClientError extends Error {
  constructor(classified, endpoint) {
    super(toAnchorError(classified));
    this.name = 'ChainClientError';
    this.code = classified.code;
    this.action = classified.action;
    this.reason = classified.reason;
    this.endpoint = endpoint;
    if (classified.field !== undefined) this.field = classified.field;
    if (classified.currentStage !== undefined) this.currentStage = classified.currentStage;
  }
}

// The host name is the only part of an RPC URL that may be logged: providers put the API
// key in the path (Infura /v3/<key>, Alchemy /v2/<key>), never in the host.
export function hostOf(url) {
  return new URL(url).hostname;
}

export function makeProvider(url, network, { timeoutMs, transport }) {
  const request = new FetchRequest(url);
  request.timeout = timeoutMs;
  // No automatic retries on HTTP 429: ethers would otherwise retry up to 12 times with
  // growing delays. One answer per provider; the fallback and the worker's backoff decide.
  request.setThrottleParams({ maxAttempts: 1 });
  // Test seam: tests replace the HTTP layer with an in-memory function, so no test can
  // reach the network. Production leaves it unset and ethers uses Node's https module.
  if (transport) request.getUrlFunc = transport;

  return new JsonRpcProvider(request, network, {
    // The chain id is fixed by config, so ethers never asks the node for it on its own.
    // Without this, ethers would send eth_chainId in the background as soon as it starts,
    // and retry every second, printing to console, while the RPC is unreachable.
    staticNetwork: network,
    // One JSON-RPC call per HTTP request: some free plans refuse batches, and a failure
    // then belongs to exactly one call.
    batchMaxCount: 1,
    // No reuse of answers between calls: a nonce or receipt read twice must be read twice.
    cacheTimeout: -1,
  });
}

export function assertBytes32Hex(value, name) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new TypeError(`${name} must be 0x and 64 hex characters`);
  }
}

// Returns withFallback(operation, fn) over the given endpoints ({ name, provider, ... }).
// It runs one read on the primary, and on the fallback only when the primary could not be
// reached. Any other error, such as a revert, is an answer, and asking again elsewhere
// would not change it. onFallback(endpoint, next, operation) is called before moving on,
// so each caller writes its own warning line (and decides what it may name in it).
export function createWithFallback(endpoints, onFallback) {
  return async function withFallback(operation, fn) {
    let lastError;
    for (const endpoint of endpoints) {
      try {
        return await fn(endpoint);
      } catch (err) {
        const classified = classifyChainError(err);
        lastError = new ChainClientError(classified, endpoint.name);
        if (classified.code !== 'RPC_UNAVAILABLE') throw lastError;
        const next = endpoints[endpoints.indexOf(endpoint) + 1];
        if (next) onFallback(endpoint, next, operation);
      }
    }
    throw lastError;
  };
}

// Decodes MineChain's own events from raw logs. Logs from other contracts, or with topics
// that are not ours, are left out rather than failing the whole receipt.
export function decodeEvents(logs, contractAddress) {
  const events = [];
  for (const log of logs) {
    if (log.address.toLowerCase() !== contractAddress.toLowerCase()) continue;
    let parsed;
    try {
      parsed = abi.parseLog({ topics: [...log.topics], data: log.data });
    } catch {
      parsed = null;
    }
    if (!parsed) continue;
    events.push(
      Object.freeze({
        address: log.address,
        name: parsed.name,
        // A plain object read by name, the same shape the fake returns.
        args: Object.freeze(parsed.args.toObject()),
        blockNumber: log.blockNumber,
        transactionHash: log.transactionHash,
        logIndex: log.index,
      }),
    );
  }
  return Object.freeze(events);
}

// An ethers receipt as both modules return it: null until mined; status 1 succeeded, 0
// reverted (the nonce and fee are still used); only MineChain's own events.
export function toReceipt(receipt, contractAddress) {
  if (receipt === null) return null;
  return Object.freeze({
    hash: receipt.hash,
    status: receipt.status,
    blockNumber: receipt.blockNumber,
    blockHash: receipt.blockHash,
    gasUsed: receipt.gasUsed,
    events: decodeEvents(receipt.logs, contractAddress),
  });
}
