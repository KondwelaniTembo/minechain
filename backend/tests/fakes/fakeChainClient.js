// An in-memory chain client for tests. It has the same methods, return shapes and errors
// as src/chain/chainClient.js, plus controls that script what a real chain can do: revert
// with each custom error, drop a transaction, fail the primary RPC, run out of funds.
//
// It copies the contract's rules (MineChain.sol): the role check, then the zero-input
// checks, then the stage rules. Errors are made the way the real client makes them: a raw
// error shaped like ethers', run through classifyChainError, wrapped in ChainClientError.
// So a test against the fake exercises the same classification as production.
//
// Transactions are really signed with a fake key, so hashes and nonces behave as on a
// real chain: the same call signed with another fee or nonce has another hash.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Interface, Transaction, Wallet, keccak256 } from 'ethers';
import { CONSIGNMENT_STAGES, ChainClientError } from '../../src/chain/chainClient.js';
import { classifyChainError, feeTooHigh } from '../../src/chain/chainErrors.js';
import { DEPLOY_BLOCK, MINECHAIN_ABI, SEPOLIA_CHAIN_ID } from '../../src/chain/mineChainAbi.js';
import { EXPECTED_RECORDER_ROLE } from '../../src/chain/preflight.js';

const abi = new Interface(MINECHAIN_ABI);

export const FAKE_CONTRACT_ADDRESS = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';
// Fake, and never funded anywhere.
export const FAKE_RECORDER_KEY = `0x${'1a2b3c4d'.repeat(8)}`;
export const FAKE_HOSTS = Object.freeze({ primary: 'primary.rpc.example', fallback: 'fallback.rpc.example' });

// The real deployed bytecode, so the code-hash check passes for the right reason. Test code
// may read contracts/; src/ never does. A path, not a URL, because of the '#' in the name.
const ARTIFACT_PATH = join(
  fileURLToPath(new URL('../../../contracts/ignition/deployments/chain-11155111/artifacts/', import.meta.url)),
  'MineChainModule#MineChain.json',
);
export const MINECHAIN_RUNTIME_CODE = JSON.parse(readFileSync(ARTIFACT_PATH, 'utf8')).deployedBytecode;

// Roughly what the plan estimates, so balances fall at a believable rate.
export const FAKE_GAS = Object.freeze({ registerConsignment: 95_000n, recordHandoff: 48_000n, recordPurchase: 48_000n });

const GWEI = 1_000_000_000n;
const ZERO_BYTES32 = `0x${'00'.repeat(32)}`;
const SECONDS_PER_BLOCK = 12;
const GENESIS_TIMESTAMP = 1_762_000_000;

const STEP_EVENTS = Object.freeze({
  registerConsignment: { eventName: 'ConsignmentRegistered', actorArg: 'minerRef' },
  recordHandoff: { eventName: 'HandoffRecorded', actorArg: 'transporterRef' },
  recordPurchase: { eventName: 'PurchaseRecorded', actorArg: 'buyerRef' },
});

const stageIndex = (name) => CONSIGNMENT_STAGES.indexOf(name);

function chainError(rawError, endpoint) {
  return new ChainClientError(classifyChainError(rawError), endpoint);
}

// What ethers throws for a revert: CALL_EXCEPTION with the ABI-encoded custom error as data.
function revertError(errorName, args, endpoint) {
  return chainError({ code: 'CALL_EXCEPTION', data: abi.encodeErrorResult(errorName, args) }, endpoint);
}

// options: hasFallback (default true), balanceWei (0.01 test ETH, like the real recorder
// wallet), maxFeePerGasWei (the config cap, default 50 gwei), privateKey.
export function createFakeChainClient(options = {}) {
  const {
    hasFallback = true,
    balanceWei = 10_000_000_000_000_000n,
    maxFeePerGasWei = 50n * GWEI,
    privateKey = FAKE_RECORDER_KEY,
  } = options;

  const wallet = new Wallet(privateKey);
  const endpointNames = hasFallback ? ['primary', 'fallback'] : ['primary'];

  const state = {
    chainIds: { primary: SEPOLIA_CHAIN_ID, fallback: SEPOLIA_CHAIN_ID },
    code: MINECHAIN_RUNTIME_CODE,
    recorderRole: EXPECTED_RECORDER_ROLE,
    roleHolders: new Set([wallet.address.toLowerCase()]),
    balance: balanceWei,
    latestNonce: 0,
    // nonce -> { hash, rawTx, name, args, gasLimit, maxFeePerGas, maxPriorityFeePerGas }
    mempool: new Map(),
    feeData: { maxFeePerGas: 2n * GWEI, maxPriorityFeePerGas: 1n * GWEI },
    blockNumber: DEPLOY_BLOCK + 100,
    consignments: new Map(),
    receipts: new Map(),
    events: [],
    rpc: { primaryDown: false, allDown: false },
    estimateReverts: [],
    minedReverts: [],
    closed: false,
  };

  // What the tests can inspect afterwards. Every entry is a plain record, never a secret.
  const records = {
    calls: [], // { method, endpoint }
    signed: [], // { hash, nonce, functionName, gasLimit, maxFeePerGas, maxPriorityFeePerGas }
    sent: [], // { hash, nonce, accepted, refused }
    dropped: [], // hash
    mined: [], // { hash, nonce, blockNumber, status }
  };

  const timestampOf = (blockNumber) => GENESIS_TIMESTAMP + (blockNumber - DEPLOY_BLOCK) * SECONDS_PER_BLOCK;

  function pendingNonce() {
    let nonce = state.latestNonce;
    while (state.mempool.has(nonce)) nonce += 1;
    return nonce;
  }

  // The endpoint a read goes to, as withFallback would choose it.
  function endpointFor(method) {
    if (state.closed) throw new Error('fake chain client is closed');
    if (state.rpc.allDown || (state.rpc.primaryDown && !hasFallback)) {
      const endpoint = state.rpc.allDown && hasFallback ? 'fallback' : 'primary';
      records.calls.push({ method, endpoint, failed: true });
      throw chainError({ code: 'ECONNREFUSED' }, endpoint);
    }
    const endpoint = state.rpc.primaryDown ? 'fallback' : 'primary';
    records.calls.push({ method, endpoint });
    return endpoint;
  }

  // async, so a failure is always a rejected promise, as with the real client.
  async function read(method, fn) {
    return fn(endpointFor(method));
  }

  function decodeCall(call) {
    if (!call || !Object.hasOwn(STEP_EVENTS, call.functionName)) {
      throw new TypeError('call must be built by buildAnchorCall');
    }
    const data = abi.encodeFunctionData(call.functionName, call.args);
    return { data, ...decodeData(data) };
  }

  function decodeData(data) {
    const parsed = abi.parseTransaction({ data });
    return { name: parsed.name, args: [...parsed.args] };
  }

  // The contract's write logic. Returns { revert: [errorName, args] } or { event }.
  // dryRun leaves the state alone, as eth_estimateGas does.
  function execute(name, [id, actorRef, weight, dataHash], { dryRun, blockNumber }) {
    if (!state.roleHolders.has(wallet.address.toLowerCase())) {
      return { revert: ['AccessControlUnauthorizedAccount', [wallet.address, state.recorderRole]] };
    }
    const inputs = [id, actorRef, weight, dataHash];
    const zeroField = inputs.findIndex((v) => v === ZERO_BYTES32 || v === 0n);
    if (zeroField !== -1) return { revert: ['InvalidInput', [zeroField]] };

    const current = state.consignments.get(id.toLowerCase())?.stage ?? 'None';
    let next;
    if (name === 'registerConsignment') {
      if (current !== 'None') return { revert: ['ConsignmentAlreadyExists', [id]] };
      next = 'Registered';
    } else if (name === 'recordHandoff') {
      if (current !== 'Registered' && current !== 'InTransit') return { revert: ['InvalidStage', [id, stageIndex(current)]] };
      next = 'InTransit';
    } else {
      if (current !== 'InTransit') return { revert: ['InvalidStage', [id, stageIndex(current)]] };
      next = 'Purchased';
    }

    const timestamp = BigInt(timestampOf(blockNumber));
    if (!dryRun) {
      state.consignments.set(id.toLowerCase(), {
        stage: next,
        weightMilligrams: weight,
        timestamp,
        actorRef,
        dataHash,
      });
    }
    const { eventName, actorArg } = STEP_EVENTS[name];
    return {
      event: {
        name: eventName,
        args: Object.freeze({ id, [actorArg]: actorRef, weightMilligrams: weight, dataHash, timestamp }),
      },
    };
  }

  const client = {
    recorderAddress: wallet.address,
    contractAddress: FAKE_CONTRACT_ADDRESS,
    endpointHosts: Object.freeze(endpointNames.map((name) => Object.freeze({ name, host: FAKE_HOSTS[name] }))),

    async getChainId(endpointName = 'primary') {
      if (!endpointNames.includes(endpointName)) {
        throw new TypeError('endpoint must be primary or a configured fallback');
      }
      records.calls.push({ method: 'getChainId', endpoint: endpointName });
      const down = state.rpc.allDown || (endpointName === 'primary' && state.rpc.primaryDown);
      if (down) throw chainError({ code: 'ECONNREFUSED' }, endpointName);
      return state.chainIds[endpointName];
    },

    getCode(address = FAKE_CONTRACT_ADDRESS) {
      return read('getCode', () => (address.toLowerCase() === FAKE_CONTRACT_ADDRESS.toLowerCase() ? state.code : '0x'));
    },

    getRecorderRole() {
      return read('RECORDER_ROLE', () => state.recorderRole);
    },

    hasRole(role, account = wallet.address) {
      return read('hasRole', () => role === state.recorderRole && state.roleHolders.has(account.toLowerCase()));
    },

    getBalance() {
      return read('getBalance', () => state.balance);
    },

    async getNonce(blockTag) {
      if (blockTag !== 'latest' && blockTag !== 'pending') {
        throw new TypeError("blockTag must be 'latest' or 'pending'");
      }
      return read(`getNonce(${blockTag})`, () => (blockTag === 'latest' ? state.latestNonce : pendingNonce()));
    },

    getFeeData() {
      return read('getFeeData', () => Object.freeze({ ...state.feeData }));
    },

    async estimateGas(call) {
      const { name, args } = decodeCall(call);
      return read('estimateGas', (endpoint) => {
        const scripted = state.estimateReverts.shift();
        if (scripted) throw revertError(...scripted, endpoint);
        // Against the latest block only: a step waiting in the mempool has not happened yet.
        const outcome = execute(name, args, { dryRun: true, blockNumber: state.blockNumber });
        if (outcome.revert) throw revertError(...outcome.revert, endpoint);
        return FAKE_GAS[name];
      });
    },

    async signTransaction({ call, nonce, gasLimit, maxFeePerGas, maxPriorityFeePerGas }) {
      const { data } = decodeCall(call);
      if (!Number.isSafeInteger(nonce) || nonce < 0) throw new TypeError('nonce must be a non-negative whole number');
      if (maxFeePerGas > maxFeePerGasWei) throw new ChainClientError(feeTooHigh(), 'local');
      const rawTx = await wallet.signTransaction({
        type: 2,
        chainId: SEPOLIA_CHAIN_ID,
        nonce,
        to: FAKE_CONTRACT_ADDRESS,
        data,
        value: 0n,
        gasLimit,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      const hash = keccak256(rawTx);
      records.signed.push({ hash, nonce, functionName: call.functionName, gasLimit, maxFeePerGas, maxPriorityFeePerGas });
      return Object.freeze({ rawTx, hash });
    },

    async broadcast(rawTx) {
      if (state.closed) throw new Error('fake chain client is closed');
      const tx = Transaction.from(rawTx);
      const hash = keccak256(rawTx);

      // Which endpoints are reachable, as the real client sends to all of them at once.
      const reachable = endpointNames.filter((name) => !(state.rpc.allDown || (name === 'primary' && state.rpc.primaryDown)));
      const unreachable = endpointNames.filter((name) => !reachable.includes(name));
      if (reachable.length === 0) throw chainError({ code: 'ECONNREFUSED' }, 'primary');
      const endpoint = reachable[0];

      // The node's own checks, in the order a real node makes them.
      if (tx.nonce < state.latestNonce) throw chainError({ code: 'NONCE_EXPIRED' }, endpoint);
      const waiting = state.mempool.get(tx.nonce);
      if (waiting && waiting.hash !== hash) {
        // A replacement must raise both fees by at least 10%, as geth requires.
        const bumped = (old, fresh) => fresh * 100n >= old * 110n;
        if (!bumped(waiting.maxFeePerGas, tx.maxFeePerGas) || !bumped(waiting.maxPriorityFeePerGas, tx.maxPriorityFeePerGas)) {
          throw chainError({ code: 'REPLACEMENT_UNDERPRICED' }, endpoint);
        }
      }
      if (state.balance < tx.gasLimit * tx.maxFeePerGas) throw chainError({ code: 'INSUFFICIENT_FUNDS' }, endpoint);

      // The same bytes again are "already known", which the real client counts as accepted.
      if (!waiting || waiting.hash !== hash) {
        state.mempool.set(tx.nonce, {
          hash,
          rawTx,
          ...decodeData(tx.data),
          gasLimit: tx.gasLimit,
          maxFeePerGas: tx.maxFeePerGas,
          maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
        });
      }
      const result = Object.freeze({
        hash,
        accepted: Object.freeze([...reachable]),
        refused: Object.freeze(unreachable.map((name) => Object.freeze({ endpoint: name, code: 'RPC_UNAVAILABLE' }))),
      });
      records.sent.push({ hash, nonce: tx.nonce, accepted: result.accepted, refused: result.refused });
      return result;
    },

    getReceipt(hash) {
      return read('getReceipt', () => state.receipts.get(hash.toLowerCase()) ?? null);
    },

    getBlockNumber() {
      return read('getBlockNumber', () => state.blockNumber);
    },

    getBlockTimestamp(blockNumber) {
      return read('getBlock', () => (blockNumber <= state.blockNumber ? timestampOf(blockNumber) : null));
    },

    getConsignment(id) {
      return read('getConsignment', () => {
        const record = state.consignments.get(id.toLowerCase());
        return Object.freeze(
          record ?? { stage: 'None', weightMilligrams: 0n, timestamp: 0n, actorRef: ZERO_BYTES32, dataHash: ZERO_BYTES32 },
        );
      });
    },

    getLogs(id, fromBlock, toBlock) {
      return read('getLogs', () =>
        Object.freeze(
          state.events.filter(
            (e) =>
              e.args.id.toLowerCase() === id.toLowerCase() &&
              e.blockNumber >= Math.max(fromBlock, DEPLOY_BLOCK) &&
              e.blockNumber <= toBlock,
          ),
        ),
      );
    },

    close() {
      state.closed = true;
    },
  };

  // ---------- controls: what a real chain or provider can do to the worker ----------

  const control = {
    records,

    // Mines `blocks` blocks. The first one takes every waiting transaction whose nonce is
    // next in line; a gap in nonces stops it, as on a real chain. Returns the mined hashes.
    mine(blocks = 1) {
      const minedHashes = [];
      for (let i = 0; i < blocks; i += 1) {
        state.blockNumber += 1;
        const blockNumber = state.blockNumber;
        let logIndex = 0;
        while (state.mempool.has(state.latestNonce)) {
          const tx = state.mempool.get(state.latestNonce);
          state.mempool.delete(state.latestNonce);

          let outcome;
          if (tx.foreign) {
            outcome = { event: null };
          } else {
            const scripted = state.minedReverts.shift();
            outcome = scripted ? { revert: scripted } : execute(tx.name, tx.args, { dryRun: false, blockNumber });
          }
          const gasUsed = tx.foreign ? 21_000n : FAKE_GAS[tx.name];
          // A reverted transaction still uses its nonce and pays for its gas.
          state.balance -= gasUsed * tx.maxFeePerGas;

          const events = [];
          if (outcome.event) {
            const event = Object.freeze({
              address: FAKE_CONTRACT_ADDRESS,
              ...outcome.event,
              blockNumber,
              transactionHash: tx.hash,
              logIndex: logIndex++,
            });
            events.push(event);
            state.events.push(event);
          }
          const status = outcome.revert ? 0 : 1;
          state.receipts.set(
            tx.hash,
            Object.freeze({
              hash: tx.hash,
              status,
              blockNumber,
              blockHash: keccak256(`0x${blockNumber.toString(16).padStart(64, '0')}`),
              gasUsed,
              events: Object.freeze(events),
            }),
          );
          records.mined.push({ hash: tx.hash, nonce: state.latestNonce, blockNumber, status });
          state.latestNonce += 1;
          minedHashes.push(tx.hash);
        }
      }
      return minedHashes;
    },

    // The next estimateGas reverts with this custom error, whatever the state says.
    revertNextEstimate(errorName, args) {
      state.estimateReverts.push([errorName, args ?? defaultRevertArgs(errorName)]);
    },

    // The next mined transaction reverts (status 0) although its estimate passed: the state
    // changed between estimate and mining.
    revertNextMined(errorName, args) {
      state.minedReverts.push([errorName, args ?? defaultRevertArgs(errorName)]);
    },

    // The node forgets the transaction, as a mempool does when it is full or the fee is too
    // low. Its receipt then never appears, and its nonce is free again.
    dropTransaction(hash) {
      for (const [nonce, tx] of state.mempool) {
        if (tx.hash === hash.toLowerCase()) {
          state.mempool.delete(nonce);
          records.dropped.push(hash);
          return true;
        }
      }
      return false;
    },

    // Someone sends from the recorder wallet by hand: the pending nonce moves on without
    // the worker.
    sendByHand() {
      const nonce = pendingNonce();
      state.mempool.set(nonce, {
        hash: keccak256(`0x${nonce.toString(16).padStart(64, '0')}ff`),
        foreign: true,
        maxFeePerGas: state.feeData.maxFeePerGas,
        maxPriorityFeePerGas: state.feeData.maxPriorityFeePerGas,
      });
      return nonce;
    },

    failPrimary(down = true) {
      state.rpc.primaryDown = down;
    },
    failAllRpc(down = true) {
      state.rpc.allDown = down;
    },
    runOutOfFunds() {
      state.balance = 0n;
    },
    setBalance(wei) {
      state.balance = wei;
    },
    setFeeData(fees) {
      state.feeData = { ...state.feeData, ...fees };
    },
    setChainId(endpointName, chainId) {
      state.chainIds[endpointName] = chainId;
    },
    setCode(code) {
      state.code = code;
    },
    setRecorderRole(role) {
      state.recorderRole = role;
    },
    revokeRecorderRole() {
      state.roleHolders.delete(wallet.address.toLowerCase());
    },
    mempoolSize() {
      return state.mempool.size;
    },
  };

  function defaultRevertArgs(errorName) {
    switch (errorName) {
      case 'AccessControlUnauthorizedAccount':
        return [wallet.address, state.recorderRole];
      case 'InvalidInput':
        return [0];
      case 'InvalidStage':
        return [`0x${'11'.repeat(32)}`, stageIndex('Purchased')];
      case 'ConsignmentAlreadyExists':
        return [`0x${'11'.repeat(32)}`];
      default:
        throw new TypeError(`unknown MineChain error ${errorName}`);
    }
  }

  return { client: Object.freeze(client), control };
}
