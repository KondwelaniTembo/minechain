import { randomBytes, randomUUID } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import {
  MISSING_ID,
  insertUser,
  insertZone,
  insertTransaction,
  transactionInsert,
  transactionParents,
} from './fixtures.js';

const t = useTestDb();

const tx = (overrides) => insertTransaction(t.db, overrides);

async function expectTxRejected(overrides, code) {
  const parents = await transactionParents(t.db, overrides);
  const { text, params } = transactionInsert({ ...overrides, ...parents });
  return expectPgError(t.db, text, params, code);
}

// Every reject test names the rule expected to fire, so it cannot pass because a different
// rule happened to reject the row.
async function expectCheckFails(overrides, constraint) {
  const err = await expectTxRejected(overrides, PG_ERROR.CHECK_VIOLATION);
  expect(err.constraint).toBe(constraint);
}

// Anchoring states that satisfy every rule, used as starting points.
const submitted = () => ({ anchor_status: 'submitted', chain_tx_hash: randomBytes(32), anchor_attempts: 1 });
const confirmed = () => ({
  ...submitted(),
  anchor_status: 'confirmed',
  block_number: '12050000',
  anchored_at: new Date(),
});

// Only the columns that have no default, so the defaults can be seen. Written out in full,
// like the fixtures.
const INSERT_REQUIRED_ONLY = `
  INSERT INTO transactions (consignment_id, actor_id, type, idempotency_key, weight_mg,
                            latitude, longitude, captured_at, signed_payload, signature,
                            signer_public_key, data_hash, review_status)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
  RETURNING *`;
const INSERT_WITH_OLD_UPDATED_AT = `
  INSERT INTO transactions (consignment_id, actor_id, type, idempotency_key, weight_mg,
                            latitude, longitude, captured_at, signed_payload, signature,
                            signer_public_key, data_hash, review_status, updated_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
  RETURNING *`;

function requiredValues(parents) {
  return [
    parents.consignment_id, parents.actor_id, 'handoff', randomUUID(), '1000', -13.45, 25.82,
    new Date('2026-11-01T08:00:00Z'), '{"step":"handoff"}', randomBytes(70), randomBytes(91),
    randomBytes(32), 'passed',
  ];
}

describe('transactions table', () => {
  it('fills in received_at, hash_version, anchor_status and anchor_attempts', async () => {
    const parents = await transactionParents(t.db);

    const { rows } = await t.db.query(INSERT_REQUIRED_ONLY, requiredValues(parents));

    expect(rows[0].received_at).toBeInstanceOf(Date);
    expect(rows[0].hash_version).toBe(1);
    expect(rows[0].anchor_status).toBe('pending');
    expect(rows[0].anchor_attempts).toBe(0);
    expect(rows[0].zone_id).toBeNull();
  });

  describe('type', () => {
    it.each(['registration', 'handoff', 'purchase'])('accepts %s', async (type) => {
      expect((await tx({ type })).type).toBe(type);
    });

    it('rejects an unknown type', async () => {
      await expectCheckFails({ type: 'export' }, 'transactions_type_valid');
    });
  });

  describe('idempotency key', () => {
    it('rejects the same key twice from the same actor', async () => {
      const first = await tx({ type: 'handoff' });

      const err = await expectTxRejected(
        {
          consignment_id: first.consignment_id,
          actor_id: first.actor_id,
          idempotency_key: first.idempotency_key,
          type: 'handoff',
        },
        PG_ERROR.UNIQUE_VIOLATION,
      );
      expect(err.constraint).toBe('transactions_idempotency_key_unique');
    });

    it('accepts the same key from a different actor', async () => {
      const first = await tx({ type: 'handoff' });
      const other = await insertUser(t.db, { role: 'transporter', status: 'active' });

      const second = await tx({
        consignment_id: first.consignment_id,
        actor_id: other.id,
        idempotency_key: first.idempotency_key,
        type: 'handoff',
      });

      expect(second.idempotency_key).toBe(first.idempotency_key);
    });

    it('accepts a different key from the same actor', async () => {
      const first = await tx({ type: 'handoff' });

      const second = await tx({ consignment_id: first.consignment_id, actor_id: first.actor_id, type: 'handoff' });

      expect(second.idempotency_key).not.toBe(first.idempotency_key);
    });

    it('absorbs a retried sync of the same signed record without a second row', async () => {
      const parents = await transactionParents(t.db);
      // The phone sends exactly the same record both times; only the network failed.
      const record = {
        ...parents,
        type: 'handoff',
        idempotency_key: randomUUID(),
        signed_payload: '{"step":"handoff","n":1}',
        signature: randomBytes(70),
        signer_public_key: randomBytes(91),
        data_hash: randomBytes(32),
      };
      const sync = () => {
        const { text, params } = transactionInsert(record, { onConflictDoNothing: true });
        return t.db.query(text, params);
      };

      const firstSend = await sync();
      const retry = await sync();

      expect(firstSend.rowCount).toBe(1);
      expect(retry.rowCount).toBe(0); // nothing inserted, and no error
      const { rows } = await t.db.query(
        'SELECT data_hash FROM transactions WHERE actor_id = $1 AND idempotency_key = $2',
        [record.actor_id, record.idempotency_key],
      );
      expect(rows).toHaveLength(1);
      // The service compares hashes: equal means a true retry (200), different means 409.
      expect(Buffer.compare(rows[0].data_hash, record.data_hash)).toBe(0);
    });
  });

  describe('weight_mg', () => {
    it.each([
      ['1 mg', '1'],
      ['the largest bigint', '9223372036854775807'],
    ])('accepts %s and returns it as a string', async (_label, weight_mg) => {
      expect((await tx({ weight_mg })).weight_mg).toBe(weight_mg);
    });

    it.each([['0', '0'], ['a negative weight', '-5']])('rejects %s', async (_label, weight_mg) => {
      await expectCheckFails({ weight_mg }, 'transactions_weight_positive');
    });
  });

  describe('latitude and longitude', () => {
    it.each([
      [-90, -180, '-90.000000', '-180.000000'],
      [90, 180, '90.000000', '180.000000'],
    ])('accepts the limits %d, %d', async (latitude, longitude, latText, lngText) => {
      const row = await tx({ latitude, longitude });

      // pg returns numeric as a string, so no precision is lost on the way to JavaScript.
      expect(row.latitude).toBe(latText);
      expect(row.longitude).toBe(lngText);
    });

    it('rounds a 7th decimal place silently, which the API must refuse to allow', async () => {
      const row = await tx({ longitude: 25.1234567 });

      expect(row.longitude).toBe('25.123457');
    });

    it.each([
      ['latitude 90.000001', { latitude: 90.000001 }, 'transactions_latitude_range'],
      ['longitude -180.5', { longitude: -180.5 }, 'transactions_longitude_range'],
    ])('rejects %s', async (_label, overrides, constraint) => {
      await expectCheckFails(overrides, constraint);
    });

    it('rejects a value too large for numeric(9,6) before any CHECK runs', async () => {
      await expectTxRejected({ latitude: 1000 }, PG_ERROR.NUMERIC_OUT_OF_RANGE);
    });
  });

  describe('signed evidence', () => {
    it('keeps signed_payload byte for byte, including key order and spacing', async () => {
      const exact = '{"weightMg":"1500000",  "lat":-13.450000,"a":[1.50, 2]}\n';

      expect((await tx({ signed_payload: exact })).signed_payload).toBe(exact);
    });

    it('rejects a blank signed_payload', async () => {
      await expectCheckFails({ signed_payload: '   ' }, 'transactions_signed_payload_not_blank');
    });

    it.each([64, 70, 72])('accepts a %i-byte signature', async (length) => {
      expect((await tx({ signature: randomBytes(length) })).signature).toHaveLength(length);
    });

    it.each([7, 73])('rejects a %i-byte signature', async (length) => {
      await expectCheckFails({ signature: randomBytes(length) }, 'transactions_signature_der_length');
    });

    it('accepts a 91-byte signer key and stores it unchanged', async () => {
      const key = randomBytes(91);

      expect(Buffer.compare((await tx({ signer_public_key: key })).signer_public_key, key)).toBe(0);
    });

    it('rejects a signer key of the wrong length', async () => {
      await expectCheckFails({ signer_public_key: randomBytes(65) }, 'transactions_signer_key_p256_spki');
    });

    it('accepts a 32-byte data_hash and hash_version 2', async () => {
      const row = await tx({ data_hash: randomBytes(32), hash_version: 2 });

      expect(row.data_hash).toHaveLength(32);
      expect(row.hash_version).toBe(2);
    });

    it('rejects a 31-byte data_hash', async () => {
      await expectCheckFails({ data_hash: randomBytes(31) }, 'transactions_data_hash_32_bytes');
    });

    it('rejects hash_version 0', async () => {
      await expectCheckFails({ hash_version: 0 }, 'transactions_hash_version_positive');
    });
  });

  describe('review_status', () => {
    it.each(['passed', 'flagged', 'cleared', 'rejected'])('accepts %s while pending', async (review_status) => {
      expect((await tx({ review_status })).review_status).toBe(review_status);
    });

    it('rejects an unknown review status', async () => {
      await expectCheckFails({ review_status: 'approved' }, 'transactions_review_status_valid');
    });
  });

  describe('anchor_status', () => {
    it.each([
      ['submitted with a chain hash', () => submitted()],
      ['confirmed with hash, block and time', () => confirmed()],
      ['failed with an error', () => ({ anchor_status: 'failed', anchor_error: 'execution reverted: InvalidStage' })],
      ['cleared and submitted', () => ({ ...submitted(), review_status: 'cleared' })],
    ])('accepts %s', async (_label, state) => {
      const values = state();

      expect((await tx(values)).anchor_status).toBe(values.anchor_status);
    });

    it.each([
      ['an unknown status', () => ({ anchor_status: 'mined' }), 'transactions_anchor_status_valid'],
      ['submitted without a chain hash', () => ({ anchor_status: 'submitted' }), 'transactions_sent_needs_tx_hash'],
      ['confirmed without a block number', () => ({ ...confirmed(), block_number: null }), 'transactions_confirmed_needs_block'],
      ['confirmed without anchored_at', () => ({ ...confirmed(), anchored_at: null }), 'transactions_confirmed_needs_block'],
      ['failed without an error', () => ({ anchor_status: 'failed' }), 'transactions_failed_needs_error'],
      ['failed with a blank error', () => ({ anchor_status: 'failed', anchor_error: '  ' }), 'transactions_failed_needs_error'],
      ['a flagged step that was submitted', () => ({ ...submitted(), review_status: 'flagged' }), 'transactions_anchor_only_if_approved'],
      ['a rejected step that was confirmed', () => ({ ...confirmed(), review_status: 'rejected' }), 'transactions_anchor_only_if_approved'],
    ])('rejects %s', async (_label, state, constraint) => {
      await expectCheckFails(state(), constraint);
    });

    it('refuses to mark an anchored step as rejected afterwards', async () => {
      const row = await tx(confirmed());

      const err = await expectPgError(
        t.db,
        "UPDATE transactions SET review_status = 'rejected' WHERE id = $1",
        [row.id],
        PG_ERROR.CHECK_VIOLATION,
      );
      expect(err.constraint).toBe('transactions_anchor_only_if_approved');
    });
  });

  describe('chain_tx_hash, block_number and anchor_attempts', () => {
    it('accepts any number of rows with no chain hash yet', async () => {
      const first = await tx();
      const second = await tx();

      expect(first.chain_tx_hash).toBeNull();
      expect(second.chain_tx_hash).toBeNull();
    });

    it('rejects two steps anchored by the same chain transaction', async () => {
      const hash = randomBytes(32);
      await tx({ ...submitted(), chain_tx_hash: hash });

      const err = await expectTxRejected({ ...submitted(), chain_tx_hash: hash }, PG_ERROR.UNIQUE_VIOLATION);
      expect(err.constraint).toBe('transactions_chain_tx_hash_unique');
    });

    it('rejects a 31-byte chain hash', async () => {
      await expectCheckFails({ chain_tx_hash: randomBytes(31) }, 'transactions_chain_tx_hash_32_bytes');
    });

    it('accepts block number 1 and 0 attempts', async () => {
      const row = await tx({ ...confirmed(), block_number: '1', anchor_attempts: 0 });

      expect(row.block_number).toBe('1');
      expect(row.anchor_attempts).toBe(0);
    });

    it('rejects block number 0', async () => {
      await expectCheckFails({ block_number: '0' }, 'transactions_block_number_positive');
    });

    it('rejects negative anchor attempts', async () => {
      await expectCheckFails({ anchor_attempts: -1 }, 'transactions_anchor_attempts_non_negative');
    });
  });

  // The same rules apply to both, so the tests run once for each type.
  describe.each(['registration', 'purchase'])('one accepted %s per consignment', (type) => {
    const index = `transactions_one_accepted_${type}_idx`;

    async function firstAccepted() {
      return tx({ type, review_status: 'passed' });
    }

    function sameConsignment(first, review_status) {
      return { consignment_id: first.consignment_id, actor_id: first.actor_id, type, review_status };
    }

    it.each(['passed', 'cleared'])('rejects a second %s one', async (review_status) => {
      const first = await firstAccepted();

      const err = await expectTxRejected(sameConsignment(first, review_status), PG_ERROR.UNIQUE_VIOLATION);
      expect(err.constraint).toBe(index);
    });

    it.each(['flagged', 'rejected'])('keeps a %s duplicate as evidence', async (review_status) => {
      const first = await firstAccepted();

      const duplicate = await tx(sameConsignment(first, review_status));

      expect(duplicate.review_status).toBe(review_status);
    });

    it('accepts two flagged attempts on one consignment', async () => {
      const first = await tx({ type, review_status: 'flagged' });

      const second = await tx(sameConsignment(first, 'flagged'));

      expect(second.consignment_id).toBe(first.consignment_id);
    });

    it('refuses an officer clearing a second one', async () => {
      const first = await firstAccepted();
      const duplicate = await tx(sameConsignment(first, 'flagged'));

      const err = await expectPgError(
        t.db,
        "UPDATE transactions SET review_status = 'cleared' WHERE id = $1",
        [duplicate.id],
        PG_ERROR.UNIQUE_VIOLATION,
      );
      expect(err.constraint).toBe(index);
    });
  });

  it('accepts several passed handoffs on one consignment (several transporters)', async () => {
    const first = await tx({ type: 'handoff' });
    await tx({ consignment_id: first.consignment_id, type: 'handoff' });
    await tx({ consignment_id: first.consignment_id, type: 'handoff' });

    const { rows } = await t.db.query(
      "SELECT count(*)::int AS n FROM transactions WHERE consignment_id = $1 AND type = 'handoff'",
      [first.consignment_id],
    );
    expect(rows[0].n).toBe(3);
  });

  describe('foreign keys', () => {
    it('accepts a real zone', async () => {
      const zone = await insertZone(t.db);

      expect((await tx({ zone_id: zone.id })).zone_id).toBe(zone.id);
    });

    it.each([
      ['consignment', { consignment_id: MISSING_ID }, 'transactions_consignment_id_fkey'],
      ['actor', { actor_id: MISSING_ID }, 'transactions_actor_id_fkey'],
      ['zone', { zone_id: MISSING_ID }, 'transactions_zone_id_fkey'],
    ])('rejects a %s that does not exist', async (_label, missing, constraint) => {
      // Real parents first, then the missing one replaces its slot.
      const parents = await transactionParents(t.db);
      const { text, params } = transactionInsert({ ...parents, ...missing });

      const err = await expectPgError(t.db, text, params, PG_ERROR.FOREIGN_KEY_VIOLATION);
      expect(err.constraint).toBe(constraint);
    });

    it('refuses to delete a zone a step points to', async () => {
      const zone = await insertZone(t.db);
      await tx({ zone_id: zone.id });

      const err = await expectPgError(t.db, 'DELETE FROM gps_zones WHERE id = $1', [zone.id], PG_ERROR.RESTRICT_VIOLATION);
      expect(err.constraint).toBe('transactions_zone_id_fkey');
    });

    it('refuses to delete a consignment that has steps', async () => {
      const row = await tx();

      const err = await expectPgError(
        t.db,
        'DELETE FROM consignments WHERE id = $1',
        [row.consignment_id],
        PG_ERROR.RESTRICT_VIOLATION,
      );
      expect(err.constraint).toBe('transactions_consignment_id_fkey');
    });

    it('refuses to delete an actor who recorded a step', async () => {
      // A transporter, not the miner, so only the transactions foreign key points at them.
      const transporter = await insertUser(t.db, { role: 'transporter', status: 'active' });
      await tx({ actor_id: transporter.id, type: 'handoff', consignment_id: (await tx()).consignment_id });

      const err = await expectPgError(
        t.db,
        'DELETE FROM users WHERE id = $1',
        [transporter.id],
        PG_ERROR.RESTRICT_VIOLATION,
      );
      expect(err.constraint).toBe('transactions_actor_id_fkey');
    });
  });

  it('moves updated_at forward on update', async () => {
    // Starts from an old updated_at, because now() is fixed for the test transaction.
    const OLD = new Date('2020-01-01T00:00:00Z');
    const parents = await transactionParents(t.db);
    const { rows: inserted } = await t.db.query(INSERT_WITH_OLD_UPDATED_AT, [...requiredValues(parents), OLD]);

    const { rows } = await t.db.query(
      'UPDATE transactions SET anchor_attempts = 1 WHERE id = $1 RETURNING updated_at',
      [inserted[0].id],
    );

    expect(rows[0].updated_at.getTime()).toBeGreaterThan(OLD.getTime());
  });
});
