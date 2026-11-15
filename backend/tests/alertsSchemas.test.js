import { describe, it, expect } from 'vitest';
import {
  alertIdParamsSchema,
  listAlertsQuerySchema,
  notesBodySchema,
  ALERT_STATUSES,
  NOTES_MAX_LENGTH,
} from '../src/schemas/alerts.js';
import { ALERT_TYPES } from '../src/services/anomalyChecks.js';

const ALERT_ID = '7a3e9b10-0000-4000-8000-000000000001';

// Each issue as "path: message", so a test also shows which field was refused.
const issues = (schema, value) => {
  const result = schema.safeParse(value);
  return result.success ? [] : result.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
};

describe('ALERT_STATUSES', () => {
  it('are the three statuses of the alerts_status_valid CHECK', () => {
    expect(ALERT_STATUSES).toEqual(['open', 'reviewed', 'dismissed']);
  });
});

describe('alertIdParamsSchema', () => {
  it('accepts a uuid', () => {
    expect(alertIdParamsSchema.parse({ id: ALERT_ID })).toEqual({ id: ALERT_ID });
  });

  it.each([
    ['not a uuid', { id: 'alert-1' }, 'id: must be a valid alert id'],
    ['an extra parameter', { id: ALERT_ID, other: 'x' }, ': Unrecognized key: "other"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(alertIdParamsSchema, value)).toEqual([issue]);
  });
});

describe('listAlertsQuerySchema', () => {
  it('lists the first page of open alerts of every type when the query is empty', () => {
    expect(listAlertsQuerySchema.parse({})).toEqual({ status: 'open', limit: 20, offset: 0 });
  });

  it.each(ALERT_STATUSES)('accepts status %s', (status) => {
    expect(listAlertsQuerySchema.parse({ status }).status).toBe(status);
  });

  // The list comes from the anomaly checks, so every type they can store is accepted.
  it.each(ALERT_TYPES)('accepts type %s', (type) => {
    expect(listAlertsQuerySchema.parse({ type }).type).toBe(type);
  });

  it('turns limit and offset from plain digits into numbers', () => {
    expect(listAlertsQuerySchema.parse({ status: 'reviewed', type: 'gps_zone', limit: '100', offset: '10000' })).toEqual({
      status: 'reviewed',
      type: 'gps_zone',
      limit: 100,
      offset: 10000,
    });
  });

  it.each([
    ['an unknown status', { status: 'closed' }, 'status: must be open, reviewed or dismissed'],
    ['an unknown type', { type: 'weight' }, `type: must be one of ${ALERT_TYPES.join(', ')}`],
    ['a limit of 0', { limit: '0' }, 'limit: must be at least 1'],
    ['a limit over 100', { limit: '101' }, 'limit: must be at most 100'],
    ['an offset over 10 000', { offset: '10001' }, 'offset: must be at most 10000'],
    ['a limit in scientific notation', { limit: '1e2' }, 'limit: must be a whole number'],
    ['a limit in hex', { limit: '0x10' }, 'limit: must be a whole number'],
    ['a limit with spaces', { limit: ' 5 ' }, 'limit: must be a whole number'],
    ['a negative offset', { offset: '-1' }, 'offset: must be a whole number'],
    ['an unknown parameter', { severity: 'high' }, ': Unrecognized key: "severity"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(listAlertsQuerySchema, value)).toEqual([issue]);
  });

  it('refuses a repeated parameter, which arrives as an array', () => {
    expect(listAlertsQuerySchema.safeParse({ status: ['open', 'reviewed'] }).success).toBe(false);
  });
});

describe('notesBodySchema', () => {
  it('trims surrounding spaces and line breaks', () => {
    expect(notesBodySchema.parse({ notes: '  \n Weighed again at the depot \n ' })).toEqual({
      notes: 'Weighed again at the depot',
    });
  });

  it('keeps line breaks inside the notes', () => {
    const notes = 'Scale at the depot was faulty.\nWeighed again: within 2%.';

    expect(notesBodySchema.parse({ notes })).toEqual({ notes });
  });

  it.each([
    ['exactly 3 characters', 'abc'],
    [`exactly ${NOTES_MAX_LENGTH} characters`, 'n'.repeat(NOTES_MAX_LENGTH)],
  ])('accepts notes of %s', (_label, notes) => {
    expect(notesBodySchema.safeParse({ notes }).success).toBe(true);
  });

  it.each([
    ['no body field', {}, 'notes: Invalid input: expected string, received undefined'],
    ['notes that are not text', { notes: 42 }, 'notes: Invalid input: expected string, received number'],
    ['blank notes', { notes: '   \n  ' }, 'notes: must be at least 3 characters'],
    ['notes of 2 characters after trimming', { notes: ' ab ' }, 'notes: must be at least 3 characters'],
    [
      `notes over ${NOTES_MAX_LENGTH} characters`,
      { notes: 'n'.repeat(NOTES_MAX_LENGTH + 1) },
      `notes: must be at most ${NOTES_MAX_LENGTH} characters`,
    ],
    ['a status sent with the notes', { notes: 'Checked', status: 'dismissed' }, ': Unrecognized key: "status"'],
    ['a reviewer sent with the notes', { notes: 'Checked', reviewedBy: ALERT_ID }, ': Unrecognized key: "reviewedBy"'],
  ])('refuses %s', (_label, value, issue) => {
    expect(issues(notesBodySchema, value)).toEqual([issue]);
  });
});
