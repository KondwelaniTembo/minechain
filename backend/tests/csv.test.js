import { describe, it, expect } from 'vitest';
import { toCsv, neutraliseFormula, CSV_BOM, CSV_LINE_END, FORMULA_TRIGGERS } from '../src/services/csv.js';

const TEXT = { header: 'qr_code', kind: 'text', key: 'qr' };
const NUMBER = { header: 'latitude', kind: 'number', key: 'lat' };
const TIME = { header: 'captured_at_utc', kind: 'time', key: 'at' };

// The file without its BOM, split into records. Only safe for tests whose cells hold no
// CRLF of their own.
const records = (csv) => csv.slice(CSV_BOM.length).split(CSV_LINE_END);

// The single data cell of a one-column, one-row file, quotes included.
const onlyCell = (column, value) => records(toCsv([column], [{ [column.key]: value }]))[1];

describe('toCsv: file layout', () => {
  it('starts with the UTF-8 BOM, then the header row', () => {
    const csv = toCsv([TEXT, NUMBER], []);

    expect(csv.startsWith(CSV_BOM)).toBe(true);
    expect(CSV_BOM).toBe('\uFEFF');
    expect(Buffer.from(csv, 'utf8').subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
    expect(records(csv)[0]).toBe('"qr_code","latitude"');
  });

  it('is just the header when there are no rows', () => {
    expect(toCsv([TEXT], [])).toBe(`${CSV_BOM}"qr_code"\r\n`);
  });

  it('ends every record with CRLF, including the last, and has no bare LF', () => {
    const csv = toCsv([TEXT], [{ qr: 'MC-001' }, { qr: 'MC-002' }]);

    expect(csv).toBe(`${CSV_BOM}"qr_code"\r\n"MC-001"\r\n"MC-002"\r\n`);
    expect(csv.replaceAll('\r\n', '')).not.toContain('\n');
  });

  it('writes the columns in the order given, reading each by its key', () => {
    const csv = toCsv([NUMBER, TEXT], [{ qr: 'MC-001', lat: '-15.419012', unused: 'x' }]);

    expect(records(csv)[1]).toBe('"-15.419012","MC-001"');
  });

  it('writes null and undefined as an empty quoted field, in every kind', () => {
    const csv = toCsv([TEXT, NUMBER, TIME], [{ qr: null, lat: undefined }]);

    expect(records(csv)[1]).toBe('"","",""');
  });
});

describe('toCsv: RFC 4180 quoting', () => {
  it('quotes every field, even plain ones', () => {
    expect(onlyCell(TEXT, 'MC001')).toBe('"MC001"');
  });

  it('doubles a quote inside a field', () => {
    expect(onlyCell(TEXT, 'He said "hi"')).toBe('"He said ""hi"""');
  });

  it('keeps a comma inside the field', () => {
    expect(onlyCell(TEXT, 'Kasempa, North')).toBe('"Kasempa, North"');
  });

  it('keeps line breaks inside the quotes as data', () => {
    const csv = toCsv([TEXT], [{ qr: 'line one\r\nline two\nline three' }]);

    expect(csv).toBe(`${CSV_BOM}"qr_code"\r\n"line one\r\nline two\nline three"\r\n`);
  });

  it('keeps characters outside ASCII as they are', () => {
    expect(onlyCell(TEXT, 'Zone −1 (Kabwé)')).toBe('"Zone −1 (Kabwé)"');
  });
});

describe('toCsv: CSV injection', () => {
  it.each(FORMULA_TRIGGERS.map((c) => [JSON.stringify(c), c]))('puts a quote mark before a text cell starting with %s', (_label, trigger) => {
    expect(onlyCell(TEXT, `${trigger}1+1`)).toBe(`"'${trigger}1+1"`);
  });

  it('neutralises a formula and still doubles its quotes', () => {
    const formula = '=HYPERLINK("http://evil.example","Click")';

    expect(onlyCell(TEXT, formula)).toBe('"\'=HYPERLINK(""http://evil.example"",""Click"")"');
  });

  it('leaves a trigger character that is not first alone', () => {
    expect(onlyCell(TEXT, 'MC-2026=1')).toBe('"MC-2026=1"');
  });

  it('does not check past a leading space (a known limit)', () => {
    expect(onlyCell(TEXT, ' =1+1')).toBe('" =1+1"');
  });

  it('does not cover full-width look-alikes (a known limit)', () => {
    expect(onlyCell(TEXT, '\uFF1D1+1')).toBe('"\uFF1D1+1"');
  });

  it('leaves a negative number cell unchanged, because it is checked instead', () => {
    expect(onlyCell(NUMBER, '-15.419012')).toBe('"-15.419012"');
  });

  it('neutraliseFormula leaves an empty string empty', () => {
    expect(neutraliseFormula('')).toBe('');
  });
});

describe('toCsv: number cells', () => {
  it.each([
    ['an integer', '1500000'],
    ['a decimal', '28.288000'],
    ['a negative decimal', '-15.419012'],
    ['zero', '0'],
    ['a kilogram value', '0.000500'],
  ])('accepts %s', (_label, value) => {
    expect(onlyCell(NUMBER, value)).toBe(`"${value}"`);
  });

  it('accepts a bigint', () => {
    expect(onlyCell(NUMBER, 7123456n)).toBe('"7123456"');
  });

  it.each([
    ['a formula', '=1+1'],
    ['a leading plus', '+1'],
    ['exponent form', '1e5'],
    ['hexadecimal', '0x10'],
    ['a leading zero', '007'],
    ['a leading space', ' 1'],
    ['a bare fraction', '.5'],
    ['a trailing point', '1.'],
    ['an empty string', ''],
    ['a JavaScript number, which could be a float', 1.5],
  ])('refuses %s, naming the column and row but not the value', (_label, value) => {
    expect(() => toCsv([NUMBER], [{ lat: '1' }, { lat: value }])).toThrow('CSV column "latitude" (number), row 2: must be a plain decimal number as text or a bigint');
  });
});

describe('toCsv: time cells', () => {
  it('writes a Date as UTC ISO 8601 with milliseconds', () => {
    expect(onlyCell(TIME, new Date('2026-11-10T10:00:00+02:00'))).toBe('"2026-11-10T08:00:00.000Z"');
  });

  it('accepts text already in the exact UTC form', () => {
    expect(onlyCell(TIME, '2026-11-10T08:00:00.000Z')).toBe('"2026-11-10T08:00:00.000Z"');
  });

  it.each([
    ['an invalid Date', new Date('not a date')],
    ['a time with an offset', '2026-11-10T10:00:00+02:00'],
    ['a date without a time', '2026-11-10'],
    ['an impossible month in the right shape', '2026-13-45T08:00:00.000Z'],
    ['30 February in the right shape', '2026-02-30T08:00:00.000Z'],
    ['a number of milliseconds', 1794297600000],
    ['a formula', '=NOW()'],
  ])('refuses %s', (_label, value) => {
    expect(() => onlyCell(TIME, value)).toThrow(/CSV column "captured_at_utc" \(time\), row 1:/);
  });
});

describe('toCsv: text cells and columns', () => {
  it('refuses a text cell that is not a string', () => {
    expect(() => onlyCell(TEXT, 42)).toThrow('CSV column "qr_code" (text), row 1: must be a string');
  });

  it.each([
    ['no columns', []],
    ['a header that is not snake_case', [{ header: 'QR Code', kind: 'text', key: 'qr' }]],
    ['a header starting with a formula character', [{ header: '=cmd', kind: 'text', key: 'qr' }]],
    ['an unknown kind', [{ header: 'qr_code', kind: 'formula', key: 'qr' }]],
    ['a missing key', [{ header: 'qr_code', kind: 'text' }]],
    ['the same header twice', [TEXT, { ...TEXT, key: 'other' }]],
  ])('refuses %s', (_label, columns) => {
    expect(() => toCsv(columns, [])).toThrow(TypeError);
  });

  it('refuses rows that are not an array', () => {
    expect(() => toCsv([TEXT], { qr: 'MC-001' })).toThrow('toCsv needs an array of rows');
  });
});
