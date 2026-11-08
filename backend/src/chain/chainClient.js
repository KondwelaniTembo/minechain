// The only module that talks to Ethereum over the network (docs/contract-spec.md, section 6).
// Everything else about anchoring is pure or database code, so it can be tested without a
// chain; the anchoring worker uses this interface, and tests use tests/fakes/fakeChainClient.js,
// which implements the same one in memory.
//
// Secrets: the RPC URLs carry the provider's API key in their path, and the private key can
// spend the recorder wallet's funds. All three stay in this module's closures. The client
// object itself holds only methods and public facts, so console.log, util.inspect and
// JSON.stringify of it show nothing secret. Provider errors are never passed on: ethers puts
// the request URL into its error messages, so every error is classified first and replaced
// by a ChainClientError built from our fixed codes and reasons (chainErrors.js).
import { Contract, FetchRequest, Interface, JsonRpcProvider, Network, Wallet, keccak256 } from 'ethers';
import { CHAIN_ERRORS, classifyChainError, feeTooHigh, toAnchorError } from './chainErrors.js';
import { DEPLOY_BLOCK, MINECHAIN_ABI } from './mineChainAbi.js';

const abi = new Interface(MINECHAIN_ABI);

// The contract's Stage enum, in declaration order (MineChain.sol).
export const CONSIGNMENT_STAGES = Object.freeze(['None', 'Registered', 'InTransit', 'Purchased']);

// The three writes this client will sign. Anything else is refused before signing.
const WRITE_FUNCTIONS = new Set(['registerConsignment', 'recordHandoff', 'recordPurchase']);
const EVENT_TOPICS = Object.freeze(
  ['ConsignmentRegistered', 'HandoffRecorded', 'PurchaseRecorded'].map((name) => abi.getEvent(name).topicHash),
);

// A request that has not answered by then is treated as unavailable, so the worker can move
// on to the fallback instead of waiting for ethers' default of five minutes.
const DEFAULT_TIMEOUT_MS = 15_000;
// Blocks per eth_getLogs request. Some free RPC plans refuse wider ranges, so the client
// asks in small pieces rather than finding the limit by failing.
const DEFAULT_LOG_CHUNK_BLOCKS = 500;

const UNKNOWN = Object.freeze({ code: 'UNKNOWN', ...CHAIN_ERRORS.UNKNOWN });

// The only error this module throws for chain problems. It carries a code, the action the
// worker should take, a fixed reason, and which endpoint answered. Deliberately no `cause`:
// util.inspect prints an error's cause, and the original error contains the URL.
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
function hostOf(url) {
  return new URL(url).hostname;
}

function requireSetting(value, name) {
  if (value === null || value === undefined) {
    throw new Error(`Chain client needs ${name}`);
  }
  return value;
}

function makeProvider(url, network, { timeoutMs, transport }) {
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

function assertNonNegativeInteger(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`${name} must be a non-negative whole number`);
  }
}

function assertPositiveBigInt(value, name) {
  if (typeof value !== 'bigint' || value <= 0n) {
    throw new TypeError(`${name} must be a bigint above 0`);
  }
}

function assertBytes32Hex(value, name) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new TypeError(`${name} must be 0x and 64 hex characters`);
  }
}

// Decodes MineChain's own events from raw logs. Logs from other contracts, or with topics
// that are not ours, are left out rather than failing the whole receipt.
function decodeEvents(logs, contractAddress) {
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

// anchorConfig: config.anchor from loadConfig. options are for the worker and tests:
//   log            where fallback warnings go (default console); gets host names only
//   timeoutMs      per HTTP request
//   logChunkBlocks blocks per eth_getLogs request
//   transport      tests only: replaces the HTTP layer (see makeProvider)
// Construction makes no network call. The first request goes out when a method is used.
export function createChainClient(anchorConfig, options = {}) {
  const {
    log = console,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    logChunkBlocks = DEFAULT_LOG_CHUNK_BLOCKS,
    transport = null,
  } = options;

  const chainId = requireSetting(anchorConfig.chainId, 'CHAIN_ID');
  const contractAddress = requireSetting(anchorConfig.contractAddress, 'MINECHAIN_CONTRACT_ADDRESS');
  const rpcUrl = requireSetting(anchorConfig.rpcUrl, 'SEPOLIA_RPC_URL');
  const fallbackRpcUrl = anchorConfig.fallbackRpcUrl;
  // Wallet with no provider: it can only sign. Sending is always done by this module
  // explicitly, so nothing can broadcast as a side effect of signing.
  const wallet = new Wallet(requireSetting(anchorConfig.recorderPrivateKey, 'RECORDER_PRIVATE_KEY'));
  const maxFeePerGasWei = anchorConfig.maxFeePerGasWei;

  const network = Network.from(chainId);
  const endpoints = [{ name: 'primary', host: hostOf(rpcUrl), provider: makeProvider(rpcUrl, network, { timeoutMs, transport }) }];
  if (fallbackRpcUrl) {
    endpoints.push({
      name: 'fallback',
      host: hostOf(fallbackRpcUrl),
      provider: makeProvider(fallbackRpcUrl, network, { timeoutMs, transport }),
    });
  }
  for (const endpoint of endpoints) {
    endpoint.contract = new Contract(contractAddress, MINECHAIN_ABI, endpoint.provider);
  }

  // Runs one read on the primary, and on the fallback only when the primary could not be
  // reached. Any other error, such as a revert, is an answer, and asking again elsewhere
  // would not change it.
  async function withFallback(operation, fn) {
    let lastError;
    for (const endpoint of endpoints) {
      try {
        return await fn(endpoint);
      } catch (err) {
        const classified = classifyChainError(err);
        lastError = new ChainClientError(classified, endpoint.name);
        if (classified.code !== 'RPC_UNAVAILABLE') throw lastError;
        const next = endpoints[endpoints.indexOf(endpoint) + 1];
        if (next) {
          log.warn(`Anchoring: ${endpoint.name} RPC ${endpoint.host} unavailable during ${operation}; trying ${next.name} RPC ${next.host}`);
        }
      }
    }
    throw lastError;
  }

  function encode(call) {
    if (!call || !WRITE_FUNCTIONS.has(call.functionName)) {
      throw new TypeError('call must be built by buildAnchorCall');
    }
    return abi.encodeFunctionData(call.functionName, call.args);
  }

  const client = {
    // Public: shown on Etherscan, safe to log. No bigint here (the chain id stays in
    // config), because JSON.stringify throws on a bigint, and a log line must never crash.
    recorderAddress: wallet.address,
    contractAddress,
    endpointHosts: Object.freeze(endpoints.map(({ name, host }) => Object.freeze({ name, host }))),

    // Asks the node itself, on one named endpoint and without fallback, so the startup
    // check proves each configured RPC is on the right chain. provider.getNetwork() would
    // only return the static network from config.
    async getChainId(endpointName = 'primary') {
      const endpoint = endpoints.find((e) => e.name === endpointName);
      if (!endpoint) throw new TypeError('endpoint must be primary or a configured fallback');
      try {
        return BigInt(await endpoint.provider.send('eth_chainId', []));
      } catch (err) {
        throw new ChainClientError(classifyChainError(err), endpoint.name);
      }
    },

    // Every method is async, so even a refused argument arrives as a rejected promise:
    // callers handle one kind of failure, not a throw sometimes and a rejection other times.
    async getCode(address = contractAddress) {
      return withFallback('getCode', (e) => e.provider.getCode(address));
    },

    async getRecorderRole() {
      return withFallback('RECORDER_ROLE', (e) => e.contract.RECORDER_ROLE());
    },

    async hasRole(role, account = wallet.address) {
      assertBytes32Hex(role, 'role');
      return withFallback('hasRole', (e) => e.contract.hasRole(role, account));
    },

    async getBalance() {
      return withFallback('getBalance', (e) => e.provider.getBalance(wallet.address, 'latest'));
    },

    // 'latest' counts mined transactions; 'pending' also counts those waiting in the
    // node's mempool. A difference means something from this wallet is not mined yet.
    async getNonce(blockTag) {
      if (blockTag !== 'latest' && blockTag !== 'pending') {
        throw new TypeError("blockTag must be 'latest' or 'pending'");
      }
      return withFallback(`getNonce(${blockTag})`, (e) => e.provider.getTransactionCount(wallet.address, blockTag));
    },

    async getFeeData() {
      const fees = await withFallback('getFeeData', (e) => e.provider.getFeeData());
      // Sepolia has EIP-1559 fees; a node without them is not one this worker can use.
      if (fees.maxFeePerGas === null || fees.maxPriorityFeePerGas === null) {
        throw new ChainClientError(UNKNOWN, 'primary');
      }
      return Object.freeze({ maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
    },

    // Also a dry run: eth_estimateGas executes the call against the latest block, so a
    // step that would revert fails here, before any fee is paid, with the same custom error.
    async estimateGas(call) {
      const data = encode(call);
      return withFallback('estimateGas', (e) =>
        e.provider.estimateGas({ from: wallet.address, to: contractAddress, data }),
      );
    },

    // Signs locally, with no network. The hash is known before broadcast, so the worker can
    // store it (and the nonce) first: after a crash it then knows what it may have sent.
    async signTransaction({ call, nonce, gasLimit, maxFeePerGas, maxPriorityFeePerGas }) {
      const data = encode(call);
      assertNonNegativeInteger(nonce, 'nonce');
      assertPositiveBigInt(gasLimit, 'gasLimit');
      assertPositiveBigInt(maxFeePerGas, 'maxFeePerGas');
      if (typeof maxPriorityFeePerGas !== 'bigint' || maxPriorityFeePerGas < 0n || maxPriorityFeePerGas > maxFeePerGas) {
        throw new TypeError('maxPriorityFeePerGas must be a bigint from 0 to maxFeePerGas');
      }
      // The worker checks this too; repeating it here means no caller can ever sign above
      // ANCHOR_MAX_FEE_GWEI.
      if (maxFeePerGas > maxFeePerGasWei) throw new ChainClientError(feeTooHigh(), 'local');

      const rawTx = await wallet.signTransaction({
        type: 2,
        chainId,
        nonce,
        to: contractAddress,
        data,
        value: 0n,
        gasLimit,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      // A transaction's hash is keccak256 of its signed bytes.
      return Object.freeze({ rawTx, hash: keccak256(rawTx) });
    },

    // Sends the same signed bytes to every configured RPC at once, so the transaction
    // reaches the network even if one provider drops it. Sending identical bytes twice is
    // safe: they have one hash and one nonce, so they can be mined at most once.
    async broadcast(rawTx) {
      if (typeof rawTx !== 'string' || !/^0x([0-9a-fA-F]{2})+$/.test(rawTx)) {
        throw new TypeError('rawTx must be signed transaction bytes as 0x hex');
      }
      const hash = keccak256(rawTx);

      const outcomes = await Promise.all(
        endpoints.map(async (endpoint) => {
          try {
            const returned = await endpoint.provider.send('eth_sendRawTransaction', [rawTx]);
            // A node reporting another hash is broken or not telling the truth.
            if (typeof returned !== 'string' || returned.toLowerCase() !== hash) {
              return { endpoint, error: UNKNOWN };
            }
            return { endpoint, accepted: true };
          } catch (err) {
            const classified = classifyChainError(err);
            // "Already known" means the node has exactly these bytes: the send succeeded.
            if (classified.code === 'ALREADY_KNOWN') return { endpoint, accepted: true };
            return { endpoint, error: classified };
          }
        }),
      );

      const accepted = outcomes.filter((o) => o.accepted).map((o) => o.endpoint.name);
      const refused = outcomes.filter((o) => !o.accepted);
      if (accepted.length > 0) {
        for (const { endpoint, error } of refused) {
          log.warn(`Anchoring: broadcast via ${endpoint.name} RPC ${endpoint.host} refused: ${error.code}`);
        }
        return Object.freeze({
          hash,
          accepted: Object.freeze(accepted),
          refused: Object.freeze(refused.map((o) => Object.freeze({ endpoint: o.endpoint.name, code: o.error.code }))),
        });
      }
      // Nobody took it. A node's real answer (funds, nonce) says more than "unreachable".
      const telling = refused.find((o) => o.error.code !== 'RPC_UNAVAILABLE') ?? refused[0];
      throw new ChainClientError(telling.error, telling.endpoint.name);
    },

    // null until mined. status 1 succeeded, 0 reverted (the nonce and fee are still used).
    async getReceipt(hash) {
      assertBytes32Hex(hash, 'hash');
      const receipt = await withFallback('getReceipt', (e) => e.provider.getTransactionReceipt(hash));
      if (receipt === null) return null;
      return Object.freeze({
        hash: receipt.hash,
        status: receipt.status,
        blockNumber: receipt.blockNumber,
        blockHash: receipt.blockHash,
        gasUsed: receipt.gasUsed,
        events: decodeEvents(receipt.logs, contractAddress),
      });
    },

    async getBlockNumber() {
      return withFallback('getBlockNumber', (e) => e.provider.getBlockNumber());
    },

    // Seconds since 1970, from the block header: the chain's clock, not the server's.
    // null when this RPC has not seen the block yet.
    async getBlockTimestamp(blockNumber) {
      assertNonNegativeInteger(blockNumber, 'blockNumber');
      const block = await withFallback('getBlock', (e) => e.provider.getBlock(blockNumber));
      return block === null ? null : block.timestamp;
    },

    // The contract's current record for one id. An id it has never seen reports stage None
    // with zero fields, rather than reverting.
    async getConsignment(id) {
      assertBytes32Hex(id, 'id');
      const record = await withFallback('getConsignment', (e) => e.contract.getConsignment(id));
      return Object.freeze({
        stage: CONSIGNMENT_STAGES[Number(record.stage)] ?? 'unknown',
        weightMilligrams: record.weightMilligrams,
        timestamp: record.timestamp,
        actorRef: record.actorRef,
        dataHash: record.dataHash,
      });
    },

    // Every MineChain event for one consignment id between two blocks, inclusive, oldest
    // first. Used after a crash to find a step anchored by a transaction the row never
    // recorded. Nothing can be older than the deployment block, so the search starts there
    // at the earliest.
    async getLogs(id, fromBlock, toBlock) {
      assertBytes32Hex(id, 'id');
      assertNonNegativeInteger(fromBlock, 'fromBlock');
      assertNonNegativeInteger(toBlock, 'toBlock');
      const start = Math.max(fromBlock, DEPLOY_BLOCK);
      const events = [];
      for (let chunkStart = start; chunkStart <= toBlock; chunkStart += logChunkBlocks) {
        const chunkEnd = Math.min(chunkStart + logChunkBlocks - 1, toBlock);
        const logs = await withFallback('getLogs', (e) =>
          e.provider.getLogs({
            address: contractAddress,
            // Any of the three events, with this id as the first indexed argument.
            topics: [[...EVENT_TOPICS], id.toLowerCase()],
            fromBlock: chunkStart,
            toBlock: chunkEnd,
          }),
        );
        events.push(...decodeEvents(logs, contractAddress));
      }
      return Object.freeze(events);
    },

    // Stops the providers, so a script such as anchor:once can exit.
    close() {
      for (const endpoint of endpoints) endpoint.provider.destroy();
    },
  };

  return Object.freeze(client);
}
