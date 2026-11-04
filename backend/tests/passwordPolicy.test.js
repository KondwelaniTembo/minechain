import { describe, it, expect } from 'vitest';
import { checkPasswordPolicy, MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH } from '../src/services/passwordPolicy.js';

const codes = (password, options) => checkPasswordPolicy(password, options).map((p) => p.code);

describe('checkPasswordPolicy', () => {
  it('uses a 12 to 128 character range', () => {
    expect(MIN_PASSWORD_LENGTH).toBe(12);
    expect(MAX_PASSWORD_LENGTH).toBe(128);
  });

  describe('accepts', () => {
    it.each([
      ['a three-word passphrase with spaces', 'gold river kasempa'],
      ['exactly 12 characters', 'copperbelt26'],
      ['exactly 128 characters', 'a1'.repeat(64)],
      ['lower case only, with no digits or symbols', 'emeraldsunrisevalley'],
      ['letters from other alphabets', 'Ндола медь 2026 рынок'],
    ])('%s', (_label, password) => {
      expect(codes(password, { username: 'banda' })).toEqual([]);
    });

    it('counts an accented letter as one character, whichever way it was typed', () => {
      // 11 characters plus é: 12 characters, even though the decomposed form is 13 UTF-16 units.
      const decomposed = 'mine café 26';

      expect(codes(decomposed)).toEqual([]);
    });
  });

  describe('length', () => {
    it('refuses 11 characters', () => {
      expect(codes('copperbelt2')).toEqual(['PASSWORD_TOO_SHORT']);
    });

    it('refuses 129 characters', () => {
      expect(codes(`${'a1'.repeat(64)}x`)).toEqual(['PASSWORD_TOO_LONG']);
    });

    it('measures length after NFKC, so it cannot be padded with look-alike characters', () => {
      // The ligature "ﬃ" is one character but becomes "ffi" (three) under NFKC.
      expect(codes('ﬃ'.repeat(4))).not.toContain('PASSWORD_TOO_SHORT');
    });

    it('gives the advice in plain language', () => {
      const [problem] = checkPasswordPolicy('short');

      expect(problem.message).toBe('Use at least 12 characters. A few words with spaces works well.');
    });
  });

  describe('repeated characters', () => {
    it.each([
      ['one letter', 'aaaaaaaaaaaaaa'],
      ['only spaces', '              '],
    ])('refuses %s repeated', (_label, password) => {
      expect(codes(password)).toContain('PASSWORD_REPEATED');
    });

    it('accepts a password that only starts with a repeat', () => {
      expect(codes('aaaa river kasempa')).toEqual([]);
    });
  });

  describe('username', () => {
    it.each([
      ['exactly', 'mutale_banda'],
      ['in a different case', 'MUTALE_banda'],
      ['inside other words', 'my name is mutale_banda!'],
    ])('refuses a password containing the username %s', (_label, password) => {
      expect(codes(password, { username: 'mutale_banda' })).toContain('PASSWORD_CONTAINS_USERNAME');
    });

    it('allows the same text when no username is given', () => {
      expect(codes('my name is mutale_banda!')).toEqual([]);
    });
  });

  describe('common passwords', () => {
    it.each(['kindergarten', 'qwaszxqwaszx', '123456asdfgh'])('refuses %s from the list', (password) => {
      expect(codes(password)).toContain('PASSWORD_TOO_COMMON');
    });

    it('refuses a listed password in different letter case', () => {
      expect(codes('KinderGarten')).toContain('PASSWORD_TOO_COMMON');
    });

    it('does not treat the comment lines at the top of the list as passwords', () => {
      expect(codes('# Common passwords of 12 or more characters, refused at registration (B5 password policy).')).toEqual([]);
    });
  });

  it('reports every problem at once', () => {
    expect(codes('banda', { username: 'banda' })).toEqual(['PASSWORD_TOO_SHORT', 'PASSWORD_CONTAINS_USERNAME']);
  });
});
