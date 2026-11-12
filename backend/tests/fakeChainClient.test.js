import { describe, it, expect } from 'vitest';
import { createFakeChainClient, FAKE_GAS } from './fakes/fakeChainClient.js';
import { createChainClient, ChainClientError } from '../src/chain/chainClient.js';
import { buildAnchorCall, receiptEventMismatches } from '../src/services/anchorCall.js';

// The worker's tests (8.7) will trust this fake, so it is tested itself: that it has the
// real client's interface, and that it follows the contract's rules.

const GWEI = 1_000_000_000n;
// Enough gas for a registration (352,951 in the live run); the fake does not enforce it.
const FEES = { gasLimit: 450_000n, maxFeePerGas: 2n * GWEI, maxPriorityFeePerGas: 1n * GWEI };

// One consignment's three steps, as the worker's query will return them.
const CHAIN_ID = Buffer.concat([Buffer.alloc(16), Buffer.from('6f1d2c3a00004000800000000000a101', 'hex')]);
const step = (type, fill) => ({
  type,
  chain_id: CHAIN_ID,
  actor_ref: Buffer.alloc(32, fill),
  weight_mg: '1500000',
  data_hash: Buffer.alloc(32, fill + 1),
});
const STEPS = { registration: step('registration', 0x10), handoff: step('handoff', 0x20), purchase: step('purchase', 0x30) };
const ID = buildAnchorCall(STEPS.registration).args[0];

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

// Signs and broadcasts one step with the next free nonce, as the worker will.
async function send(client, stepRow, overrides = {}) {
  const nonce = overrides.nonce ?? (await client.getNonce('pending'));
  const signed = await client.signTransaction({ call: buildAnchorCall(stepRow), nonce, ...FEES, ...overrides });
  await client.broadcast(signed.rawTx);
  return { ...signed, nonce };
}

describe('fake chain client: same interface as the real one', () => {
  it('has exactly the same properties, of the same kinds', () => {
    const real = createChainClient(
      {
        chainId: 11155111n,
        contractAddress: '0x6419cB5268706E2aA4713AB3bCFc336248Ed158a',
        rpcUrl: 'https://primary.rpc.example/fake-key',
        fallbackRpcUrl: 'https://fallback.rpc.example/fake-key',
        recorderPrivateKey: `0x${'1a2b3c4d'.repeat(8)}`,
        maxFeePerGasWei: 50n * GWEI,
      },
      { transport: () => Promise.reject(new Error('no request expected')) },
    );
    const { client: fake } = createFakeChainClient();

    const shape = (obj) => Object.fromEntries(Object.keys(obj).map((k) => [k, typeof obj[k]]));
    expect(shape(fake)).toEqual(shape(real));
    // Same key, same wallet: a step signed by either is from the same address.
    expect(fake.recorderAddress).toBe(real.recorderAddress);
    real.close();
  });
});

describe('fake chain client: the contract rules', () => {
  it('anchors registration, handoff and purchase in order, with matching receipt events', async () => {
    const { client, control } = createFakeChainClient();

    for (const type of ['registration', 'handoff', 'purchase']) {
      const { hash } = await send(client, STEPS[type]);
      control.mine();
      const receipt = await client.getReceipt(hash);

      expect(receipt.status).toBe(1);
      expect(receiptEventMismatches(receipt.events[0], STEPS[type], client.contractAddress)).toEqual([]);
    }

    expect((await client.getConsignment(ID)).stage).toBe('Purchased');
    const logs = await client.getLogs(ID, 0, await client.getBlockNumber());
    expect(logs.map((e) => e.name)).toEqual(['ConsignmentRegistered', 'HandoffRecorded', 'PurchaseRecorded']);
  });

  it('allows a second handoff from InTransit, as the contract does', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.registration);
    await send(client, STEPS.handoff);
    control.mine();

    await expect(client.estimateGas(buildAnchorCall(step('handoff', 0x40)))).resolves.toBe(FAKE_GAS.recordHandoff);
  });

  it('refuses a second registration with ALREADY_EXISTS, to be reconciled', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.registration);
    control.mine();

    await expectChainError(client.estimateGas(buildAnchorCall(STEPS.registration)), { code: 'ALREADY_EXISTS', action: 'reconcile' });
  });

  it('refuses a purchase straight after registration with INVALID_STAGE from Registered, which fails', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.registration);
    control.mine();

    await expectChainError(client.estimateGas(buildAnchorCall(STEPS.purchase)), {
      code: 'INVALID_STAGE',
      currentStage: 'Registered',
      action: 'fail',
    });
  });

  it('estimates against mined state only: a registration still waiting makes a handoff INVALID_STAGE None, to retry', async () => {
    const { client } = createFakeChainClient();
    await send(client, STEPS.registration);

    await expectChainError(client.estimateGas(buildAnchorCall(STEPS.handoff)), {
      code: 'INVALID_STAGE',
      currentStage: 'None',
      action: 'retry',
    });
  });

  it('refuses everything with ROLE_LOST once the role is revoked', async () => {
    const { client, control } = createFakeChainClient();
    control.revokeRecorderRole();

    await expectChainError(client.estimateGas(buildAnchorCall(STEPS.registration)), { code: 'ROLE_LOST', action: 'stop' });
  });

  it.each([
    ['AccessControlUnauthorizedAccount', undefined, { code: 'ROLE_LOST' }],
    ['InvalidInput', [3], { code: 'INVALID_INPUT', field: 'dataHash' }],
    ['InvalidStage', undefined, { code: 'INVALID_STAGE', currentStage: 'Purchased' }],
    ['ConsignmentAlreadyExists', undefined, { code: 'ALREADY_EXISTS' }],
  ])('can be scripted to revert the next estimate with %s', async (errorName, args, expected) => {
    const { client, control } = createFakeChainClient();
    control.revertNextEstimate(errorName, args);

    await expectChainError(client.estimateGas(buildAnchorCall(STEPS.registration)), expected);
    // Only the next one.
    await expect(client.estimateGas(buildAnchorCall(STEPS.registration))).resolves.toBe(FAKE_GAS.registerConsignment);
  });

  it('can revert a transaction when mined: status 0, nonce and fee used, nothing recorded', async () => {
    const { client, control } = createFakeChainClient();
    const before = await client.getBalance();
    control.revertNextMined('ConsignmentAlreadyExists');

    const { hash } = await send(client, STEPS.registration);
    control.mine();

    const receipt = await client.getReceipt(hash);
    expect(receipt.status).toBe(0);
    expect(receipt.events).toEqual([]);
    expect(await client.getNonce('latest')).toBe(1);
    expect(await client.getBalance()).toBeLessThan(before);
    expect((await client.getConsignment(ID)).stage).toBe('None');
  });
});

describe('fake chain client: nonces and the mempool', () => {
  it('records every signature and send with its nonce', async () => {
    const { client, control } = createFakeChainClient();

    const first = await send(client, STEPS.registration);

    expect(control.records.signed).toEqual([expect.objectContaining({ hash: first.hash, nonce: 0, functionName: 'registerConsignment' })]);
    expect(control.records.sent).toEqual([{ hash: first.hash, nonce: 0, accepted: ['primary', 'fallback'], refused: [] }]);
    expect(await client.getNonce('pending')).toBe(1);
    expect(await client.getNonce('latest')).toBe(0);
  });

  it('accepts the same bytes twice without a second transaction', async () => {
    const { client, control } = createFakeChainClient();
    const { rawTx } = await client.signTransaction({ call: buildAnchorCall(STEPS.registration), nonce: 0, ...FEES });

    await client.broadcast(rawTx);
    await client.broadcast(rawTx);

    expect(control.mempoolSize()).toBe(1);
  });

  it('drops a transaction: no receipt ever, and the nonce is free again for a resend', async () => {
    const { client, control } = createFakeChainClient();
    const dropped = await send(client, STEPS.registration);

    expect(control.dropTransaction(dropped.hash)).toBe(true);
    control.mine(3);

    expect(await client.getReceipt(dropped.hash)).toBeNull();
    expect(await client.getNonce('pending')).toBe(0);

    // The resend uses the same nonce, so only one of the two could ever be mined.
    const resent = await send(client, STEPS.registration, { nonce: dropped.nonce });
    control.mine();
    expect((await client.getReceipt(resent.hash)).status).toBe(1);
  });

  it('refuses a replacement without a 10% fee rise, and accepts one with it', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.registration, { nonce: 0 });

    const call = buildAnchorCall(STEPS.registration);
    const small = await client.signTransaction({ call, nonce: 0, ...FEES, maxFeePerGas: 2_100_000_000n });
    await expectChainError(client.broadcast(small.rawTx), { code: 'REPLACEMENT_UNDERPRICED', action: 'inspect' });

    const bumped = await client.signTransaction({ call, nonce: 0, ...FEES, maxFeePerGas: 3n * GWEI, maxPriorityFeePerGas: 2n * GWEI });
    await client.broadcast(bumped.rawTx);
    control.mine();

    expect((await client.getReceipt(bumped.hash)).status).toBe(1);
  });

  it('refuses a nonce that is already mined with NONCE_USED', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.registration, { nonce: 0 });
    control.mine();

    await expectChainError(send(client, STEPS.handoff, { nonce: 0 }), { code: 'NONCE_USED', action: 'inspect' });
  });

  it('does not mine past a gap in nonces', async () => {
    const { client, control } = createFakeChainClient();
    await send(client, STEPS.handoff, { nonce: 1 });

    expect(control.mine()).toEqual([]);
  });
});

describe('fake chain client: provider and wallet failures', () => {
  it('uses the fallback while the primary is down', async () => {
    const { client, control } = createFakeChainClient();
    control.failPrimary();

    await client.getBlockNumber();
    const { rawTx, hash } = await client.signTransaction({ call: buildAnchorCall(STEPS.registration), nonce: 0, ...FEES });

    await expect(client.broadcast(rawTx)).resolves.toEqual({
      hash,
      accepted: ['fallback'],
      refused: [{ endpoint: 'primary', code: 'RPC_UNAVAILABLE' }],
    });
    expect(control.records.calls.at(0)).toEqual({ method: 'getBlockNumber', endpoint: 'fallback' });
  });

  it('gives RPC_UNAVAILABLE when the primary is down and there is no fallback', async () => {
    const { client, control } = createFakeChainClient({ hasFallback: false });
    control.failPrimary();

    await expectChainError(client.getBlockNumber(), { code: 'RPC_UNAVAILABLE', action: 'backoff', endpoint: 'primary' });
  });

  it('gives RPC_UNAVAILABLE for everything when every RPC is down', async () => {
    const { client, control } = createFakeChainClient();
    control.failAllRpc();

    await expectChainError(client.getBalance(), { code: 'RPC_UNAVAILABLE' });
    const { rawTx } = await client.signTransaction({ call: buildAnchorCall(STEPS.registration), nonce: 0, ...FEES });
    await expectChainError(client.broadcast(rawTx), { code: 'RPC_UNAVAILABLE' });
  });

  it('refuses to send with INSUFFICIENT_FUNDS once out of funds, and sends nothing', async () => {
    const { client, control } = createFakeChainClient();
    control.runOutOfFunds();

    await expectChainError(send(client, STEPS.registration), { code: 'INSUFFICIENT_FUNDS', action: 'pause' });
    expect(control.mempoolSize()).toBe(0);
    expect(control.records.sent).toEqual([]);
  });

  it('refuses to sign above the configured maximum fee', async () => {
    const { client } = createFakeChainClient();

    await expectChainError(
      client.signTransaction({ call: buildAnchorCall(STEPS.registration), nonce: 0, ...FEES, maxFeePerGas: 51n * GWEI }),
      { code: 'FEE_TOO_HIGH', endpoint: 'local' },
    );
  });
});
