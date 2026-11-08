import { describe, it, expect, vi } from 'vitest';
import { inspect } from 'node:util';
import { Console } from 'node:console';
import { Writable } from 'node:stream';
import { Interface, Transaction, keccak256 } from 'ethers';
import { createChainClient, ChainClientError } from '../src/chain/chainClient.js';
import { DEPLOY_BLOCK, MINECHAIN_ABI } from '../src/chain/mineChainAbi.js';
import { buildAnchorCall } from '../src/services/anchorCall.js';
import { loadConfig } from '../src/config.js';

// Real ethers, real config, fake HTTP: every request goes to rpcTransport below instead of
// the network, so these tests prove the adapter's own logic without touching Sepolia. The
// adapter against a real node is proven by the manual live run.

const abi = new Interface(MINECHAIN_ABI);

// Fake values only, in the same style as tests/config.test.js.
const FAKE_RPC_URL = 'https://sepolia.rpc.example/v2/fake-primary-api-key-1234';
const FAKE_FALLBACK_URL = 'https://fallback.rpc.example/fake-fallback-api-key-5678';
const FAKE_PRIVATE_KEY = `0x${'1a2b3c4d'.repeat(8)}`;
const CONTRACT_ADDRESS = '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a';
const GWEI = 1_000_000_000n;

// Every text that must never appear in output: the URLs, their key parts, and the private
// key with and without 0x.
const SECRETS = [
  FAKE_RPC_URL,
  FAKE_FALLBACK_URL,
  'fake-primary-api-key-1234',
  'fake-fallback-api-key-5678',
  FAKE_PRIVATE_KEY,
  FAKE_PRIVATE_KEY.slice(2),
];

function expectNoSecrets(text) {
  for (const secret of SECRETS) expect(text).not.toContain(secret);
}

function anchorConfig(overrides = {}) {
  return loadConfig({
    NODE_ENV: 'development',
    PORT: '3000',
    DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_dev',
    TEST_DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_test',
    JWT_SECRET: 'a-fake-test-secret-that-is-long-enough-1234',
    JWT_EXPIRES_IN: '60m',
    ANCHOR_ENABLED: 'true',
    SEPOLIA_RPC_URL: FAKE_RPC_URL,
    SEPOLIA_RPC_URL_FALLBACK: FAKE_FALLBACK_URL,
    MINECHAIN_CONTRACT_ADDRESS: CONTRACT_ADDRESS,
    RECORDER_PRIVATE_KEY: FAKE_PRIVATE_KEY,
    ...overrides,
  }).anchor;
}

// An in-memory replacement for ethers' HTTP layer. handler(payload, url) returns
// { result }, { error } (a JSON-RPC error) or { httpStatus }, or throws as a broken
// connection would. Every request is recorded.
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

const silentLog = () => ({ warn: vi.fn() });

function clientWith(handler, { config = anchorConfig(), log = silentLog(), ...options } = {}) {
  const transport = rpcTransport(handler);
  const client = createChainClient(config, { transport: transport.getUrl, log, ...options });
  return { client, requests: transport.requests, log };
}

const noRequestsExpected = () => {
  throw new Error('no request was expected');
};

const unreachable = (url) => {
  // A Node connection error repeats what it tried to reach, so the raw error holds the key.
  throw Object.assign(new Error(`connect ECONNREFUSED ${url}`), { code: 'ECONNREFUSED' });
};

const CALL = buildAnchorCall({
  type: 'registration',
  chain_id: Buffer.concat([Buffer.alloc(16), Buffer.from('6f1d2c3a00004000800000000000a101', 'hex')]),
  actor_ref: Buffer.alloc(32, 0xaa),
  weight_mg: '1500000',
  data_hash: Buffer.alloc(32, 0xdd),
});

const FEES = { nonce: 0, gasLimit: 120_000n, maxFeePerGas: 2n * GWEI, maxPriorityFeePerGas: 1n * GWEI };

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

describe('createChainClient: construction', () => {
  it('makes no network request, not even later in the background', async () => {
    const { client, requests } = clientWith(noRequestsExpected);

    // Long enough for any timer ethers might start (its network detection retries every 1s
    // only after a first attempt, which would already be recorded here).
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(requests).toEqual([]);
    client.close();
  });

  it('sends exactly the call asked for, with no eth_chainId detection first', async () => {
    // Proves the transport seam is wired: without this, the test above could pass because
    // requests went somewhere else.
    const { client, requests } = clientWith(() => ({ result: '0x10' }));

    await expect(client.getBlockNumber()).resolves.toBe(16);

    expect(requests.map((r) => [r.url, r.method])).toEqual([[FAKE_RPC_URL, 'eth_blockNumber']]);
    client.close();
  });

  it('exposes only public facts', () => {
    const { client } = clientWith(noRequestsExpected);

    expect(client.contractAddress).toBe(CONTRACT_ADDRESS);
    expect(client.recorderAddress).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(client.endpointHosts).toEqual([
      { name: 'primary', host: 'sepolia.rpc.example' },
      { name: 'fallback', host: 'fallback.rpc.example' },
    ]);
    expect(Object.isFrozen(client)).toBe(true);
    client.close();
  });

  it('has only a primary endpoint when no fallback is configured', () => {
    const { client } = clientWith(noRequestsExpected, { config: anchorConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) });

    expect(client.endpointHosts.map((e) => e.name)).toEqual(['primary']);
    client.close();
  });

  it.each([
    ['SEPOLIA_RPC_URL', { SEPOLIA_RPC_URL: '', SEPOLIA_RPC_URL_FALLBACK: '' }],
    ['RECORDER_PRIVATE_KEY', { RECORDER_PRIVATE_KEY: '' }],
    ['MINECHAIN_CONTRACT_ADDRESS', { MINECHAIN_CONTRACT_ADDRESS: '' }],
  ])('refuses to start without %s, naming the variable only', (name, overrides) => {
    // ANCHOR_ENABLED false, so config itself allows the missing value.
    const config = anchorConfig({ ANCHOR_ENABLED: 'false', ...overrides });

    let thrown;
    try {
      createChainClient(config, { transport: noRequestsExpected });
    } catch (err) {
      thrown = err;
    }
    expect(thrown?.message).toBe(`Chain client needs ${name}`);
    expectNoSecrets(inspect(thrown));
  });
});

describe('createChainClient: secrets stay out of output', () => {
  it.each([
    ['util.inspect', (client) => inspect(client)],
    ['util.inspect with hidden properties, at any depth', (client) => inspect(client, { showHidden: true, depth: Infinity })],
    ['JSON.stringify', (client) => JSON.stringify(client)],
    ['String', (client) => String(client)],
  ])('%s shows neither the RPC URLs nor the private key', (_label, show) => {
    const { client } = clientWith(noRequestsExpected);

    const text = show(client);

    expectNoSecrets(text);
    client.close();
  });

  it('console output of the client shows the recorder address and hosts, and no secret', () => {
    const { client } = clientWith(noRequestsExpected);
    let output = '';
    const stream = new Writable({
      write(chunk, _encoding, done) {
        output += chunk;
        done();
      },
    });
    // A real Console writing into memory: it formats exactly as console.log does.
    const console = new Console({ stdout: stream, stderr: stream });

    console.log(client);
    console.error('client:', client);
    console.dir(client, { showHidden: true, depth: null });

    // Not empty: the public facts are there, so the check below is not vacuous.
    expect(output).toContain(client.recorderAddress);
    expect(output).toContain('sepolia.rpc.example');
    expectNoSecrets(output);
    client.close();
  });

  it('has no own property, enumerable or not, holding a secret', () => {
    const { client } = clientWith(noRequestsExpected);

    for (const key of Reflect.ownKeys(client)) {
      const value = client[key];
      if (typeof value === 'function') continue;
      expectNoSecrets(JSON.stringify(value, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
    }
    client.close();
  });
});

describe('createChainClient: provider errors are classified, never passed on', () => {
  it('a connection error carrying the URL becomes RPC_UNAVAILABLE without it', async () => {
    let rawMessage;
    const { client } = clientWith(
      (_payload, url) => {
        try {
          unreachable(url);
        } catch (err) {
          rawMessage = err.message;
          throw err;
        }
      },
      { config: anchorConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) },
    );

    const err = await expectChainError(client.getBlockNumber(), {
      code: 'RPC_UNAVAILABLE',
      action: 'backoff',
      endpoint: 'primary',
    });

    // The raw error really did contain the URL, so this test is not vacuous...
    expect(rawMessage).toContain(FAKE_RPC_URL);
    // ...and nothing of it survives in what the worker gets.
    expect(err.cause).toBeUndefined();
    expectNoSecrets(err.message);
    expectNoSecrets(err.stack);
    expectNoSecrets(inspect(err, { showHidden: true, depth: Infinity }));
    expectNoSecrets(JSON.stringify(err));
    client.close();
  });

  it('an HTTP 503, which ethers reports with the request URL, becomes RPC_UNAVAILABLE without it', async () => {
    const { client } = clientWith(() => ({ httpStatus: 503 }), { config: anchorConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) });

    const err = await expectChainError(client.getBalance(), { code: 'RPC_UNAVAILABLE', endpoint: 'primary' });

    expectNoSecrets(inspect(err, { showHidden: true, depth: Infinity }));
    client.close();
  });

  it('a custom-error revert from estimateGas is decoded, and not retried on the fallback', async () => {
    const revertData = abi.encodeErrorResult('AccessControlUnauthorizedAccount', [
      '0x25E19030C6cdb1e2608819BceF797a23eb0738fA',
      `0x${'f9'.repeat(32)}`,
    ]);
    const { client, requests } = clientWith(() => ({ error: { code: 3, message: 'execution reverted', data: revertData } }));

    await expectChainError(client.estimateGas(CALL), { code: 'ROLE_LOST', action: 'stop', endpoint: 'primary' });

    // A revert is an answer, so the fallback is never asked.
    expect(requests.map((r) => r.url)).toEqual([FAKE_RPC_URL]);
    client.close();
  });

  it('both endpoints down gives RPC_UNAVAILABLE from the fallback', async () => {
    const { client, requests } = clientWith((_payload, url) => unreachable(url));

    await expectChainError(client.getBlockNumber(), { code: 'RPC_UNAVAILABLE', endpoint: 'fallback' });

    expect(requests.map((r) => r.url)).toEqual([FAKE_RPC_URL, FAKE_FALLBACK_URL]);
    client.close();
  });
});

describe('createChainClient: primary and fallback', () => {
  it('uses the fallback when the primary is unavailable, and logs host names only', async () => {
    const { client, requests, log } = clientWith((_payload, url) => (url === FAKE_RPC_URL ? { httpStatus: 503 } : { result: '0x2a' }));

    await expect(client.getBlockNumber()).resolves.toBe(42);

    expect(requests.map((r) => r.url)).toEqual([FAKE_RPC_URL, FAKE_FALLBACK_URL]);
    expect(log.warn).toHaveBeenCalledTimes(1);
    const [line] = log.warn.mock.calls[0];
    expect(line).toContain('sepolia.rpc.example');
    expect(line).toContain('fallback.rpc.example');
    expectNoSecrets(line);
    client.close();
  });

  it('getChainId asks the named endpoint itself, with no fallback', async () => {
    const { client, requests } = clientWith((_payload, url) => ({ result: url === FAKE_RPC_URL ? '0xaa36a7' : '0x1' }));

    await expect(client.getChainId('primary')).resolves.toBe(11155111n);
    await expect(client.getChainId('fallback')).resolves.toBe(1n);

    expect(requests.map((r) => [r.url, r.method])).toEqual([
      [FAKE_RPC_URL, 'eth_chainId'],
      [FAKE_FALLBACK_URL, 'eth_chainId'],
    ]);
    await expect(client.getChainId('other')).rejects.toThrow(TypeError);
    client.close();
  });
});

describe('createChainClient: signTransaction', () => {
  it('signs locally: no request, and the hash is keccak256 of the signed bytes', async () => {
    const { client, requests } = clientWith(noRequestsExpected);

    const { rawTx, hash } = await client.signTransaction({ call: CALL, ...FEES, nonce: 7 });

    expect(requests).toEqual([]);
    expect(hash).toBe(keccak256(rawTx));
    // Decoding the bytes back proves what was signed, including the sender recovered from
    // the signature. Fields are copied out because Transaction exposes them as getters.
    const tx = Transaction.from(rawTx);
    const { type, chainId, nonce, to, from, value, gasLimit, maxFeePerGas, maxPriorityFeePerGas } = tx;
    expect({ type, chainId, nonce, to, from, value, gasLimit, maxFeePerGas, maxPriorityFeePerGas, hash: tx.hash }).toEqual({
      type: 2,
      chainId: 11155111n,
      nonce: 7,
      to: CONTRACT_ADDRESS,
      from: client.recorderAddress,
      value: 0n,
      gasLimit: 120_000n,
      maxFeePerGas: 2n * GWEI,
      maxPriorityFeePerGas: 1n * GWEI,
      hash,
    });
    const decoded = abi.parseTransaction({ data: tx.data });
    expect(decoded.name).toBe('registerConsignment');
    expect([...decoded.args]).toEqual([...CALL.args]);
    client.close();
  });

  it('gives the same nonce and call with another fee a different hash', async () => {
    const { client } = clientWith(noRequestsExpected);

    const first = await client.signTransaction({ call: CALL, ...FEES });
    const bumped = await client.signTransaction({ call: CALL, ...FEES, maxFeePerGas: 3n * GWEI });

    expect(bumped.hash).not.toBe(first.hash);
    client.close();
  });

  it('refuses a fee above ANCHOR_MAX_FEE_GWEI with FEE_TOO_HIGH', async () => {
    const { client, requests } = clientWith(noRequestsExpected);

    await expectChainError(client.signTransaction({ call: CALL, ...FEES, maxFeePerGas: 51n * GWEI }), {
      code: 'FEE_TOO_HIGH',
      action: 'pause',
      endpoint: 'local',
    });
    expect(requests).toEqual([]);
    client.close();
  });

  it.each([
    ['a function that is not one of the three writes', { call: { functionName: 'grantRole', args: [] } }],
    ['no call', { call: undefined }],
    ['a negative nonce', { nonce: -1 }],
    ['a nonce as text', { nonce: '0' }],
    ['a gas limit as a number', { gasLimit: 120000 }],
    ['a priority fee above the maximum fee', { maxPriorityFeePerGas: 3n * GWEI }],
  ])('refuses %s', async (_label, overrides) => {
    const { client } = clientWith(noRequestsExpected);

    await expect(client.signTransaction({ call: CALL, ...FEES, ...overrides })).rejects.toThrow(TypeError);
    client.close();
  });
});

describe('createChainClient: broadcast', () => {
  async function signed(client) {
    return client.signTransaction({ call: CALL, ...FEES });
  }

  it('sends the same bytes to both endpoints and reports both as accepted', async () => {
    const { client: signer } = clientWith(noRequestsExpected);
    const { rawTx, hash } = await signed(signer);
    const { client, requests } = clientWith(() => ({ result: hash }));

    await expect(client.broadcast(rawTx)).resolves.toEqual({ hash, accepted: ['primary', 'fallback'], refused: [] });

    expect(requests.map((r) => [r.url, r.method, r.params[0]])).toEqual([
      [FAKE_RPC_URL, 'eth_sendRawTransaction', rawTx],
      [FAKE_FALLBACK_URL, 'eth_sendRawTransaction', rawTx],
    ]);
    signer.close();
    client.close();
  });

  it('counts "already known" as accepted, and reports an unreachable endpoint as refused', async () => {
    const { client: signer } = clientWith(noRequestsExpected);
    const { rawTx, hash } = await signed(signer);
    const { client, log } = clientWith((_payload, url) =>
      url === FAKE_RPC_URL ? { error: { code: -32000, message: 'already known' } } : { httpStatus: 503 },
    );

    await expect(client.broadcast(rawTx)).resolves.toEqual({
      hash,
      accepted: ['primary'],
      refused: [{ endpoint: 'fallback', code: 'RPC_UNAVAILABLE' }],
    });
    expectNoSecrets(log.warn.mock.calls.flat().join('\n'));
    signer.close();
    client.close();
  });

  it("when nobody accepts, a node's real answer wins over an unreachable endpoint", async () => {
    const { client: signer } = clientWith(noRequestsExpected);
    const { rawTx } = await signed(signer);
    const { client } = clientWith((_payload, url) =>
      url === FAKE_RPC_URL ? { httpStatus: 503 } : { error: { code: -32000, message: 'insufficient funds for gas * price + value' } },
    );

    await expectChainError(client.broadcast(rawTx), { code: 'INSUFFICIENT_FUNDS', action: 'pause', endpoint: 'fallback' });
    signer.close();
    client.close();
  });

  it('does not accept a node that answers with a different hash', async () => {
    const { client: signer } = clientWith(noRequestsExpected);
    const { rawTx } = await signed(signer);
    const { client } = clientWith(() => ({ result: `0x${'ab'.repeat(32)}` }), { config: anchorConfig({ SEPOLIA_RPC_URL_FALLBACK: '' }) });

    await expectChainError(client.broadcast(rawTx), { code: 'UNKNOWN', endpoint: 'primary' });
    signer.close();
    client.close();
  });
});

describe('createChainClient: getLogs', () => {
  const ID = CALL.args[0];

  // One ConsignmentRegistered log as a node returns it, plus one from another contract.
  function nodeLog(address, blockNumber) {
    const { data, topics } = abi.encodeEventLog(abi.getEvent('ConsignmentRegistered'), [
      ID,
      CALL.args[1],
      CALL.args[2],
      CALL.args[3],
      1_762_600_000n,
    ]);
    return {
      address,
      topics,
      data,
      blockNumber: `0x${blockNumber.toString(16)}`,
      blockHash: `0x${'bb'.repeat(32)}`,
      transactionHash: `0x${'cc'.repeat(32)}`,
      transactionIndex: '0x0',
      logIndex: '0x0',
      removed: false,
    };
  }

  it('asks in chunks of 500 blocks from the deployment block at the earliest, and decodes our events only', async () => {
    const { client, requests } = clientWith((payload) => {
      const from = Number(payload.params[0].fromBlock);
      return {
        result:
          from === DEPLOY_BLOCK
            ? [nodeLog(CONTRACT_ADDRESS, DEPLOY_BLOCK + 3), nodeLog(`0x${'12'.repeat(20)}`, DEPLOY_BLOCK + 4)]
            : [],
      };
    });

    const events = await client.getLogs(ID, DEPLOY_BLOCK - 10, DEPLOY_BLOCK + 1199);

    const ranges = requests.map((r) => [Number(r.params[0].fromBlock), Number(r.params[0].toBlock)]);
    expect(ranges).toEqual([
      [DEPLOY_BLOCK, DEPLOY_BLOCK + 499],
      [DEPLOY_BLOCK + 500, DEPLOY_BLOCK + 999],
      [DEPLOY_BLOCK + 1000, DEPLOY_BLOCK + 1199],
    ]);
    const filter = requests[0].params[0];
    expect(filter.address.toLowerCase()).toBe(CONTRACT_ADDRESS.toLowerCase());
    expect(filter.topics[0]).toHaveLength(3);
    expect(filter.topics[1]).toBe(ID);

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      name: 'ConsignmentRegistered',
      blockNumber: DEPLOY_BLOCK + 3,
      args: { id: ID, minerRef: CALL.args[1], weightMilligrams: 1_500_000n, dataHash: CALL.args[3] },
    });
    client.close();
  });
});
