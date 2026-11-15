// An in-memory chain reader for tests: the same methods, shapes and errors as
// src/chain/chainReader.js, plus controls for what verification must survive (the RPC
// down, a node on the wrong network, a receipt that is missing or altered).
//
// Two ways to use it:
//   createFakeChainReader()                 its own receipts and block number, set by the test
//   createFakeChainReader({ chain: client }) reads from a fake chain client
//                                            (fakeChainClient.js), so steps anchored by the
//                                            worker in a test can then be verified
import { ChainClientError } from '../../src/chain/rpc.js';
import { READER_REFUSALS } from '../../src/chain/chainReader.js';
import { classifyChainError } from '../../src/chain/chainErrors.js';
import { DEPLOY_BLOCK } from '../../src/chain/mineChainAbi.js';
import { FAKE_CONTRACT_ADDRESS } from './fakeChainClient.js';

export function createFakeChainReader({ chain = null } = {}) {
  const state = {
    receipts: new Map(),
    blockNumber: DEPLOY_BLOCK + 100,
    down: false,
    refusal: null,
    closed: false,
  };
  // { method, hash? } for every call that reached the "network", so tests can count RPC use.
  const calls = [];

  async function read(method, fn, detail = {}) {
    if (state.closed) throw new Error('fake chain reader is closed');
    calls.push({ method, ...detail });
    // The same classification as the real reader, from an error shaped like Node's.
    if (state.down) throw new ChainClientError(classifyChainError({ code: 'ECONNREFUSED' }), 'primary');
    if (state.refusal) throw new ChainClientError(state.refusal, 'primary');
    return fn();
  }

  const reader = {
    contractAddress: chain ? chain.contractAddress : FAKE_CONTRACT_ADDRESS,

    async getReceipt(hash) {
      if (typeof hash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
        throw new TypeError('hash must be 0x and 64 hex characters');
      }
      return read('getReceipt', () => (chain ? chain.getReceipt(hash) : state.receipts.get(hash.toLowerCase()) ?? null), { hash });
    },

    async getBlockNumber() {
      return read('getBlockNumber', () => (chain ? chain.getBlockNumber() : state.blockNumber));
    },

    close() {
      state.closed = true;
    },
  };

  const control = {
    calls,
    // receipt: the shape getReceipt returns ({ hash, status, blockNumber, blockHash,
    // gasUsed, events }). Ignored when reading from a fake chain client.
    setReceipt(hash, receipt) {
      state.receipts.set(hash.toLowerCase(), Object.freeze({ ...receipt }));
    },
    setBlockNumber(blockNumber) {
      state.blockNumber = blockNumber;
    },
    // Every call fails as an unreachable RPC does: RPC_UNAVAILABLE.
    failRpc(down = true) {
      state.down = down;
    },
    // Every call fails the network check, as on a node on another chain ('WRONG_CHAIN') or
    // one with no contract at the address ('NO_CONTRACT_CODE'). null clears it.
    refuse(code) {
      state.refusal = code === null ? null : READER_REFUSALS[code];
      if (state.refusal === undefined) throw new TypeError(`unknown refusal ${code}`);
    },
    isClosed() {
      return state.closed;
    },
  };

  return { reader: Object.freeze(reader), control };
}
