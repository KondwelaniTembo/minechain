import { describe, it, expect, vi } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { insertUser, insertTransaction } from './fixtures.js';
import { createPool } from '../../src/db.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createAnchorService, ANCHOR_ERRORS } from '../../src/services/anchorService.js';
import { tryAnchorLock } from '../../src/services/anchorQueue.js';
import {
  createAnchorStatusService,
  splitAnchorError,
  RETRY_REQUESTED,
  RUN_REFUSAL_MESSAGES,
} from '../../src/services/anchorStatusService.js';
import { createAnchorWorker } from '../../src/anchorWorker.js';
import { ChainClientError } from '../../src/chain/chainClient.js';
import { classifyChainError } from '../../src/chain/chainErrors.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';
import { anchorUntilIdle, freeLock, silentLog } from './realStackHelpers.js';

// The two admin actions on anchoring (plan §2-§4): retry a failed step, and run one tick
// now. Failures are produced by driving the fake chain wherever the worker can reach them;
// codes the worker would need a broken contract or a backend bug to produce are inserted.

const t = useTestDb();

const GWEI = 1_000_000_000n;
// maxAttempts 1: one refused dry run or one mined revert fails the step at once.
const CONFIG = Object.freeze({ confirmations: 2, maxAttempts: 1, maxFeePerGasWei: 50n * GWEI });
const IP = '203.0.113.7';
const REASON = 'RPC provider was down during the first try';
const quiet = () => ({ info: () => {}, warn: () => {}, error: () => {} });
const chainError = (raw) => new ChainClientError(classifyChainError(raw), 'primary');

// The worker as server.js wires it, around the real service and the fake chain, but with
// timers that never fire: only run-now ticks happen, so nothing else uses the test's
// connection. start() runs a preflight stand-in that passes.
async function rig({ audit = createAuditService(), lock = freeLock, start = true, log = quiet() } = {}) {
  const fake = createFakeChainClient();
  const service = createAnchorService({ db: t.db, chain: fake.client, config: CONFIG, lock, log: silentLog() });
  const worker = createAnchorWorker({
    runOnce: service.runOnce,
    preflight: async () => ({ startable: true, canSend: true, checks: [], warnings: [], facts: { recorderAddress: fake.client.recorderAddress } }),
    intervalSeconds: 30,
    log: quiet(),
    timers: { setTimeout: () => 1, clearTimeout: () => {} },
  });
  if (start) expect(await worker.start()).toBe(true);
  const anchoring = createAnchorStatusService({ db: t.db, audit, anchorWorker: worker, intervalSeconds: 30, log });
  // A tick on another chain view, to inject an error at one call.
  const tick = (chain = fake.client) =>
    createAnchorService({ db: t.db, chain, config: CONFIG, lock: freeLock, log: silentLog() }).runOnce();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  return { fake, service, worker, anchoring, tick, admin };
}

async function load(id) {
  const { rows } = await t.db.query('SELECT * FROM transactions WHERE id = $1', [id]);
  return rows[0];
}
async function auditRows() {
  const { rows } = await t.db.query('SELECT actor_id, action, entity_type, entity_id, details, ip_address FROM audit_logs ORDER BY id');
  return rows;
}
const hex = (bytes) => `0x${bytes.toString('hex')}`;
const failedRow = (anchorError, extra = {}) =>
  insertTransaction(t.db, { anchor_status: 'failed', anchor_error: anchorError, anchor_attempts: 1, ...extra });

// Takes a function that starts the action, so the refusal is caught from the action itself.
async function expectRefused(start, { status, code, message }) {
  let caught;
  try {
    await start();
  } catch (err) {
    caught = err;
  }
  expect(caught, 'expected the action to be refused').toBeDefined();
  expect(caught).toMatchObject({ name: 'AppError', status, code, ...(message && { message }) });
}

describe('retry: each allowed code, produced on the fake chain', () => {
  const PRODUCE = {
    'INVALID_STAGE:None': async (r) => {
      r.fake.control.revertNextEstimate('InvalidStage', [`0x${'11'.repeat(32)}`, 0]);
      await r.tick();
    },
    UNKNOWN: async (r) => {
      const estimateGas = async () => {
        throw chainError(new Error('something odd'));
      };
      await r.tick({ ...r.fake.client, estimateGas });
    },
    MAX_ATTEMPTS: async (r) => {
      r.fake.control.revertNextMined('ConsignmentAlreadyExists');
      await r.tick();
      r.fake.control.mine(2);
      await r.tick();
    },
  };

  it.each(Object.keys(PRODUCE))('%s: back to pending, then confirmed once by the worker', async (key) => {
    const r = await rig();
    const step = await insertTransaction(t.db);
    await PRODUCE[key](r);
    const failed = await load(step.id);
    expect(failed.anchor_status).toBe('failed');
    const split = splitAnchorError(failed.anchor_error);
    expect(split.detail === null ? split.code : `${split.code}:${split.detail}`).toBe(key);

    const view = await r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id, ipAddress: IP });

    expect(view).toEqual({
      stepId: step.id,
      consignmentId: step.consignment_id,
      type: 'registration',
      anchorStatus: 'pending',
      code: 'RETRY_REQUESTED',
      detail: null,
      error: RETRY_REQUESTED,
      attempts: 0,
      chainTxHash: null,
      updatedAt: expect.any(Date),
    });
    expect(await load(step.id)).toMatchObject({ anchor_nonce: null, anchor_submitted_at: null });

    await anchorUntilIdle(r.service, r.fake, { confirmations: CONFIG.confirmations });
    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'confirmed', anchor_attempts: 1, anchor_error: null });
    // On-chain exactly once: one successful transaction (a reverted try changed nothing).
    expect(r.fake.control.records.mined.filter((m) => m.status === 1)).toHaveLength(1);
    expect(hex(row.chain_tx_hash)).toBe(r.fake.control.records.mined.find((m) => m.status === 1).hash);
  });

  it('the audit entry keeps the previous error, attempts and the reverted hash, which the row loses', async () => {
    const r = await rig();
    const step = await insertTransaction(t.db);
    await PRODUCE.MAX_ATTEMPTS(r);
    const failed = await load(step.id);

    await r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id, ipAddress: IP });

    expect(await auditRows()).toEqual([
      {
        actor_id: r.admin.id,
        action: 'transaction.anchor_retry',
        entity_type: 'transaction',
        entity_id: step.id,
        details: { reason: REASON, previousError: ANCHOR_ERRORS.MAX_ATTEMPTS, previousAttempts: 1, previousTxHash: hex(failed.chain_tx_hash) },
        ip_address: IP,
      },
    ]);
    expect((await load(step.id)).chain_tx_hash).toBeNull();
  });
});

describe('retry: refusals', () => {
  it.each([
    ['INVALID_STAGE', 'INVALID_STAGE:Registered: the step is not allowed from the consignment stage on-chain'],
    ['INVALID_STAGE', 'INVALID_STAGE:InTransit: the step is not allowed from the consignment stage on-chain'],
    ['INVALID_STAGE', 'INVALID_STAGE:Purchased: the step is not allowed from the consignment stage on-chain'],
    ['INVALID_INPUT', 'INVALID_INPUT:dataHash: the contract refused a zero id, actor reference, weight or hash'],
    ['STEP_TYPE_UNKNOWN', 'STEP_TYPE_UNKNOWN: step type must be registration, handoff or purchase'],
    ['BYTES32_INVALID', 'BYTES32_INVALID: data_hash must not be all zero'],
    ['WEIGHT_INVALID', 'WEIGHT_INVALID: weight_mg does not fit the contract (uint64)'],
    ['ID_ALREADY_ANCHORED', ANCHOR_ERRORS.ID_ALREADY_ANCHORED],
    ['RECEIPT_MISMATCH', ANCHOR_ERRORS.receiptMismatch(['dataHash'])],
  ])('%s (%s): ANCHOR_NOT_RETRYABLE, row and audit unchanged', async (code, text) => {
    const r = await rig();
    const step = await failedRow(text, { chain_tx_hash: randomBytes(32) });
    const before = await load(step.id);

    await expectRefused(() => r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id }), {
      status: 409,
      code: 'ANCHOR_NOT_RETRYABLE',
      message: `This step failed for a reason a retry cannot fix (${code}). It needs investigating.`,
    });
    expect(await load(step.id)).toEqual(before);
    expect(await auditRows()).toEqual([]);
  });

  it.each([
    ['pending', {}],
    ['submitted', { anchor_status: 'submitted', chain_tx_hash: randomBytes(32), anchor_nonce: '0', anchor_submitted_at: new Date() }],
    ['confirmed', { anchor_status: 'confirmed', chain_tx_hash: randomBytes(32), block_number: '12047700', anchored_at: new Date() }],
  ])('a %s step: INVALID_STATUS_TRANSITION, nothing changed', async (status, overrides) => {
    const r = await rig();
    const step = await insertTransaction(t.db, overrides);
    const before = await load(step.id);

    await expectRefused(() => r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id }), {
      status: 409,
      code: 'INVALID_STATUS_TRANSITION',
      message: `Only a failed step can be retried. This step is ${status}.`,
    });
    expect(await load(step.id)).toEqual(before);
    expect(await auditRows()).toEqual([]);
  });

  it('an unknown id: 404 STEP_NOT_FOUND', async () => {
    const r = await rig();
    await expectRefused(() => r.anchoring.retry({ stepId: randomUUID(), reason: REASON, actorId: r.admin.id }), {
      status: 404,
      code: 'STEP_NOT_FOUND',
    });
  });

  it('a second retry of the same step: 409, with one audit entry', async () => {
    const r = await rig();
    const step = await failedRow(ANCHOR_ERRORS.MAX_ATTEMPTS);
    await r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id });

    await expectRefused(() => r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id }), {
      status: 409,
      code: 'INVALID_STATUS_TRANSITION',
      message: 'Only a failed step can be retried. This step is pending.',
    });
    expect(await auditRows()).toHaveLength(1);
  });

  it('nothing is saved when the audit write fails', async () => {
    const failingAudit = { record: async () => { throw new Error('audit store unavailable'); } };
    const r = await rig({ audit: failingAudit });
    const step = await failedRow(ANCHOR_ERRORS.MAX_ATTEMPTS, { chain_tx_hash: randomBytes(32) });
    const before = await load(step.id);

    await expect(r.anchoring.retry({ stepId: step.id, reason: REASON, actorId: r.admin.id })).rejects.toThrow('audit store unavailable');
    expect(await load(step.id)).toEqual(before);
    expect(await auditRows()).toEqual([]);
  });
});

describe('retry: the id', () => {
  it('in capitals finds the step, and the audit entry has the one lower-case spelling', async () => {
    const r = await rig();
    const step = await failedRow(ANCHOR_ERRORS.MAX_ATTEMPTS);

    const view = await r.anchoring.retry({ stepId: step.id.toUpperCase(), reason: REASON, actorId: r.admin.id });

    expect(view.stepId).toBe(step.id);
    expect((await auditRows())[0].entity_id).toBe(step.id);
  });
});

describe('run: one tick now', () => {
  it('passes the summary back and writes anchoring.run with outcome, code and step', async () => {
    const r = await rig();
    const step = await insertTransaction(t.db);

    const summary = await r.anchoring.run({ actorId: r.admin.id, ipAddress: IP });

    expect(summary).toEqual({
      outcome: 'sent',
      reconciled: { confirmed: 0, waiting: 0, resent: 0, returnedToPending: 0, failed: 0 },
      stepId: step.id,
      code: null,
    });
    expect((await load(step.id)).anchor_status).toBe('submitted');
    expect(await auditRows()).toEqual([
      { actor_id: r.admin.id, action: 'anchoring.run', entity_type: null, entity_id: null, details: { outcome: 'sent', code: null, stepId: step.id }, ip_address: IP },
    ]);
  });

  it('ANCHORING_DISABLED with no worker', async () => {
    const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
    const anchoring = createAnchorStatusService({ db: t.db, audit: createAuditService() });

    await expectRefused(() => anchoring.run({ actorId: admin.id }), {
      status: 409,
      code: 'ANCHORING_DISABLED',
      message: RUN_REFUSAL_MESSAGES.ANCHORING_DISABLED,
    });
    expect(await auditRows()).toEqual([]);
  });

  it('ANCHORING_NOT_STARTED before preflight has passed', async () => {
    const r = await rig({ start: false });
    await insertTransaction(t.db);

    await expectRefused(() => r.anchoring.run({ actorId: r.admin.id }), {
      status: 409,
      code: 'ANCHORING_NOT_STARTED',
      message: RUN_REFUSAL_MESSAGES.ANCHORING_NOT_STARTED,
    });
    expect(r.fake.control.records.calls).toEqual([]);
    expect(await auditRows()).toEqual([]);
  });

  it('ANCHORING_BUSY while another process holds the advisory lock', async () => {
    const pool = createPool(testDatabaseUrl());
    const holder = await tryAnchorLock(pool);
    try {
      const r = await rig({ lock: () => tryAnchorLock(pool) });
      const step = await insertTransaction(t.db);

      await expectRefused(() => r.anchoring.run({ actorId: r.admin.id }), {
        status: 409,
        code: 'ANCHORING_BUSY',
        message: RUN_REFUSAL_MESSAGES.ANCHORING_BUSY,
      });
      expect((await load(step.id)).anchor_status).toBe('pending');
      expect(await auditRows()).toEqual([]);
    } finally {
      await holder.release();
      await pool.end();
    }
  });

  it('after the wallet loses its role: the run that finds it is audited, the next is ANCHORING_STOPPED', async () => {
    const r = await rig();
    const step = await insertTransaction(t.db);
    r.fake.control.revokeRecorderRole();

    expect(await r.anchoring.run({ actorId: r.admin.id })).toMatchObject({ outcome: 'stopped', code: 'ROLE_LOST' });
    await expectRefused(() => r.anchoring.run({ actorId: r.admin.id }), {
      status: 409,
      code: 'ANCHORING_STOPPED',
      message: RUN_REFUSAL_MESSAGES.ANCHORING_STOPPED,
    });

    expect((await load(step.id)).anchor_status).toBe('pending');
    const entries = await auditRows();
    expect(entries).toHaveLength(1);
    expect(entries[0].details).toEqual({ outcome: 'stopped', code: 'ROLE_LOST', stepId: null });
  });

  it('when the audit write fails after the tick ran: the tick stands, the error is passed on, one log line says so', async () => {
    const failingAudit = { record: async () => { throw new Error('audit store unavailable'); } };
    const log = { error: vi.fn() };
    const r = await rig({ audit: failingAudit, log });
    const step = await insertTransaction(t.db);

    await expect(r.anchoring.run({ actorId: r.admin.id })).rejects.toThrow('audit store unavailable');

    // Already sent: undoing it is impossible (the transaction may be on its way to a node)
    // and unnecessary (it is what the next timer tick would have done).
    expect((await load(step.id)).anchor_status).toBe('submitted');
    expect(r.worker.snapshot().lastTick).toMatchObject({ outcome: 'sent', stepId: step.id });
    expect(log.error).toHaveBeenCalledTimes(1);
    expect(log.error.mock.calls[0][0]).toMatch(new RegExp(`^Anchoring run by user ${r.admin.id} ran \\(outcome sent\\) but its audit entry could not be written`));
    expect(await auditRows()).toEqual([]);
  });
});
