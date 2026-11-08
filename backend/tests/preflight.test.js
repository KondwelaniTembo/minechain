import { describe, it, expect } from 'vitest';
import { id } from 'ethers';
import { runPreflight, EXPECTED_RECORDER_ROLE, MAX_GAS_PER_STEP } from '../src/chain/preflight.js';
import { loadConfig } from '../src/config.js';
import { createFakeChainClient } from './fakes/fakeChainClient.js';

const GWEI = 1_000_000_000n;
const ETH = 10n ** 18n;

// The defaults from config: chain 11155111, low balance 0.002 ETH, maximum fee 50 gwei.
// Anchoring is off, so no chain setting is needed; preflight only reads these three.
const anchorConfig = loadConfig({
  NODE_ENV: 'development',
  PORT: '3000',
  DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_dev',
  TEST_DATABASE_URL: 'postgresql://user:pass@localhost:5432/minechain_test',
  JWT_SECRET: 'a-fake-test-secret-that-is-long-enough-1234',
  JWT_EXPIRES_IN: '60m',
}).anchor;

const statuses = (result) => Object.fromEntries(result.checks.map((c) => [c.name, c.status]));
const check = (result, name) => result.checks.find((c) => c.name === name);
const warningNames = (result) => result.warnings.map((w) => w.name);

async function preflightWith(script = () => {}, options) {
  const fake = createFakeChainClient(options);
  script(fake.control);
  const result = await runPreflight(fake.client, anchorConfig);
  return { result, fake };
}

describe('runPreflight: all good', () => {
  it('passes every check, may start and send, and has no warnings', async () => {
    const { result, fake } = await preflightWith();

    expect(result.startable).toBe(true);
    expect(result.canSend).toBe(true);
    expect(statuses(result)).toEqual({ chainId: 'passed', code: 'passed', role: 'passed' });
    expect(result.warnings).toEqual([]);
    expect(result.facts).toEqual({
      recorderAddress: fake.client.recorderAddress,
      balanceWei: ETH / 100n,
      latestNonce: 0,
      pendingNonce: 0,
      // The fake's network fee (2 gwei) is below the cap, so it is used.
      oneTransactionWei: MAX_GAS_PER_STEP * 2n * GWEI,
    });
  });

  it('checks the chain id of both endpoints', async () => {
    const { fake } = await preflightWith();

    const asked = fake.control.records.calls.filter((c) => c.method === 'getChainId').map((c) => c.endpoint);
    expect(asked).toEqual(['primary', 'fallback']);
  });

  it('works with no fallback configured', async () => {
    const { result } = await preflightWith(() => {}, { hasFallback: false });

    expect(result.startable).toBe(true);
  });

  it('expects RECORDER_ROLE to be keccak256 of the text "RECORDER_ROLE"', () => {
    expect(EXPECTED_RECORDER_ROLE).toBe(id('RECORDER_ROLE'));
    // The value in docs/contract-spec.md, so the two cannot drift apart silently.
    expect(EXPECTED_RECORDER_ROLE).toBe('0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4');
  });

  it('returns a frozen result', async () => {
    const { result } = await preflightWith();

    expect(Object.isFrozen(result)).toBe(true);
    expect(Object.isFrozen(result.checks)).toBe(true);
    expect(Object.isFrozen(result.warnings)).toBe(true);
    expect(Object.isFrozen(result.facts)).toBe(true);
  });
});

describe('runPreflight: checks that stop the worker', () => {
  it('fails on the wrong chain id, and skips the later checks', async () => {
    const { result, fake } = await preflightWith((c) => c.setChainId('primary', 1n));

    expect(result.startable).toBe(false);
    expect(result.canSend).toBe(false);
    expect(statuses(result)).toEqual({ chainId: 'failed', code: 'skipped', role: 'skipped' });
    expect(check(result, 'chainId').problem).toBe('primary RPC primary.rpc.example is on chain 1, not 11155111');
    // Nothing was read from a chain that is not ours.
    expect(fake.control.records.calls.map((c) => c.method)).not.toContain('getCode');
  });

  it('fails when only the fallback is on the wrong chain', async () => {
    const { result } = await preflightWith((c) => c.setChainId('fallback', 1n));

    expect(statuses(result).chainId).toBe('failed');
    expect(check(result, 'chainId').problem).toContain('fallback RPC fallback.rpc.example');
  });

  it('fails when there is no contract at the address', async () => {
    const { result } = await preflightWith((c) => c.setCode('0x'));

    expect(statuses(result)).toEqual({ chainId: 'passed', code: 'failed', role: 'skipped' });
    expect(check(result, 'code').problem).toBe('there is no contract at MINECHAIN_CONTRACT_ADDRESS');
  });

  it('fails when the address holds some other contract', async () => {
    const { result } = await preflightWith((c) => c.setCode('0x6080604052'));

    expect(statuses(result)).toEqual({ chainId: 'passed', code: 'failed', role: 'skipped' });
    expect(check(result, 'code').problem).toBe('the contract at MINECHAIN_CONTRACT_ADDRESS is not the deployed MineChain');
  });

  it('fails when the contract reports an unexpected RECORDER_ROLE', async () => {
    const { result } = await preflightWith((c) => c.setRecorderRole(id('SOME_OTHER_ROLE')));

    expect(statuses(result)).toEqual({ chainId: 'passed', code: 'passed', role: 'failed' });
    expect(check(result, 'role').problem).toBe('the contract reports an unexpected RECORDER_ROLE value');
  });

  it('fails when the recorder wallet does not hold the role, naming the public address', async () => {
    const { result, fake } = await preflightWith((c) => c.revokeRecorderRole());

    expect(statuses(result).role).toBe('failed');
    expect(check(result, 'role').problem).toBe(`the recorder wallet ${fake.client.recorderAddress} does not hold RECORDER_ROLE`);
    expect(result.startable).toBe(false);
  });

  it('reports "could not check", not "failed", when no RPC answers', async () => {
    const { result } = await preflightWith((c) => c.failAllRpc());

    expect(result.startable).toBe(false);
    expect(check(result, 'chainId')).toMatchObject({ status: 'error', errorCode: 'RPC_UNAVAILABLE' });
    expect(statuses(result)).toEqual({ chainId: 'error', code: 'skipped', role: 'skipped' });
    expect(warningNames(result)).toEqual(['rpcUnreachable', 'rpcUnreachable']);
  });

  it('reports an RPC failure during a later check as an error with its code', async () => {
    // No fallback, and the primary goes down after the chain id answered.
    const fake = createFakeChainClient({ hasFallback: false });
    const client = {
      ...fake.client,
      getCode: () => {
        fake.control.failAllRpc();
        return fake.client.getCode();
      },
    };

    const result = await runPreflight(client, anchorConfig);

    expect(check(result, 'code')).toMatchObject({ status: 'error', errorCode: 'RPC_UNAVAILABLE' });
    expect(check(result, 'code').problem).toMatch(/^RPC_UNAVAILABLE: /);
    expect(statuses(result).role).toBe('skipped');
  });

  it('never passes on the message of an error that is not from the chain client', async () => {
    const fake = createFakeChainClient();
    const client = {
      ...fake.client,
      getCode: async () => {
        throw new Error('https://leaky.example/v3/secret-key');
      },
    };

    const result = await runPreflight(client, anchorConfig);

    expect(check(result, 'code')).toEqual({ name: 'code', status: 'error', problem: 'an unexpected error', errorCode: 'UNKNOWN' });
  });
});

describe('runPreflight: warnings', () => {
  it('warns about an unreachable primary but starts on the fallback', async () => {
    const { result } = await preflightWith((c) => c.failPrimary());

    expect(result.startable).toBe(true);
    expect(statuses(result).chainId).toBe('passed');
    expect(warningNames(result)).toEqual(['rpcUnreachable']);
    expect(result.warnings[0].message).toMatch(/^primary RPC primary\.rpc\.example did not answer: RPC_UNAVAILABLE: /);
  });

  it('warns when the balance is below ANCHOR_LOW_BALANCE_ETH but still pays for a transaction', async () => {
    const { result } = await preflightWith((c) => c.setBalance(ETH / 1000n)); // 0.001 ETH

    expect(result.canSend).toBe(true);
    expect(warningNames(result)).toEqual(['lowBalance']);
  });

  it('pauses sending when the balance cannot pay for one transaction', async () => {
    const oneTransaction = MAX_GAS_PER_STEP * 2n * GWEI;
    const { result } = await preflightWith((c) => c.setBalance(oneTransaction - 1n));

    expect(result.startable).toBe(true);
    expect(result.canSend).toBe(false);
    // Not also "low balance": one warning for one problem.
    expect(warningNames(result)).toEqual(['cannotAffordTransaction']);
  });

  it('can send with exactly the cost of one transaction', async () => {
    const { result } = await preflightWith((c) => c.setBalance(MAX_GAS_PER_STEP * 2n * GWEI));

    expect(result.canSend).toBe(true);
  });

  it('pauses sending with an empty wallet', async () => {
    const { result } = await preflightWith((c) => c.runOutOfFunds());

    expect(result.canSend).toBe(false);
    expect(result.facts.balanceWei).toBe(0n);
  });

  it('warns when the pending nonce differs from the latest, as when the wallet was used by hand', async () => {
    const { result } = await preflightWith((c) => c.sendByHand());

    expect(result.facts).toMatchObject({ latestNonce: 0, pendingNonce: 1 });
    expect(warningNames(result)).toEqual(['pendingTransactions']);
    expect(result.warnings[0].message).toBe('1 transaction(s) from the recorder wallet are waiting to be mined');
  });

  it('warns when the network fee is above the maximum, and costs a transaction at the maximum', async () => {
    const { result } = await preflightWith((c) => c.setFeeData({ maxFeePerGas: 60n * GWEI }));

    expect(warningNames(result)).toEqual(['feeAboveMaximum']);
    expect(result.facts.oneTransactionWei).toBe(MAX_GAS_PER_STEP * 50n * GWEI);
  });

  it('gives no balance facts or sending verdict when the checks did not pass', async () => {
    const { result } = await preflightWith((c) => c.setCode('0x'));

    expect(result.facts).toEqual({ recorderAddress: expect.any(String) });
    expect(result.canSend).toBe(false);
  });
});
