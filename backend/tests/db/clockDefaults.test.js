import { describe, it, expect } from 'vitest';
import { useTestDb } from './helpers.js';
import { insertTransaction, insertAlert } from './fixtures.js';

// The clock-timestamp-defaults migration: two columns whose order matters inside one
// database transaction default to clock_timestamp() (the time of the INSERT), not now()
// (the time the transaction started).

const t = useTestDb();

describe('timestamp defaults', () => {
  it.each([
    ['transactions', 'received_at'],
    ['alerts', 'created_at'],
  ])('%s.%s defaults to clock_timestamp()', async (table, column) => {
    const { rows } = await t.db.query(
      `SELECT column_default FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
      [table, column],
    );

    expect(rows).toEqual([{ column_default: 'clock_timestamp()' }]);
  });

  it("dates a step and then its alert, written in one transaction without either time, in that order", async () => {
    // The fixtures pass neither received_at nor created_at, so both come from the defaults.
    // Every test runs inside its own transaction, so both inserts share one; it began
    // before them, at now().
    const step = await insertTransaction(t.db);
    await insertAlert(t.db, { transaction_id: step.id });

    const { rows } = await t.db.query(
      `SELECT s.received_at > now()           AS step_after_transaction_start,
              a.created_at  > s.received_at   AS alert_after_step
         FROM transactions s JOIN alerts a ON a.transaction_id = s.id
        WHERE s.id = $1`,
      [step.id],
    );

    // Strictly later, both. With now() as the default, all three times would be the SAME
    // (the transaction's start), so both comparisons would be false. A >= check would
    // pass with now() too and prove nothing.
    expect(rows).toEqual([{ step_after_transaction_start: true, alert_after_step: true }]);
  });
});
