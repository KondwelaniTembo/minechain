import { describe, it, expect, vi } from 'vitest';
import { inspect } from 'node:util';
import { Interface, keccak256 } from 'ethers';
import { createChainReader, createChainReaderFromConfig, READER_REFUSALS } from '../src/chain/chainReader.js';
import { ChainClientError } from '../src/chain/rpc.js';
import { ChainClientError as ReExported } from '../src/chain/chainClient.js';
import { EXPECTED_CODE_HASH, MINECHAIN_ABI } from '../src/chain/mineChainAbi.js';
import { loadConfig } from '../src/config.js';
import { createFakeChainReader } from './fakes/fakeChainReader.js';
import { createFakeChainClient, MINECHAIN_RUNTIME_CODE } from './fakes/fakeChainClient.js';

// Real ethers, real config, fake HTTP (as in chainClient.test.js): every request goes to
// rpcTransport below, so no test here can reach Sepolia.

const abi = new Interface(MINECHAIN_ABI);

// Fake values only.
const FAKE_RPC_URL = 'https://sepolia.rpc.example/v2/fake-primary-api-key-1234';
const FAKE_FALLBACK_URL = 'https://fallback.rpc.example/fake-fallback-api-key-5678';
const CONTRACT_ADDRESS = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';
const SEPOLIA_HEX = '0xaa36a7';
// Some contract, but not MineChain.
const OTHER_CODE = '0x6080604052';
const TX_HASH = `0x${'cc'.repeat(32)}`;

// The URLs, their key parts, and the host names: the reader logs and reports none of them.
const SECRETS = [
  FAKE_RPC_URL,
  FAKE_FALLBACK_URL,
  'fake-primary-api-key-1234',
  'fake-fallback-api-key-5678',
  'sepolia.rpc.example',
  'fallback.rpc.example',
];

function expectNoSecrets(text) {
  for (const secret of SECRETS) expect(text).not.toContain(secret);
}

// Anchoring off and no recorder key: what the reader must work with.
function readerConfig(overrides = {}) {
  return loadConfig({
    NODE_ENV: 'development',
    PORT: '3000',
    DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_dev',
    JWT_SECRET: 'a-fake-test-secret-that-is-long-enough-1234',
    JWT_EXPIRES_IN: '60m',
    ANCHOR_ENABLED: 'false',
    SEPOLIA_RPC_URL: FAKE_RPC_URL,
    SEPOLIA_RPC_URL_FALLBACK: FAKE_FALLBACK_URL,
    MINECHAIN_CONTRACT_ADDRESS: CONTRACT_ADDRESS,
    ...overrides,
  }).anchor;
}

// handler(payload, url) returns { result }, { error } or { httpStatus }, or throws as a
// broken connection would. Every request is recorded.
function rpcTransport(handler) {
  const requests = [];
  async function getUrl(req) {
    const payload = JSON.parse(Buffer.from(req.body).toString('utf8'));
    requests.push({ url: req.url, method: payload.method, params: payload.params });
    const reply = await handler(payload, req.url);
    if (reply.httpStatus) {
      // A provider's error page that repeats the URL, as some do.
      return { statusCode: reply.httpStatus, statusMessage: 'Service Unavailable', headers: {}, body: Buffer.from(`upstream down: ${req.url}`) };
    }
    const body = 'error' in reply
      ? { jsonrpc: '2.0', id: payload.id, error: reply.error }
      : { jsonrpc: '2.0', id: payload.id, result: reply.result };
    return { statusCode: 200, statusMessage: 'OK', headers: { 'content-type': 'application/json' }, body: Buffer.from(JSON.stringify(body)) };
  }
  return { getUrl, requests };
}

const unreachable = (url) => {
  // A Node connection error repeats what it tried to reach, so the raw error holds the key.
  throw Object.assign(new Error(`connect ECONNREFUSED ${url}`), { code: 'ECONNREFUSED' });
};

const noRequestsExpected = () => {
  throw new Error('no request was expected');
};

// A healthy Sepolia node with the contract deployed; `answers` overrides methods.
function sepoliaNode(answers = {}) {
  return (payload, url) => {
    if (payload.method in answers) return answers[payload.method](payload, url);
    if (payload.method === 'eth_chainId') return { result: SEPOLIA_HEX };
    // The real deployed bytecode (read from the committed artifact by the fake chain client),
    // so the code-hash check passes for the right reason.
    if (payload.method === 'eth_getCode') return { result: MINECHAIN_RUNTIME_CODE };
    if (payload.method === 'eth_blockNumber') return { result: '0x10' };
    // A transaction this node has not seen; tests that need a receipt override it.
    if (payload.method === 'eth_getTransactionReceipt') return { result: null };
    throw new Error(`unexpected ${payload.method}`);
  };
}

function readerWith(handler, { config = readerConfig(), ...options } = {}) {
  const transport = rpcTransport(handler);
  const log = { warn: vi.fn() };
  const reader = createChainReader(config, { transport: transport.getUrl, log, ...options });
  const methods = () => transport.requests.map((r) => r.method);
  return { reader, requests: transport.requests, methods, log };
}

async function expectChainError(promise, expected) {
  const err = await promise.then(
    () => {
      throw new Error('expected a ChainClientError');
    },
    (e) => e,
  );
  expect(err).toBeInstanceOf(ChainClientError);
  expect(err).toMatchObject(expected);
  return err;
}

describe('createChainReader: construction', () => {
  it('needs no recorder key: it works with RECORDER_PRIVATE_KEY absent', async () => {
    const config = readerConfig();
    expect(config.recorderPrivateKey).toBeNull();
    const { reader } = readerWith(sepoliaNode(), { config });

    await expect(reader.getBlockNumber()).resolves.toBe(16);
    reader.close();
  });

  it('never reads recorderPrivateKey at all', async () => {
    const config = readerConfig();
    // A copy whose key getter fails the test if anything touches it.
    const guarded = Object.defineProperties(
      { contractAddress: config.contractAddress, chainId: config.chainId },
      {
        rpcUrl: { get: () => config.rpcUrl },
        fallbackRpcUrl: { get: () => config.fallbackRpcUrl },
        recorderPrivateKey: {
          get: () => {
            throw new Error('the reader read the recorder key');
          },
        },
      },
    );
    const { reader } = readerWith(sepoliaNode(), { config: guarded });

    await expect(reader.getBlockNumber()).resolves.toBe(16);
    reader.close();
  });

  it('makes no network request, not even later in the background', async () => {
    const { reader, requests } = readerWith(noRequestsExpected);

    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(requests).toEqual([]);
    reader.close();
  });

  it('exposes only contractAddress, getReceipt, getBlockNumber and close', () => {
    const { reader } = readerWith(noRequestsExpected);

    expect(Object.keys(reader).sort()).toEqual(['close', 'contractAddress', 'getBlockNumber', 'getReceipt']);
    expect(reader.contractAddress).toBe(CONTRACT_ADDRESS);
    expect(Object.isFrozen(reader)).toBe(true);
    reader.close();
  });

  it.each([
    ['SEPOLIA_RPC_URL', { SEPOLIA_RPC_URL: '', SEPOLIA_RPC_URL_FALLBACK: '' }],
    ['MINECHAIN_CONTRACT_ADDRESS', { MINECHAIN_CONTRACT_ADDRESS: '' }],
  ])('refuses to start without %s, naming the variable only', (name, overrides) => {
    let thrown;
    try {
      createChainReader(readerConfig(overrides), { transport: noRequestsExpected });
    } catch (err) {
      thrown = err;
    }
    expect(thrown?.message).toBe(`Chain reader needs ${name}`);
    expectNoSecrets(inspect(thrown));
  });

  it('throws the same ChainClientError class that chainClient.js exports', () => {
    expect(ReExported).toBe(ChainClientError);
  });
});

describe('createChainReader: the network check', () => {
  it('checks chain id and code before the first answer, and only once when it passes', async () => {
    const { reader, methods } = readerWith(sepoliaNode());

    await expect(reader.getBlockNumber()).resolves.toBe(16);
    await expect(reader.getBlockNumber()).resolves.toBe(16);
    await expect(reader.getReceipt(TX_HASH)).resolves.toBeNull();

    expect(methods()).toEqual(['eth_chainId', 'eth_getCode', 'eth_blockNumber', 'eth_blockNumber', 'eth_getTransactionReceipt']);
    reader.close();
  });

  it('asks for the code at the configured contract address', async () => {
    const { reader, requests } = readerWith(sepoliaNode());

    await reader.getBlockNumber();

    const getCode = requests.find((r) => r.method === 'eth_getCode');
    expect(getCode.params[0].toLowerCase()).toBe(CONTRACT_ADDRESS.toLowerCase());
    reader.close();
  });

  it('refuses a node on another chain: WRONG_CHAIN, nothing else asked, not trusted later', async () => {
    const { reader, methods, log } = readerWith(sepoliaNode({ eth_chainId: () => ({ result: '0x1' }) }));

    await expectChainError(reader.getReceipt(TX_HASH), { code: 'WRONG_CHAIN', action: 'stop', endpoint: 'primary' });
    // A wrong network is a configuration fault, so the fallback is not asked either.
    expect(methods()).toEqual(['eth_chainId']);

    // Still refused: a failed check is never remembered as passed.
    await expectChainError(reader.getBlockNumber(), { code: 'WRONG_CHAIN' });
    expect(methods()).toEqual(['eth_chainId', 'eth_chainId']);

    expect(log.warn).toHaveBeenCalledWith('Chain reader: primary RPC failed the network check: WRONG_CHAIN');
    reader.close();
  });

  it('refuses a contract address with no code: NO_CONTRACT_CODE, and no receipt is asked for', async () => {
    const { reader, methods } = readerWith(sepoliaNode({ eth_getCode: () => ({ result: '0x' }) }));

    const err = await expectChainError(reader.getReceipt(TX_HASH), { code: 'NO_CONTRACT_CODE', action: 'stop' });

    expect(err.reason).toBe(READER_REFUSALS.NO_CONTRACT_CODE.reason);
    expect(methods()).toEqual(['eth_chainId', 'eth_getCode']);
    reader.close();
  });

  it('passes the deployed MineChain bytecode, by the code hash preflight uses', async () => {
    expect(keccak256(MINECHAIN_RUNTIME_CODE)).toBe(EXPECTED_CODE_HASH);
    const { reader, methods } = readerWith(sepoliaNode());

    await expect(reader.getBlockNumber()).resolves.toBe(16);
    await expect(reader.getBlockNumber()).resolves.toBe(16);

    expect(methods()).toEqual(['eth_chainId', 'eth_getCode', 'eth_blockNumber', 'eth_blockNumber']);
    reader.close();
  });

  it('refuses other non-empty code: WRONG_CONTRACT_CODE, with no extra request and nothing further asked', async () => {
    const { reader, methods, log } = readerWith(sepoliaNode({ eth_getCode: () => ({ result: OTHER_CODE }) }));

    const err = await expectChainError(reader.getReceipt(TX_HASH), {
      code: 'WRONG_CONTRACT_CODE',
      action: 'stop',
      endpoint: 'primary',
    });

    expect(err.reason).toBe(READER_REFUSALS.WRONG_CONTRACT_CODE.reason);
    // The hash is worked out from the eth_getCode reply; no receipt, no fallback.
    expect(methods()).toEqual(['eth_chainId', 'eth_getCode']);
    expect(log.warn).toHaveBeenCalledWith('Chain reader: primary RPC failed the network check: WRONG_CONTRACT_CODE');

    await expectChainError(reader.getBlockNumber(), { code: 'WRONG_CONTRACT_CODE' });
    expect(methods()).toEqual(['eth_chainId', 'eth_getCode', 'eth_chainId', 'eth_getCode']);
    reader.close();
  });

  it('is unavailable while the check cannot be made, and passes once the node answers', async () => {
    let down = true;
    const { reader, methods } = readerWith(
      sepoliaNode({ eth_chainId: (_p, url) => (down ? unreachable(url) : { result: SEPOLIA_HEX }) }),
      { config: readerConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) },
    );

    await expectChainError(reader.getBlockNumber(), { code: 'RPC_UNAVAILABLE', endpoint: 'primary' });
    expect(methods()).toEqual(['eth_chainId']);

    down = false;
    await expect(reader.getBlockNumber()).resolves.toBe(16);
    expect(methods()).toEqual(['eth_chainId', 'eth_chainId', 'eth_getCode', 'eth_blockNumber']);
    reader.close();
  });

  it('shares one check between calls made at the same time', async () => {
    const { reader, methods } = readerWith(sepoliaNode());

    await Promise.all([reader.getBlockNumber(), reader.getReceipt(TX_HASH), reader.getBlockNumber()]);

    expect(methods().filter((m) => m === 'eth_chainId')).toHaveLength(1);
    expect(methods().filter((m) => m === 'eth_getCode')).toHaveLength(1);
    reader.close();
  });

  it('checks the fallback itself before trusting its first answer', async () => {
    const { reader, requests, log } = readerWith(
      sepoliaNode({
        eth_chainId: (_p, url) => (url === FAKE_RPC_URL ? unreachable(url) : { result: SEPOLIA_HEX }),
      }),
    );

    await expect(reader.getBlockNumber()).resolves.toBe(16);

    expect(requests.map((r) => [r.url === FAKE_RPC_URL ? 'primary' : 'fallback', r.method])).toEqual([
      ['primary', 'eth_chainId'],
      ['fallback', 'eth_chainId'],
      ['fallback', 'eth_getCode'],
      ['fallback', 'eth_blockNumber'],
    ]);
    expect(log.warn).toHaveBeenCalledWith('Chain reader: primary RPC unavailable during getBlockNumber; trying fallback RPC');
    reader.close();
  });

  it('refuses a fallback on another chain even when the primary was fine before', async () => {
    let primaryDown = false;
    const { reader } = readerWith(
      sepoliaNode({
        eth_chainId: (_p, url) => (url === FAKE_RPC_URL ? { result: SEPOLIA_HEX } : { result: '0x1' }),
        eth_blockNumber: (_p, url) => (url === FAKE_RPC_URL && primaryDown ? unreachable(url) : { result: '0x10' }),
      }),
    );
    await expect(reader.getBlockNumber()).resolves.toBe(16);

    primaryDown = true;
    await expectChainError(reader.getBlockNumber(), { code: 'WRONG_CHAIN', endpoint: 'fallback' });
    reader.close();
  });
});

describe('createChainReader: getReceipt', () => {
  const ID = `0x${'11'.repeat(32)}`;
  const ACTOR = `0x${'aa'.repeat(32)}`;
  const DATA_HASH = `0x${'dd'.repeat(32)}`;

  function nodeLog(address) {
    const { data, topics } = abi.encodeEventLog(abi.getEvent('HandoffRecorded'), [ID, ACTOR, 1_500_000n, DATA_HASH, 1_762_600_000n]);
    return {
      address,
      topics,
      data,
      blockNumber: '0x64',
      blockHash: `0x${'bb'.repeat(32)}`,
      transactionHash: TX_HASH,
      transactionIndex: '0x0',
      logIndex: '0x0',
      removed: false,
    };
  }

  const nodeReceipt = {
    transactionHash: TX_HASH,
    blockHash: `0x${'bb'.repeat(32)}`,
    blockNumber: '0x64',
    transactionIndex: '0x0',
    from: `0x${'25'.repeat(20)}`,
    to: CONTRACT_ADDRESS,
    contractAddress: null,
    gasUsed: '0xe7ac',
    cumulativeGasUsed: '0xe7ac',
    effectiveGasPrice: '0x3b9aca00',
    logsBloom: `0x${'00'.repeat(256)}`,
    status: '0x1',
    type: '0x2',
    logs: [nodeLog(CONTRACT_ADDRESS), nodeLog(`0x${'12'.repeat(20)}`)],
  };

  it('returns the receipt with MineChain events only, the same shape as the chain client', async () => {
    const { reader, requests } = readerWith(sepoliaNode({ eth_getTransactionReceipt: () => ({ result: nodeReceipt }) }));

    const receipt = await reader.getReceipt(TX_HASH);

    expect(requests.at(-1)).toMatchObject({ method: 'eth_getTransactionReceipt', params: [TX_HASH] });
    expect(receipt).toMatchObject({ hash: TX_HASH, status: 1, blockNumber: 100, gasUsed: 59_308n });
    expect(receipt.events).toHaveLength(1);
    expect(receipt.events[0]).toMatchObject({
      name: 'HandoffRecorded',
      args: { id: ID, transporterRef: ACTOR, weightMilligrams: 1_500_000n, dataHash: DATA_HASH },
    });
    expect(Object.isFrozen(receipt)).toBe(true);
    reader.close();
  });

  it('returns null for a transaction the node does not know', async () => {
    const { reader } = readerWith(sepoliaNode({ eth_getTransactionReceipt: () => ({ result: null }) }));

    await expect(reader.getReceipt(TX_HASH)).resolves.toBeNull();
    reader.close();
  });

  it('refuses a malformed hash before any request', async () => {
    const { reader, requests } = readerWith(noRequestsExpected);

    await expect(reader.getReceipt('0x1234')).rejects.toThrow(TypeError);
    expect(requests).toEqual([]);
    reader.close();
  });
});

describe('createChainReader: secrets stay out of errors, logs and output', () => {
  it('a connection error carrying the URL becomes RPC_UNAVAILABLE without it, on both endpoints', async () => {
    const { reader, requests, log } = readerWith((_payload, url) => unreachable(url));

    const err = await expectChainError(reader.getReceipt(TX_HASH), { code: 'RPC_UNAVAILABLE', endpoint: 'fallback' });

    // Both URLs really were used, so the checks below are not vacuous.
    expect(requests.map((r) => r.url)).toEqual([FAKE_RPC_URL, FAKE_FALLBACK_URL]);
    expect(err.cause).toBeUndefined();
    expectNoSecrets(err.message);
    expectNoSecrets(err.stack);
    expectNoSecrets(inspect(err, { showHidden: true, depth: Infinity }));
    expectNoSecrets(JSON.stringify(err));
    expectNoSecrets(log.warn.mock.calls.flat().join('\n'));
    reader.close();
  });

  it('an HTTP 503 page repeating the URL becomes RPC_UNAVAILABLE without it', async () => {
    const { reader } = readerWith(() => ({ httpStatus: 503 }), { config: readerConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) });

    const err = await expectChainError(reader.getBlockNumber(), { code: 'RPC_UNAVAILABLE', endpoint: 'primary' });

    expectNoSecrets(inspect(err, { showHidden: true, depth: Infinity }));
    reader.close();
  });

  it('every log line names endpoints by role only', async () => {
    const { reader, log } = readerWith(
      sepoliaNode({ eth_chainId: (_p, url) => (url === FAKE_RPC_URL ? unreachable(url) : { result: '0x1' }) }),
    );

    await expectChainError(reader.getBlockNumber(), { code: 'WRONG_CHAIN', endpoint: 'fallback' });

    const lines = log.warn.mock.calls.flat();
    expect(lines).toHaveLength(2);
    for (const line of lines) {
      expect(line).toMatch(/^Chain reader: (primary|fallback) RPC /);
      expectNoSecrets(line);
    }
    reader.close();
  });

  it.each([
    ['util.inspect', (reader) => inspect(reader, { showHidden: true, depth: Infinity })],
    ['JSON.stringify', (reader) => JSON.stringify(reader)],
    ['String', (reader) => String(reader)],
  ])('%s of the reader shows no URL or host', (_label, show) => {
    const { reader } = readerWith(noRequestsExpected);

    expectNoSecrets(show(reader));
    reader.close();
  });
});

describe('createChainReader: close', () => {
  it('stops the providers: a later call fails with a ChainClientError and sends nothing', async () => {
    const { reader, requests } = readerWith(sepoliaNode());
    await reader.getBlockNumber();
    const before = requests.length;

    reader.close();

    await expectChainError(reader.getBlockNumber(), { endpoint: 'primary' });
    expect(requests).toHaveLength(before);
  });
});

describe('createChainReaderFromConfig: the server wiring', () => {
  it('creates a reader with ANCHOR_ENABLED false, making no request', async () => {
    const transport = rpcTransport(noRequestsExpected);

    const reader = createChainReaderFromConfig(readerConfig({ ANCHOR_ENABLED: 'false' }), { transport: transport.getUrl });

    expect(reader).not.toBeNull();
    expect(reader.contractAddress).toBe(CONTRACT_ADDRESS);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(transport.requests).toEqual([]);
    reader.close();
  });

  it('creates a reader with ANCHOR_ENABLED true as well', () => {
    const config = readerConfig({ ANCHOR_ENABLED: 'true', RECORDER_PRIVATE_KEY: `0x${'1a2b3c4d'.repeat(8)}` });

    const reader = createChainReaderFromConfig(config, { transport: noRequestsExpected });

    expect(reader).not.toBeNull();
    reader.close();
  });

  it.each([
    ['no RPC URL', { SEPOLIA_RPC_URL: '', SEPOLIA_RPC_URL_FALLBACK: '' }],
    ['no contract address', { MINECHAIN_CONTRACT_ADDRESS: '' }],
    ['the .env.example placeholders', { SEPOLIA_RPC_URL: 'https://replace-with-your-rpc-url', SEPOLIA_RPC_URL_FALLBACK: '' }],
  ])('returns null with %s', (_label, overrides) => {
    expect(createChainReaderFromConfig(readerConfig(overrides), { transport: noRequestsExpected })).toBeNull();
  });
});

describe('fakeChainReader', () => {
  it('has the same public keys as the real reader', () => {
    const { reader: real } = readerWith(noRequestsExpected);
    const { reader: fake } = createFakeChainReader();

    expect(Object.keys(fake).sort()).toEqual(Object.keys(real).sort());
    real.close();
  });

  it('fails as the real reader does: RPC_UNAVAILABLE when down, the refusal codes when refused', async () => {
    const { reader, control } = createFakeChainReader();

    control.failRpc();
    await expectChainError(reader.getBlockNumber(), { code: 'RPC_UNAVAILABLE', action: 'backoff' });
    control.failRpc(false);
    control.refuse('WRONG_CHAIN');
    await expectChainError(reader.getReceipt(TX_HASH), { code: 'WRONG_CHAIN', action: 'stop' });
    control.refuse(null);
    await expect(reader.getReceipt(TX_HASH)).resolves.toBeNull();
    expect(control.calls.map((c) => c.method)).toEqual(['getBlockNumber', 'getReceipt', 'getReceipt']);
  });

  it.each(['WRONG_CHAIN', 'NO_CONTRACT_CODE', 'WRONG_CONTRACT_CODE'])('refuse() accepts %s, as the real reader reports it', async (code) => {
    const { reader, control } = createFakeChainReader();

    control.refuse(code);

    const err = await expectChainError(reader.getBlockNumber(), { code, action: 'stop' });
    expect(err.reason).toBe(READER_REFUSALS[code].reason);
  });

  it('refuse() refuses a code the real reader does not have', () => {
    const { control } = createFakeChainReader();

    expect(() => control.refuse('BAD_CODE')).toThrow(TypeError);
  });

  it('reads receipts from a fake chain client, so anchored steps can be verified', async () => {
    const { client } = createFakeChainClient();
    const { reader } = createFakeChainReader({ chain: client });

    await expect(reader.getBlockNumber()).resolves.toBe(await client.getBlockNumber());
    await expect(reader.getReceipt(TX_HASH)).resolves.toBeNull();
    expect(reader.contractAddress).toBe(client.contractAddress);
  });
});
