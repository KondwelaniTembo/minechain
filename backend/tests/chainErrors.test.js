import { describe, it, expect } from 'vitest';
import { Interface, makeError } from 'ethers';
import { classifyChainError, feeTooHigh, toAnchorError, CHAIN_ERRORS } from '../src/chain/chainErrors.js';
import { MINECHAIN_ABI } from '../src/chain/mineChainAbi.js';

const abi = new Interface(MINECHAIN_ABI);
const ID = `0x${'00'.repeat(16)}${'ab'.repeat(16)}`;
const RECORDER_ROLE = '0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4';

// A revert as ethers v6 reports it from estimateGas or a call: CALL_EXCEPTION, with the
// raw revert bytes in data.
const revert = (data) => makeError('execution reverted', 'CALL_EXCEPTION', { data });
const revertWith = (name, args) => revert(abi.encodeErrorResult(name, args));

describe('classifyChainError: the contract custom errors', () => {
  it('AccessControlUnauthorizedAccount is ROLE_LOST, which stops the worker', () => {
    const err = revertWith('AccessControlUnauthorizedAccount', [`0x${'12'.repeat(20)}`, RECORDER_ROLE]);

    expect(classifyChainError(err)).toMatchObject({ code: 'ROLE_LOST', action: 'stop' });
  });

  it.each([
    [0, 'id'],
    [1, 'actorRef'],
    [2, 'weightMilligrams'],
    [3, 'dataHash'],
  ])('InvalidInput(%i) is INVALID_INPUT for field %s, which fails the step', (field, name) => {
    expect(classifyChainError(revertWith('InvalidInput', [field]))).toMatchObject({
      code: 'INVALID_INPUT',
      action: 'fail',
      field: name,
    });
  });

  it('ConsignmentAlreadyExists is ALREADY_EXISTS, which reads the chain before deciding', () => {
    expect(classifyChainError(revertWith('ConsignmentAlreadyExists', [ID]))).toMatchObject({
      code: 'ALREADY_EXISTS',
      action: 'reconcile',
    });
  });

  it('InvalidStage at None is retried: the registration may not be visible yet', () => {
    expect(classifyChainError(revertWith('InvalidStage', [ID, 0]))).toMatchObject({
      code: 'INVALID_STAGE',
      action: 'retry',
      currentStage: 'None',
    });
  });

  it.each([
    [1, 'Registered'],
    [2, 'InTransit'],
    [3, 'Purchased'],
  ])('InvalidStage at stage %i (%s) fails the step: waiting cannot change it', (stage, name) => {
    expect(classifyChainError(revertWith('InvalidStage', [ID, stage]))).toMatchObject({
      code: 'INVALID_STAGE',
      action: 'fail',
      currentStage: name,
    });
  });

  it.each([
    ['in error.data (a wrapped provider error)', (data) => ({ message: 'wrapped', error: { data } })],
    ['in info.error.data (an ethers JSON-RPC error)', (data) => ({ info: { error: { code: 3, data } } })],
    ['in cause.data', (data) => ({ cause: { data } })],
    ['in data.data (some providers nest it)', (data) => ({ data: { data } })],
  ])('finds revert data %s', (_label, wrap) => {
    const err = wrap(abi.encodeErrorResult('ConsignmentAlreadyExists', [ID]));

    expect(classifyChainError(err).code).toBe('ALREADY_EXISTS');
  });

  it.each([
    ['a selector that is not ours', '0xdeadbeef'],
    ['a standard Error(string) revert', '0x08c379a0' + '00'.repeat(64)],
    ['our InvalidStage selector with its arguments cut short', abi.getError('InvalidStage').selector + '00'.repeat(10)],
  ])('treats %s as UNKNOWN without throwing', (_label, data) => {
    expect(classifyChainError(revert(data)).code).toBe('UNKNOWN');
  });

  it('treats a revert with no data at all as UNKNOWN', () => {
    expect(classifyChainError(makeError('missing revert data', 'CALL_EXCEPTION', { data: null })).code).toBe('UNKNOWN');
  });
});

describe('classifyChainError: wallet and transaction problems', () => {
  it.each([
    ['the ethers code', makeError('insufficient funds for intrinsic transaction cost', 'INSUFFICIENT_FUNDS')],
    ['the node message only', { code: -32000, message: 'insufficient funds for gas * price + value' }],
  ])('INSUFFICIENT_FUNDS from %s pauses sending', (_label, err) => {
    expect(classifyChainError(err)).toMatchObject({ code: 'INSUFFICIENT_FUNDS', action: 'pause' });
  });

  it.each([
    ['the ethers code', makeError('nonce has already been used', 'NONCE_EXPIRED')],
    ['the node message', { code: -32000, message: 'nonce too low: next nonce 5, tx nonce 4' }],
  ])('NONCE_USED from %s', (_label, err) => {
    expect(classifyChainError(err)).toMatchObject({ code: 'NONCE_USED', action: 'inspect' });
  });

  it('REPLACEMENT_UNDERPRICED', () => {
    const err = makeError('replacement fee too low', 'REPLACEMENT_UNDERPRICED');

    expect(classifyChainError(err)).toMatchObject({ code: 'REPLACEMENT_UNDERPRICED', action: 'inspect' });
  });

  it('ALREADY_KNOWN, when the second RPC is sent the same signed transaction', () => {
    expect(classifyChainError({ code: -32000, message: 'already known' }).code).toBe('ALREADY_KNOWN');
  });

  it("FEE_TOO_HIGH from the node's own fee cap", () => {
    const err = { code: -32000, message: 'tx fee (1.20 ether) exceeds the configured cap (1.00 ether)' };

    expect(classifyChainError(err)).toMatchObject({ code: 'FEE_TOO_HIGH', action: 'pause' });
  });

  it("feeTooHigh() gives the same result for the worker's own fee check", () => {
    expect(feeTooHigh()).toEqual(classifyChainError({ message: 'exceeds the configured cap' }));
  });
});

describe('classifyChainError: the RPC provider', () => {
  it.each([
    ['ethers NETWORK_ERROR', makeError('network changed', 'NETWORK_ERROR')],
    ['ethers TIMEOUT', makeError('timeout', 'TIMEOUT')],
    ['ethers SERVER_ERROR with status 503', makeError('server response 503', 'SERVER_ERROR', { response: { statusCode: 503 } })],
    ['HTTP 429 in responseStatus', makeError('bad response', 'UNKNOWN_ERROR', { info: { responseStatus: '429 Too Many Requests' } })],
    ['HTTP 502 as status', { status: 502 }],
    ['ethers BAD_DATA', makeError('invalid JSON', 'BAD_DATA')],
    ['JSON-RPC -32005 (limit exceeded)', { code: -32005, message: 'daily request count exceeded' }],
    ['JSON-RPC -32603 (internal error)', { code: -32603, message: 'internal error' }],
    ['fetch failed with ECONNRESET', Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNRESET' } })],
    ['DNS failure ENOTFOUND', { code: 'ENOTFOUND' }],
    ['a bare fetch failed', new TypeError('fetch failed')],
  ])('%s is RPC_UNAVAILABLE, which backs off without counting an attempt', (_label, err) => {
    expect(classifyChainError(err)).toMatchObject({ code: 'RPC_UNAVAILABLE', action: 'backoff' });
  });

  it('a revert is never mistaken for an outage, even inside a SERVER_ERROR', () => {
    const err = makeError('server error', 'SERVER_ERROR', { error: { data: abi.encodeErrorResult('InvalidInput', [3]) } });

    expect(classifyChainError(err).code).toBe('INVALID_INPUT');
  });
});

describe('classifyChainError: anything else', () => {
  it.each([
    ['a plain Error', new Error('something odd')],
    ['null', null],
    ['undefined', undefined],
    ['a string', 'boom'],
    ['a number', 42],
    ['an empty object', {}],
  ])('%s is UNKNOWN', (_label, err) => {
    expect(classifyChainError(err)).toMatchObject({ code: 'UNKNOWN', action: 'retry' });
  });

  it('does not loop on an error that refers to itself', () => {
    const err = { message: 'loop' };
    err.cause = err;

    expect(classifyChainError(err).code).toBe('UNKNOWN');
  });
});

describe('output never carries provider text', () => {
  const API_KEY = 'SuperSecretApiKey123';
  const RPC_URL = `https://eth-sepolia.g.alchemy.com/v2/${API_KEY}`;

  // The places ethers and fetch put request details: the message, ethers' info, the
  // request object, and the error behind it.
  const leakyErrors = [
    ['an outage', makeError(`request failed: ${RPC_URL}`, 'SERVER_ERROR', { info: { requestUrl: RPC_URL }, response: { statusCode: 503 } })],
    ['a revert', makeError(`execution reverted (url=${RPC_URL})`, 'CALL_EXCEPTION', { data: abi.encodeErrorResult('InvalidStage', [ID, 2]), info: { url: RPC_URL } })],
    ['insufficient funds', { message: `insufficient funds, sent to ${RPC_URL}`, request: { url: RPC_URL } }],
    ['an unknown error', new Error(`HTTP request failed. URL: ${RPC_URL}`)],
    ['a fetch failure', Object.assign(new TypeError(`fetch failed for ${RPC_URL}`), { cause: { code: 'ECONNRESET', host: 'eth-sepolia.g.alchemy.com' } })],
  ];

  it.each(leakyErrors)('%s: the result has no URL, host or key', (_label, err) => {
    const text = JSON.stringify(classifyChainError(err));

    expect(text).not.toContain('https://');
    expect(text).not.toContain('alchemy');
    expect(text).not.toContain(API_KEY);
  });

  it.each(leakyErrors)('%s: the stored anchor_error has no URL, host or key', (_label, err) => {
    const stored = toAnchorError(classifyChainError(err));

    expect(stored).not.toContain('https://');
    expect(stored).not.toContain('alchemy');
    expect(stored).not.toContain(API_KEY);
  });

  it('every result has only our own keys and a reason from the fixed table', () => {
    const reasons = Object.values(CHAIN_ERRORS).map((e) => e.reason);

    for (const [, err] of leakyErrors) {
      const classified = classifyChainError(err);

      expect(Object.isFrozen(classified)).toBe(true);
      for (const key of Object.keys(classified)) {
        expect(['code', 'action', 'reason', 'field', 'currentStage']).toContain(key);
      }
      expect(reasons).toContain(classified.reason);
    }
  });
});

describe('toAnchorError', () => {
  it('stores the code, the decoded detail and the fixed reason', () => {
    expect(toAnchorError(classifyChainError(revertWith('InvalidInput', [2])))).toBe(
      `INVALID_INPUT:weightMilligrams: ${CHAIN_ERRORS.INVALID_INPUT.reason}`,
    );
    expect(toAnchorError(classifyChainError(revertWith('InvalidStage', [ID, 3])))).toBe(
      `INVALID_STAGE:Purchased: ${CHAIN_ERRORS.INVALID_STAGE.reason}`,
    );
  });

  it('stores code and reason only when there is no detail', () => {
    expect(toAnchorError(feeTooHigh())).toBe(`FEE_TOO_HIGH: ${CHAIN_ERRORS.FEE_TOO_HIGH.reason}`);
  });

  it('is never blank, as the transactions_failed_needs_error CHECK requires', () => {
    for (const code of Object.keys(CHAIN_ERRORS)) {
      const stored = toAnchorError({ code, ...CHAIN_ERRORS[code] });

      expect(stored.trim()).not.toBe('');
    }
  });
});
