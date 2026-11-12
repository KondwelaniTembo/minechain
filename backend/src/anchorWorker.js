// The anchoring worker inside the API process (8 Nov plan, step 8, process model). When
// ANCHOR_ENABLED is true, server.js starts it after listen:
//   1. preflight once, logged as one line. A failed check (wrong chain, wrong contract, no
//      role) means a person must fix the configuration, so the worker does not start; the
//      API keeps serving either way. A check that could not be made (RPC down at boot) is
//      retried with backoff instead, so a provider hiccup during a deploy does not leave
//      anchoring off until the next one.
//   2. then runOnce on a timer: every ANCHOR_INTERVAL_SECONDS, or with a growing delay
//      (30 s doubling to 5 min) after "backoff", reset by any other outcome. "stopped"
//      (the wallet lost its role) ends the schedule.
// Each tick is scheduled only after the previous one has finished, so two never overlap.
// Log lines appear when the outcome changes, not on every tick.
//
// Render's free tier spins an idle service down, and a stopped process anchors nothing:
// steps then wait, safely pending or submitted, until the next request wakes it.
import { createChainClient } from './chain/chainClient.js';
import { describePreflight } from './chain/describe.js';
import { runPreflight } from './chain/preflight.js';
import { createAnchorService } from './services/anchorService.js';

export const BACKOFF_INITIAL_SECONDS = 30;
export const BACKOFF_MAX_SECONDS = 300;

export const nextBackoffSeconds = (previous) =>
  previous === null ? BACKOFF_INITIAL_SECONDS : Math.min(previous * 2, BACKOFF_MAX_SECONDS);

// What may be logged about an unexpected error: a database error by its SQLSTATE code and
// constraint only (its detail can echo values), anything else by name and message, which
// for our own code and chain errors are fixed texts.
export function describeError(err) {
  if (typeof err?.code === 'string' && /^[0-9A-Z]{5}$/.test(err.code)) {
    return `database error ${err.code}${err.constraint ? ` (constraint ${err.constraint})` : ''}`;
  }
  return `${err?.name ?? 'Error'}: ${err?.message ?? String(err)}`;
}

// Why runNow did not run a tick. Each becomes a 409 at the admin endpoint (plan §3).
//   DISABLED     ANCHOR_ENABLED is not true, so there is no worker
//   NOT_STARTED  preflight has not passed (yet): chain, contract and role are unconfirmed
//   STOPPED      the wallet lost its role, or the server is shutting down
//   BUSY         a tick is running in this process, or another process holds the lock
export const RUN_NOW_REFUSALS = Object.freeze({
  DISABLED: 'ANCHORING_DISABLED',
  NOT_STARTED: 'ANCHORING_NOT_STARTED',
  STOPPED: 'ANCHORING_STOPPED',
  BUSY: 'ANCHORING_BUSY',
});

const refused = (code) => Object.freeze({ ran: false, code });

// The snapshot's state, from the worst condition down:
//   stopped      ROLE_LOST seen, or stop() called; nothing more will run
//   not_started  preflight never ran, or a check failed (a person must fix the configuration)
//   backoff      preflight or the last tick could not reach the chain (or threw); retrying
//   paused       the last tick could not send for funds or fee
//   running      anything else
// "disabled" never comes from a worker: anchoringSnapshot(null) gives it.
export const WORKER_STATES = Object.freeze(['running', 'backoff', 'paused', 'stopped', 'not_started', 'disabled']);

// The tick summary's code may hold describeError text for a thrown error, which can name a
// database host. The snapshot is shown to admins, so it keeps a fixed code instead.
const INTERNAL_ERROR = 'INTERNAL_ERROR';

// runOnce: the anchoring service's tick. preflight: () => a preflight result.
// timers: injectable for tests (vitest's fake timers also work with the defaults).
// now: the time stamped on the snapshot, injectable for tests.
export function createAnchorWorker({
  runOnce,
  preflight,
  intervalSeconds,
  log = console,
  timers = { setTimeout, clearTimeout },
  now = () => new Date(),
}) {
  let timer = null;
  let current = null; // the timer's task running now, so stop() can wait for it
  let manual = null; // a runNow tick running now, likewise
  let stopping = false;
  let roleLost = false;
  let backoff = null;
  let lastLogged = null;

  // What the snapshot reports. Only fixed words, check names, ids and times: never a
  // preflight problem text (it names RPC hosts), an error message or a secret.
  let startedAt = null;
  let preflightSeen = null; // { at, passed, retrying, checks: [{ name, status }] not passed }
  let lastTick = null; // { at, outcome, code, stepId }

  function notePreflight(result) {
    const notPassed = result.checks.filter((c) => c.status !== 'passed');
    preflightSeen = Object.freeze({
      at: now(),
      passed: result.startable === true,
      retrying: !result.startable && !notPassed.some((c) => c.status === 'failed'),
      checks: Object.freeze(notPassed.map((c) => Object.freeze({ name: c.name, status: c.status }))),
    });
  }

  function noteTick(summary) {
    const thrown = summary.outcome === 'error';
    lastTick = Object.freeze({
      at: now(),
      outcome: summary.outcome,
      code: thrown ? INTERNAL_ERROR : (summary.code ?? null),
      stepId: summary.stepId ?? null,
    });
    if (summary.outcome === 'stopped') roleLost = true;
  }

  function state() {
    if (stopping || roleLost) return 'stopped';
    if (startedAt === null) return preflightSeen?.retrying ? 'backoff' : 'not_started';
    if (lastTick?.outcome === 'backoff' || lastTick?.outcome === 'error') return 'backoff';
    if (lastTick?.outcome === 'paused') return 'paused';
    return 'running';
  }

  function schedule(seconds, task) {
    if (stopping || roleLost) return;
    timer = timers.setTimeout(() => {
      timer = null;
      current = task().finally(() => {
        current = null;
      });
    }, seconds * 1000);
  }

  function logOnChange(key, line, level = 'info') {
    if (key === lastLogged) return;
    lastLogged = key;
    log[level](line);
  }

  async function preflightTask() {
    let result;
    try {
      result = await preflight();
    } catch (err) {
      backoff = nextBackoffSeconds(backoff);
      preflightSeen = Object.freeze({ at: now(), passed: false, retrying: true, checks: Object.freeze([]) });
      log.error(`Anchoring preflight failed unexpectedly (${describeError(err)}); trying again in ${backoff} s`);
      schedule(backoff, preflightTask);
      return false;
    }

    notePreflight(result);
    if (result.startable) {
      log.info(describePreflight(result));
      backoff = null;
      startedAt = now();
      schedule(0, tickTask);
      return true;
    }
    if (result.checks.some((c) => c.status === 'failed')) {
      log.error(`${describePreflight(result)}; the anchoring worker is not started (the API keeps running). Fix the configuration and restart.`);
      return false;
    }
    // Only "could not check": try again later.
    backoff = nextBackoffSeconds(backoff);
    log.warn(`${describePreflight(result)}; trying again in ${backoff} s`);
    schedule(backoff, preflightTask);
    return false;
  }

  async function tickTask() {
    let summary;
    try {
      summary = await runOnce();
    } catch (err) {
      // A bug or the database being down. Treated like an outage: wait longer, try again.
      summary = { outcome: 'error', code: describeError(err), stepId: null };
    }
    noteTick(summary);

    if (summary.outcome === 'stopped') {
      log.error('Anchoring worker stopped: the recorder wallet no longer holds RECORDER_ROLE. Fix the role, then restart.');
      return;
    }
    const failing = summary.outcome === 'backoff' || summary.outcome === 'error';
    backoff = failing ? nextBackoffSeconds(backoff) : null;
    const delay = failing ? backoff : intervalSeconds;

    const code = summary.code ? ` (${summary.code})` : '';
    const step = summary.stepId ? ` step ${summary.stepId}` : '';
    logOnChange(
      `${summary.outcome}|${summary.code}|${summary.stepId}`,
      `Anchoring: ${summary.outcome}${code}${step}; next tick in ${delay} s`,
      failing || summary.outcome === 'paused' ? 'warn' : 'info',
    );
    schedule(delay, tickTask);
  }

  return Object.freeze({
    // Resolves with true once the worker is running, false if it did not start (yet).
    start() {
      stopping = false;
      current = preflightTask().finally(() => {
        current = null;
      });
      return current;
    },

    // No new tick starts after this; a tick already running (timer or runNow) is waited
    // for, so the database pool is not closed under it. A submitted row left behind
    // recovers by design.
    async stop() {
      stopping = true;
      if (timer !== null) {
        timers.clearTimeout(timer);
        timer = null;
      }
      await Promise.all([current, manual].map((task) => task?.catch(() => {})));
    },

    // One tick now, for an administrator (plan §3), on the same runOnce as the timer, so it
    // shares the service's stopped flag and the advisory lock. One tick only, never "until
    // idle". It does not move the timer: the next scheduled tick comes when it would have.
    // Returns { ran: true, summary } or { ran: false, code } with a RUN_NOW_REFUSALS code.
    // A thrown error (a bug, the database down) is noted in the snapshot and rethrown.
    async runNow() {
      if (stopping || roleLost) return refused(RUN_NOW_REFUSALS.STOPPED);
      if (startedAt === null) return refused(RUN_NOW_REFUSALS.NOT_STARTED);
      // Checked here first, so a tick already running in this process is not asked for the
      // lock a second time (it would answer busy anyway, after a database round trip).
      if (current !== null || manual !== null) return refused(RUN_NOW_REFUSALS.BUSY);

      const task = runOnce();
      manual = task;
      let summary;
      try {
        summary = await task;
      } catch (err) {
        noteTick({ outcome: 'error', code: null, stepId: null });
        throw err;
      } finally {
        manual = null;
      }
      // Another process (anchor:once, a second server) holds the lock: nothing ran.
      if (summary.outcome === 'busy') return refused(RUN_NOW_REFUSALS.BUSY);
      noteTick(summary);
      if (roleLost && timer !== null) {
        timers.clearTimeout(timer);
        timer = null;
      }
      return Object.freeze({ ran: true, summary });
    },

    // The worker's memory, for the admin status. Times are Date objects; the caller formats.
    snapshot() {
      return Object.freeze({ state: state(), startedAt, preflight: preflightSeen, lastTick });
    },
  });
}

// The admin side's view when ANCHOR_ENABLED is false: server.js passes null instead of a
// worker (plan §5), and these answer for it, so the four refusals live in one place.
export async function runAnchoringNow(anchoring) {
  return anchoring ? anchoring.runNow() : refused(RUN_NOW_REFUSALS.DISABLED);
}

export function anchoringSnapshot(anchoring) {
  return anchoring
    ? anchoring.snapshot()
    : Object.freeze({ state: 'disabled', startedAt: null, preflight: null, lastTick: null, recorderAddress: null, contractAddress: null });
}

// The real wiring, used by server.js.
export function createAnchorWorkerFromConfig({ db, pool, anchorConfig, log = console }) {
  const chain = createChainClient(anchorConfig, { log });
  const service = createAnchorService({ db, pool, chain, config: anchorConfig, log });
  const worker = createAnchorWorker({
    runOnce: service.runOnce,
    preflight: () => runPreflight(chain, anchorConfig),
    intervalSeconds: anchorConfig.intervalSeconds,
    log,
  });
  return Object.freeze({
    start: worker.start,
    async stop() {
      await worker.stop();
      chain.close();
    },
    runNow: worker.runNow,
    // Both addresses are public on Sepolia; an admin needs the recorder's to fund it
    // (decision 1, 12 Nov). Read from the client, which never exposes an RPC URL or key.
    snapshot: () =>
      Object.freeze({ ...worker.snapshot(), recorderAddress: chain.recorderAddress, contractAddress: chain.contractAddress }),
  });
}
