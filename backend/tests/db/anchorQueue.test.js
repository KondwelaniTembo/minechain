import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { randomBytes } from 'node:crypto';
import { useTestDb, testDatabaseUrl } from './helpers.js';
import { insertUser, insertConsignment, insertTransaction, insertAlert } from './fixtures.js';
import { createPool, createDb } from '../../src/db.js';
import {
  nextEligibleStep,
  submittedSteps,
  tryAnchorLock,
  isConsignmentHeld,
  ANCHOR_LOCK_KEY,
} from '../../src/services/anchorQueue.js';
import { buildAnchorCall } from '../../src/services/anchorCall.js';

// Inside one test transaction now() is frozen, so every step would get the same
// received_at. Each step is therefore given its own, one minute after the previous one,
// unless the test sets it.
const BASE_TIME = Date.parse('2026-11-01T08:00:00Z');
let minute = 0;
const nextTime = () => new Date(BASE_TIME + (minute += 1) * 60_000);

// The anchoring states a step can be in, as overrides for insertTransaction.
const SUBMITTED = () => ({
  anchor_status: 'submitted',
  chain_tx_hash: randomBytes(32),
  anchor_nonce: '0',
  anchor_submitted_at: new Date(),
});
const CONFIRMED = () => ({
  anchor_status: 'confirmed',
  chain_tx_hash: randomBytes(32),
  block_number: '12047700',
  anchored_at: new Date(),
});
const FAILED = () => ({
  anchor_status: 'failed',
  anchor_error: 'INVALID_STAGE:Purchased: the step is not allowed from the consignment stage on-chain',
});

// received_at is not in the fixture's insert (the database sets it), so it is set here.
async function insertStep(db, overrides = {}, receivedAt = nextTime()) {
  const row = await insertTransaction(db, overrides);
  const { rows } = await db.query('UPDATE transactions SET received_at = $2 WHERE id = $1 RETURNING *', [row.id, receivedAt]);
  return rows[0];
}

// A consignment with its own miner, transporter and buyer, so each step has the right actor.
async function journey(db) {
  const miner = await insertUser(db, { role: 'miner', status: 'active' });
  const transporter = await insertUser(db, { role: 'transporter', status: 'active' });
  const buyer = await insertUser(db, { role: 'buyer', status: 'active' });
  const consignment = await insertConsignment(db, { miner_id: miner.id });
  const step = (type, actor, overrides = {}, receivedAt) =>
    insertStep(db, { consignment_id: consignment.id, actor_id: actor.id, type, ...overrides }, receivedAt);
  return {
    consignment,
    miner,
    users: [miner, transporter, buyer],
    registration: (overrides, at) => step('registration', miner, overrides, at),
    handoff: (overrides, at) => step('handoff', transporter, overrides, at),
    purchase: (overrides, at) => step('purchase', buyer, overrides, at),
  };
}

async function closeAlert(db, alert, status) {
  const officer = await insertUser(db, { role: 'officer', status: 'active' });
  await db.query(
    `UPDATE alerts SET status = $2, reviewed_by = $3, reviewed_at = now(), review_notes = 'Checked on site'
     WHERE id = $1`,
    [alert.id, status, officer.id],
  );
}

const confirm = (db, step) =>
  db.query(
    `UPDATE transactions SET anchor_status = 'confirmed', chain_tx_hash = $2, block_number = 12047700, anchored_at = now()
     WHERE id = $1`,
    [step.id, randomBytes(32)],
  );

describe('nextEligibleStep', () => {
  const t = useTestDb();

  it('returns null when nothing is queued', async () => {
    expect(await nextEligibleStep(t.db)).toBeNull();
  });

  it('returns exactly what buildAnchorCall needs, from the step, consignment and actor', async () => {
    const j = await journey(t.db);
    const registration = await j.registration();

    const row = await nextEligibleStep(t.db);

    expect(row).toMatchObject({
      id: registration.id,
      consignment_id: j.consignment.id,
      actor_id: j.miner.id,
      type: 'registration',
      weight_mg: '1500000',
      anchor_attempts: 0,
    });
    expect(row.data_hash.equals(registration.data_hash)).toBe(true);
    expect(row.chain_id.equals(j.consignment.chain_id)).toBe(true);
    expect(row.actor_ref.equals(j.miner.actor_ref)).toBe(true);
    // The row maps to a contract call without any conversion in between.
    expect(buildAnchorCall(row).functionName).toBe('registerConsignment');
  });

  it('returns the oldest eligible step first, across consignments', async () => {
    const newer = await (await journey(t.db)).registration({}, new Date('2026-11-01T10:00:00Z'));
    const older = await (await journey(t.db)).registration({}, new Date('2026-11-01T09:00:00Z'));

    expect((await nextEligibleStep(t.db)).id).toBe(older.id);
    expect(newer.id).not.toBe(older.id);
  });

  it('breaks a received_at tie by id, the same way every time', async () => {
    const same = new Date('2026-11-01T09:00:00Z');
    const a = await (await journey(t.db)).registration({}, same);
    const b = await (await journey(t.db)).registration({}, same);
    // PostgreSQL orders uuids byte by byte, which matches comparing their lowercase text.
    const [first] = [a.id, b.id].sort();

    expect((await nextEligibleStep(t.db)).id).toBe(first);
    expect((await nextEligibleStep(t.db)).id).toBe(first);
  });

  it('applies the tie-break inside one consignment too: of two handoffs, the lower id goes first', async () => {
    const j = await journey(t.db);
    await j.registration(CONFIRMED());
    const same = nextTime();
    const h1 = await j.handoff({}, same);
    const h2 = await j.handoff({}, same);
    const [first, second] = [h1.id, h2.id].sort();

    expect((await nextEligibleStep(t.db)).id).toBe(first);
    await confirm(t.db, { id: first });
    expect((await nextEligibleStep(t.db)).id).toBe(second);
  });

  describe('the step itself', () => {
    it.each([
      ['passed', true],
      ['cleared', true],
      ['flagged', false],
      ['rejected', false],
    ])('a %s step is eligible: %s', async (review_status, eligible) => {
      const step = await (await journey(t.db)).registration({ review_status });

      const row = await nextEligibleStep(t.db);

      expect(row?.id ?? null).toBe(eligible ? step.id : null);
    });

    it.each([
      ['submitted', SUBMITTED],
      ['confirmed', CONFIRMED],
      ['failed', FAILED],
    ])('a %s step is not offered again', async (_label, state) => {
      await (await journey(t.db)).registration(state());

      expect(await nextEligibleStep(t.db)).toBeNull();
    });
  });

  describe('holds', () => {
    it('skips a step with an open alert', async () => {
      const step = await (await journey(t.db)).registration();
      await insertAlert(t.db, { transaction_id: step.id });

      expect(await nextEligibleStep(t.db)).toBeNull();
    });

    it("skips every step of a consignment held by an alert on another of its steps", async () => {
      const j = await journey(t.db);
      await j.registration();
      // A later, flagged handoff: it is not "earlier", so only the hold can stop the
      // registration.
      const flagged = await j.handoff({ review_status: 'flagged' });
      await insertAlert(t.db, { transaction_id: flagged.id, type: 'handoff_order' });

      expect(await nextEligibleStep(t.db)).toBeNull();
    });

    it("does not hold other consignments", async () => {
      const held = await (await journey(t.db)).registration({}, new Date('2026-11-01T09:00:00Z'));
      await insertAlert(t.db, { transaction_id: held.id });
      const free = await (await journey(t.db)).registration({}, new Date('2026-11-01T10:00:00Z'));

      expect((await nextEligibleStep(t.db)).id).toBe(free.id);
    });

    it.each(['dismissed', 'reviewed'])('a %s alert releases the hold', async (status) => {
      const step = await (await journey(t.db)).registration();
      const alert = await insertAlert(t.db, { transaction_id: step.id });
      expect(await nextEligibleStep(t.db)).toBeNull();

      await closeAlert(t.db, alert, status);

      expect((await nextEligibleStep(t.db)).id).toBe(step.id);
    });

    it('stays held while any one of several alerts is open', async () => {
      const step = await (await journey(t.db)).registration();
      const first = await insertAlert(t.db, { transaction_id: step.id, type: 'quantity_discrepancy' });
      await insertAlert(t.db, { transaction_id: step.id, type: 'gps_zone' });

      await closeAlert(t.db, first, 'dismissed');

      expect(await nextEligibleStep(t.db)).toBeNull();
    });
  });

  describe('order within a consignment', () => {
    it('a handoff waits while its registration is pending: the registration is offered instead', async () => {
      const j = await journey(t.db);
      const registration = await j.registration();
      await j.handoff();

      expect((await nextEligibleStep(t.db)).id).toBe(registration.id);
    });

    it('a handoff waits while its registration is submitted, and goes once it is confirmed', async () => {
      const j = await journey(t.db);
      const registration = await j.registration(SUBMITTED());
      const handoff = await j.handoff();
      expect(await nextEligibleStep(t.db)).toBeNull();

      await confirm(t.db, registration);

      expect((await nextEligibleStep(t.db)).id).toBe(handoff.id);
    });

    it('a purchase waits for its handoff to be confirmed', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      const handoff = await j.handoff(SUBMITTED());
      const purchase = await j.purchase();
      expect(await nextEligibleStep(t.db)).toBeNull();

      await confirm(t.db, handoff);

      expect((await nextEligibleStep(t.db)).id).toBe(purchase.id);
    });

    it('a failed earlier step blocks every later step', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      await j.handoff(FAILED());
      await j.handoff();

      expect(await nextEligibleStep(t.db)).toBeNull();
    });

    it('a rejected earlier step does not block', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      await j.handoff({ review_status: 'rejected' });
      const later = await j.handoff();

      expect((await nextEligibleStep(t.db)).id).toBe(later.id);
    });

    it('a flagged earlier step blocks, even with no open alert, since it may yet be cleared', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      await j.handoff({ review_status: 'flagged' });
      await j.handoff();

      expect(await nextEligibleStep(t.db)).toBeNull();
    });

    it('a cleared earlier step goes first, then the one after it', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      const cleared = await j.handoff({ review_status: 'cleared' });
      await j.handoff();

      expect((await nextEligibleStep(t.db)).id).toBe(cleared.id);
    });

    it('a later step does not block an earlier one', async () => {
      const j = await journey(t.db);
      await j.registration(CONFIRMED());
      const first = await j.handoff();
      await j.handoff(FAILED());

      expect((await nextEligibleStep(t.db)).id).toBe(first.id);
    });

    it('known limit: a handoff whose registration was rejected stays pending', async () => {
      // Rule 2 ignores the rejected registration; rule 3 still finds no confirmed one.
      const j = await journey(t.db);
      await j.registration({ review_status: 'rejected' });
      await j.handoff();

      expect(await nextEligibleStep(t.db)).toBeNull();
    });
  });

});

// The duplicate exception to D3 (decisions.md, 9 Nov): a flagged duplicate of an accepted
// registration must not stop the original consignment, through the hold or the gate.
describe('duplicates of an accepted registration', () => {
  const t = useTestDb();

  // A flagged registration on the same consignment with its open duplicate_consignment alert,
  // as sync stores one.
  async function duplicateOf(j, receivedAt) {
    const duplicate = await j.registration({ review_status: 'flagged' }, receivedAt);
    await insertAlert(t.db, { transaction_id: duplicate.id, type: 'duplicate_consignment', severity: 'high', details: {} });
    return duplicate;
  }

  it('lets the original registration, handoff and purchase anchor in order, the duplicate received before the handoff', async () => {
    const j = await journey(t.db);
    const registration = await j.registration();
    const duplicate = await duplicateOf(j); // received after the registration...
    const handoff = await j.handoff(); // ...and before the handoff, so the gate meets it
    const purchase = await j.purchase();

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(false);
    expect((await nextEligibleStep(t.db)).id).toBe(registration.id);
    await confirm(t.db, registration);
    expect((await nextEligibleStep(t.db)).id).toBe(handoff.id);
    await confirm(t.db, handoff);
    expect((await nextEligibleStep(t.db)).id).toBe(purchase.id);
    await confirm(t.db, purchase);

    // The duplicate itself is never offered, before or after.
    expect(await nextEligibleStep(t.db)).toBeNull();
    const { rows } = await t.db.query('SELECT review_status, anchor_status FROM transactions WHERE id = $1', [duplicate.id]);
    expect(rows[0]).toEqual({ review_status: 'flagged', anchor_status: 'pending' });
  });

  it('also lets the original anchor when the duplicate arrives after its handoff', async () => {
    const j = await journey(t.db);
    await j.registration({ anchor_status: 'confirmed', chain_tx_hash: randomBytes(32), block_number: '12047700', anchored_at: new Date() });
    const handoff = await j.handoff();
    await duplicateOf(j);

    expect((await nextEligibleStep(t.db)).id).toBe(handoff.id);
  });

  it('never offers the duplicate, even when it is the only pending step', async () => {
    const j = await journey(t.db);
    await j.registration({ anchor_status: 'confirmed', chain_tx_hash: randomBytes(32), block_number: '12047700', anchored_at: new Date() });
    await duplicateOf(j);

    expect(await nextEligibleStep(t.db)).toBeNull();
  });

  it('still holds when the original registration is not accepted itself', async () => {
    // The original was flagged for a bad signature, and an officer has rejected it. With no
    // accepted registration there is no genuine consignment to protect.
    const j = await journey(t.db);
    await j.registration({ review_status: 'rejected' });
    await duplicateOf(j);

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(true);
  });

  it('still holds while the original is flagged too, and stops holding once the original is cleared', async () => {
    const j = await journey(t.db);
    const original = await j.registration({ review_status: 'flagged' });
    const signatureAlert = await insertAlert(t.db, { transaction_id: original.id, type: 'invalid_signature', severity: 'high', details: {} });
    await duplicateOf(j);
    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(true);

    // The officer dismisses the original's alert, which clears it (as the review service will).
    await closeAlert(t.db, signatureAlert, 'dismissed');
    await t.db.query("UPDATE transactions SET review_status = 'cleared' WHERE id = $1", [original.id]);

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(false);
    expect((await nextEligibleStep(t.db)).id).toBe(original.id);
  });

  it('still holds for a quantity alert on the consignment', async () => {
    const j = await journey(t.db);
    await j.registration({ anchor_status: 'confirmed', chain_tx_hash: randomBytes(32), block_number: '12047700', anchored_at: new Date() });
    await j.handoff();
    // A later, flagged handoff: being later, it is not in the gate's way, so only the hold
    // can stop the first handoff.
    const flagged = await j.handoff({ review_status: 'flagged' });
    await insertAlert(t.db, { transaction_id: flagged.id, type: 'quantity_discrepancy' });

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(true);
    expect(await nextEligibleStep(t.db)).toBeNull();
  });

  it('excuses every alert on the duplicate step: an off-site copy with a bad signature does not hold the original', async () => {
    // Sync runs every check on the copy, so it can carry gps_zone and invalid_signature
    // alerts as well as duplicate_consignment. None of them may freeze the original.
    const j = await journey(t.db);
    const registration = await j.registration();
    const duplicate = await duplicateOf(j);
    await insertAlert(t.db, { transaction_id: duplicate.id, type: 'gps_zone', details: {} });
    await insertAlert(t.db, { transaction_id: duplicate.id, type: 'invalid_signature', severity: 'high', details: {} });
    const handoff = await j.handoff();

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(false);
    expect((await nextEligibleStep(t.db)).id).toBe(registration.id);
    await confirm(t.db, registration);
    expect((await nextEligibleStep(t.db)).id).toBe(handoff.id);
  });

  it("still holds for a GPS alert on the original consignment's own later step", async () => {
    const j = await journey(t.db);
    // Pending, so it would be offered if the consignment were not held.
    await j.registration();
    await duplicateOf(j);
    // Not the duplicate: a step of the consignment's genuine custody chain, received later,
    // so only the hold (not the gate) can stop the registration.
    const handoff = await j.handoff({ review_status: 'flagged' });
    await insertAlert(t.db, { transaction_id: handoff.id, type: 'gps_zone', details: {} });

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(true);
    expect(await nextEligibleStep(t.db)).toBeNull();
  });

  it('still holds for a duplicate_consignment alert on anything but a flagged registration', async () => {
    const j = await journey(t.db);
    await j.registration();
    const handoff = await j.handoff({ review_status: 'flagged' });
    await insertAlert(t.db, { transaction_id: handoff.id, type: 'duplicate_consignment', details: {} });

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(true);
  });

  it('is released for good once the duplicate alert is closed, as any alert is', async () => {
    const j = await journey(t.db);
    await j.registration({ review_status: 'rejected' });
    const duplicate = await j.registration({ review_status: 'flagged' });
    const alert = await insertAlert(t.db, { transaction_id: duplicate.id, type: 'duplicate_consignment', details: {} });

    await closeAlert(t.db, alert, 'reviewed');

    expect(await isConsignmentHeld(t.db, j.consignment.id)).toBe(false);
  });
});

describe('submittedSteps', () => {
  const t = useTestDb();

  it('returns only submitted steps, oldest nonce first, with what reconciling needs', async () => {
    const a = await (await journey(t.db)).registration({ ...SUBMITTED(), anchor_nonce: '7' });
    const b = await (await journey(t.db)).registration({ ...SUBMITTED(), anchor_nonce: '3' });
    await (await journey(t.db)).registration();
    await (await journey(t.db)).registration(CONFIRMED());
    await (await journey(t.db)).registration(FAILED());

    const rows = await submittedSteps(t.db);

    expect(rows.map((r) => r.id)).toEqual([b.id, a.id]);
    expect(rows[0].anchor_nonce).toBe('3');
    expect(rows[0].chain_tx_hash.equals(b.chain_tx_hash)).toBe(true);
    expect(rows[0].anchor_submitted_at).toBeInstanceOf(Date);
    expect(rows[0].chain_id).toHaveLength(32);
    expect(rows[0].actor_ref).toHaveLength(32);
  });

  it('includes a held step: what was sent may be mined whatever the alert says now', async () => {
    const step = await (await journey(t.db)).registration(SUBMITTED());
    await insertAlert(t.db, { transaction_id: step.id });

    expect((await submittedSteps(t.db)).map((r) => r.id)).toEqual([step.id]);
  });

  it('keeps a nonce above 2^53 exact, as text', async () => {
    await (await journey(t.db)).registration({ ...SUBMITTED(), anchor_nonce: '9007199254740993' });

    expect((await submittedSteps(t.db))[0].anchor_nonce).toBe('9007199254740993');
  });
});

// These need two real connections, so they cannot use the rolled-back test transaction:
// a second connection cannot see uncommitted rows at all, and would "skip" them for the
// wrong reason. The rows are committed, dated long before anything else in the database
// so they come first, and deleted in finally.
describe('across connections', () => {
  let pool;
  let db;

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
    db = createDb(pool);
  });

  afterAll(async () => {
    await db.close();
  });

  // Returns the two steps and every row made for them, so finally can delete exactly those.
  async function commitTwoRegistrations() {
    return db.transaction(async (tx) => {
      const j1 = await journey(tx);
      const j2 = await journey(tx);
      const steps = [
        await j1.registration({}, new Date('2000-01-01T00:00:00Z')),
        await j2.registration({}, new Date('2000-01-01T00:00:01Z')),
      ];
      return {
        steps,
        consignmentIds: [j1.consignment.id, j2.consignment.id],
        userIds: [...j1.users, ...j2.users].map((u) => u.id),
      };
    });
  }

  // Children first, because every foreign key here is ON DELETE RESTRICT.
  async function removeCommitted({ consignmentIds, userIds }) {
    await db.query('DELETE FROM transactions WHERE consignment_id = ANY($1::uuid[])', [consignmentIds]);
    await db.query('DELETE FROM consignments WHERE id = ANY($1::uuid[])', [consignmentIds]);
    await db.query('DELETE FROM users WHERE id = ANY($1::uuid[])', [userIds]);
  }

  it('SKIP LOCKED: a second connection passes over the row the first one holds', async () => {
    const committed = await commitTwoRegistrations();
    const { steps } = committed;
    const first = await pool.connect();
    const second = await pool.connect();
    try {
      await first.query('BEGIN');
      await second.query('BEGIN');

      const a = await nextEligibleStep(createDb(first, { inTransaction: true }));
      const b = await nextEligibleStep(createDb(second, { inTransaction: true }));

      expect(a.id).toBe(steps[0].id);
      // Not null and not the same row: it saw the queue and skipped the locked one.
      expect(b.id).toBe(steps[1].id);

      // Once the first connection's transaction ends, its row is free again.
      await first.query('ROLLBACK');
      await second.query('ROLLBACK');
      await second.query('BEGIN');
      expect((await nextEligibleStep(createDb(second, { inTransaction: true }))).id).toBe(steps[0].id);
    } finally {
      await first.query('ROLLBACK').catch(() => {});
      await second.query('ROLLBACK').catch(() => {});
      first.release();
      second.release();
      await removeCommitted(committed);
    }
  });

  describe('tryAnchorLock', () => {
    const checkedOut = () => pool.totalCount - pool.idleCount;

    it('lets one holder in and tells a second one it is busy', async () => {
      const holder = await tryAnchorLock(pool);
      let other;
      try {
        expect(holder.acquired).toBe(true);
        expect(holder.isLost()).toBe(false);

        other = await tryAnchorLock(pool);

        expect(other.acquired).toBe(false);
        // The busy attempt handed its connection straight back; only the holder keeps one.
        expect(checkedOut()).toBe(1);
      } finally {
        await other?.release();
        await holder.release();
      }
      expect(checkedOut()).toBe(0);
    });

    it('can be taken again once released', async () => {
      const first = await tryAnchorLock(pool);
      await first.release();

      const second = await tryAnchorLock(pool);
      try {
        expect(second.acquired).toBe(true);
      } finally {
        await second.release();
      }
    });

    it('shows in pg_locks under the fixed key while held, and not after release', async () => {
      const countLocks = async () =>
        (
          await db.query(
            `SELECT count(*)::int AS n FROM pg_locks
             WHERE locktype = 'advisory' AND granted AND objsubid = 1
               -- A bigint key is stored split in two: high 32 bits in classid, low in objid.
               AND ((classid::bigint << 32) | objid::bigint) = $1::bigint`,
            [ANCHOR_LOCK_KEY],
          )
        ).rows[0].n;

      const holder = await tryAnchorLock(pool);
      try {
        expect(await countLocks()).toBe(1);
      } finally {
        await holder.release();
      }
      expect(await countLocks()).toBe(0);
    });

    it('release is safe to call twice', async () => {
      const holder = await tryAnchorLock(pool);
      await holder.release();
      await expect(holder.release()).resolves.toBeUndefined();
    });
  });
});
