import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  createAnchorWorker,
  nextBackoffSeconds,
  describeError,
  BACKOFF_INITIAL_SECONDS,
  BACKOFF_MAX_SECONDS,
} from '../src/anchorWorker.js';

// The worker's scheduling, with vitest's fake timers: time only moves when a test moves it,
// so a 5-minute backoff takes no real time.

const ZERO = Object.freeze({ confirmed: 0, waiting: 0, resent: 0, returnedToPending: 0, failed: 0 });
const summary = (outcome, extra = {}) => ({ outcome, reconciled: ZERO, stepId: null, code: null, ...extra });

const READY = Object.freeze({
  startable: true,
  canSend: true,
  checks: [
    { name: 'chainId', status: 'passed' },
    { name: 'code', status: 'passed' },
    { name: 'role', status: 'passed' },
  ],
  warnings: [],
  facts: { recorderAddress: '0x25E19030C6cdb1e2608819BceF797a23eb0738fA', balanceWei: 10n ** 16n, latestNonce: 0, pendingNonce: 0 },
});
const notStartable = (status) => ({
  ...READY,
  startable: false,
  canSend: false,
  checks: [{ name: 'chainId', status, problem: 'primary RPC rpc.example is on chain 1, not 11155111' }],
  facts: { recorderAddress: READY.facts.recorderAddress },
});

// outcomes: what runOnce returns on each call, in order (an Error is thrown instead);
// after the list runs out it answers idle.
function setup({ outcomes = [], preflight = async () => READY, intervalSeconds = 30 } = {}) {
  const calls = [];
  const runOnce = vi.fn(async () => {
    calls.push(Date.now());
    const next = outcomes.shift();
    if (next instanceof Error) throw next;
    return next ?? summary('idle');
  });
  const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
  const preflightFn = vi.fn(preflight);
  const worker = createAnchorWorker({ runOnce, preflight: preflightFn, intervalSeconds, log });
  // Seconds between consecutive ticks.
  const gaps = () => calls.slice(1).map((time, i) => (time - calls[i]) / 1000);
  return { worker, runOnce, log, preflight: preflightFn, gaps, calls };
}

const advance = (seconds) => vi.advanceTimersByTimeAsync(seconds * 1000);
const allLogged = (log) => [...log.info.mock.calls, ...log.warn.mock.calls, ...log.error.mock.calls].flat().join('\n');

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('nextBackoffSeconds', () => {
  it('starts at 30 s, doubles, and stops growing at 5 minutes', () => {
    const seen = [];
    let value = null;
    for (let i = 0; i < 7; i += 1) {
      value = nextBackoffSeconds(value);
      seen.push(value);
    }
    expect(seen).toEqual([30, 60, 120, 240, 300, 300, 300]);
    expect(BACKOFF_INITIAL_SECONDS).toBe(30);
    expect(BACKOFF_MAX_SECONDS).toBe(300);
  });
});

describe('createAnchorWorker: start', () => {
  it('runs preflight once, logs it as one line, then ticks at once and every interval', async () => {
    const { worker, runOnce, preflight, log } = setup();

    await expect(worker.start()).resolves.toBe(true);
    expect(preflight).toHaveBeenCalledTimes(1);
    expect(log.info.mock.calls[0][0]).toMatch(/^Anchoring preflight passed: recorder 0x25E1.*balance 0\.010000 ETH/);

    await advance(0);
    expect(runOnce).toHaveBeenCalledTimes(1);
    await advance(29.999);
    expect(runOnce).toHaveBeenCalledTimes(1);
    await advance(0.001);
    expect(runOnce).toHaveBeenCalledTimes(2);
    await advance(30);
    expect(runOnce).toHaveBeenCalledTimes(3);
    expect(preflight).toHaveBeenCalledTimes(1);
    await worker.stop();
  });

  it('does not start the worker when a check failed, and never ticks', async () => {
    const { worker, runOnce, log } = setup({ preflight: async () => notStartable('failed') });

    await expect(worker.start()).resolves.toBe(false);
    await advance(3600);

    expect(runOnce).not.toHaveBeenCalled();
    expect(log.error.mock.calls[0][0]).toMatch(/did not pass \(chainId failed: .*\).*not started \(the API keeps running\)/);
  });

  it('retries preflight with backoff when a check could not be made, then starts', async () => {
    const answers = [notStartable('error'), notStartable('error'), READY];
    const { worker, runOnce, preflight, calls } = setup({ preflight: async () => answers.shift() });
    const startedAt = Date.now();

    await expect(worker.start()).resolves.toBe(false);
    await advance(30);
    expect(preflight).toHaveBeenCalledTimes(2);
    await advance(60);
    expect(preflight).toHaveBeenCalledTimes(3);
    expect(runOnce).not.toHaveBeenCalled();

    // The third preflight ran from a timer, so its schedule(0, tickTask) happened while the
    // fake clock was ticking, and fake-timers puts a 0 ms timer made then at now + 1 ms
    // (real timers clamp 0 ms to at least 1 ms too). Run the next timer wherever it is.
    await vi.advanceTimersToNextTimerAsync();
    expect(runOnce).toHaveBeenCalledTimes(1);
    // ...and it really was the tick, straight after the preflight at 90 s.
    expect(calls[0] - startedAt).toBeGreaterThanOrEqual(90_000);
    expect(calls[0] - startedAt).toBeLessThanOrEqual(90_001);
    await worker.stop();
  });
});

describe('createAnchorWorker: backoff', () => {
  it('grows 30 s to 5 min on backoff, and goes back to the interval after any other outcome', async () => {
    const backoffs = Array.from({ length: 6 }, () => summary('backoff', { code: 'RPC_UNAVAILABLE' }));
    const { worker, gaps } = setup({ outcomes: [...backoffs, summary('idle')] });

    await worker.start();
    await advance(0 + 30 + 60 + 120 + 240 + 300 + 300 + 30);

    expect(gaps()).toEqual([30, 60, 120, 240, 300, 300, 30]);
    await worker.stop();
  });

  it('starts again from 30 s after a reset', async () => {
    const { worker, gaps } = setup({
      outcomes: [summary('backoff'), summary('backoff'), summary('sent', { stepId: 'a' }), summary('backoff'), summary('idle')],
    });

    await worker.start();
    await advance(30 + 60 + 30 + 30 + 1);

    expect(gaps()).toEqual([30, 60, 30, 30]);
    await worker.stop();
  });

  it('treats a thrown error like backoff, and logs only its code for a database error', async () => {
    const dbDown = Object.assign(new Error('duplicate key value: Key (username)=(secret-name) exists'), { code: '23505', constraint: 'users_x' });
    const { worker, gaps, log } = setup({ outcomes: [dbDown, summary('idle')] });

    await worker.start();
    await advance(30 + 1);

    expect(gaps()).toEqual([30]);
    const text = allLogged(log);
    expect(text).toContain('database error 23505 (constraint users_x)');
    expect(text).not.toContain('secret-name');
    await worker.stop();
  });

  it('stops scheduling for good on stopped', async () => {
    const { worker, runOnce, log } = setup({ outcomes: [summary('stopped', { code: 'ROLE_LOST' })] });

    await worker.start();
    await advance(3600);

    expect(runOnce).toHaveBeenCalledTimes(1);
    expect(log.error.mock.calls.at(-1)[0]).toMatch(/stopped: the recorder wallet no longer holds RECORDER_ROLE/);
  });

  it('keeps the normal interval while paused or busy', async () => {
    const { worker, gaps } = setup({ outcomes: [summary('paused', { code: 'FEE_TOO_HIGH' }), summary('busy'), summary('idle')] });

    await worker.start();
    await advance(61);

    expect(gaps()).toEqual([30, 30]);
    await worker.stop();
  });
});

describe('createAnchorWorker: logging', () => {
  it('logs once per change of outcome, not on every tick', async () => {
    const { worker, log } = setup({
      outcomes: [summary('idle'), summary('idle'), summary('sent', { stepId: 's1' }), summary('waiting'), summary('waiting'), summary('idle')],
    });

    await worker.start();
    await advance(5 * 30 + 1);

    // The preflight line, then idle, sent, waiting, idle.
    const lines = log.info.mock.calls.map((c) => c[0]);
    expect(lines).toHaveLength(5);
    expect(lines.slice(1).map((l) => l.split(';')[0])).toEqual([
      'Anchoring: idle',
      'Anchoring: sent step s1',
      'Anchoring: waiting',
      'Anchoring: idle',
    ]);
    await worker.stop();
  });

  it('logs pauses and backoffs as warnings', async () => {
    const { worker, log } = setup({ outcomes: [summary('paused', { code: 'INSUFFICIENT_FUNDS' })] });

    await worker.start();
    await advance(0);

    expect(log.warn.mock.calls[0][0]).toBe('Anchoring: paused (INSUFFICIENT_FUNDS); next tick in 30 s');
    await worker.stop();
  });
});

describe('createAnchorWorker: stop', () => {
  it('cancels the next tick', async () => {
    const { worker, runOnce } = setup();
    await worker.start();
    await advance(0);

    await worker.stop();
    await advance(3600);

    expect(runOnce).toHaveBeenCalledTimes(1);
  });

  it('waits for a tick that is already running, so the pool is not closed under it', async () => {
    let finishTick;
    const { worker, runOnce } = setup();
    runOnce.mockImplementationOnce(() => new Promise((resolve) => (finishTick = () => resolve(summary('sent')))));
    await worker.start();
    await advance(0);

    let stopped = false;
    const stopping = worker.stop().then(() => {
      stopped = true;
    });
    await advance(0);
    expect(stopped).toBe(false);

    finishTick();
    await stopping;
    expect(stopped).toBe(true);
    await advance(3600);
    expect(runOnce).toHaveBeenCalledTimes(1);
  });
});

describe('describeError', () => {
  it('names a database error by code and constraint only', () => {
    const err = Object.assign(new Error('Key (qr_code)=(MC-1) already exists'), { code: '23505', constraint: 'c' });
    expect(describeError(err)).toBe('database error 23505 (constraint c)');
  });

  it('gives name and message for anything else', () => {
    expect(describeError(new TypeError('bad thing'))).toBe('TypeError: bad thing');
  });
});
