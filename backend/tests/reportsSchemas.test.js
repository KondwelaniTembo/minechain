import { describe, it, expect } from 'vitest';
import {
  transactionsReportQuerySchema,
  auditTrailQuerySchema,
  utcDayRange,
  MAX_REPORT_DAYS,
} from '../src/schemas/reports.js';

// Fake, well-formed ids (version 4, variant 8).
const USER_ID = '3f2b6c1e-0000-4000-8000-000000000001';
const ZONE_ID = '7a1c2d3e-0000-4000-8000-0000000000aa';
const CONSIGNMENT_ID = '5c0d7e21-0000-4000-8000-000000000001';

const NOVEMBER = { from: '2026-11-01', to: '2026-11-30' };

// Each issue as "path: message", so a test also shows which parameter was refused.
const issues = (schema, value) => {
  const result = schema.safeParse(value);
  return result.success ? [] : result.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
};

describe('transactionsReportQuerySchema', () => {
  it('accepts a date range alone', () => {
    expect(transactionsReportQuerySchema.parse(NOVEMBER)).toEqual(NOVEMBER);
  });

  it('accepts every filter together', () => {
    const query = {
      ...NOVEMBER,
      mineral: 'gold',
      actorId: USER_ID,
      zoneId: ZONE_ID,
      type: 'handoff',
      reviewStatus: 'flagged',
      anchorStatus: 'confirmed',
    };

    expect(transactionsReportQuerySchema.parse(query)).toEqual(query);
  });

  it('accepts a single day (from and to the same)', () => {
    expect(transactionsReportQuerySchema.safeParse({ from: '2026-11-10', to: '2026-11-10' }).success).toBe(true);
  });

  it(`accepts exactly ${MAX_REPORT_DAYS} days, counting both ends`, () => {
    // 2028 is a leap year: 1 Jan to 31 Dec is 366 days.
    expect(transactionsReportQuerySchema.safeParse({ from: '2028-01-01', to: '2028-12-31' }).success).toBe(true);
  });

  it.each([
    ['no from', { to: '2026-11-30' }, 'from: Invalid input: expected string, received undefined'],
    ['no to', { from: '2026-11-01' }, 'to: Invalid input: expected string, received undefined'],
    ['a date in another format', { ...NOVEMBER, from: '01/11/2026' }, 'from: must be a date such as 2026-11-01'],
    ['a date with a time', { ...NOVEMBER, to: '2026-11-30T23:59:59Z' }, 'to: must be a date such as 2026-11-01'],
    ['a day that does not exist', { ...NOVEMBER, from: '2026-02-30' }, 'from: must be a real calendar date'],
    ['29 February in a year that is not a leap year', { ...NOVEMBER, from: '2026-02-29' }, 'from: must be a real calendar date'],
    ['to before from', { from: '2026-11-30', to: '2026-11-01' }, 'to: must be the same day as from or later'],
    [
      `${MAX_REPORT_DAYS + 1} days`,
      { from: '2026-01-01', to: '2027-01-02' },
      `to: must be at most ${MAX_REPORT_DAYS} days after from, counting both days`,
    ],
    ['an unknown mineral', { ...NOVEMBER, mineral: 'silver' }, 'mineral: must be one of gold, copper, cobalt, manganese, emerald, amethyst'],
    ['a malformed actor id', { ...NOVEMBER, actorId: 'user-1' }, 'actorId: must be a valid user id'],
    ['a malformed zone id', { ...NOVEMBER, zoneId: 'zone-1' }, 'zoneId: must be a valid zone id'],
    ['an unknown step type', { ...NOVEMBER, type: 'transfer' }, 'type: must be one of registration, handoff, purchase'],
    ['an unknown review status', { ...NOVEMBER, reviewStatus: 'open' }, 'reviewStatus: must be one of passed, flagged, cleared, rejected'],
    ['an unknown anchor status', { ...NOVEMBER, anchorStatus: 'mined' }, 'anchorStatus: must be one of pending, submitted, confirmed, failed'],
    ['a repeated parameter (an array)', { ...NOVEMBER, mineral: ['gold', 'copper'] }, expect.stringMatching(/^mineral: /)],
    ['an unknown parameter', { ...NOVEMBER, fullName: 'x' }, ': Unrecognized key: "fullName"'],
  ])('refuses %s', (_label, query, issue) => {
    expect(issues(transactionsReportQuerySchema, query)).toEqual([issue]);
  });

  it('reports a malformed date alone, without a range message', () => {
    // to is before from as well, but the range check only runs once both dates are valid.
    expect(issues(transactionsReportQuerySchema, { from: '2026-11-31', to: '2026-11-01' })).toEqual(['from: must be a real calendar date']);
  });
});

describe('auditTrailQuerySchema', () => {
  it("accepts a consignment's trail with no dates", () => {
    expect(auditTrailQuerySchema.parse({ consignmentId: CONSIGNMENT_ID })).toEqual({ consignmentId: CONSIGNMENT_ID });
  });

  it("accepts an actor's trail with a date range", () => {
    expect(auditTrailQuerySchema.parse({ actorId: USER_ID, ...NOVEMBER })).toEqual({ actorId: USER_ID, ...NOVEMBER });
  });

  it.each([
    ['neither id', {}, ': give consignmentId or actorId'],
    ['both ids', { consignmentId: CONSIGNMENT_ID, actorId: USER_ID, ...NOVEMBER }, ': give consignmentId or actorId, not both'],
    ['dates with a consignment', { consignmentId: CONSIGNMENT_ID, from: '2026-11-01' }, "from: is not used with consignmentId: a consignment's trail is always complete"],
    ['an actor with no to', { actorId: USER_ID, from: '2026-11-01' }, 'to: is required with actorId'],
    ['an actor with a range that is too long', { actorId: USER_ID, from: '2026-01-01', to: '2027-01-02' }, `to: must be at most ${MAX_REPORT_DAYS} days after from, counting both days`],
    ['a malformed consignment id', { consignmentId: 'MC-001' }, 'consignmentId: must be a valid consignment id'],
    ['an unknown parameter', { consignmentId: CONSIGNMENT_ID, qrCode: 'MC-001' }, ': Unrecognized key: "qrCode"'],
  ])('refuses %s', (_label, query, issue) => {
    expect(issues(auditTrailQuerySchema, query)).toEqual([issue]);
  });

  it('names both missing dates for an actor', () => {
    expect(issues(auditTrailQuerySchema, { actorId: USER_ID })).toEqual(['from: is required with actorId', 'to: is required with actorId']);
  });
});

describe('utcDayRange', () => {
  it('runs from the start of from to the start of the day after to, in UTC', () => {
    expect(utcDayRange(NOVEMBER)).toEqual({
      start: new Date('2026-11-01T00:00:00.000Z'),
      endExclusive: new Date('2026-12-01T00:00:00.000Z'),
    });
  });

  it('covers one whole day when from and to are the same', () => {
    const { start, endExclusive } = utcDayRange({ from: '2026-11-10', to: '2026-11-10' });

    expect(endExclusive.getTime() - start.getTime()).toBe(86_400_000);
  });

  it('refuses days that were not validated', () => {
    expect(() => utcDayRange({ from: '2026-02-30', to: '2026-03-01' })).toThrow(TypeError);
  });
});
