import { describe, it, expect } from 'vitest';
import {
  splitAnchorError,
  isRetryableAnchorError,
  findProblems,
  createAnchorStatusService,
  RETRYABLE_ANCHOR_ERRORS,
  NO_RECENT_TICK_INTERVALS,
} from '../src/services/anchorStatusService.js';
import { ANCHOR_ERRORS } from '../src/services/anchorService.js';
import { CHAIN_ERRORS, toAnchorError } from '../src/chain/chainErrors.js';
import { BACKOFF_MAX_SECONDS } from '../src/anchorWorker.js';

// The pure parts of the admin anchoring status: the anchor_error split, the retry
// allow-list and the problems list. The queries are tested in tests/db/anchorStatus.test.js.

// Texts exactly as the worker stores them, made by the worker's own functions.
const stored = (code, details = {}) => toAnchorError({ code, ...CHAIN_ERRORS[code], ...details });
const TEXTS = Object.freeze({
  invalidStageNone: stored('INVALID_STAGE', { currentStage: 'None' }),
  invalidStagePurchased: stored('INVALID_STAGE', { currentStage: 'Purchased' }),
  invalidInput: stored('INVALID_INPUT', { field: 'weightMilligrams' }),
  unknown: stored('UNKNOWN'),
  maxAttempts: ANCHOR_ERRORS.MAX_ATTEMPTS,
  idAlreadyAnchored: ANCHOR_ERRORS.ID_ALREADY_ANCHORED,
  receiptMismatch: ANCHOR_ERRORS.receiptMismatch(['id', 'dataHash']),
  bytes32: 'BYTES32_INVALID: data_hash must not be all zero',
  stepType: 'STEP_TYPE_UNKNOWN: step type must be registration, handoff or purchase',
  weight: 'WEIGHT_INVALID: weight_mg does not fit the contract (uint64)',
});

describe('splitAnchorError', () => {
  it.each([
    [TEXTS.invalidStageNone, 'INVALID_STAGE', 'None'],
    [TEXTS.invalidInput, 'INVALID_INPUT', 'weightMilligrams'],
    [TEXTS.unknown, 'UNKNOWN', null],
    [TEXTS.maxAttempts, 'MAX_ATTEMPTS', null],
    [TEXTS.receiptMismatch, 'RECEIPT_MISMATCH', 'id,dataHash'],
    [TEXTS.bytes32, 'BYTES32_INVALID', null],
  ])('splits %j', (text, code, detail) => {
    expect(splitAnchorError(text)).toEqual({ code, detail });
  });

  it('gives null for no error, and UNRECOGNISED for text not in our format', () => {
    expect(splitAnchorError(null)).toBeNull();
    for (const text of ['', 'something odd happened', 'lowercase: no', 'UNKNOWN:', 'UNKNOWN:None:no space after']) {
      expect(splitAnchorError(text)).toEqual({ code: 'UNRECOGNISED', detail: null });
    }
  });
});

describe('isRetryableAnchorError', () => {
  it('allows exactly INVALID_STAGE:None, UNKNOWN and MAX_ATTEMPTS', () => {
    expect(RETRYABLE_ANCHOR_ERRORS).toEqual(['INVALID_STAGE:None', 'UNKNOWN', 'MAX_ATTEMPTS']);
    expect(isRetryableAnchorError(TEXTS.invalidStageNone)).toBe(true);
    expect(isRetryableAnchorError(TEXTS.unknown)).toBe(true);
    expect(isRetryableAnchorError(TEXTS.maxAttempts)).toBe(true);
  });

  it('refuses every other code, any other stage, and anything unrecognised', () => {
    for (const text of [
      TEXTS.invalidStagePurchased,
      stored('INVALID_STAGE', { currentStage: 'Registered' }),
      stored('INVALID_STAGE', { currentStage: 'InTransit' }),
      TEXTS.invalidInput,
      TEXTS.idAlreadyAnchored,
      TEXTS.receiptMismatch,
      TEXTS.bytes32,
      TEXTS.stepType,
      TEXTS.weight,
      'UNKNOWN:extra: a detail where none belongs',
      'not our format',
      null,
    ]) {
      expect(isRetryableAnchorError(text), String(text)).toBe(false);
    }
  });
});

// ---------- problems ----------

const NOW = new Date('2026-11-12T10:00:00.000Z');
const INTERVAL = 30;
const ago = (seconds) => new Date(NOW.getTime() - seconds * 1000);
const worker = (state, extra = {}) => ({ state, startedAt: ago(600), preflight: null, lastTick: { at: ago(1) }, ...extra });
const problems = (overrides = {}) =>
  findProblems({ worker: worker('running'), inFlight: [], failedCount: 0, now: NOW, intervalSeconds: INTERVAL, ...overrides }).map((p) => p.code);

describe('findProblems', () => {
  it('a healthy running worker has none', () => {
    expect(problems()).toEqual([]);
  });

  it.each([
    ['disabled', 'WORKER_DISABLED'],
    ['not_started', 'WORKER_NOT_STARTED'],
    ['stopped', 'WORKER_STOPPED'],
    ['backoff', 'WORKER_BACKOFF'],
    ['paused', 'WORKER_PAUSED'],
  ])('state %s gives %s, with a fixed message', (state, code) => {
    const [problem] = findProblems({ worker: worker(state), inFlight: [], failedCount: 0, now: NOW, intervalSeconds: INTERVAL });
    expect(problem.code).toBe(code);
    expect(problem.message).toMatch(/^[A-Z].+\.$/);
  });

  it('STUCK_SUBMITTED for a stuck step in flight, FAILED_STEPS for any failed step, in that order', () => {
    expect(problems({ inFlight: [{ stuck: false }] })).toEqual([]);
    expect(problems({ inFlight: [{ stuck: true }], failedCount: 2 })).toEqual(['STUCK_SUBMITTED', 'FAILED_STEPS']);
  });

  it('NO_RECENT_TICK after three intervals without a tick, not at three exactly', () => {
    const limit = NO_RECENT_TICK_INTERVALS * INTERVAL;
    expect(problems({ worker: worker('running', { lastTick: { at: ago(limit) } }) })).toEqual([]);
    expect(problems({ worker: worker('running', { lastTick: { at: ago(limit + 1) } }) })).toEqual(['NO_RECENT_TICK']);
    expect(problems({ worker: worker('paused', { lastTick: { at: ago(limit + 1) } }) })).toEqual(['WORKER_PAUSED', 'NO_RECENT_TICK']);
    // Started but no tick yet: measured from the start.
    expect(problems({ worker: worker('running', { lastTick: null, startedAt: ago(limit + 1) }) })).toEqual(['NO_RECENT_TICK']);
  });

  it('while backing off, NO_RECENT_TICK allows the backoff cap on top', () => {
    const limit = BACKOFF_MAX_SECONDS + NO_RECENT_TICK_INTERVALS * INTERVAL;
    expect(problems({ worker: worker('backoff', { lastTick: { at: ago(limit) } }) })).toEqual(['WORKER_BACKOFF']);
    expect(problems({ worker: worker('backoff', { lastTick: { at: ago(limit + 1) } }) })).toEqual(['WORKER_BACKOFF', 'NO_RECENT_TICK']);
    // Preflight still retrying: measured from the last preflight.
    const retrying = worker('backoff', { startedAt: null, lastTick: null, preflight: { at: ago(limit + 1) } });
    expect(problems({ worker: retrying })).toEqual(['WORKER_BACKOFF', 'NO_RECENT_TICK']);
  });

  it('never NO_RECENT_TICK for a worker that is not meant to tick', () => {
    for (const state of ['disabled', 'not_started', 'stopped']) {
      expect(problems({ worker: worker(state, { lastTick: { at: ago(86_400) } }) })).not.toContain('NO_RECENT_TICK');
    }
  });
});

describe('createAnchorStatusService', () => {
  it('needs the interval when there is a worker, and not without one', () => {
    const fakeWorker = { snapshot: () => ({ state: 'running' }) };
    expect(() => createAnchorStatusService({ db: {}, anchorWorker: fakeWorker })).toThrow(TypeError);
    expect(() => createAnchorStatusService({ db: {}, anchorWorker: fakeWorker, intervalSeconds: 0 })).toThrow(TypeError);
    expect(() => createAnchorStatusService({ db: {}, anchorWorker: fakeWorker, intervalSeconds: 30 })).not.toThrow();
    expect(() => createAnchorStatusService({ db: {} })).not.toThrow();
  });
});
