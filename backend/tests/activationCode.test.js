import { createHash } from 'node:crypto';
import { describe, it, expect, vi, afterEach } from 'vitest';
import {
  generate,
  normalise,
  hash,
  matches,
  ACTIVATION_CODE_ALPHABET,
  ACTIVATION_CODE_LENGTH,
  ACTIVATION_CODE_BITS,
} from '../src/services/activationCode.js';

// A fixed, fake code in canonical form, and the same as shown to an administrator.
const CODE = '7KQ4M2XD9TNE';
const DISPLAY = '7KQ4-M2XD-9TNE';

const CANONICAL = new RegExp(`^[${ACTIVATION_CODE_ALPHABET}]{${ACTIVATION_CODE_LENGTH}}$`);

afterEach(() => {
  vi.restoreAllMocks();
});

describe('the code format', () => {
  it('is 12 characters of 5 bits each, 60 bits in all, from the 32-symbol Crockford alphabet', () => {
    expect(ACTIVATION_CODE_ALPHABET).toBe('0123456789ABCDEFGHJKMNPQRSTVWXYZ');
    expect(new Set(ACTIVATION_CODE_ALPHABET).size).toBe(32);
    expect(ACTIVATION_CODE_LENGTH).toBe(12);
    expect(ACTIVATION_CODE_BITS).toBe(ACTIVATION_CODE_LENGTH * Math.log2(ACTIVATION_CODE_ALPHABET.length));
  });

  it('leaves out I, L, O and U', () => {
    for (const letter of 'ILOU') expect(ACTIVATION_CODE_ALPHABET).not.toContain(letter);
  });
});

describe('generate', () => {
  it('gives 12 characters from the alphabet, every time', () => {
    for (let i = 0; i < 200; i += 1) {
      expect(generate().code).toMatch(CANONICAL);
    }
  });

  it('uses every character of the alphabet across a sample (a sanity check, not a statistics test)', () => {
    const seen = new Set();
    // 500 codes are 6,000 characters, about 190 of each symbol; missing one is vanishingly
    // unlikely unless the generator never produces it.
    for (let i = 0; i < 500; i += 1) for (const c of generate().code) seen.add(c);

    expect([...seen].sort().join('')).toBe([...ACTIVATION_CODE_ALPHABET].sort().join(''));
  });

  it('gives a different code each time', () => {
    const codes = new Set(Array.from({ length: 200 }, () => generate().code));

    expect(codes.size).toBe(200);
  });

  it('shows the code in three groups of four, which normalises back to the code', () => {
    const { code, display } = generate();

    expect(display).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
    expect(display.replaceAll('-', '')).toBe(code);
    expect(normalise(display)).toBe(code);
  });

  it('never uses Math.random', () => {
    const random = vi.spyOn(Math, 'random');

    generate();

    expect(random).not.toHaveBeenCalled();
  });
});

describe('normalise', () => {
  it.each([
    ['the canonical form', CODE],
    ['the display form with hyphens', DISPLAY],
    ['lower case', '7kq4-m2xd-9tne'],
    ['spaces instead of hyphens', '7KQ4 M2XD 9TNE'],
    ['separators anywhere', ' 7K-Q4M 2X-D9T NE '],
  ])('accepts %s', (_label, input) => {
    expect(normalise(input)).toBe(CODE);
  });

  it.each([
    ['O for 0', 'OOOO-1111-2222', '000011112222'],
    ['I for 1', 'IIII-0000-2222', '111100002222'],
    ['L for 1', 'LLLL-0000-2222', '111100002222'],
    ['lower-case o, i and l', 'oil0-0000-2222', '011000002222'],
  ])('reads %s', (_label, input, expected) => {
    expect(normalise(input)).toBe(expected);
  });

  it.each([
    ['a U, which is never in a code', '7KQ4-M2XD-9TNU'],
    ['a dot', '7KQ4.M2XD.9TNE'],
    ['an underscore', '7KQ4_M2XD_9TNE'],
    ['11 characters', '7KQ4-M2XD-9TN'],
    ['13 characters', '7KQ4-M2XD-9TNEE'],
    ['an empty string', ''],
    ['only separators', '- - -'],
    ['a Turkish dotless i, which upper-cases to I', '7KQ4-M2XD-9TN\u0131'],
    ['a full-width digit', '7KQ4-M2XD-9TN\uFF11'],
    ['a tab', '7KQ4\tM2XD9TNE'],
    ['very long input', `${CODE}${'-'.repeat(100)}`],
  ])('refuses %s', (_label, input) => {
    expect(normalise(input)).toBeNull();
  });

  it.each([
    ['null', null],
    ['undefined', undefined],
    ['a number', 123456789012],
    ['an object', { code: CODE }],
    ['an array', [CODE]],
  ])('gives null for %s instead of throwing', (_label, input) => {
    expect(normalise(input)).toBeNull();
  });
});

describe('hash', () => {
  it('gives 32 bytes, the same each time for the same code', () => {
    const first = hash(CODE);

    expect(Buffer.isBuffer(first)).toBe(true);
    expect(first).toHaveLength(32);
    expect(hash(CODE).equals(first)).toBe(true);
  });

  it('is the SHA-256 of the canonical text', () => {
    // Worked out here with Node's crypto directly, not through the module.
    const expected = createHash('sha256').update(CODE, 'utf8').digest();

    expect(hash(CODE).equals(expected)).toBe(true);
  });

  it('gives the same hash for a code typed with look-alikes, lower case and separators', () => {
    const typed = normalise('oo00-1l1i-2222');

    expect(typed).toBe('000011112222');
    expect(hash(typed).equals(hash('000011112222'))).toBe(true);
  });

  it('gives different hashes for different codes', () => {
    expect(hash(CODE).equals(hash('7KQ4M2XD9TNF'))).toBe(false);
  });

  it.each([
    ['the display form', DISPLAY],
    ['lower case', '7kq4m2xd9tne'],
    ['a non-string', 42],
  ])('refuses %s, without repeating it in the message', (_label, input) => {
    let error;
    try {
      hash(input);
    } catch (err) {
      error = err;
    }

    expect(error).toBeInstanceOf(TypeError);
    expect(error.message).not.toContain(String(input));
    expect(error.message).not.toMatch(/7KQ4|M2XD|9TNE/i);
  });
});

describe('matches', () => {
  it('is true for the hash of the same code', () => {
    expect(matches(hash(CODE), hash(CODE))).toBe(true);
  });

  it('is false for a different code', () => {
    expect(matches(hash('7KQ4M2XD9TNF'), hash(CODE))).toBe(false);
  });

  it.each([
    ['no stored hash (no code issued)', () => [hash(CODE), null]],
    ['no typed hash', () => [undefined, hash(CODE)]],
    ['a 31-byte stored hash', () => [hash(CODE), hash(CODE).subarray(0, 31)]],
    ['a 33-byte stored hash', () => [hash(CODE), Buffer.concat([hash(CODE), Buffer.from([0])])]],
    ['the code as text instead of a hash', () => [CODE, hash(CODE)]],
    ['a Uint8Array that is not a Buffer', () => [new Uint8Array(hash(CODE)), hash(CODE)]],
  ])('is false, without throwing, for %s', (_label, args) => {
    expect(() => matches(...args())).not.toThrow();
    expect(matches(...args())).toBe(false);
  });
});

describe('logging', () => {
  it('writes nothing to the console, whatever it is given', () => {
    const spies = ['log', 'info', 'warn', 'error', 'debug'].map((method) => vi.spyOn(console, method).mockImplementation(() => {}));

    const { code, display } = generate();
    normalise(display);
    normalise('not a code at all');
    normalise(null);
    matches(hash(code), null);
    try {
      hash('bad');
    } catch {
      // Expected: only the console matters here.
    }

    for (const spy of spies) expect(spy).not.toHaveBeenCalled();
  });
});
