// CSV for spreadsheet reports (FR-09, FR-13). Pure: no database, no HTTP. The report
// service passes column definitions and rows, and gets back the whole file as one string.
//
// Format (RFC 4180, with two choices made for Excel):
//   - fields separated by commas, records ended by CRLF, including the last one;
//   - EVERY field in double quotes, with a " inside written as "". Quoting only some
//     fields would also be valid, but quoting all of them leaves nothing to get wrong;
//   - a header row of fixed column names first;
//   - UTF-8 with a byte order mark (BOM) at the very start. Without it, Excel on Windows
//     guesses a legacy encoding and garbles anything outside ASCII, such as the minus sign
//     in a zone name. A few command-line tools show the BOM; that is the trade-off.
//
// CSV injection (OWASP "CSV Injection"): a spreadsheet treats a cell that starts with = + -
// or @ as a formula, and a tab or carriage return at the start can hide one. A licence
// number typed at registration such as =HYPERLINK("http://evil.example","Click") would then
// run when an officer opens the report. Every TEXT cell that starts with one of those
// characters gets a single quote (') put in front, which spreadsheets show as plain text.
// Only the first character is checked, so " =1" (a leading space) is not changed; and
// full-width look-alikes such as ＝ are not covered (both known limits).
//
// Number and time cells are not neutralised, because a latitude such as -15.419012 must stay
// a number. They are safe because they are checked instead: a number cell must be plain
// decimal digits and a time cell an exact UTC timestamp, so no formula can get into one. A
// cell that fails its check stops the whole export with an error (a 500), rather than being
// written out unprotected.

export const CSV_BOM = '\uFEFF';
export const CSV_LINE_END = '\r\n';

export const COLUMN_KINDS = Object.freeze(['text', 'number', 'time']);

// The characters OWASP lists as starting a formula or hiding one.
export const FORMULA_TRIGGERS = Object.freeze(['=', '+', '-', '@', '\t', '\r']);

// Column names are fixed constants in the report service, never request text. The rule
// keeps them plain, so a header can never need neutralising itself.
const HEADER_FORMAT = /^[a-z][a-z0-9_]*$/;

// A plain decimal: an optional minus, no leading zeros, an optional fraction. Matches what
// pg returns for bigint and numeric, and what mgToKg returns. Refuses '1e5', ' 1', '0x10',
// '+1', '.5', '1.' and '' : anything a spreadsheet might read differently, or a formula.
const PLAIN_DECIMAL = /^-?(0|[1-9]\d*)(\.\d+)?$/;

// Exactly what Date.prototype.toISOString gives: UTC, milliseconds, a Z.
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

// Puts a single quote in front of a text that a spreadsheet would read as a formula.
// '=1+1' -> "'=1+1"; 'MC-001' (not at the start) and '' are unchanged.
export function neutraliseFormula(text) {
  return text.length > 0 && FORMULA_TRIGGERS.includes(text[0]) ? `'${text}` : text;
}

// Messages name the column and the row, never the value, so a bad value (which could be
// personal data) does not reach the server log.
function cellError(column, rowIndex, problem) {
  return new TypeError(`CSV column "${column.header}" (${column.kind}), row ${rowIndex + 1}: ${problem}`);
}

// One cell's text, before quoting. null and undefined are an empty cell in every kind.
function cellText(column, value, rowIndex) {
  if (value === null || value === undefined) return '';

  if (column.kind === 'text') {
    if (typeof value !== 'string') throw cellError(column, rowIndex, 'must be a string');
    return neutraliseFormula(value);
  }

  if (column.kind === 'number') {
    // Text (as pg returns bigint and numeric) or a bigint. A JavaScript number is refused,
    // so a float can never reach a report; values from signed payloads stay text.
    const text = typeof value === 'bigint' ? value.toString() : value;
    if (typeof text !== 'string' || !PLAIN_DECIMAL.test(text)) {
      throw cellError(column, rowIndex, 'must be a plain decimal number as text or a bigint');
    }
    return text;
  }

  // time: a Date (pg returns timestamptz as one) or text already in the exact UTC form.
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) throw cellError(column, rowIndex, 'is an invalid date');
    return value.toISOString();
  }
  // The round trip refuses an impossible time in the right shape, such as 30 February,
  // which some engines would quietly move to March.
  if (typeof value === 'string' && ISO_UTC.test(value)) {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime()) && parsed.toISOString() === value) return value;
  }
  throw cellError(column, rowIndex, 'must be a Date or a UTC time such as 2026-11-10T08:00:00.000Z');
}

// Every field is quoted, and a quote inside is doubled: He said "hi" -> "He said ""hi""".
// Commas, CR and LF inside the quotes are then plain data (RFC 4180, section 2).
const quote = (text) => `"${text.replaceAll('"', '""')}"`;

// Checked once per call, before any row: a mistake here is a programming error.
function checkColumns(columns) {
  if (!Array.isArray(columns) || columns.length === 0) {
    throw new TypeError('toCsv needs at least one column');
  }
  const seen = new Set();
  for (const column of columns) {
    if (typeof column?.header !== 'string' || !HEADER_FORMAT.test(column.header)) {
      throw new TypeError('toCsv: each column needs a snake_case header');
    }
    if (seen.has(column.header)) throw new TypeError(`toCsv: column "${column.header}" appears twice`);
    seen.add(column.header);
    if (!COLUMN_KINDS.includes(column.kind)) {
      throw new TypeError(`toCsv: column "${column.header}" needs a kind of ${COLUMN_KINDS.join(', ')}`);
    }
    if (typeof column.key !== 'string' || column.key === '') {
      throw new TypeError(`toCsv: column "${column.header}" needs the key to read from each row`);
    }
  }
}

// The whole file: BOM, header row, then one record per row, each ended by CRLF.
//   columns: [{ header, kind, key }]: header is the column name in the file, kind is one of
//            COLUMN_KINDS, key is the property read from each row
//   rows:    plain objects
// With no rows, the file is the header alone: an empty report is still a valid file.
export function toCsv(columns, rows) {
  checkColumns(columns);
  if (!Array.isArray(rows)) throw new TypeError('toCsv needs an array of rows');

  const lines = [columns.map((column) => quote(column.header)).join(',')];
  rows.forEach((row, rowIndex) => {
    lines.push(columns.map((column) => quote(cellText(column, row[column.key], rowIndex))).join(','));
  });
  return CSV_BOM + lines.join(CSV_LINE_END) + CSV_LINE_END;
}
