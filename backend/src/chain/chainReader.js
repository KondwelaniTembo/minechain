// Read-only chain access for verification (FR-04, plan B2 "Read-only chain access"). It
// works whatever ANCHOR_ENABLED says, because it needs no key: there is no Wallet here and
// recorderPrivateKey is never read, so a server with anchoring off can still check
// receipts.
//
// Same secret rules as chainClient.js: the RPC URLs stay in this closure, every provider
// error becomes a ChainClientError (rpc.js), and warnings name an endpoint only by its role
// (primary, fallback), never its host or URL.
//
// The guard. A misconfigured RPC on another network would return no receipt for an honest
// step, and a missing receipt can count as tampering. So before an endpoint's first answer
// is used, the reader asks that endpoint once for its chain id (must be Sepolia) and for
// the code at the contract address (must be exactly the deployed MineChain, by the same
// code hash the worker's preflight uses). Until that passes, every method
// fails with a ChainClientError, which verification reports as chain_unavailable, never as
// a mismatch. Once passed, it is not asked again.
import { Network, keccak256 } from 'ethers';
import { EXPECTED_CODE_HASH, SEPOLIA_CHAIN_ID } from './mineChainAbi.js';
import { ChainClientError, assertBytes32Hex, createWithFallback, makeProvider, toReceipt } from './rpc.js';

// Below the worker's 15 s: a consignment view must answer within NFR-03's 10 s, and the
// plan gives each chain request 8 s.
const DEFAULT_TIMEOUT_MS = 8_000;

const refusal = (code, reason) => Object.freeze({ code, action: 'stop', reason });

// The guard's three refusals: WRONG_CHAIN, NO_CONTRACT_CODE and WRONG_CONTRACT_CODE. A
// person has to fix the configuration, hence 'stop'.
export const READER_REFUSALS = Object.freeze({
  WRONG_CHAIN: refusal('WRONG_CHAIN', 'the RPC provider is not on Sepolia'),
  NO_CONTRACT_CODE: refusal('NO_CONTRACT_CODE', 'there is no contract at MINECHAIN_CONTRACT_ADDRESS on this RPC'),
  WRONG_CONTRACT_CODE: refusal(
    'WRONG_CONTRACT_CODE',
    'the contract at MINECHAIN_CONTRACT_ADDRESS on this RPC is not the deployed MineChain',
  ),
});

function requireSetting(value, name) {
  if (value === null || value === undefined) {
    throw new Error(`Chain reader needs ${name}`);
  }
  return value;
}

// anchorConfig: config.anchor from loadConfig. Only rpcUrl, fallbackRpcUrl and
// contractAddress are read. options:
//   log        where warnings go (default console); gets endpoint roles only
//   timeoutMs  per HTTP request
//   transport  tests only: replaces the HTTP layer (see makeProvider in rpc.js)
// Construction makes no network call, and neither does the guard until a method is used.
export function createChainReader(anchorConfig, options = {}) {
  const { log = console, timeoutMs = DEFAULT_TIMEOUT_MS, transport = null } = options;

  const contractAddress = requireSetting(anchorConfig.contractAddress, 'MINECHAIN_CONTRACT_ADDRESS');
  const rpcUrl = requireSetting(anchorConfig.rpcUrl, 'SEPOLIA_RPC_URL');
  const fallbackRpcUrl = anchorConfig.fallbackRpcUrl;

  // Sepolia, not config.chainId: the guard's whole point is that this reader only ever
  // trusts Sepolia, and config already refuses any other CHAIN_ID.
  const network = Network.from(SEPOLIA_CHAIN_ID);
  // verified: the guard passed on this endpoint. checking: the guard's promise while it
  // runs, so parallel calls share one check instead of each sending their own.
  const endpoints = [{ name: 'primary', provider: makeProvider(rpcUrl, network, { timeoutMs, transport }), verified: false, checking: null }];
  if (fallbackRpcUrl) {
    endpoints.push({
      name: 'fallback',
      provider: makeProvider(fallbackRpcUrl, network, { timeoutMs, transport }),
      verified: false,
      checking: null,
    });
  }

  const withFallback = createWithFallback(endpoints, (endpoint, next, operation) => {
    log.warn(`Chain reader: ${endpoint.name} RPC unavailable during ${operation}; trying ${next.name} RPC`);
  });

  // null when the endpoint may be trusted, or one of READER_REFUSALS. A provider error is
  // thrown as it is, so withFallback classifies it and moves on to the fallback when the
  // endpoint could not be reached. A failed or refused check is forgotten, so the next call
  // asks again.
  function guard(endpoint) {
    if (endpoint.verified) return null;
    if (!endpoint.checking) {
      endpoint.checking = (async () => {
        const chainId = BigInt(await endpoint.provider.send('eth_chainId', []));
        if (chainId !== SEPOLIA_CHAIN_ID) return READER_REFUSALS.WRONG_CHAIN;
        const code = await endpoint.provider.getCode(contractAddress);
        if (code === '0x') return READER_REFUSALS.NO_CONTRACT_CODE;
        // Hashed locally from the reply already in hand, so no extra request. Any contract
        // at the address is not enough: another one could emit look-alike events.
        if (keccak256(code) !== EXPECTED_CODE_HASH) return READER_REFUSALS.WRONG_CONTRACT_CODE;
        endpoint.verified = true;
        return null;
      })().finally(() => {
        endpoint.checking = null;
      });
    }
    return endpoint.checking;
  }

  // One read behind the guard. A refusal is returned out of withFallback, not thrown inside
  // it, so it is not reclassified and does not send the read on to the fallback: a node on
  // the wrong network is a configuration fault to fix, as in the worker's preflight.
  async function read(operation, fn) {
    const outcome = await withFallback(operation, async (endpoint) => {
      const refused = await guard(endpoint);
      if (refused) return { refused, endpoint: endpoint.name };
      return { value: await fn(endpoint) };
    });
    if (outcome.refused) {
      log.warn(`Chain reader: ${outcome.endpoint} RPC failed the network check: ${outcome.refused.code}`);
      throw new ChainClientError(outcome.refused, outcome.endpoint);
    }
    return outcome.value;
  }

  const reader = {
    // Public on Etherscan, safe to log.
    contractAddress,

    // The same shape as chainClient.getReceipt: null until mined, MineChain events only.
    async getReceipt(hash) {
      assertBytes32Hex(hash, 'hash');
      const receipt = await read('getReceipt', (e) => e.provider.getTransactionReceipt(hash));
      return toReceipt(receipt, contractAddress);
    },

    async getBlockNumber() {
      return read('getBlockNumber', (e) => e.provider.getBlockNumber());
    },

    // Stops the providers at shutdown. A call after this fails with a ChainClientError.
    close() {
      for (const endpoint of endpoints) endpoint.provider.destroy();
    },
  };

  return Object.freeze(reader);
}

// What server.js calls: a reader when the RPC URL and contract address are both set,
// whatever ANCHOR_ENABLED says, otherwise null (verification then reports
// chain_unavailable). Makes no network call.
export function createChainReaderFromConfig(anchorConfig, options = {}) {
  if (!anchorConfig.rpcUrl || !anchorConfig.contractAddress) return null;
  return createChainReader(anchorConfig, options);
}
