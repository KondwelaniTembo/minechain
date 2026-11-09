import { describe, it, expect } from 'vitest';
import {
  parseAnchorOnceArgs,
  runAnchorOnce,
  UsageError,
  EXIT,
  TICK_SPACING_SECONDS,
  STUCK_AFTER_SECONDS,
} from '../src/cli/anchorOnce.js';
import { runPreflight } from '../src/chain/preflight.js';
import { SEPOLIA_CHAIN_ID } from '../src/chain/mineChainAbi.js';
import { createFakeChainClient, FAKE_RECORDER_KEY } from './fakes/fakeChainClient.js';

// The script's logic with everything injected: a real preflight against the fake chain, a
// scripted runOnce, an in-memory steps reader, and a clock that sleep moves forward.

const GWEI = 1_000_000_000n;
const ANCHOR_CONFIG = Object.freeze({ chainId: SEPOLIA_CHAIN_ID, lowBalanceWei: 2_000_000_000_000_000n, maxFeePerGasWei: 50n * GWEI });
const ZERO = Object.freeze({ confirmed: 0, waiting: 0, resent: 0, returnedToPending: 0, failed: 0 });
const summary = (outcome, extra = {}) => ({ outcome, reconciled: ZERO, stepId: null, code: null, ...extra });
const HASH = `0x${'ab'.repeat(32)}`;
const STEP = '11111111-1111-4111-8111-111111111111';

function setup({ outcomes = [], submitted = () => [], byIds = () => [], script } = {}) {
  const fake = createFakeChainClient();
  script?.(fake.control);
  let ms = Date.parse('2026-11-09T10:00:00Z');
  const sleeps = [];
  const lines = [];
  const ticks = [];
  const run = (args = []) =>
    runAnchorOnce({
      options: parseAnchorOnceArgs(args),
      preflight: () => runPreflight(fake.client, ANCHOR_CONFIG),
      runOnce: async () => {
        ticks.push(ms);
        return outcomes.shift() ?? summary('waiting');
      },
      steps: { submitted: async () => submitted(ms), byIds: async (ids) => byIds(ids) },
      print: (line) => lines.push(line),
      sleep: async (delay) => {
        sleeps.push(delay);
        ms += delay;
      },
      now: () => new Date(ms),
    });
  return { fake, run, lines, sleeps, ticks, output: () => lines.join('\n') };
}

describe('parseAnchorOnceArgs', () => {
  it('runs one tick by default', () => {
    expect(parseAnchorOnceArgs([])).toEqual({ untilIdle: false });
  });

  it('accepts --until-idle', () => {
    expect(parseAnchorOnceArgs(['--until-idle'])).toEqual({ untilIdle: true });
  });

  it.each([[['--until-idel']], [['--until-idle', 'extra']], [['-u']], [['--help']]])('refuses %j', (args) => {
    expect(() => parseAnchorOnceArgs(args)).toThrow(UsageError);
  });

  it('names the unknown argument and the only option', () => {
    expect(() => parseAnchorOnceArgs(['--until-idel'])).toThrow('Unknown argument(s): --until-idel. The only option is --until-idle.');
  });
});

describe('runAnchorOnce: preflight', () => {
  it('prints the checks, recorder address and balance in ETH, and never the key', async () => {
    const { run, output, fake } = setup({ outcomes: [summary('idle')] });

    await run();

    const text = output();
    expect(text).toContain(`Recorder wallet: ${fake.client.recorderAddress}`);
    expect(text).toContain('Balance:         0.010000 ETH');
    expect(text).toMatch(/chainId +passed/);
    expect(text).toMatch(/code +passed/);
    expect(text).toMatch(/role +passed/);
    expect(text).not.toContain(FAKE_RECORDER_KEY.slice(2));
  });

  it('prints warnings', async () => {
    const { run, output } = setup({ outcomes: [summary('idle')], script: (c) => c.setBalance(10n ** 15n) });

    await run();

    expect(output()).toMatch(/Warnings:\n {2}lowBalance: /);
  });

  it('exits 1 without ticking when preflight does not pass', async () => {
    const { run, ticks, output } = setup({ script: (c) => c.setCode('0x') });

    expect(await run()).toBe(EXIT.PROBLEM);
    expect(ticks).toEqual([]);
    expect(output()).toContain('Not startable.');
  });
});

describe('runAnchorOnce: one tick', () => {
  it('exits 0 when idle', async () => {
    const { run, output } = setup({ outcomes: [summary('idle')] });

    expect(await run()).toBe(EXIT.IDLE);
    expect(output()).toContain('Idle: nothing is waiting to be anchored.');
  });

  it('prints the outcome, step id and an Etherscan link for a step it sent, and exits 3', async () => {
    const { run, output } = setup({
      outcomes: [summary('sent', { stepId: STEP })],
      byIds: (ids) => (ids.includes(STEP) ? [{ id: STEP, anchor_status: 'submitted', chain_tx_hash: HASH }] : []),
    });

    expect(await run()).toBe(EXIT.NOT_IDLE_YET);
    const text = output();
    expect(text).toContain(`Tick 1: sent, step ${STEP}`);
    expect(text).toContain(`in flight ${STEP}: https://sepolia.etherscan.io/tx/${HASH}`);
    expect(text).toContain('Not idle yet. Run it again, or use --until-idle.');
  });

  it('prints a link for a step that was in flight and is now confirmed', async () => {
    const { run, output } = setup({
      outcomes: [summary('idle', { reconciled: { ...ZERO, confirmed: 1 } })],
      submitted: () => [{ id: STEP, chain_tx_hash: HASH, anchor_submitted_at: new Date() }],
      byIds: () => [{ id: STEP, anchor_status: 'confirmed', chain_tx_hash: HASH }],
    });

    await run();

    expect(output()).toContain(`confirmed ${STEP}: https://sepolia.etherscan.io/tx/${HASH}`);
  });

  it.each([
    ['stopped', summary('stopped', { code: 'ROLE_LOST' }), /Stopped: the recorder wallet does not hold RECORDER_ROLE/],
    ['paused', summary('paused', { code: 'FEE_TOO_HIGH' }), /Paused \(FEE_TOO_HIGH\)/],
    ['busy', summary('busy'), /Busy: another process/],
  ])('exits 1 when %s', async (_label, outcome, message) => {
    const { run, output } = setup({ outcomes: [outcome] });

    expect(await run()).toBe(EXIT.PROBLEM);
    expect(output()).toMatch(message);
  });

  it('reports a stuck submitted row and exits 1, because it blocks all anchoring', async () => {
    const { run, output } = setup({
      outcomes: [summary('waiting', { reconciled: { ...ZERO, waiting: 1 } })],
      // Submitted longer ago than the stuck limit, by the script's clock.
      submitted: (ms) => [{ id: STEP, chain_tx_hash: HASH, anchor_submitted_at: new Date(ms - (STUCK_AFTER_SECONDS + 1) * 1000) }],
      byIds: () => [{ id: STEP, anchor_status: 'submitted', chain_tx_hash: HASH }],
    });

    expect(await run()).toBe(EXIT.PROBLEM);
    const text = output();
    expect(text).toMatch(new RegExp(`STUCK: step ${STEP} has been submitted since .* Nothing else can be anchored`));
    expect(text).toContain(`last hash: https://sepolia.etherscan.io/tx/${HASH}`);
  });

  it('does not call a recently submitted row stuck', async () => {
    const { run } = setup({
      outcomes: [summary('waiting')],
      submitted: (ms) => [{ id: STEP, chain_tx_hash: HASH, anchor_submitted_at: new Date(ms - 60_000) }],
    });

    expect(await run()).toBe(EXIT.NOT_IDLE_YET);
  });
});

describe('runAnchorOnce: --until-idle', () => {
  it('keeps ticking 15 s apart until idle, then exits 0', async () => {
    const { run, sleeps, ticks } = setup({
      outcomes: [summary('sent', { stepId: STEP }), summary('waiting'), summary('backoff', { code: 'RPC_UNAVAILABLE' }), summary('idle')],
    });

    expect(await run(['--until-idle'])).toBe(EXIT.IDLE);
    expect(ticks).toHaveLength(4);
    expect(sleeps).toEqual([1, 2, 3].map(() => TICK_SPACING_SECONDS * 1000));
  });

  it('stops at once, exiting 1, on stopped', async () => {
    const { run, ticks } = setup({ outcomes: [summary('sent'), summary('stopped', { code: 'ROLE_LOST' })] });

    expect(await run(['--until-idle'])).toBe(EXIT.PROBLEM);
    expect(ticks).toHaveLength(2);
  });

  it('gives up after 10 minutes without reaching idle, exiting 1', async () => {
    const { run, ticks, output } = setup(); // waiting for ever

    expect(await run(['--until-idle'])).toBe(EXIT.PROBLEM);
    expect(output()).toContain('Gave up after 10 minutes without reaching idle.');
    // 600 s at 15 s apart: the first tick plus 40 more.
    expect(ticks).toHaveLength(41);
  });

  it('stops on a stuck row instead of waiting out the 10 minutes', async () => {
    const { run, ticks } = setup({
      submitted: (ms) => [{ id: STEP, chain_tx_hash: HASH, anchor_submitted_at: new Date(ms - (STUCK_AFTER_SECONDS + 1) * 1000) }],
    });

    expect(await run(['--until-idle'])).toBe(EXIT.PROBLEM);
    expect(ticks).toHaveLength(1);
  });
});
