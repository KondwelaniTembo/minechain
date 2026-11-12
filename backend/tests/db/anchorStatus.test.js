import { describe, it, expect } from 'vitest';
import { randomBytes } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createAnchorStatusService, FAILED_LIST_LIMIT, PROBLEMS } from '../../src/services/anchorStatusService.js';
import { STUCK_AFTER_SECONDS, nextEligibleStep } from '../../src/services/anchorQueue.js';
import { ANCHOR_ERRORS } from '../../src/services/anchorService.js';
import { createAnchorWorkerFromConfig } from '../../src/anchorWorker.js';
import { createServices } from '../../src/services/index.js';
import { loadConfig } from '../../src/config.js';
import { FAKE_CONTRACT_ADDRESS, FAKE_RECORDER_KEY } from '../fakes/fakeChainClient.js';

// The admin anchoring status against real rows (plan §1, §6 "Status"). Every time is set
// relative to one fixed NOW, which is also the injected clock, so every age is exact.

const t = useTestDb();

const NOW = new Date('2026-11-12T10:00:00.000Z');
const ago = (seconds) => new Date(NOW.getTime() - seconds * 1000);
const INTERVAL = 30;

const status = (anchorWorker = null) =>
  createAnchorStatusService({ db: t.db, anchorWorker, intervalSeconds: INTERVAL, clock: () => NOW }).status();

// A worker stand-in whose snapshot the test chooses.
const fakeWorker = (snapshot) => ({ snapshot: () => snapshot });
const workerSnapshot = (state, extra = {}) => ({
  state,
  startedAt: ago(600),
  preflight: { at: ago(600), passed: true, retrying: false, checks: [] },
  lastTick: { at: ago(5), outcome: 'idle', code: null, stepId: null },
  recorderAddress: '0x25E19030C6cdb1e2608819BceF797a23eb0738fA',
  contractAddress: FAKE_CONTRACT_ADDRESS,
  ...extra,
});

// The anchoring states as fixture overrides.
const SUBMITTED = (extra = {}) => ({ anchor_status: 'submitted', chain_tx_hash: randomBytes(32), anchor_nonce: '0', anchor_submitted_at: ago(10), ...extra });
const CONFIRMED = (extra = {}) => ({ anchor_status: 'confirmed', chain_tx_hash: randomBytes(32), block_number: '12047700', anchored_at: ago(60), ...extra });
const FAILED = (extra = {}) => ({ anchor_status: 'failed', anchor_error: ANCHOR_ERRORS.MAX_ATTEMPTS, anchor_attempts: 5, ...extra });

const hex = (bytes) => `0x${bytes.toString('hex')}`;

// received_at is set by the database, so it is moved afterwards.
async function insertStep(overrides, receivedAt) {
  const row = await insertTransaction(t.db, overrides);
  const { rows } = await t.db.query('UPDATE transactions SET received_at = $2 WHERE id = $1 RETURNING *', [row.id, receivedAt]);
  return rows[0];
}

// A consignment with its own miner, transporter and buyer. Each step defaults to a
// received_at one second later than the previous one in the test.
let second = 0;
async function journey() {
  const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
  const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
  const buyer = await insertUser(t.db, { role: 'buyer', status: 'active' });
  const consignment = await insertConsignment(t.db, { miner_id: miner.id });
  const step = (type, actor) => (overrides = {}, at = ago(3600 - (second += 1))) =>
    insertStep({ consignment_id: consignment.id, actor_id: actor.id, type, ...overrides }, at);
  return { consignment, registration: step('registration', miner), handoff: step('handoff', transporter), purchase: step('purchase', buyer) };
}

const codes = (body) => body.problems.map((p) => p.code);

describe('anchoring status: shape', () => {
  it('with anchoring off and nothing stored: exactly the planned keys and empty values', async () => {
    expect(await status()).toEqual({
      worker: { state: 'disabled', startedAt: null, preflight: null, lastTick: null, recorderAddress: null, contractAddress: null },
      counts: { pending: 0, submitted: 0, confirmed: 0, failed: 0 },
      inFlight: [],
      failed: [],
      pending: { oldestReceivedAt: null, oldestAgeSeconds: null, onHeldConsignments: 0, behindFailedStep: 0, sendableNow: null },
      held: [],
      lastConfirmed: null,
      lastSubmitted: null,
      problems: [{ code: 'WORKER_DISABLED', message: PROBLEMS.WORKER_DISABLED }],
    });
  });

  it('the worker part is copied field by field: an extra snapshot field never appears', async () => {
    const snap = workerSnapshot('running', { somethingNew: 'must-not-leak' });
    const body = await status(fakeWorker(snap));

    expect(Object.keys(body.worker)).toEqual(['state', 'startedAt', 'preflight', 'lastTick', 'recorderAddress', 'contractAddress']);
    expect(body.worker).toMatchObject({ state: 'running', recorderAddress: snap.recorderAddress, contractAddress: FAKE_CONTRACT_ADDRESS });
    expect(JSON.stringify(body)).not.toContain('must-not-leak');
    expect(body.problems).toEqual([]);
  });
});

describe('anchoring status: counts', () => {
  it('counts approved steps only (passed or cleared), by anchor status', async () => {
    for (const overrides of [
      {},
      { review_status: 'cleared' },
      { review_status: 'flagged' }, // waiting for an officer, not for the chain
      { review_status: 'rejected' }, // never anchored
      SUBMITTED(),
      CONFIRMED(),
      FAILED(),
    ]) {
      await (await journey()).registration(overrides);
    }
    const j = await journey();
    await j.registration(CONFIRMED());
    await j.handoff(FAILED({ anchor_error: ANCHOR_ERRORS.receiptMismatch(['dataHash']), chain_tx_hash: randomBytes(32) }));

    expect((await status()).counts).toEqual({ pending: 2, submitted: 1, confirmed: 2, failed: 2 });
  });
});

describe('anchoring status: in flight', () => {
  it('hash as hex, nonce as text, age from the injected clock, stuck only past STUCK_AFTER_SECONDS', async () => {
    const atLimit = await (await journey()).registration(SUBMITTED({ anchor_nonce: '4', anchor_submitted_at: ago(STUCK_AFTER_SECONDS) }));
    const past = await (await journey()).registration(SUBMITTED({ anchor_nonce: '9007199254740993', anchor_submitted_at: ago(STUCK_AFTER_SECONDS + 1) }));

    const body = await status();

    expect(body.inFlight).toEqual([
      {
        stepId: atLimit.id,
        consignmentId: atLimit.consignment_id,
        type: 'registration',
        chainTxHash: hex(atLimit.chain_tx_hash),
        nonce: '4',
        submittedAt: ago(STUCK_AFTER_SECONDS),
        ageSeconds: STUCK_AFTER_SECONDS,
        stuck: false,
        lastRefusal: null,
      },
      expect.objectContaining({ stepId: past.id, nonce: '9007199254740993', ageSeconds: STUCK_AFTER_SECONDS + 1, stuck: true }),
    ]);
    expect(codes(body)).toContain('STUCK_SUBMITTED');
  });

  it('lastRefusal: the refusal stored on a submitted row, split into code and detail', async () => {
    const text = 'INVALID_STAGE:Purchased: the step is not allowed from the consignment stage on-chain';
    await (await journey()).registration(SUBMITTED({ anchor_error: text }));

    const [step] = (await status()).inFlight;
    expect(step.lastRefusal).toEqual({ code: 'INVALID_STAGE', detail: 'Purchased', error: text });
  });
});

describe('anchoring status: failed', () => {
  it('each with code, detail, error, attempts, hash and retryable', async () => {
    const j = await journey();
    await j.registration(CONFIRMED());
    const mismatchHash = randomBytes(32);
    const mismatch = await j.handoff(FAILED({ anchor_error: ANCHOR_ERRORS.receiptMismatch(['id', 'dataHash']), anchor_attempts: 1, chain_tx_hash: mismatchHash }));
    const maxed = await (await journey()).registration(FAILED());

    const body = await status();
    const byId = Object.fromEntries(body.failed.map((f) => [f.stepId, f]));

    expect(byId[mismatch.id]).toEqual({
      stepId: mismatch.id,
      consignmentId: mismatch.consignment_id,
      type: 'handoff',
      code: 'RECEIPT_MISMATCH',
      detail: 'id,dataHash',
      error: ANCHOR_ERRORS.receiptMismatch(['id', 'dataHash']),
      attempts: 1,
      chainTxHash: hex(mismatchHash),
      updatedAt: expect.any(Date),
      retryable: false,
    });
    expect(byId[maxed.id]).toMatchObject({ code: 'MAX_ATTEMPTS', detail: null, attempts: 5, chainTxHash: null, retryable: true });
    expect(codes(body)).toContain('FAILED_STEPS');
  });

  it(`lists at most ${FAILED_LIST_LIMIT}, newest first, while counts has them all`, async () => {
    const j = await journey();
    await j.registration(CONFIRMED());
    for (let i = 0; i < FAILED_LIST_LIMIT + 1; i += 1) await j.handoff(FAILED());

    const body = await status();

    expect(body.counts.failed).toBe(FAILED_LIST_LIMIT + 1);
    expect(body.failed).toHaveLength(FAILED_LIST_LIMIT);
    // Inside one test transaction updated_at is the same for every row (the trigger uses
    // now()), so this shows the tie-break: id, descending, the same way every time.
    const ids = body.failed.map((f) => f.stepId);
    expect(ids).toEqual([...ids].sort().reverse());
  });
});

describe('anchoring status: pending and held', () => {
  it('oldest age, steps on held consignments and behind failed steps, with a real open alert, and what goes next', async () => {
    // A: registration anchored; the handoff waits because the purchase after it is flagged
    // with an open alert, which holds the whole consignment.
    const a = await journey();
    await a.registration(CONFIRMED(), ago(3000));
    await a.handoff({}, ago(600));
    const flagged = await a.purchase({ review_status: 'flagged' }, ago(500));
    await insertAlert(t.db, { transaction_id: flagged.id });
    // B: the registration failed, so the handoff after it waits.
    const b = await journey();
    await b.registration(FAILED(), ago(2000));
    await b.handoff({}, ago(300));
    // C: a registration the worker can send now.
    const c = await journey();
    const sendable = await c.registration({}, ago(120));
    // D: an older step that is only flagged: not approved, so not counted as waiting.
    await (await journey()).registration({ review_status: 'flagged' }, ago(9000));

    const body = await status();

    expect(body.pending).toEqual({
      // A's handoff. B's older registration has failed, not pending, and D is not approved.
      oldestReceivedAt: ago(600),
      oldestAgeSeconds: 600,
      onHeldConsignments: 1,
      behindFailedStep: 1,
      sendableNow: sendable.id,
    });
    expect(body.held).toEqual([{ consignmentId: a.consignment.id, qrCode: a.consignment.qr_code, pendingSteps: 1, openAlerts: 1 }]);
    expect(body.counts.pending).toBe(3);

    // The peek locked nothing: the worker's own query still takes the same step.
    expect((await t.db.transaction((tx) => nextEligibleStep(tx)))?.id).toBe(sendable.id);
  });

  it('an alert on a flagged duplicate of an accepted registration holds nothing, by the queue\'s own rule', async () => {
    const j = await journey();
    const accepted = await j.registration({}, ago(200));
    const duplicate = await j.registration({ review_status: 'flagged' }, ago(100));
    await insertAlert(t.db, { transaction_id: duplicate.id, type: 'duplicate_consignment', severity: 'high', details: {} });

    const body = await status();

    expect(body.held).toEqual([]);
    expect(body.pending).toMatchObject({ onHeldConsignments: 0, sendableNow: accepted.id });
  });
});

describe('anchoring status: last activity from the rows', () => {
  it('lastConfirmed is the newest anchored_at, lastSubmitted the newest anchor_submitted_at', async () => {
    await (await journey()).registration(CONFIRMED({ anchored_at: ago(900) }));
    const newest = await (await journey()).registration(CONFIRMED({ anchored_at: ago(400) }));
    const inFlight = await (await journey()).registration(SUBMITTED({ anchor_submitted_at: ago(30) }));
    await (await journey()).registration(SUBMITTED({ anchor_submitted_at: ago(90), anchor_nonce: '1' }));

    const body = await status();

    expect(body.lastConfirmed).toEqual({ stepId: newest.id, anchoredAt: ago(400) });
    expect(body.lastSubmitted).toEqual({ stepId: inFlight.id, submittedAt: ago(30) });
  });
});

describe('anchoring status: problems from the worker', () => {
  it.each([
    ['not_started', 'WORKER_NOT_STARTED'],
    ['stopped', 'WORKER_STOPPED'],
    ['backoff', 'WORKER_BACKOFF'],
    ['paused', 'WORKER_PAUSED'],
  ])('state %s gives %s', async (state, code) => {
    expect(codes(await status(fakeWorker(workerSnapshot(state))))).toEqual([code]);
  });

  it('NO_RECENT_TICK once the last tick is more than three intervals old', async () => {
    const quiet = (seconds) => fakeWorker(workerSnapshot('running', { lastTick: { at: ago(seconds), outcome: 'idle', code: null, stepId: null } }));

    expect(codes(await status(quiet(3 * INTERVAL)))).toEqual([]);
    expect(codes(await status(quiet(3 * INTERVAL + 1)))).toEqual(['NO_RECENT_TICK']);
  });
});

describe('anchoring status: no secrets', () => {
  // Marked fake values for every secret and ANCHOR_ setting, through the real loadConfig and
  // the real worker wiring (whose chain client makes no network call until used).
  const MARK = 'FAKE-SECRET';
  const ENV = Object.freeze({
    NODE_ENV: 'test',
    DATABASE_URL: `postgres://dev-db.example/${MARK}-dev-db`,
    TEST_DATABASE_URL: `postgres://test-db.example/${MARK}-test-db`,
    JWT_SECRET: `${MARK}-jwt-0123456789abcdefghijklmnopqrstuvwxyz`,
    JWT_EXPIRES_IN: '60m',
    ANCHOR_ENABLED: 'true',
    SEPOLIA_RPC_URL: `https://primary-rpc.example/v3/${MARK}-primary-key`,
    SEPOLIA_RPC_URL_FALLBACK: `https://fallback-rpc.example/v3/${MARK}-fallback-key`,
    MINECHAIN_CONTRACT_ADDRESS: FAKE_CONTRACT_ADDRESS,
    RECORDER_PRIVATE_KEY: FAKE_RECORDER_KEY,
    ANCHOR_INTERVAL_SECONDS: '45',
    ANCHOR_MAX_FEE_GWEI: '47.123456789',
    ANCHOR_LOW_BALANCE_ETH: '0.004321',
  });

  it('the serialised body holds none of them, but does hold the two public addresses', async () => {
    const config = loadConfig(ENV);
    const unusedPool = { connect: () => Promise.reject(new Error('not used: no tick runs in this test')) };
    const anchorWorker = createAnchorWorkerFromConfig({ db: t.db, pool: unusedPool, anchorConfig: config.anchor, log: { info() {}, warn() {}, error() {} } });
    const services = createServices({ db: t.db, config, anchorWorker, clock: () => NOW });
    // Something in every list, so every part of the body is filled in.
    const j = await journey();
    await j.registration(CONFIRMED());
    await j.handoff(SUBMITTED({ anchor_error: 'FEE_TOO_HIGH: the network fee is above the configured maximum' }));
    await (await journey()).registration(FAILED());

    const text = JSON.stringify(await services.anchoring.status());

    for (const value of [MARK, 'primary-rpc.example', 'fallback-rpc.example', 'dev-db.example', 'test-db.example', FAKE_RECORDER_KEY, FAKE_RECORDER_KEY.slice(2), '47123456789', '4321000000000000']) {
      expect(text, value).not.toContain(value);
    }
    expect(text).toContain(anchorWorker.snapshot().recorderAddress);
    expect(text).toContain(FAKE_CONTRACT_ADDRESS);
    await anchorWorker.stop();
  });
});
