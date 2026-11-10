import { describe, it, expect } from 'vitest';
import { mgToKg, KG_DECIMALS } from '../src/services/units.js';

describe('mgToKg', () => {
  it.each([
    ['1500000', '1.500000'],
    ['1234567', '1.234567'],
    ['1000000', '1.000000'],
    ['999999', '0.999999'],
    ['500', '0.000500'],
    ['1', '0.000001'],
    ['0', '0.000000'],
    ['25000000000', '25000.000000'],
  ])('%s mg is %s kg', (mg, kg) => {
    expect(mgToKg(mg)).toBe(kg);
  });

  it(`always gives exactly ${KG_DECIMALS} decimal places`, () => {
    for (const mg of ['1', '10', '1500000', '123456789012']) {
      expect(mgToKg(mg).split('.')[1]).toHaveLength(KG_DECIMALS);
    }
  });

  it('accepts a bigint', () => {
    expect(mgToKg(1500000n)).toBe('1.500000');
  });

  it('drops leading zeros', () => {
    expect(mgToKg('0001500000')).toBe('1.500000');
  });

  it('stays exact beyond what a JavaScript number can hold', () => {
    // 2^53 + 1: as a JavaScript number this would become 9007199254740992.
    expect(mgToKg('9007199254740993')).toBe('9007199254.740993');
  });

  it.each([
    ['a JavaScript number, which could be a float', 1500000],
    ['a decimal', '1500000.5'],
    ['a negative weight as text', '-1'],
    ['a negative bigint', -1n],
    ['exponent form', '1e6'],
    ['spaces', ' 1500000'],
    ['an empty string', ''],
    ['null', null],
  ])('refuses %s', (_label, value) => {
    expect(() => mgToKg(value)).toThrow(TypeError);
  });
});
