import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { CHECK_PARALLELISM, createConsignmentService, mapWithLimit } from '../src/services/consignmentService.js';
import { AppError } from '../src/errors.js';
import { DEPLOY_BLOCK } from '../src/chain/mineChainAbi.js';
import { FAKE_CONTRACT_ADDRESS } from './fakes/fakeChainClient.js';

// The service's shape without a database: a fake db that knows when a transaction is open,
// and a reader that fails the test if it is called while one is. The DB tests cannot show
// this, because each of them runs inside one outer test transaction.

const VECTORS = JSON.parse(readFileSync(new URL('../../docs/signing-vectors.json', import.meta.url), 'utf8'));
const REG = VECTORS.positive.find((v) => v.name === 'registration');
const BLOCK = DEPLOY_BLOCK + 50;
const VIEWER = Object.freeze({ id: '3f2b6c1e-0000-4000-8000-0000000000d1', role: 'officer' });

// n confirmed steps with genuine evidence, so the check reaches the chain.
function confirmedSteps(n) {
  return Array.from({ length: n }, (_, i) => ({
    id: `7b000000-0000-4000-8000-00000000000${i}`,
    type: 'registration',
    actor_id: REG.fields.actorId,
    actor_role: 'miner',
    actor_username: 'miner-user',
    idempotency_key: REG.fields.stepId,
    qr_code: REG.fields.qrCode,
    mineral_type: 'gold',
    weight_mg: REG.fields.weightMg,
    latitude: REG.fields.latitude,
    longitude: REG.fields.longitude,
    zone_name: 'Campus Zone',
    captured_at: REG.fields.capturedAt,
    received_at: new Date('2026-11-10T08:05:00.000Z'),
    signed_payload: REG.payload,
    signature: Buffer.from(REG.signature, 'base64'),
    signer_public_key: Buffer.from(REG.publicKey, 'base64'),
    data_hash: Buffer.from(REG.anchorHash, 'hex'),
    hash_version: 1,
    review_status: 'passed',
    anchor_status: 'confirmed',
    chain_tx_hash: Buffer.alloc(32, 0xc0 + i),
    block_number: String(BLOCK),
    chain_id: Buffer.alloc(32, 0x11),
    actor_ref: Buffer.alloc(32, 0xaa),
  }));
}

const CONSIGNMENT = Object.freeze({
  id: '9a000000-0000-4000-8000-000000000001',
  qr_code: REG.fields.qrCode,
  mineral_type: 'gold',
  stage: 'registered',
  held: false,
  has_accepted_purchase: false,
  has_own_handoff: false,
});

// Answers the service's statements by what they contain, and records what ran inside which
// transaction. heldAfterInsert: what the held re-read answers.
function fakeDb({ consignment = CONSIGNMENT, steps = [], heldAfterInsert = true } = {}) {
  const state = { open: false, transactions: [], log: [] };
  function query(text, params) {
    // transaction: 1 for the first transaction, 2 for the second, 0 outside any.
    state.log.push({ text, params, inTransaction: state.open, transaction: state.open ? state.transactions.length : 0 });
    // Checked in this order on purpose: the HELD fragment itself contains "FROM alerts a".
    if (text.includes('WHERE c.qr_code = $1')) return { rows: consignment ? [consignment] : [] };
    if (text.includes('ORDER BY t.received_at, t.id')) return { rows: steps };
    if (text.includes('INSERT INTO alerts')) return { rows: [], rowCount: 1 };
    if (text.includes('FOR UPDATE')) return { rows: [{ id: params[0] }] };
    if (text.includes('AS held')) return { rows: [{ held: heldAfterInsert }] };
    if (text.includes('FROM alerts a')) return { rows: [] };
    throw new Error(`unexpected statement: ${text}`);
  }
  const db = {
    query: async (text, params = []) => query(text, params),
    async transaction(fn, { isolation = 'read committed' } = {}) {
      if (state.open) throw new Error('nested transaction');
      state.open = true;
      state.transactions.push(isolation);
      try {
        return await fn(db);
      } finally {
        state.open = false;
      }
    },
  };
  return { db, state };
}

// A reader that fails if a transaction is open, and counts how many calls run at once.
// receipt null with the node far ahead: every check becomes a TX_NOT_FOUND mismatch;
// with the node behind: chain_unavailable.
function watchingReader(dbState, { latest = BLOCK - 10 } = {}) {
  const stats = { calls: [], inFlight: 0, maxInFlight: 0 };
  async function call(method, answer) {
    if (dbState.open) throw new Error(`${method} called with a database transaction open`);
    stats.calls.push(method);
    stats.inFlight += 1;
    stats.maxInFlight = Math.max(stats.maxInFlight, stats.inFlight);
    await new Promise((resolve) => setTimeout(resolve, 5));
    stats.inFlight -= 1;
    return answer;
  }
  const reader = {
    contractAddress: FAKE_CONTRACT_ADDRESS,
    getReceipt: () => call('getReceipt', null),
    getBlockNumber: () => call('getBlockNumber', latest),
    close() {},
  };
  return { reader, stats };
}

describe('mapWithLimit', () => {
  it('keeps the order of the items and never runs more than the limit at once', async () => {
    let running = 0;
    let most = 0;
    const out = await mapWithLimit([5, 1, 4, 2, 3], 2, async (n) => {
      running += 1;
      most = Math.max(most, running);
      await new Promise((resolve) => setTimeout(resolve, n));
      running -= 1;
      return n * 10;
    });

    expect(out).toEqual([50, 10, 40, 20, 30]);
    expect(most).toBe(2);
  });

  it('handles an empty list', async () => {
    await expect(mapWithLimit([], 3, async () => 1)).resolves.toEqual([]);
  });
});

describe('createConsignmentService: phases', () => {
  it('reads in one REPEATABLE READ snapshot, and no transaction is open during any chain call', async () => {
    const { db, state } = fakeDb({ steps: confirmedSteps(4) });
    const { reader, stats } = watchingReader(state);
    const service = createConsignmentService({ db, chainReader: reader, confirmations: 2 });

    const body = await service.viewByQr(VIEWER, CONSIGNMENT.qr_code);

    // The reader would have thrown had a transaction been open.
    expect(stats.calls.length).toBeGreaterThan(0);
    expect(state.transactions).toEqual(['repeatable read']);
    expect(body.steps.map((s) => s.check.result)).toEqual(Array(4).fill('chain_unavailable'));
  });

  it(`asks the chain for at most ${CHECK_PARALLELISM} steps at once`, async () => {
    const { db, state } = fakeDb({ steps: confirmedSteps(7) });
    const { reader, stats } = watchingReader(state);
    const service = createConsignmentService({ db, chainReader: reader, confirmations: 2 });

    await service.viewByQr(VIEWER, CONSIGNMENT.qr_code);

    // Each step makes two calls one after the other (receipt, then block number), so the
    // number in flight equals the number of steps being checked.
    expect(stats.calls.filter((m) => m === 'getReceipt')).toHaveLength(7);
    expect(stats.maxInFlight).toBe(CHECK_PARALLELISM);
  });

  it('raises the alerts after every chain call, in a second short transaction, and shows held from the re-read', async () => {
    const { db, state } = fakeDb({ steps: confirmedSteps(2), heldAfterInsert: true });
    const { reader } = watchingReader(state, { latest: BLOCK + 100 });
    const service = createConsignmentService({ db, chainReader: reader, confirmations: 2 });

    const body = await service.viewByQr(VIEWER, CONSIGNMENT.qr_code);

    expect(state.transactions).toEqual(['repeatable read', 'read committed']);
    const inserts = state.log.filter((q) => q.text.includes('INSERT INTO alerts'));
    expect(inserts).toHaveLength(2);
    for (const insert of inserts) expect(insert.inTransaction).toBe(true);
    expect(JSON.parse(inserts[0].params[1])).toEqual({
      source: 'verification',
      fields: ['chain_tx_hash'],
      chainTxHash: `0x${'c0'.repeat(32)}`,
    });
    // The second transaction: the consignment lock first, then the inserts, then held and
    // (for an officer) the alerts read again, so the new alert shows.
    const write = state.log.filter((q) => q.transaction === 2).map((q) => q.text);
    expect(write).toHaveLength(5);
    expect(write[0]).toContain('FOR UPDATE');
    expect(write[1]).toContain('INSERT INTO alerts');
    expect(write[2]).toContain('INSERT INTO alerts');
    expect(write[3]).toContain('AS held');
    expect(write[4]).toContain('FROM alerts a');
    // Nothing is written outside a transaction.
    expect(state.log.filter((q) => !q.inTransaction)).toEqual([]);
    expect(body.consignment.held).toBe(true);
  });

  it('writes nothing when no step mismatches', async () => {
    const { db, state } = fakeDb({ steps: confirmedSteps(2) });
    const { reader } = watchingReader(state);

    await createConsignmentService({ db, chainReader: reader, confirmations: 2 }).viewByQr(VIEWER, CONSIGNMENT.qr_code);

    expect(state.transactions).toEqual(['repeatable read']);
    expect(state.log.some((q) => q.text.includes('INSERT'))).toBe(false);
  });

  it('with no reader: every confirmed step is chain_unavailable and nothing is written', async () => {
    const { db, state } = fakeDb({ steps: confirmedSteps(2) });

    const body = await createConsignmentService({ db, chainReader: null, confirmations: 2 }).viewByQr(VIEWER, CONSIGNMENT.qr_code);

    expect(body.steps.map((s) => s.check.result)).toEqual(['chain_unavailable', 'chain_unavailable']);
    expect(state.transactions).toEqual(['repeatable read']);
  });
});

describe('createConsignmentService: not found', () => {
  async function refusal(promise) {
    const err = await promise.then(() => null, (e) => e);
    expect(err).toBeInstanceOf(AppError);
    return { status: err.status, code: err.code, message: err.message, details: err.details };
  }

  it('an unknown code and a consignment the viewer may not see get the identical 404, with no chain call', async () => {
    const unknown = fakeDb({ consignment: null });
    const hidden = fakeDb({ consignment: { ...CONSIGNMENT, stage: 'registered' }, steps: confirmedSteps(2) });
    const { reader, stats } = watchingReader(hidden.state);
    const buyer = { id: '3f2b6c1e-0000-4000-8000-0000000000c1', role: 'buyer' };

    const a = await refusal(createConsignmentService({ db: unknown.db, chainReader: reader, confirmations: 2 }).viewByQr(buyer, 'MC-NOPE-0001'));
    const b = await refusal(createConsignmentService({ db: hidden.db, chainReader: reader, confirmations: 2 }).viewByQr(buyer, CONSIGNMENT.qr_code));

    expect(a).toEqual({ status: 404, code: 'CONSIGNMENT_NOT_FOUND', message: 'No consignment has this QR code.', details: undefined });
    expect(b).toEqual(a);
    expect(stats.calls).toEqual([]);
    expect(hidden.state.log.some((q) => q.text.includes('INSERT'))).toBe(false);
  });
});
