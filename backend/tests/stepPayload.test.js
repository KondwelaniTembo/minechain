import { describe, it, expect } from 'vitest';
import { canonicalise, parsePayload, MINERALS, STEP_TYPES } from '../src/services/stepPayload.js';
import { SigningError } from '../src/services/signingError.js';

// The two examples from docs/signing-spec.md, section 3, field for field. All ids are fake.
const REGISTRATION = Object.freeze({
  type: 'registration',
  stepId: '6f1d2c3a-0000-4000-8000-000000000001',
  actorId: '3f2b6c1e-0000-4000-8000-000000000001',
  qrCode: 'MC-2026-000123',
  mineral: 'gold',
  weightMg: '1500000',
  latitude: '-15.419751',
  longitude: '28.287496',
  capturedAt: '2026-11-10T08:00:00.000Z',
});
const REGISTRATION_TEXT = [
  'minechain-step/1/registration',
  'step_id=6f1d2c3a-0000-4000-8000-000000000001',
  'actor_id=3f2b6c1e-0000-4000-8000-000000000001',
  'qr_code=MC-2026-000123',
  'mineral=gold',
  'weight_mg=1500000',
  'latitude=-15.419751',
  'longitude=28.287496',
  'captured_at=2026-11-10T08:00:00.000Z',
].join('\n') + '\n';

const HANDOFF = Object.freeze({
  type: 'handoff',
  stepId: '6f1d2c3a-0000-4000-8000-000000000002',
  actorId: '3f2b6c1e-0000-4000-8000-000000000002',
  qrCode: 'MC-2026-000123',
  weightMg: '1495000',
  latitude: '-15.390012',
  longitude: '28.322540',
  capturedAt: '2026-11-10T14:30:05.250Z',
});
const HANDOFF_TEXT = [
  'minechain-step/1/handoff',
  'step_id=6f1d2c3a-0000-4000-8000-000000000002',
  'actor_id=3f2b6c1e-0000-4000-8000-000000000002',
  'qr_code=MC-2026-000123',
  'weight_mg=1495000',
  'latitude=-15.390012',
  'longitude=28.322540',
  'captured_at=2026-11-10T14:30:05.250Z',
].join('\n') + '\n';

// Not in the spec; the same shape as a handoff.
const PURCHASE = Object.freeze({
  type: 'purchase',
  stepId: '6f1d2c3a-0000-4000-8000-000000000003',
  actorId: '3f2b6c1e-0000-4000-8000-000000000003',
  qrCode: 'MC-2026-000123',
  weightMg: '1494500',
  latitude: '-15.416600',
  longitude: '28.283300',
  capturedAt: '2026-11-11T09:15:00.000Z',
});

// Runs fn and returns what it threw. A function, not a value, so the call happens here,
// where the error is caught (the expectRefused lesson).
function refusal(fn) {
  try {
    fn();
  } catch (err) {
    return err;
  }
  throw new Error('expected a refusal, but nothing was thrown');
}

const parseRefusal = (text) => refusal(() => parsePayload(text));

// Replaces one key=value line of a payload, leaving every other byte alone. Used while the
// it.each tables are built, outside any test, so it throws plainly instead of using expect.
// The replacement is a function, so a value containing $ is never read as a pattern.
const withLine = (text, key, line) => {
  const pattern = new RegExp(`^${key}=.*$`, 'm');
  if (!pattern.test(text)) throw new Error(`test setup: the payload has no ${key} line`);
  return text.replace(pattern, () => line);
};
const withValue = (text, key, value) => withLine(text, key, `${key}=${value}`);
const lines = (text) => text.slice(0, -1).split('\n');
const fromLines = (list) => `${list.join('\n')}\n`;

describe('canonicalise: the spec examples, byte for byte', () => {
  it('reproduces the registration example', () => {
    expect(canonicalise(REGISTRATION)).toBe(REGISTRATION_TEXT);
  });

  it('reproduces the handoff example', () => {
    expect(canonicalise(HANDOFF)).toBe(HANDOFF_TEXT);
  });

  it('ends every line with LF, the last one included, and uses one byte per character', () => {
    const bytes = Buffer.from(canonicalise(REGISTRATION), 'utf8');

    expect(bytes.length).toBe(REGISTRATION_TEXT.length);
    expect(bytes.at(-1)).toBe(0x0a);
    expect(bytes.includes(0x0d)).toBe(false);
  });

  it('gives 9 lines for a registration and 8 for a handoff or purchase', () => {
    expect(lines(canonicalise(REGISTRATION))).toHaveLength(9);
    expect(lines(canonicalise(HANDOFF))).toHaveLength(8);
    expect(lines(canonicalise(PURCHASE))).toHaveLength(8);
  });

  it('accepts the weight as a bigint as well as text', () => {
    expect(canonicalise({ ...REGISTRATION, weightMg: 1500000n })).toBe(REGISTRATION_TEXT);
  });
});

describe('round trips', () => {
  it.each([
    ['registration', REGISTRATION],
    ['handoff', HANDOFF],
    ['purchase', PURCHASE],
  ])('a %s parses back to the same step and the same bytes', (_type, step) => {
    const text = canonicalise(step);
    const parsed = parsePayload(text);

    expect(parsed).toEqual(step);
    expect(canonicalise(parsed)).toBe(text);
  });

  it('keeps weight and coordinates as text, never numbers', () => {
    const parsed = parsePayload(REGISTRATION_TEXT);

    expect(typeof parsed.weightMg).toBe('string');
    expect(typeof parsed.latitude).toBe('string');
    expect(typeof parsed.longitude).toBe('string');
  });

  it('has no mineral on a parsed handoff', () => {
    expect(parsePayload(HANDOFF_TEXT)).not.toHaveProperty('mineral');
  });

  it.each(MINERALS)('accepts the mineral %s', (mineral) => {
    expect(parsePayload(withValue(REGISTRATION_TEXT, 'mineral', mineral)).mineral).toBe(mineral);
  });

  it('knows exactly three step types', () => {
    expect(STEP_TYPES).toEqual(['registration', 'handoff', 'purchase']);
  });
});

describe('parsePayload: bytes and lines', () => {
  it.each([
    ['CRLF line endings', REGISTRATION_TEXT.replaceAll('\n', '\r\n')],
    ['a missing final LF', REGISTRATION_TEXT.slice(0, -1)],
    ['a trailing space on a line', withValue(REGISTRATION_TEXT, 'mineral', 'gold ')],
    ['a space before the value', withLine(REGISTRATION_TEXT, 'mineral', 'mineral= gold')],
    ['a tab', withValue(REGISTRATION_TEXT, 'qr_code', 'MC-2026\t000123')],
    ['a byte order mark', `﻿${REGISTRATION_TEXT}`],
    ['a non-ASCII character', withValue(REGISTRATION_TEXT, 'qr_code', 'MC-2026-00012é')],
    ['a look-alike Cyrillic letter', withValue(REGISTRATION_TEXT, 'mineral', 'gоld')],
    ['an empty line in the middle', REGISTRATION_TEXT.replace('mineral=gold\n', 'mineral=gold\n\n')],
    ['an empty line at the end', `${REGISTRATION_TEXT}\n`],
    ['an empty payload', ''],
  ])('refuses %s', (_label, text) => {
    const err = parseRefusal(text);

    expect(err).toBeInstanceOf(SigningError);
    expect(err.code).toBe('PAYLOAD_MALFORMED');
  });

  it.each([
    ['a Buffer', Buffer.from(REGISTRATION_TEXT)],
    ['undefined', undefined],
    ['an object', { payload: REGISTRATION_TEXT }],
  ])('refuses %s instead of text', (_label, value) => {
    expect(parseRefusal(value).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses two lines swapped', () => {
    const list = lines(REGISTRATION_TEXT);
    [list[5], list[6]] = [list[6], list[5]];

    expect(parseRefusal(fromLines(list)).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a repeated line in place of another', () => {
    const list = lines(REGISTRATION_TEXT);
    list[7] = list[6]; // latitude twice, no longitude

    expect(parseRefusal(fromLines(list)).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses an extra line', () => {
    expect(parseRefusal(`${REGISTRATION_TEXT}note=hello\n`).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a missing line', () => {
    const list = lines(REGISTRATION_TEXT).filter((line) => !line.startsWith('longitude='));

    expect(parseRefusal(fromLines(list)).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a mineral line on a handoff', () => {
    const list = lines(HANDOFF_TEXT);
    list.splice(4, 0, 'mineral=gold');

    expect(parseRefusal(fromLines(list)).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a registration without its mineral line', () => {
    const list = lines(REGISTRATION_TEXT).filter((line) => !line.startsWith('mineral='));

    expect(parseRefusal(fromLines(list)).code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a handoff body under a registration header', () => {
    // The type is part of the signed bytes, so each type's body is only valid under its own
    // header.
    const text = HANDOFF_TEXT.replace('minechain-step/1/handoff', 'minechain-step/1/registration');

    expect(parseRefusal(text).code).toBe('PAYLOAD_MALFORMED');
  });

  it.each([
    ['without =', 'mineral:gold'],
    ['with the key in capitals', 'MINERAL=gold'],
    ['with an empty value', 'mineral='],
  ])('refuses a line %s', (_label, line) => {
    expect(parseRefusal(withLine(REGISTRATION_TEXT, 'mineral', line)).code).toBe('PAYLOAD_MALFORMED');
  });
});

describe('parsePayload: the header', () => {
  const withHeader = (header) => fromLines([header, ...lines(REGISTRATION_TEXT).slice(1)]);

  it.each(['minechain-step/2/registration', 'minechain-step/0/registration', 'minechain-step/01/registration'])(
    'refuses %s as an unsupported version',
    (header) => {
      expect(parseRefusal(withHeader(header)).code).toBe('PAYLOAD_UNSUPPORTED_VERSION');
    },
  );

  it.each([
    ['an unknown type', 'minechain-step/1/export'],
    ['a type in capitals', 'minechain-step/1/Registration'],
    ['another prefix', 'minechain-steps/1/registration'],
    ['no version', 'minechain-step/registration'],
    ['a key=value line first', 'step_id=6f1d2c3a-0000-4000-8000-000000000001'],
  ])('refuses %s', (_label, header) => {
    expect(parseRefusal(withHeader(header)).code).toBe('PAYLOAD_MALFORMED');
  });
});

describe('parsePayload: values', () => {
  const refusedValue = (key, value, text = REGISTRATION_TEXT) => parseRefusal(withValue(text, key, value));

  describe('ids', () => {
    it.each([
      ['in capitals', '6F1D2C3A-0000-4000-8000-000000000001'],
      ['without dashes', '6f1d2c3a000040008000000000000001'],
      ['in braces', '{6f1d2c3a-0000-4000-8000-000000000001}'],
      ['a character short', '6f1d2c3a-0000-4000-8000-00000000001'],
    ])('refuses a step_id %s', (_label, value) => {
      expect(refusedValue('step_id', value).code).toBe('PAYLOAD_MALFORMED');
    });

    it('refuses an actor_id in capitals', () => {
      expect(refusedValue('actor_id', '3F2B6C1E-0000-4000-8000-000000000001').code).toBe('PAYLOAD_MALFORMED');
    });
  });

  describe('qr_code', () => {
    it.each(['MC-1', 'a'.repeat(128), 'https://example.test/MC-2026-000123', 'MC_2026.000123:A'])('accepts %s', (value) => {
      expect(parsePayload(withValue(REGISTRATION_TEXT, 'qr_code', value)).qrCode).toBe(value);
    });

    it.each([
      ['3 characters', 'MC1'],
      ['129 characters', 'a'.repeat(129)],
      ['an = sign', 'MC=2026'],
      ['a # sign', 'MC#2026'],
    ])('refuses %s', (_label, value) => {
      expect(refusedValue('qr_code', value).code).toBe('PAYLOAD_MALFORMED');
    });
  });

  describe('mineral', () => {
    it.each(['Gold', 'GOLD', 'diamond', 'gold,copper'])('refuses %s', (value) => {
      expect(refusedValue('mineral', value).code).toBe('PAYLOAD_MALFORMED');
    });
  });

  describe('weight_mg', () => {
    it.each(['1', '9223372036854775807'])('accepts %s', (value) => {
      expect(parsePayload(withValue(REGISTRATION_TEXT, 'weight_mg', value)).weightMg).toBe(value);
    });

    it.each([
      ['zero', '0'],
      ['a leading zero', '01500000'],
      ['a plus sign', '+1500000'],
      ['a minus sign', '-1500000'],
      ['a decimal point', '1500000.0'],
      ['an exponent', '1.5e6'],
      ['one above the bigint maximum', '9223372036854775808'],
      ['20 digits', '10000000000000000000'],
      ['a thousands separator', '1,500,000'],
    ])('refuses %s', (_label, value) => {
      expect(refusedValue('weight_mg', value).code).toBe('PAYLOAD_MALFORMED');
    });
  });

  describe('latitude and longitude', () => {
    it.each([
      ['latitude', '90.000000'],
      ['latitude', '-90.000000'],
      ['latitude', '0.000000'],
      ['latitude', '-0.000001'],
      ['longitude', '180.000000'],
      ['longitude', '-180.000000'],
      ['longitude', '28.288000'],
    ])('accepts %s %s', (key, value) => {
      expect(parsePayload(withValue(REGISTRATION_TEXT, key, value))[key]).toBe(value);
    });

    it.each([
      ['latitude', 'only one decimal', '15.4'],
      ['latitude', '7 decimals', '-15.4197512'],
      ['latitude', 'no decimals', '-15'],
      ['latitude', 'negative zero', '-0.000000'],
      ['latitude', 'just above 90', '90.000001'],
      ['latitude', 'just below -90', '-90.000001'],
      ['latitude', 'a longitude-sized value', '120.000000'],
      ['latitude', 'a plus sign', '+15.419751'],
      ['latitude', 'a leading zero', '015.419751'],
      ['latitude', 'no whole part', '.419751'],
      ['latitude', 'an exponent', '1.5e1'],
      ['longitude', 'just above 180', '180.000001'],
      ['longitude', 'just below -180', '-180.000001'],
      ['longitude', 'four whole digits', '1000.000000'],
      ['longitude', 'a comma for the decimal point', '28,287496'],
    ])('refuses a %s with %s', (key, _label, value) => {
      expect(refusedValue(key, value).code).toBe('PAYLOAD_MALFORMED');
    });
  });

  describe('captured_at', () => {
    it.each(['2024-02-29T23:59:59.999Z', '2026-11-10T00:00:00.000Z', '2026-12-31T23:59:59.000Z'])('accepts %s', (value) => {
      expect(parsePayload(withValue(REGISTRATION_TEXT, 'captured_at', value)).capturedAt).toBe(value);
    });

    it.each([
      ['no milliseconds', '2026-11-10T08:00:00Z'],
      ['microseconds', '2026-11-10T08:00:00.000000Z'],
      ['one fraction digit', '2026-11-10T08:00:00.0Z'],
      ['an offset instead of Z', '2026-11-10T10:00:00.000+02:00'],
      ['a lower-case z', '2026-11-10T08:00:00.000z'],
      ['no time zone', '2026-11-10T08:00:00.000'],
      ['a date only', '2026-11-10'],
      ['a space instead of T', '2026-11-10 08:00:00.000Z'],
      ['30 February', '2026-02-30T08:00:00.000Z'],
      ['29 February in a common year', '2026-02-29T08:00:00.000Z'],
      ['31 April', '2026-04-31T08:00:00.000Z'],
      ['month 13', '2026-13-01T08:00:00.000Z'],
      ['day 0', '2026-11-00T08:00:00.000Z'],
      ['hour 25', '2026-11-10T25:00:00.000Z'],
      ['hour 24', '2026-11-10T24:00:00.000Z'],
      ['minute 60', '2026-11-10T08:60:00.000Z'],
      ['a leap second', '2026-12-31T23:59:60.000Z'],
    ])('refuses %s', (_label, value) => {
      expect(refusedValue('captured_at', value).code).toBe('PAYLOAD_MALFORMED');
    });
  });

  it('names the field but never repeats the value in the message', () => {
    // Payloads carry GPS positions and ids, and these messages may be logged.
    const err = refusedValue('latitude', '-15.4197512');

    expect(err.message).toContain('latitude');
    expect(err.message).not.toContain('15.4197512');
  });
});

describe('canonicalise: refusals', () => {
  const canonRefusal = (step) => refusal(() => canonicalise(step));

  it.each([
    ['an unknown type', { ...HANDOFF, type: 'export' }],
    ['a type taken from Object.prototype', { ...HANDOFF, type: 'constructor' }],
    ['a missing field', (({ capturedAt: _c, ...rest }) => rest)(HANDOFF)],
    ['a mineral on a handoff', { ...HANDOFF, mineral: 'gold' }],
    ['an unsigned extra property', { ...REGISTRATION, note: 'hello' }],
    ['a weight as a JavaScript number', { ...REGISTRATION, weightMg: 1500000 }],
    ['a latitude as a JavaScript number', { ...REGISTRATION, latitude: -15.419751 }],
    ['a time as a Date', { ...REGISTRATION, capturedAt: new Date('2026-11-10T08:00:00.000Z') }],
    ['a value outside its grammar', { ...REGISTRATION, latitude: '-15.4197512' }],
    ['a negative bigint weight', { ...REGISTRATION, weightMg: -1n }],
  ])('refuses %s', (_label, step) => {
    const err = canonRefusal(step);

    expect(err).toBeInstanceOf(SigningError);
    expect(err.code).toBe('PAYLOAD_MALFORMED');
  });

  it.each([null, undefined, 'registration'])('refuses %j instead of a step object', (value) => {
    expect(canonRefusal(value).code).toBe('PAYLOAD_MALFORMED');
  });
});

describe('SigningError', () => {
  it('carries its code and name', () => {
    const err = parseRefusal('');

    expect(err.name).toBe('SigningError');
    expect(err).toBeInstanceOf(Error);
  });

  it('refuses an unknown code, so a typo cannot reach a client', () => {
    expect(() => new SigningError('PAYLOAD_BROKEN', 'x')).toThrow(TypeError);
  });
});
