import { describe, it, expect } from 'vitest';
import { dashboardQuerySchema } from '../src/schemas/dashboard.js';
import { MAX_REPORT_DAYS } from '../src/schemas/reports.js';

const WEEK = { from: '2026-11-17', to: '2026-11-23' };

// Each issue as "path: message", so a test also shows which parameter was refused.
const issues = (value) => {
  const result = dashboardQuerySchema.safeParse(value);
  return result.success ? [] : result.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
};

describe('dashboardQuerySchema', () => {
  it('accepts a period alone', () => {
    expect(dashboardQuerySchema.parse(WEEK)).toEqual(WEEK);
  });

  it('accepts a period with a mineral', () => {
    expect(dashboardQuerySchema.parse({ ...WEEK, mineral: 'cobalt' })).toEqual({ ...WEEK, mineral: 'cobalt' });
  });

  it('accepts a single day', () => {
    expect(issues({ from: '2026-11-23', to: '2026-11-23' })).toEqual([]);
  });

  it(`accepts exactly ${MAX_REPORT_DAYS} days, counting both ends`, () => {
    expect(issues({ from: '2028-01-01', to: '2028-12-31' })).toEqual([]);
  });

  it.each([
    ['no from', { to: '2026-11-23' }, 'from: Invalid input: expected string, received undefined'],
    ['no to', { from: '2026-11-17' }, 'to: Invalid input: expected string, received undefined'],
    ['a date in another format', { ...WEEK, from: '17/11/2026' }, 'from: must be a date such as 2026-11-01'],
    ['a day that does not exist', { ...WEEK, to: '2026-11-31' }, 'to: must be a real calendar date'],
    ['to before from', { from: '2026-11-23', to: '2026-11-17' }, 'to: must be the same day as from or later'],
    [
      `${MAX_REPORT_DAYS + 1} days`,
      { from: '2026-01-01', to: '2027-01-02' },
      `to: must be at most ${MAX_REPORT_DAYS} days after from, counting both days`,
    ],
    ['an unknown mineral', { ...WEEK, mineral: 'silver' }, 'mineral: must be one of gold, copper, cobalt, manganese, emerald, amethyst'],
    ['a repeated mineral', { ...WEEK, mineral: ['gold', 'copper'] }, 'mineral: must be one of gold, copper, cobalt, manganese, emerald, amethyst'],
    ['a repeated day', { ...WEEK, from: ['2026-11-17', '2026-11-18'] }, 'from: Invalid input: expected string, received array'],
  ])('refuses %s', (_name, query, issue) => {
    expect(issues(query)).toEqual([issue]);
  });

  it('refuses a parameter the dashboard does not take, such as a report filter', () => {
    expect(issues({ ...WEEK, zoneId: '7a1c2d3e-0000-4000-8000-0000000000aa' })).toEqual([': Unrecognized key: "zoneId"']);
  });
});
