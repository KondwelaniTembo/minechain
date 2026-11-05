import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { MISSING_ID, insertUser, insertTransaction, insertAlert, alertInsert } from './fixtures.js';

const t = useTestDb();

const newOfficer = () => insertUser(t.db, { role: 'officer', status: 'active' });

// A closed alert with every review field filled in.
const closed = (status, reviewerId) => ({
  status,
  reviewed_by: reviewerId,
  reviewed_at: new Date(),
  review_notes: 'Weights re-checked at the buying centre',
});

async function expectAlertRejected(overrides, code) {
  const step = await insertTransaction(t.db);
  const { text, params } = alertInsert({ transaction_id: step.id, ...overrides });
  return expectPgError(t.db, text, params, code);
}

// Every reject test names the rule expected to fire.
async function expectCheckFails(overrides, constraint) {
  const err = await expectAlertRejected(overrides, PG_ERROR.CHECK_VIOLATION);
  expect(err.constraint).toBe(constraint);
}

describe('alerts table', () => {
  it('opens with empty details when they are left out', async () => {
    const step = await insertTransaction(t.db);
    const { rows } = await t.db.query(
      'INSERT INTO alerts (transaction_id, type, severity) VALUES ($1, $2, $3) RETURNING *',
      [step.id, 'gps_zone', 'high'],
    );

    expect(rows[0].status).toBe('open');
    // jsonb comes back already parsed.
    expect(rows[0].details).toEqual({});
    expect(rows[0].created_at).toBeInstanceOf(Date);
  });

  describe('type and severity', () => {
    it.each([
      'duplicate_consignment',
      'quantity_discrepancy',
      'gps_zone',
      'invalid_signature',
      'handoff_order',
      'record_tampered',
    ])('accepts the type %s', async (type) => {
      expect((await insertAlert(t.db, { type })).type).toBe(type);
    });

    it('rejects an unknown type', async () => {
      await expectCheckFails({ type: 'fraud' }, 'alerts_type_valid');
    });

    it.each(['low', 'medium', 'high'])('accepts the severity %s', async (severity) => {
      expect((await insertAlert(t.db, { severity })).severity).toBe(severity);
    });

    it('rejects an unknown severity', async () => {
      await expectCheckFails({ severity: 'critical' }, 'alerts_severity_valid');
    });
  });

  describe('status and review fields', () => {
    it.each(['reviewed', 'dismissed'])('accepts %s with every review field', async (status) => {
      const officer = await newOfficer();

      const alert = await insertAlert(t.db, closed(status, officer.id));

      expect(alert.status).toBe(status);
      expect(alert.reviewed_by).toBe(officer.id);
    });

    it('accepts an officer closing an open alert in one update', async () => {
      const officer = await newOfficer();
      const alert = await insertAlert(t.db);

      const { rows } = await t.db.query(
        `UPDATE alerts
            SET status = 'dismissed', reviewed_by = $1, reviewed_at = now(), review_notes = $2
          WHERE id = $3
         RETURNING status`,
        [officer.id, 'GPS drift near the zone edge; site visit confirmed', alert.id],
      );

      expect(rows[0].status).toBe('dismissed');
    });

    it('rejects an unknown status', async () => {
      // With review fields filled in, so only the status rule fails. Without them the review
      // rule would fail too, and it is reported first because CHECKs run in name order.
      const officer = await newOfficer();

      await expectCheckFails(closed('closed', officer.id), 'alerts_status_valid');
    });

    // Built per test, because most need a real officer to point at.
    it.each([
      ['an open alert with a reviewer', (id) => ({ reviewed_by: id })],
      ['an open alert with notes', () => ({ review_notes: 'Looks fine' })],
      ['an open alert with a review time', () => ({ reviewed_at: new Date() })],
      ['a reviewed alert without notes', (id) => ({ ...closed('reviewed', id), review_notes: null })],
      ['a reviewed alert with blank notes', (id) => ({ ...closed('reviewed', id), review_notes: '   ' })],
      ['a dismissed alert without a reviewer', (id) => ({ ...closed('dismissed', id), reviewed_by: null })],
      ['a reviewed alert without reviewed_at', (id) => ({ ...closed('reviewed', id), reviewed_at: null })],
    ])('rejects %s', async (_label, build) => {
      const officer = await newOfficer();

      await expectCheckFails(build(officer.id), 'alerts_review_fields_match_status');
    });

    it('refuses to close an alert without notes in an update', async () => {
      const officer = await newOfficer();
      const alert = await insertAlert(t.db);

      const err = await expectPgError(
        t.db,
        "UPDATE alerts SET status = 'reviewed', reviewed_by = $1, reviewed_at = now() WHERE id = $2",
        [officer.id, alert.id],
        PG_ERROR.CHECK_VIOLATION,
      );
      expect(err.constraint).toBe('alerts_review_fields_match_status');
    });
  });

  describe('details', () => {
    it('accepts a nested object and returns it parsed', async () => {
      const details = { expectedWeightMg: '1500000', actualWeightMg: '1200000', stage: { from: 'registered' } };

      expect((await insertAlert(t.db, { details })).details).toEqual(details);
    });

    it.each([
      ['an array', [1, 2]],
      ['a string', 'weight too low'],
    ])('rejects %s', async (_label, details) => {
      await expectCheckFails({ details }, 'alerts_details_is_object');
    });
  });

  describe('one alert per rule per step', () => {
    it('rejects the same type twice on one step', async () => {
      const first = await insertAlert(t.db, { type: 'gps_zone' });

      const { text, params } = alertInsert({ transaction_id: first.transaction_id, type: 'gps_zone' });
      const err = await expectPgError(t.db, text, params, PG_ERROR.UNIQUE_VIOLATION);
      expect(err.constraint).toBe('alerts_one_per_rule_per_step');
    });

    it('accepts a different type on the same step', async () => {
      const first = await insertAlert(t.db, { type: 'gps_zone' });

      const second = await insertAlert(t.db, { transaction_id: first.transaction_id, type: 'quantity_discrepancy' });

      expect(second.transaction_id).toBe(first.transaction_id);
    });

    it('accepts the same type on a different step', async () => {
      const first = await insertAlert(t.db, { type: 'gps_zone' });

      const second = await insertAlert(t.db, { type: 'gps_zone' });

      expect(second.transaction_id).not.toBe(first.transaction_id);
    });
  });

  it('has a queue index limited to open alerts', async () => {
    const { rows } = await t.db.query(
      'SELECT indexdef FROM pg_indexes WHERE indexname = $1',
      ['alerts_open_queue_idx'],
    );

    expect(rows).toHaveLength(1);
    expect(rows[0].indexdef).toMatch(/WHERE \(status = 'open'::text\)/);
  });

  describe('foreign keys', () => {
    it('rejects a step that does not exist', async () => {
      const { text, params } = alertInsert({ transaction_id: MISSING_ID });

      const err = await expectPgError(t.db, text, params, PG_ERROR.FOREIGN_KEY_VIOLATION);
      expect(err.constraint).toBe('alerts_transaction_id_fkey');
    });

    it('rejects a reviewer who does not exist', async () => {
      const err = await expectAlertRejected(closed('reviewed', MISSING_ID), PG_ERROR.FOREIGN_KEY_VIOLATION);

      expect(err.constraint).toBe('alerts_reviewed_by_fkey');
    });

    it('refuses to delete a step that raised an alert', async () => {
      const alert = await insertAlert(t.db);

      const err = await expectPgError(
        t.db,
        'DELETE FROM transactions WHERE id = $1',
        [alert.transaction_id],
        PG_ERROR.RESTRICT_VIOLATION,
      );
      expect(err.constraint).toBe('alerts_transaction_id_fkey');
    });

    it('refuses to delete an officer who reviewed an alert', async () => {
      const officer = await newOfficer();
      await insertAlert(t.db, closed('reviewed', officer.id));

      const err = await expectPgError(t.db, 'DELETE FROM users WHERE id = $1', [officer.id], PG_ERROR.RESTRICT_VIOLATION);
      expect(err.constraint).toBe('alerts_reviewed_by_fkey');
    });
  });
});
