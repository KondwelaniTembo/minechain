import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { useTestDb } from './helpers.js';
import { FAKE_CONFIG, insertUser, insertTransaction } from './fixtures.js';
import { auth, bindRealStack, freeLock, silentLog } from './realStackHelpers.js';
import { createAnchorService, ANCHOR_GRACE_SECONDS } from '../../src/services/anchorService.js';
import { STUCK_AFTER_SECONDS } from '../../src/services/anchorQueue.js';
import { createAnchorWorker, createAnchorWorkerFromConfig } from '../../src/anchorWorker.js';
import { loadConfig } from '../../src/config.js';
import { createFakeChainClient, FAKE_CONTRACT_ADDRESS, FAKE_RECORDER_KEY } from '../fakes/fakeChainClient.js';

// The anchoring admin endpoints through the whole stack, as server.js wires it: the real
// app, services and worker, the test's database, and the fake chain. Every tick is a
// POST /admin/anchoring/run, so the test drives the worker exactly as an admin would.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const GWEI = 1_000_000_000n;
// maxAttempts 1: one mined revert fails the step.
const ANCHOR = Object.freeze({ confirmations: 2, maxAttempts: 1, maxFeePerGasWei: 50n * GWEI });
const INTERVAL = 30;
const REASON = 'The revert was a one-off; trying again';
const quiet = () => ({ info: () => {}, warn: () => {}, error: () => {} });

// One clock for the worker, its service and the status, moved by hand.
function testClock() {
  let ms = Date.now();
  const clock = () => new Date(ms);
  clock.advance = (seconds) => {
    ms += seconds * 1000;
  };
  return clock;
}

async function stack() {
  const fake = createFakeChainClient();
  const clock = testClock();
  const service = createAnchorService({ db: t.db, chain: fake.client, config: ANCHOR, clock, lock: freeLock, log: silentLog() });
  // Timers that never fire: every tick is a run-now from the API.
  const worker = createAnchorWorker({
    runOnce: service.runOnce,
    preflight: async () => ({ startable: true, canSend: true, checks: [], warnings: [], facts: { recorderAddress: fake.client.recorderAddress } }),
    intervalSeconds: INTERVAL,
    log: quiet(),
    timers: { setTimeout: () => 1, clearTimeout: () => {} },
    now: clock,
  });
  expect(await worker.start()).toBe(true);
  const { app, tokenFor } = realStack({ config: { ...FAKE_CONFIG, anchor: { intervalSeconds: INTERVAL } }, anchorWorker: worker, clock });
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const token = await tokenFor({ id: admin.id, role: 'admin' });

  const api = {
    status: async () => {
      const res = await auth(request(app).get('/admin/anchoring'), token);
      expect(res.status).toBe(200);
      return res.body;
    },
    run: async () => {
      const res = await auth(request(app).post('/admin/anchoring/run'), token);
      expect(res.status).toBe(200);
      return res.body.summary;
    },
    retry: (stepId, reason) => auth(request(app).post(`/admin/anchoring/steps/${stepId}/retry`), token).send({ reason }),
  };
  return { fake, clock, api, admin };
}

const codes = (body) => body.problems.map((p) => p.code);
const hex = (bytes) => `0x${bytes.toString('hex')}`;
async function load(id) {
  const { rows } = await t.db.query('SELECT * FROM transactions WHERE id = $1', [id]);
  return rows[0];
}

describe('anchoring admin, end to end', () => {
  it('a failed step: shown as retryable, retried, run, confirmed, and no longer a problem', async () => {
    const { fake, api, admin } = await stack();
    const step = await insertTransaction(t.db);

    // MAX_ATTEMPTS, on the fake chain: sent, mined but reverted, failed on the next tick.
    fake.control.revertNextMined('ConsignmentAlreadyExists');
    expect(await api.run()).toMatchObject({ outcome: 'sent', stepId: step.id });
    fake.control.mine(2);
    expect((await api.run()).reconciled.failed).toBe(1);

    const before = await api.status();
    expect(before.failed).toEqual([expect.objectContaining({ stepId: step.id, code: 'MAX_ATTEMPTS', retryable: true })]);
    expect(codes(before)).toContain('FAILED_STEPS');

    const retried = await api.retry(step.id, REASON);
    expect(retried.status).toBe(200);
    expect(retried.body.step).toMatchObject({ stepId: step.id, anchorStatus: 'pending', code: 'RETRY_REQUESTED', attempts: 0 });

    expect(await api.run()).toMatchObject({ outcome: 'sent', stepId: step.id });
    fake.control.mine(2);
    expect(await api.run()).toMatchObject({ outcome: 'idle', reconciled: { confirmed: 1 } });

    const after = await api.status();
    expect(after.counts).toEqual({ pending: 0, submitted: 0, confirmed: 1, failed: 0 });
    expect(after.failed).toEqual([]);
    expect(codes(after)).not.toContain('FAILED_STEPS');
    expect(after.lastConfirmed.stepId).toBe(step.id);

    // Four runs and one retry, each audited by who did it.
    const { rows } = await t.db.query('SELECT action, actor_id FROM audit_logs ORDER BY id');
    expect(rows.map((r) => r.action)).toEqual(['anchoring.run', 'anchoring.run', 'transaction.anchor_retry', 'anchoring.run', 'anchoring.run']);
    expect(new Set(rows.map((r) => r.actor_id))).toEqual(new Set([admin.id]));
  });

  it('a stuck step: shown stuck with FEE_TOO_HIGH; once the fee falls, a run resends it with the same nonce and it confirms', async () => {
    const { fake, clock, api } = await stack();
    const step = await insertTransaction(t.db);

    expect(await api.run()).toMatchObject({ outcome: 'sent', stepId: step.id });
    const sent = await load(step.id);
    expect(fake.control.dropTransaction(hex(sent.chain_tx_hash))).toBe(true);
    // Past both the grace period (so the next tick tries to resend) and the stuck limit.
    clock.advance(Math.max(ANCHOR_GRACE_SECONDS, STUCK_AFTER_SECONDS) + 1);
    fake.control.setFeeData({ maxFeePerGas: 60n * GWEI });
    expect(await api.run()).toMatchObject({ outcome: 'waiting', reconciled: { waiting: 1 } });

    const stuck = await api.status();
    expect(stuck.inFlight).toEqual([
      expect.objectContaining({
        stepId: step.id,
        nonce: '0',
        stuck: true,
        lastRefusal: { code: 'FEE_TOO_HIGH', detail: null, error: 'FEE_TOO_HIGH: the network fee is above the configured maximum' },
      }),
    ]);
    expect(codes(stuck)).toContain('STUCK_SUBMITTED');

    fake.control.setFeeData({ maxFeePerGas: 2n * GWEI });
    expect((await api.run()).reconciled.resent).toBe(1);
    expect(fake.control.records.sent.map((s) => s.nonce)).toEqual([0, 0]);
    fake.control.mine(2);
    expect((await api.run()).reconciled.confirmed).toBe(1);

    const after = await api.status();
    expect(after.inFlight).toEqual([]);
    expect(codes(after)).not.toContain('STUCK_SUBMITTED');
    expect(await load(step.id)).toMatchObject({ anchor_status: 'confirmed', anchor_nonce: '0', anchor_error: null });
    expect(fake.control.records.mined.filter((m) => m.status === 1)).toHaveLength(1);
  });

  it('the status body holds no secret from a marked fake config', async () => {
    // Marked fake values, through the real loadConfig and the real worker wiring (whose
    // chain client makes no network call until used; this worker is never started).
    const MARK = 'FAKE-SECRET';
    const config = loadConfig({
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
      ANCHOR_MAX_FEE_GWEI: '47.123456789',
      ANCHOR_LOW_BALANCE_ETH: '0.004321',
    });
    const unusedPool = { connect: () => Promise.reject(new Error('not used: no tick runs in this test')) };
    const anchorWorker = createAnchorWorkerFromConfig({ db: t.db, pool: unusedPool, anchorConfig: config.anchor, log: quiet() });
    const { app, tokenFor } = realStack({ config, anchorWorker });
    const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
    await insertTransaction(t.db, { anchor_status: 'failed', anchor_error: 'UNKNOWN: an unrecognised error' });

    const res = await auth(request(app).get('/admin/anchoring'), await tokenFor({ id: admin.id, role: 'admin' }));

    expect(res.status).toBe(200);
    for (const value of [MARK, 'primary-rpc.example', 'fallback-rpc.example', 'dev-db.example', 'test-db.example', FAKE_RECORDER_KEY.slice(2), '47123456789', '4321000000000000']) {
      expect(res.text, value).not.toContain(value);
    }
    expect(res.body.worker).toMatchObject({ state: 'not_started', recorderAddress: anchorWorker.snapshot().recorderAddress, contractAddress: FAKE_CONTRACT_ADDRESS });
    await anchorWorker.stop();
  });
});
