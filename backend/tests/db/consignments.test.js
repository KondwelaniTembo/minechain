import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { MISSING_ID, insertUser, insertConsignment, consignmentInsert } from './fixtures.js';

const t = useTestDb();

async function expectConsignmentRejected(overrides, code) {
  const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
  const { text, params } = consignmentInsert({ miner_id: miner.id, ...overrides });
  return expectPgError(t.db, text, params, code);
}

describe('consignments table', () => {
  describe('chain_id', () => {
    it('is 16 zero bytes followed by the 16 bytes of id', async () => {
      const consignment = await insertConsignment(t.db);

      const expected = Buffer.concat([
        Buffer.alloc(16),
        Buffer.from(consignment.id.replaceAll('-', ''), 'hex'),
      ]);
      expect(consignment.chain_id).toHaveLength(32);
      expect(Buffer.compare(consignment.chain_id, expected)).toBe(0);
    });

    it('cannot be written by hand', async () => {
      const miner = await insertUser(t.db, { role: 'miner', status: 'active' });

      await expectPgError(
        t.db,
        `INSERT INTO consignments (chain_id, qr_code, mineral_type, miner_id)
         VALUES ($1, $2, $3, $4)`,
        [Buffer.alloc(32, 1), 'MC-HAND-0001', 'gold', miner.id],
        PG_ERROR.GENERATED_ALWAYS,
      );
    });
  });

  it('defaults the stage to registered', async () => {
    const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
    const { rows } = await t.db.query(
      'INSERT INTO consignments (qr_code, mineral_type, miner_id) VALUES ($1, $2, $3) RETURNING stage',
      ['MC-DEFAULT-01', 'copper', miner.id],
    );

    expect(rows[0].stage).toBe('registered');
  });

  it.each(['gold', 'copper', 'cobalt', 'manganese', 'emerald', 'amethyst'])(
    'accepts the mineral %s',
    async (mineral_type) => {
      const consignment = await insertConsignment(t.db, { mineral_type });

      expect(consignment.mineral_type).toBe(mineral_type);
    },
  );

  it.each([
    ['a capitalised mineral', { mineral_type: 'Gold' }, 'consignments_mineral_valid'],
    ['a mineral not on the list', { mineral_type: 'diamond' }, 'consignments_mineral_valid'],
    ['an unknown stage', { stage: 'exported' }, 'consignments_stage_valid'],
    ['a QR code with a space', { qr_code: 'MC 2026 01' }, 'consignments_qr_code_format'],
    ['a QR code shorter than 4 characters', { qr_code: 'MC1' }, 'consignments_qr_code_format'],
  ])('rejects %s', async (_label, overrides, constraint) => {
    const err = await expectConsignmentRejected(overrides, PG_ERROR.CHECK_VIOLATION);

    expect(err.constraint).toBe(constraint);
  });

  it('accepts a URL-style QR code', async () => {
    const consignment = await insertConsignment(t.db, { qr_code: 'https://tags.example/MC-2026-000777' });

    expect(consignment.qr_code).toBe('https://tags.example/MC-2026-000777');
  });

  it('rejects a second consignment with the same QR code', async () => {
    await insertConsignment(t.db, { qr_code: 'MC-2026-DUP001' });

    const err = await expectConsignmentRejected({ qr_code: 'MC-2026-DUP001' }, PG_ERROR.UNIQUE_VIOLATION);
    expect(err.constraint).toBe('consignments_qr_code_unique');
  });

  it('rejects miner_id pointing at a user that does not exist', async () => {
    const { text, params } = consignmentInsert({ miner_id: MISSING_ID });

    await expectPgError(t.db, text, params, PG_ERROR.FOREIGN_KEY_VIOLATION);
  });

  it('refuses to delete a miner who has consignments (D9)', async () => {
    const consignment = await insertConsignment(t.db);

    const err = await expectPgError(
      t.db,
      'DELETE FROM users WHERE id = $1',
      [consignment.miner_id],
      PG_ERROR.RESTRICT_VIOLATION,
    );
    expect(err.constraint).toBe('consignments_miner_id_fkey');
  });

  it('moves updated_at forward on update', async () => {
    // Starts from an old updated_at, because now() is fixed for the test transaction.
    const OLD = new Date('2020-01-01T00:00:00Z');
    const miner = await insertUser(t.db, { role: 'miner', status: 'active' });
    const { rows: inserted } = await t.db.query(
      `INSERT INTO consignments (qr_code, mineral_type, miner_id, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $4) RETURNING id`,
      ['MC-OLD-0001', 'gold', miner.id, OLD],
    );

    const { rows } = await t.db.query(
      "UPDATE consignments SET stage = 'in_transit' WHERE id = $1 RETURNING updated_at",
      [inserted[0].id],
    );

    expect(rows[0].updated_at.getTime()).toBeGreaterThan(OLD.getTime());
  });
});
