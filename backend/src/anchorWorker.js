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

// runOnce: the anchoring service's tick. preflight: () => a preflight result.
// timers: injectable for tests (vitest's fake timers also work with the defaults).
export function createAnchorWorker({
  runOnce,
  preflight,
  intervalSeconds,
  log = console,
  timers = { setTimeout, clearTimeout },
}) {
  let timer = null;
  let current = null; // the task running now, so stop() can wait for it
  let stopping = false;
  let backoff = null;
  let lastLogged = null;

  function schedule(seconds, task) {
    if (stopping) return;
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
      log.error(`Anchoring preflight failed unexpectedly (${describeError(err)}); trying again in ${backoff} s`);
      schedule(backoff, preflightTask);
      return false;
    }

    if (result.startable) {
      log.info(describePreflight(result));
      backoff = null;
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

    // No new tick starts after this; a tick already running is waited for, so the
    // database pool is not closed under it. A submitted row left behind recovers by design.
    async stop() {
      stopping = true;
      if (timer !== null) {
        timers.clearTimeout(timer);
        timer = null;
      }
      if (current) await current.catch(() => {});
    },
  });
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
  });
}
