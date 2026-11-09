import { describe, it, expect } from 'vitest';
import { randomBytes } from 'node:crypto';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { insertUser, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createPool } from '../../src/db.js';
import { createAnchorService, ANCHOR_GRACE_SECONDS, LOG_SEARCH_MARGIN_BLOCKS } from '../../src/services/anchorService.js';
import { tryAnchorLock } from '../../src/services/anchorQueue.js';
import { buildAnchorCall } from '../../src/services/anchorCall.js';
import { ChainClientError } from '../../src/chain/chainClient.js';
import { classifyChainError } from '../../src/chain/chainErrors.js';
import { DEPLOY_BLOCK } from '../../src/chain/mineChainAbi.js';
import { createFakeChainClient } from '../fakes/fakeChainClient.js';

// The worker against the in-memory chain: every row of the crash table and the error table
// from the Step 8 plan. Each test builds its own fake chain; the database is the usual
// rolled-back test transaction.

const GWEI = 1_000_000_000n;
const CONFIG = Object.freeze({ confirmations: 2, maxAttempts: 5, maxFeePerGasWei: 50n * GWEI });
const SIMULATED_CRASH = 'simulated crash';
const crash = () => {
  throw new Error(SIMULATED_CRASH);
};

const t = useTestDb();

// A clock the tests move by hand, to pass the grace period without waiting.
function testClock() {
  let ms = Date.now();
  const clock = () => new Date(ms);
  clock.advance = (seconds) => {
    ms += seconds * 1000;
  };
  return clock;
}
const PAST_GRACE = ANCHOR_GRACE_SECONDS + 1;

// Most tests do not care about the advisory lock (its own test is below), so they get one
// that is always free.
const freeLock = async () => ({ acquired: true, isLost: () => false, release: async () => {} });

const silentLog = () => ({ warn: () => {}, error: () => {} });

function setup({ config = CONFIG, fakeOptions } = {}) {
  const fake = createFakeChainClient(fakeOptions);
  const clock = testClock();
  // chain can be swapped for one tick, to inject a crash or an error at one call.
  const service = (chain = fake.client) =>
    createAnchorService({ db: t.db, chain, config, clock, lock: freeLock, log: silentLog() });
  const tick = (chain) => service(chain).runOnce();
  return { fake, clock, service, tick };
}

// A consignment with a miner, transporter and buyer, and steps with increasing received_at,
// because inside one test transaction now() never moves.
let minute = 0;
const nextTime = () => new Date(Date.now() - 3_600_000 + (minute += 1) * 60_000);

async function insertStep(overrides, receivedAt = nextTime()) {
  const row = await insertTransaction(t.db, overrides);
  const { rows } = await t.db.query('UPDATE transactions SET received_at = $2 WHERE id = $1 RETURNING *', [row.id, receivedAt]);
  return rows[0];
}

async function journey() {
  const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
  const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
  const buyer = await insertUser(t.db, { role: 'buyer', status: 'active' });
  const consignment = await insertConsignment(t.db, { miner_id: miner.id });
  const step = (type, actor) => (overrides = {}, at) =>
    insertStep({ consignment_id: consignment.id, actor_id: actor.id, type, ...overrides }, at);
  return {
    consignment,
    registration: step('registration', miner),
    handoff: step('handoff', transporter),
    purchase: step('purchase', buyer),
  };
}

async function load(id) {
  const { rows } = await t.db.query(
    `SELECT t.*, c.chain_id, u.actor_ref FROM transactions t
       JOIN consignments c ON c.id = t.consignment_id JOIN users u ON u.id = t.actor_id
      WHERE t.id = $1`,
    [id],
  );
  return rows[0];
}

const hex = (bytes) => `0x${bytes.toString('hex')}`;
const FEES = { gasLimit: 120_000n, maxFeePerGas: 2n * GWEI, maxPriorityFeePerGas: 1n * GWEI };

// Anchors a step on the fake chain directly, as if by a transaction this database never
// recorded.
async function anchorDirectly(fake, row, { nonce, fees = FEES } = {}) {
  const signed = await fake.client.signTransaction({
    call: buildAnchorCall(row),
    nonce: nonce ?? (await fake.client.getNonce('pending')),
    ...fees,
  });
  await fake.client.broadcast(signed.rawTx);
  fake.control.mine(CONFIG.confirmations);
  return signed.hash;
}

const chainError = (raw) => new ChainClientError(classifyChainError(raw), 'primary');

describe('runOnce: the happy path', () => {
  it('anchors registration, handoff and purchase across ticks, one transaction at a time', async () => {
    const { fake, tick } = setup();
    const j = await journey();
    const steps = [await j.registration(), await j.handoff(), await j.purchase()];

    expect(await tick()).toMatchObject({ outcome: 'sent', stepId: steps[0].id });

    fake.control.mine(1);
    // One confirmation of the two required: still in flight, so nothing new is sent.
    expect(await tick()).toMatchObject({ outcome: 'waiting', reconciled: { waiting: 1 } });

    fake.control.mine(1);
    expect(await tick()).toMatchObject({ outcome: 'sent', stepId: steps[1].id, reconciled: { confirmed: 1 } });
    fake.control.mine(2);
    expect(await tick()).toMatchObject({ outcome: 'sent', stepId: steps[2].id, reconciled: { confirmed: 1 } });
    fake.control.mine(2);
    expect(await tick()).toMatchObject({ outcome: 'idle', reconciled: { confirmed: 1 } });

    const rows = await Promise.all(steps.map((s) => load(s.id)));
    const mined = fake.control.records.mined;
    for (const [i, row] of rows.entries()) {
      expect(row).toMatchObject({ anchor_status: 'confirmed', anchor_attempts: 1, anchor_error: null, anchor_nonce: String(i) });
      expect(hex(row.chain_tx_hash)).toBe(mined[i].hash);
      expect(Number(row.block_number)).toBe(mined[i].blockNumber);
      // The block's time, not the server's.
      const seconds = await fake.client.getBlockTimestamp(mined[i].blockNumber);
      expect(row.anchored_at.getTime()).toBe(seconds * 1000);
    }
    expect(new Set(rows.map((r) => hex(r.chain_tx_hash))).size).toBe(3);
    expect(fake.control.records.sent.map((s) => s.nonce)).toEqual([0, 1, 2]);

    const id = buildAnchorCall(rows[0]).args[0];
    const events = await fake.client.getLogs(id, 0, await fake.client.getBlockNumber());
    expect(events.map((e) => e.name)).toEqual(['ConsignmentRegistered', 'HandoffRecorded', 'PurchaseRecorded']);
  });

  it('works through the fallback while the primary is down', async () => {
    const { fake, tick } = setup();
    fake.control.failPrimary();
    await (await journey()).registration();

    expect((await tick()).outcome).toBe('sent');
    expect(fake.control.records.sent[0].accepted).toEqual(['fallback']);
  });

  it('confirms a step that became held after it was sent: the chain already has it', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    await tick();
    await insertAlert(t.db, { transaction_id: step.id });

    fake.control.mine(2);
    expect((await tick()).reconciled.confirmed).toBe(1);
    expect((await load(step.id)).anchor_status).toBe('confirmed');
  });
});

describe('runOnce: the crash table', () => {
  it('1. crash before the submitted UPDATE: the row is still pending and is sent normally', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();

    const signThenCrash = async (args) => {
      await fake.client.signTransaction(args);
      crash();
    };
    await expect(tick({ ...fake.client, signTransaction: signThenCrash })).rejects.toThrow(SIMULATED_CRASH);
    expect(await load(step.id)).toMatchObject({ anchor_status: 'pending', anchor_attempts: 0 });

    expect((await tick()).outcome).toBe('sent');
    expect(fake.control.records.sent.map((s) => s.nonce)).toEqual([0]);
  });

  it('2. crash after the UPDATE, before broadcast: waits out the grace period, then resends with the same nonce', async () => {
    const { fake, clock, tick } = setup();
    const j = await journey();
    await j.registration();
    const handoff = await j.handoff();
    await tick();
    fake.control.mine(2);

    // This tick confirms the registration, then crashes just before broadcasting the handoff.
    await expect(tick({ ...fake.client, broadcast: crash })).rejects.toThrow(SIMULATED_CRASH);
    expect(await load(handoff.id)).toMatchObject({ anchor_status: 'submitted', anchor_nonce: '1' });
    expect(fake.control.mempoolSize()).toBe(0);

    expect(await tick()).toMatchObject({ outcome: 'waiting', reconciled: { waiting: 1 } });

    clock.advance(PAST_GRACE);
    expect(await tick()).toMatchObject({ outcome: 'waiting', reconciled: { resent: 1 } });
    expect(fake.control.records.sent.at(-1).nonce).toBe(1);

    fake.control.mine(2);
    expect((await tick()).reconciled.confirmed).toBe(1);
    const row = await load(handoff.id);
    expect(row).toMatchObject({ anchor_status: 'confirmed', anchor_nonce: '1', anchor_attempts: 1 });
    // On-chain exactly once.
    const events = await fake.client.getLogs(buildAnchorCall(row).args[0], 0, await fake.client.getBlockNumber());
    expect(events.map((e) => e.name)).toEqual(['ConsignmentRegistered', 'HandoffRecorded']);
  });

  it('3. broadcast but not mined: waits, then rebroadcasts the identical transaction', async () => {
    const { fake, clock, tick } = setup();
    const step = await (await journey()).registration();
    await tick();
    const sentHash = hex((await load(step.id)).chain_tx_hash);

    clock.advance(PAST_GRACE);
    // Same nonce, same fees, same gas: the same bytes and hash, which the node already has.
    expect((await tick()).reconciled.resent).toBe(1);
    expect(hex((await load(step.id)).chain_tx_hash)).toBe(sentHash);
    expect(fake.control.mempoolSize()).toBe(1);

    fake.control.mine(2);
    expect((await tick()).reconciled.confirmed).toBe(1);
  });

  it('3b. broadcast but not mined, fees changed a little: the node keeps the old copy, and so does the row', async () => {
    const { fake, clock, tick } = setup();
    const step = await (await journey()).registration();
    await tick();
    const sentHash = hex((await load(step.id)).chain_tx_hash);

    // 5% higher: a different transaction, but not enough of a rise to replace the old one.
    fake.control.setFeeData({ maxFeePerGas: 2_100_000_000n });
    clock.advance(PAST_GRACE);
    expect(await tick()).toMatchObject({ outcome: 'waiting', reconciled: { waiting: 1 } });
    expect(hex((await load(step.id)).chain_tx_hash)).toBe(sentHash);

    fake.control.mine(2);
    await tick();
    expect(await load(step.id)).toMatchObject({ anchor_status: 'confirmed' });
    expect(hex((await load(step.id)).chain_tx_hash)).toBe(sentHash);
  });

  it('4. mined but not yet marked: confirmed from the receipt, with no new send', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();

    const broadcastThenCrash = async (raw) => {
      await fake.client.broadcast(raw);
      crash();
    };
    await expect(tick({ ...fake.client, broadcast: broadcastThenCrash })).rejects.toThrow(SIMULATED_CRASH);
    fake.control.mine(2);

    expect(await tick()).toMatchObject({ outcome: 'idle', reconciled: { confirmed: 1 } });
    expect((await load(step.id)).anchor_status).toBe('confirmed');
    expect(fake.control.records.sent).toHaveLength(1);
  });

  it('5a. nonce used by another transaction that anchored this very step: confirmed with that hash', async () => {
    const { fake, clock, tick } = setup();
    const step = await (await journey()).registration();
    await expect(tick({ ...fake.client, broadcast: crash })).rejects.toThrow(SIMULATED_CRASH);
    const storedHash = hex((await load(step.id)).chain_tx_hash);

    // The same call with nonce 0 but other fees, so another hash, is what got mined.
    const otherHash = await anchorDirectly(fake, await load(step.id), {
      nonce: 0,
      fees: { ...FEES, maxFeePerGas: 3n * GWEI, maxPriorityFeePerGas: 2n * GWEI },
    });
    expect(otherHash).not.toBe(storedHash);

    clock.advance(PAST_GRACE);
    expect((await tick()).reconciled.confirmed).toBe(1);
    const row = await load(step.id);
    expect(row.anchor_status).toBe('confirmed');
    expect(hex(row.chain_tx_hash)).toBe(otherHash);
  });

  it('5b. nonce used by something unrelated: back to pending with the attempt given back, then sent with a new nonce', async () => {
    const { fake, clock, tick } = setup();
    const step = await (await journey()).registration();
    await expect(tick({ ...fake.client, broadcast: crash })).rejects.toThrow(SIMULATED_CRASH);
    fake.control.sendByHand(); // takes nonce 0
    fake.control.mine(1);

    clock.advance(PAST_GRACE);
    const result = await tick();

    expect(result).toMatchObject({ outcome: 'sent', stepId: step.id, reconciled: { returnedToPending: 1 } });
    // 1 again, not 2: the lost attempt was given back before the new send counted one.
    expect(await load(step.id)).toMatchObject({ anchor_status: 'submitted', anchor_nonce: '1', anchor_attempts: 1, anchor_error: null });
  });

  it('a dropped transaction is resent with the same nonce, costs no attempt, and is anchored once', async () => {
    const { fake, clock, tick } = setup();
    const step = await (await journey()).registration();
    await tick();
    expect(fake.control.dropTransaction(hex((await load(step.id)).chain_tx_hash))).toBe(true);

    clock.advance(PAST_GRACE);
    expect((await tick()).reconciled.resent).toBe(1);
    fake.control.mine(2);
    await tick();

    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'confirmed', anchor_nonce: '0', anchor_attempts: 1 });
    const events = await fake.client.getLogs(buildAnchorCall(row).args[0], 0, await fake.client.getBlockNumber());
    expect(events).toHaveLength(1);
  });

  it('a mined revert (status 0) goes back to pending and is sent again', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    fake.control.revertNextMined('ConsignmentAlreadyExists');
    await tick();
    fake.control.mine(2);

    expect(await tick()).toMatchObject({ outcome: 'sent', reconciled: { returnedToPending: 1 } });
    // The reverted try still counts: its nonce was really used.
    expect(await load(step.id)).toMatchObject({ anchor_status: 'submitted', anchor_attempts: 2, anchor_nonce: '1' });
  });

  it('a mined revert at the maximum attempts fails the step, keeping the hash as evidence', async () => {
    const { fake, tick } = setup({ config: { ...CONFIG, maxAttempts: 1 } });
    const step = await (await journey()).registration();
    fake.control.revertNextMined('ConsignmentAlreadyExists');
    await tick();
    const revertedHash = (await load(step.id)).chain_tx_hash;
    fake.control.mine(2);

    expect((await tick()).reconciled.failed).toBe(1);
    const row = await load(step.id);
    expect(row.anchor_status).toBe('failed');
    expect(row.anchor_error).toMatch(/^MAX_ATTEMPTS: /);
    expect(row.chain_tx_hash.equals(revertedHash)).toBe(true);
  });
});

describe('runOnce: the error table', () => {
  it('ROLE_LOST stops the service: rows untouched, and later ticks touch nothing', async () => {
    const { fake, service } = setup();
    const step = await (await journey()).registration();
    fake.control.revokeRecorderRole();
    const worker = service();

    expect(await worker.runOnce()).toMatchObject({ outcome: 'stopped', code: 'ROLE_LOST' });
    expect(await load(step.id)).toMatchObject({ anchor_status: 'pending', anchor_attempts: 0, anchor_error: null });

    const callsBefore = fake.control.records.calls.length;
    expect((await worker.runOnce()).outcome).toBe('stopped');
    expect(fake.control.records.calls).toHaveLength(callsBefore);
  });

  it('INVALID_INPUT fails the step at once', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    fake.control.revertNextEstimate('InvalidInput', [3]);

    expect(await tick()).toMatchObject({ outcome: 'refused', code: 'INVALID_INPUT', reconciled: { failed: 1 } });
    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'failed', anchor_attempts: 1 });
    expect(row.anchor_error).toMatch(/^INVALID_INPUT:dataHash: /);
  });

  it('ALREADY_EXISTS with the same hash on-chain: confirmed from the event, with no send', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    const directHash = await anchorDirectly(fake, await load(step.id));

    expect(await tick()).toMatchObject({ outcome: 'refused', code: 'ALREADY_EXISTS', reconciled: { confirmed: 1 } });
    const row = await load(step.id);
    expect(row.anchor_status).toBe('confirmed');
    expect(hex(row.chain_tx_hash)).toBe(directHash);
    expect(fake.control.records.sent).toHaveLength(1); // only the direct one
  });

  it('ALREADY_EXISTS with another hash on-chain: failed as ID_ALREADY_ANCHORED', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    await anchorDirectly(fake, { ...(await load(step.id)), data_hash: randomBytes(32) });

    expect(await tick()).toMatchObject({ outcome: 'refused', code: 'ID_ALREADY_ANCHORED' });
    const row = await load(step.id);
    expect(row.anchor_status).toBe('failed');
    expect(row.anchor_error).toMatch(/^ID_ALREADY_ANCHORED: /);
  });

  it('searches the logs from near the step\'s received_at, not from the deployment block', async () => {
    const { fake, clock, tick } = setup();
    fake.control.mine(5000); // a chain well past its deployment, as Sepolia is
    const step = await (await journey()).registration({}, new Date(clock().getTime() - 60_000));
    await anchorDirectly(fake, await load(step.id));

    const searches = [];
    const recordingChain = {
      ...fake.client,
      getLogs: (id, from, to) => {
        searches.push({ from, to });
        return fake.client.getLogs(id, from, to);
      },
    };
    await tick(recordingChain);

    expect(searches).toHaveLength(1);
    const { from, to } = searches[0];
    // 60 seconds is 5 blocks, plus the safety margin.
    expect(from).toBe(to - 5 - LOG_SEARCH_MARGIN_BLOCKS);
    expect(from).toBeGreaterThan(DEPLOY_BLOCK + 3000);
    expect((await load(step.id)).anchor_status).toBe('confirmed');
  });

  it('INVALID_STAGE from None is retried, and failed at the maximum', async () => {
    const { tick } = setup({ config: { ...CONFIG, maxAttempts: 3 } });
    const j = await journey();
    // Confirmed in the database, but this fake chain has never seen it.
    await j.registration({
      anchor_status: 'confirmed',
      chain_tx_hash: randomBytes(32),
      block_number: '12047700',
      anchored_at: new Date(),
    });
    const handoff = await j.handoff();

    expect(await tick()).toMatchObject({ outcome: 'refused', code: 'INVALID_STAGE' });
    expect(await load(handoff.id)).toMatchObject({ anchor_status: 'pending', anchor_attempts: 1 });
    expect((await load(handoff.id)).anchor_error).toMatch(/^INVALID_STAGE:None: /);

    await tick();
    expect(await tick()).toMatchObject({ reconciled: { failed: 1 } });
    expect(await load(handoff.id)).toMatchObject({ anchor_status: 'failed', anchor_attempts: 3 });
  });

  it('INVALID_STAGE from any other stage fails the step at once', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    fake.control.revertNextEstimate('InvalidStage');

    await tick();
    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'failed', anchor_attempts: 1 });
    expect(row.anchor_error).toMatch(/^INVALID_STAGE:Purchased: /);
  });

  it('UNKNOWN is retried, counting an attempt', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    const estimateGas = async () => {
      throw chainError(new Error('something odd'));
    };

    expect(await tick({ ...fake.client, estimateGas })).toMatchObject({ outcome: 'refused', code: 'UNKNOWN' });
    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'pending', anchor_attempts: 1 });
    expect(row.anchor_error).toMatch(/^UNKNOWN: /);
  });

  it('stored data the contract would refuse (all-zero hash) fails without reaching the chain', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration({ data_hash: Buffer.alloc(32) });

    expect(await tick()).toMatchObject({ outcome: 'refused', code: 'BYTES32_INVALID' });
    expect(await load(step.id)).toMatchObject({ anchor_status: 'failed' });
    expect(fake.control.records.calls.map((c) => c.method)).not.toContain('estimateGas');
  });

  it.each([
    ['the network fee is above the cap', (c) => c.setFeeData({ maxFeePerGas: 60n * GWEI }), 'FEE_TOO_HIGH'],
    ['the wallet cannot pay', (c) => c.runOutOfFunds(), 'INSUFFICIENT_FUNDS'],
    ['someone else has a transaction waiting', (c) => c.sendByHand(), 'PENDING_TRANSACTIONS'],
  ])('pauses, changing nothing, when %s', async (_label, script, code) => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    script(fake.control);

    expect(await tick()).toMatchObject({ outcome: 'paused', code });
    expect(await load(step.id)).toMatchObject({ anchor_status: 'pending', anchor_attempts: 0, chain_tx_hash: null });
    expect(fake.control.records.signed).toEqual([]);
  });

  it('a broadcast refused for funds after the UPDATE is undone, with the attempt given back', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    const broadcast = async () => {
      throw chainError({ code: 'INSUFFICIENT_FUNDS' });
    };

    expect(await tick({ ...fake.client, broadcast })).toMatchObject({ outcome: 'paused', code: 'INSUFFICIENT_FUNDS' });
    const row = await load(step.id);
    expect(row).toMatchObject({ anchor_status: 'pending', anchor_attempts: 0, chain_tx_hash: null, anchor_nonce: null });
    expect(row.anchor_error).toMatch(/^INSUFFICIENT_FUNDS: /);
  });

  it('with both RPCs down, backs off and changes nothing at all', async () => {
    const { fake, tick } = setup();
    const j = await journey();
    await j.registration();
    await (await journey()).registration();
    await tick(); // one submitted, one pending
    const snapshot = async () => (await t.db.query('SELECT * FROM transactions ORDER BY id')).rows;
    const before = await snapshot();
    const sendsBefore = fake.control.records.sent.length;
    fake.control.failAllRpc();

    expect(await tick()).toMatchObject({ outcome: 'backoff', code: 'RPC_UNAVAILABLE' });
    expect(await snapshot()).toEqual(before);
    expect(fake.control.records.sent).toHaveLength(sendsBefore);
  });

  it('stores only our own error format in anchor_error, never provider text', async () => {
    const { fake, tick } = setup();
    const step = await (await journey()).registration();
    const estimateGas = async () => {
      throw chainError(new Error('boom at https://rpc.example/v3/secret-api-key'));
    };

    await tick({ ...fake.client, estimateGas });

    const { anchor_error } = await load(step.id);
    expect(anchor_error).toMatch(/^[A-Z_]+(:[A-Za-z]+)?: [a-z]/);
    expect(anchor_error).not.toContain('secret-api-key');
    expect(anchor_error).not.toContain('https://');
  });
});

describe('runOnce: the advisory lock', () => {
  it('answers busy, touching neither the chain nor the queue, while another process holds the lock', async () => {
    const pool = createPool(testDatabaseUrl());
    const holder = await tryAnchorLock(pool);
    try {
      expect(holder.acquired).toBe(true);
      const fake = createFakeChainClient();
      await (await journey()).registration();
      const service = createAnchorService({ db: t.db, chain: fake.client, config: CONFIG, lock: () => tryAnchorLock(pool) });

      expect(await service.runOnce()).toMatchObject({ outcome: 'busy' });
      expect(fake.control.records.calls).toEqual([]);
    } finally {
      await holder.release();
      await pool.end();
    }
  });

  it('releases the lock even when the tick throws', async () => {
    const { fake } = setup();
    await (await journey()).registration();
    let released = 0;
    const lock = async () => ({ acquired: true, isLost: () => false, release: async () => { released += 1; } });
    const service = createAnchorService({ db: t.db, chain: { ...fake.client, broadcast: crash }, config: CONFIG, lock, log: silentLog() });

    await expect(service.runOnce()).rejects.toThrow(SIMULATED_CRASH);
    expect(released).toBe(1);
  });
});
