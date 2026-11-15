import { describe, it, expect } from 'vitest';
import { stepStatusFromAlerts, NOT_CLEARABLE_MESSAGES } from '../src/services/alertService.js';
import { CUSTODY_RULES, stageAfter } from '../src/services/custodyRules.js';
import { ALERT_STATUSES } from '../src/schemas/alerts.js';

// The rule, written out independently of the code under test: any reviewed -> rejected;
// all dismissed -> cleared; otherwise flagged.
function expected(statuses) {
  if (statuses.includes('reviewed')) return 'rejected';
  if (statuses.every((s) => s === 'dismissed')) return 'cleared';
  return 'flagged';
}

// Every list of 1 to 3 alert statuses, in every order: 3 + 9 + 27 = 39 combinations. Three
// alerts are enough to contain every mix of the three statuses; longer lists only repeat them.
function combinations(length) {
  if (length === 0) return [[]];
  return combinations(length - 1).flatMap((rest) => ALERT_STATUSES.map((status) => [...rest, status]));
}
const ALL = [1, 2, 3].flatMap(combinations);

describe('stepStatusFromAlerts', () => {
  it('covers 39 combinations', () => {
    expect(ALL).toHaveLength(39);
  });

  it.each(ALL.map((statuses) => [statuses.join(', '), expected(statuses), statuses]))('[%s] gives %s', (_label, result, statuses) => {
    expect(stepStatusFromAlerts(statuses)).toBe(result);
  });

  // The cases the plan names, spelled out so the intent is readable on its own.
  it.each([
    ['one alert reviewed', ['reviewed'], 'rejected'],
    ['one alert dismissed', ['dismissed'], 'cleared'],
    ['one dismissed, one still open', ['dismissed', 'open'], 'flagged'],
    ['one reviewed, one still open', ['reviewed', 'open'], 'rejected'],
    ['dismissed after the other was reviewed: the rejection stands', ['reviewed', 'dismissed'], 'rejected'],
    ['both dismissed', ['dismissed', 'dismissed'], 'cleared'],
  ])('%s', (_label, statuses, result) => {
    expect(stepStatusFromAlerts(statuses)).toBe(result);
  });

  it.each([
    ['an empty list', []],
    ['no list', undefined],
  ])('refuses %s: a step being closed always has an alert', (_label, value) => {
    expect(() => stepStatusFromAlerts(value)).toThrow(TypeError);
  });
});

describe('NOT_CLEARABLE_MESSAGES', () => {
  it('has one fixed message for each of the three cases, each telling the officer what to do instead', () => {
    expect(Object.keys(NOT_CLEARABLE_MESSAGES).sort()).toEqual(['afterPurchase', 'duplicateRegistration', 'secondPurchase']);
    for (const message of Object.values(NOT_CLEARABLE_MESSAGES)) {
      expect(message).toMatch(/^This step cannot be cleared: .+ Confirm the problem instead\.$/);
    }
  });
});

describe('custody rules', () => {
  it('are the stage rules sync has always used', () => {
    expect(CUSTODY_RULES).toEqual({
      handoff: { allowedFrom: ['registered', 'in_transit'], to: 'in_transit' },
      purchase: { allowedFrom: ['in_transit'], to: 'purchased' },
    });
  });

  it.each([
    ['registration', 'registered', null],
    ['registration', 'in_transit', null],
    ['handoff', 'registered', 'in_transit'],
    ['handoff', 'in_transit', null], // a relay
    ['handoff', 'purchased', null], // never backwards
    ['purchase', 'in_transit', 'purchased'],
    ['purchase', 'registered', null],
    ['purchase', 'purchased', null],
    ['constructor', 'registered', null],
  ])('stageAfter(%s, %s) is %s', (type, stage, result) => {
    expect(stageAfter(type, stage)).toBe(result);
  });
});
