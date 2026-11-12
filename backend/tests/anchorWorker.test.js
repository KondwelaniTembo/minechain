import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  createAnchorWorker,
  nextBackoffSeconds,
  describeError,
  runAnchoringNow,
  anchoringSnapshot,
  BACKOFF_INITIAL_SECONDS,
  BACKOFF_MAX_SECONDS,
  RUN_NOW_REFUSALS,
  WORKER_STATES,
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

// A runOnce call that stays running until the test lets it finish.
function holdNextTick(runOnce, result = summary('sent', { stepId: 's1' })) {
  let finish;
  runOnce.mockImplementationOnce(() => new Promise((resolve) => (finish = () => resolve(result))));
  return () => finish();
}

describe('createAnchorWorker: snapshot', () => {
  it('before start: not_started, with nothing seen yet', () => {
    const { worker } = setup();
    expect(worker.snapshot()).toEqual({ state: 'not_started', startedAt: null, preflight: null, lastTick: null });
  });

  it('after a passing preflight and a tick: running, with the start time and the last tick', async () => {
    const { worker } = setup({ outcomes: [summary('sent', { stepId: 's1' })] });
    const startedAt = new Date(Date.now());

    await worker.start();
    await advance(0);

    const snap = worker.snapshot();
    expect(snap).toEqual({
      state: 'running',
      startedAt,
      preflight: { at: startedAt, passed: true, retrying: false, checks: [] },
      lastTick: { at: startedAt, outcome: 'sent', code: null, stepId: 's1' },
    });
    expect(WORKER_STATES).toContain(snap.state);
    await worker.stop();
  });

  it('a failed check: not_started, naming the check and its status but never its problem text', async () => {
    const { worker } = setup({ preflight: async () => notStartable('failed') });
    await worker.start();

    const snap = worker.snapshot();
    expect(snap.state).toBe('not_started');
    expect(snap.preflight).toMatchObject({ passed: false, retrying: false, checks: [{ name: 'chainId', status: 'failed' }] });
    // The problem text names the RPC host.
    expect(JSON.stringify(snap)).not.toContain('rpc.example');
  });

  it('a check that could not be made: backoff while preflight retries', async () => {
    const { worker } = setup({ preflight: async () => notStartable('error') });
    await worker.start();

    expect(worker.snapshot()).toMatchObject({ state: 'backoff', startedAt: null, preflight: { retrying: true } });
    await worker.stop();
  });

  it('follows the last tick: paused, backoff, then running again', async () => {
    const { worker } = setup({
      outcomes: [summary('paused', { code: 'FEE_TOO_HIGH' }), summary('backoff', { code: 'RPC_UNAVAILABLE' }), summary('idle')],
    });
    await worker.start();

    await advance(0);
    expect(worker.snapshot()).toMatchObject({ state: 'paused', lastTick: { outcome: 'paused', code: 'FEE_TOO_HIGH' } });
    await advance(30);
    expect(worker.snapshot()).toMatchObject({ state: 'backoff', lastTick: { code: 'RPC_UNAVAILABLE' } });
    await advance(30);
    expect(worker.snapshot()).toMatchObject({ state: 'running', lastTick: { outcome: 'idle' } });
    await worker.stop();
  });

  it('a thrown error shows as backoff with a fixed code, never the error text', async () => {
    const dbDown = Object.assign(new Error('connect ECONNREFUSED db.internal.example:5432'), { code: 'ECONNREFUSED' });
    const { worker } = setup({ outcomes: [dbDown] });
    await worker.start();
    await advance(0);

    const snap = worker.snapshot();
    expect(snap).toMatchObject({ state: 'backoff', lastTick: { outcome: 'error', code: 'INTERNAL_ERROR', stepId: null } });
    expect(JSON.stringify(snap)).not.toContain('db.internal.example');
    await worker.stop();
  });

  it('stopped after ROLE_LOST, and after stop()', async () => {
    const lost = setup({ outcomes: [summary('stopped', { code: 'ROLE_LOST' })] });
    await lost.worker.start();
    await advance(0);
    expect(lost.worker.snapshot()).toMatchObject({ state: 'stopped', lastTick: { code: 'ROLE_LOST' } });

    const shut = setup();
    await shut.worker.start();
    await shut.worker.stop();
    expect(shut.worker.snapshot().state).toBe('stopped');
  });
});

describe('createAnchorWorker: runNow', () => {
  it('refuses NOT_STARTED before preflight has passed, without calling runOnce', async () => {
    const before = setup();
    await expect(before.worker.runNow()).resolves.toEqual({ ran: false, code: RUN_NOW_REFUSALS.NOT_STARTED });

    const failed = setup({ preflight: async () => notStartable('failed') });
    await failed.worker.start();
    await expect(failed.worker.runNow()).resolves.toEqual({ ran: false, code: 'ANCHORING_NOT_STARTED' });

    const retrying = setup({ preflight: async () => notStartable('error') });
    await retrying.worker.start();
    await expect(retrying.worker.runNow()).resolves.toEqual({ ran: false, code: 'ANCHORING_NOT_STARTED' });
    await retrying.worker.stop();

    expect(before.runOnce).not.toHaveBeenCalled();
    expect(failed.runOnce).not.toHaveBeenCalled();
    expect(retrying.runOnce).not.toHaveBeenCalled();
  });

  it('runs one tick, passes its summary back, notes it, and leaves the timer where it was', async () => {
    const sent = summary('sent', { stepId: 's2' });
    const { worker, gaps } = setup({ outcomes: [summary('idle'), sent] });
    await worker.start();
    await advance(10);

    await expect(worker.runNow()).resolves.toEqual({ ran: true, summary: sent });
    expect(worker.snapshot().lastTick).toMatchObject({ outcome: 'sent', stepId: 's2' });

    await advance(20);
    // Timer tick at 0, run-now at 10, timer tick at 30 as planned.
    expect(gaps()).toEqual([10, 20]);
    await worker.stop();
  });

  it('refuses BUSY while a timer tick or another run-now is running in this process', async () => {
    const { worker, runOnce } = setup();
    const finishTimerTick = holdNextTick(runOnce);
    await worker.start();
    await advance(0);

    await expect(worker.runNow()).resolves.toEqual({ ran: false, code: RUN_NOW_REFUSALS.BUSY });
    expect(runOnce).toHaveBeenCalledTimes(1);
    finishTimerTick();
    await advance(0);

    const finishFirstRun = holdNextTick(runOnce);
    const first = worker.runNow();
    await expect(worker.runNow()).resolves.toEqual({ ran: false, code: 'ANCHORING_BUSY' });
    finishFirstRun();
    await expect(first).resolves.toMatchObject({ ran: true });
    expect(runOnce).toHaveBeenCalledTimes(2);
    await worker.stop();
  });

  it('refuses BUSY when another process holds the lock, keeping the last real tick', async () => {
    const { worker } = setup({ outcomes: [summary('idle'), summary('busy')] });
    await worker.start();
    await advance(0);

    await expect(worker.runNow()).resolves.toEqual({ ran: false, code: 'ANCHORING_BUSY' });
    expect(worker.snapshot().lastTick.outcome).toBe('idle');
    await worker.stop();
  });

  it('refuses STOPPED after stop(), and after a run-now that finds ROLE_LOST, which also ends the timer', async () => {
    const shut = setup();
    await shut.worker.start();
    await shut.worker.stop();
    await expect(shut.worker.runNow()).resolves.toEqual({ ran: false, code: RUN_NOW_REFUSALS.STOPPED });

    const lost = setup({ outcomes: [summary('idle'), summary('stopped', { code: 'ROLE_LOST' })] });
    await lost.worker.start();
    await advance(0);
    await expect(lost.worker.runNow()).resolves.toMatchObject({ ran: true, summary: { outcome: 'stopped' } });
    await expect(lost.worker.runNow()).resolves.toEqual({ ran: false, code: 'ANCHORING_STOPPED' });
    await advance(3600);
    expect(lost.runOnce).toHaveBeenCalledTimes(2);
  });

  it('notes a thrown error with the fixed code and passes the error on', async () => {
    const { worker, runOnce } = setup();
    await worker.start();
    await advance(0);
    runOnce.mockImplementationOnce(async () => {
      throw new Error('bug at db.internal.example');
    });

    await expect(worker.runNow()).rejects.toThrow('bug at db.internal.example');
    expect(worker.snapshot()).toMatchObject({ state: 'backoff', lastTick: { outcome: 'error', code: 'INTERNAL_ERROR' } });
    await worker.stop();
  });

  it('stop() waits for a run-now tick, so the pool is not closed under it', async () => {
    const { worker, runOnce } = setup();
    await worker.start();
    await advance(0);
    const finish = holdNextTick(runOnce);
    const run = worker.runNow();

    let stopped = false;
    const stopping = worker.stop().then(() => {
      stopped = true;
    });
    await advance(0);
    expect(stopped).toBe(false);

    finish();
    await stopping;
    expect(stopped).toBe(true);
    await expect(run).resolves.toMatchObject({ ran: true });
  });
});

describe('with anchoring disabled (no worker)', () => {
  it('run-now refuses ANCHORING_DISABLED and the snapshot says disabled', async () => {
    await expect(runAnchoringNow(null)).resolves.toEqual({ ran: false, code: RUN_NOW_REFUSALS.DISABLED });
    expect(anchoringSnapshot(null)).toEqual({
      state: 'disabled',
      startedAt: null,
      preflight: null,
      lastTick: null,
      recorderAddress: null,
      contractAddress: null,
    });
  });

  it('passes through to the worker when there is one', async () => {
    const { worker } = setup({ outcomes: [summary('idle'), summary('sent', { stepId: 's3' })] });
    await worker.start();
    await advance(0);

    await expect(runAnchoringNow(worker)).resolves.toMatchObject({ ran: true, summary: { stepId: 's3' } });
    expect(anchoringSnapshot(worker).state).toBe('running');
    await worker.stop();
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
