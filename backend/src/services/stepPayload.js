// The signed payload, format version 1: docs/signing-spec.md, section 3. The phone builds
// this text once, signs its bytes, and sends the same text. This module turns a step into
// that text (canonicalise) and checks that a received text is exactly that (parsePayload).
//
// Pure: no database, no clock, no crypto. Signatures are checked in signatureService.js.
import { SigningError, SIGNING_ERROR_CODES } from './signingError.js';

const { PAYLOAD_MALFORMED, PAYLOAD_UNSUPPORTED_VERSION, PAYLOAD_NOT_CANONICAL } = SIGNING_ERROR_CODES;

export const PAYLOAD_VERSION = 1;
export const STEP_TYPES = Object.freeze(['registration', 'handoff', 'purchase']);

const HEADER_PREFIX = 'minechain-step/';

// Same list as the consignments_mineral_valid CHECK in the consignments migration. A
// mineral the database would refuse must be refused here first, before it is signed
// evidence the server has accepted.
export const MINERALS = Object.freeze(['gold', 'copper', 'cobalt', 'manganese', 'emerald', 'amethyst']);

// Same rule as the consignments_qr_code_format CHECK in the consignments migration:
// '^[A-Za-z0-9._:/-]+$' and 4 to 128 characters. It has no '=' and no LF, so a code can
// never break a key=value line.
const QR_CODE = /^[A-Za-z0-9._:/-]{4,128}$/;

// Lower case only: an upper-case id is a second spelling of the same id, so it is refused
// rather than folded (the account service lesson: compare ids as written, one form only).
const LOWER_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Up to 19 digits, no leading zero, so at least 1. BigInt then checks the exact maximum.
const WEIGHT = /^[1-9][0-9]{0,18}$/;
// The largest bigint, the type of transactions.weight_mg. It is below uint64's maximum, so
// any weight allowed here also fits the contract.
const MAX_WEIGHT_MG = 9223372036854775807n;

// Sign, whole degrees without a leading zero, exactly 6 decimals.
const COORDINATE = /^(-?)(0|[1-9][0-9]{0,2})\.([0-9]{6})$/;
const MICRO = 1_000_000n;

// Exactly what Date.prototype.toISOString() writes for years 0000 to 9999.
const CAPTURED_AT = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$/;

// Only printable ASCII (0x21 to 0x7E) and LF. This one test refuses spaces, tabs, CR, a
// BOM and every non-ASCII character, so encoding and Unicode normalisation never arise.
const ALLOWED_BYTES = /^[\x21-\x7E\n]*$/;

// Coordinates are compared as whole micro-degrees with BigInt, never as floats: "90.000001"
// becomes 90000001n, which is plainly above 90000000n. Returns false for "-0.000000",
// because zero has one spelling, "0.000000".
function coordinateInRange(text, limitDegrees) {
  const match = COORDINATE.exec(text);
  if (!match) return false;
  const [, sign, whole, fraction] = match;
  const micro = BigInt(whole) * MICRO + BigInt(fraction);
  if (sign === '-' && micro === 0n) return false;
  return micro <= BigInt(limitDegrees) * MICRO;
}

// A real calendar date and time. The pattern alone would pass 2026-02-30 or 25:00, and Date
// cannot be trusted on its own: some inputs it refuses (NaN), others it quietly rolls over
// into the next day or month. Requiring toISOString() to give back the exact text refuses
// both, because a rolled-over date prints differently.
function isRealUtcTime(text) {
  if (!CAPTURED_AT.test(text)) return false;
  const time = new Date(text);
  // toISOString() throws on an invalid Date, so NaN is checked first.
  return !Number.isNaN(time.getTime()) && time.toISOString() === text;
}

// Each field: its line key, its property name in the parsed step, and its rule. One table,
// so the text and the object can never disagree about a field.
const FIELD = {
  stepId: { key: 'step_id', rule: 'a lower-case UUID', test: (v) => LOWER_UUID.test(v) },
  actorId: { key: 'actor_id', rule: 'a lower-case UUID', test: (v) => LOWER_UUID.test(v) },
  qrCode: { key: 'qr_code', rule: '4-128 characters from A-Z a-z 0-9 . _ : / -', test: (v) => QR_CODE.test(v) },
  mineral: { key: 'mineral', rule: `one of ${MINERALS.join(', ')}`, test: (v) => MINERALS.includes(v) },
  weightMg: {
    key: 'weight_mg',
    rule: `whole milligrams, 1 to ${MAX_WEIGHT_MG}, with no sign or leading zero`,
    test: (v) => WEIGHT.test(v) && BigInt(v) <= MAX_WEIGHT_MG,
  },
  latitude: {
    key: 'latitude',
    rule: 'degrees with exactly 6 decimals, -90.000000 to 90.000000, zero written 0.000000',
    test: (v) => coordinateInRange(v, 90),
  },
  longitude: {
    key: 'longitude',
    rule: 'degrees with exactly 6 decimals, -180.000000 to 180.000000, zero written 0.000000',
    test: (v) => coordinateInRange(v, 180),
  },
  capturedAt: {
    key: 'captured_at',
    rule: 'a real UTC time written YYYY-MM-DDTHH:MM:SS.sssZ',
    test: (v) => isRealUtcTime(v),
  },
};

// The fixed order of lines after the header, per type (spec section 3, "Fields, in order").
const COMMON_HEAD = ['stepId', 'actorId', 'qrCode'];
const COMMON_TAIL = ['weightMg', 'latitude', 'longitude', 'capturedAt'];
const FIELDS_BY_TYPE = Object.freeze({
  registration: Object.freeze([...COMMON_HEAD, 'mineral', ...COMMON_TAIL]),
  handoff: Object.freeze([...COMMON_HEAD, ...COMMON_TAIL]),
  purchase: Object.freeze([...COMMON_HEAD, ...COMMON_TAIL]),
});

const malformed = (message) => new SigningError(PAYLOAD_MALFORMED, message);

// The text value of one field from a step object. Weight may be a bigint or its digits;
// coordinates and time must already be text. A JavaScript number is refused even where it
// would be exact, so no caller gets used to passing floats.
function fieldText(step, name) {
  const value = step[name];
  if (name === 'weightMg' && typeof value === 'bigint') return value.toString();
  if (typeof value !== 'string') {
    throw malformed(`${name} must be given as text${name === 'weightMg' ? ' or a bigint' : ''}`);
  }
  return value;
}

// Builds the exact payload text for a step:
//   { type, stepId, actorId, qrCode, mineral (registration only), weightMg, latitude,
//     longitude, capturedAt }
// Every value is checked against the same rules parsePayload uses, so this can only ever
// produce text that parses back to the same step.
export function canonicalise(step) {
  if (step === null || typeof step !== 'object') throw malformed('step must be an object');
  // hasOwn, not a plain lookup: a type such as "constructor" would otherwise find
  // Object.prototype's property.
  if (!Object.hasOwn(FIELDS_BY_TYPE, step.type)) {
    throw malformed(`type must be one of ${STEP_TYPES.join(', ')}`);
  }
  const fields = FIELDS_BY_TYPE[step.type];

  // A property this type does not sign (for example mineral on a handoff) is refused:
  // silently dropping it would let a caller believe it had been signed.
  const allowed = new Set(['type', ...fields]);
  const extra = Object.keys(step).filter((name) => !allowed.has(name));
  if (extra.length > 0) throw malformed(`not signed for a ${step.type}: ${extra.join(', ')}`);

  const lines = [`${HEADER_PREFIX}${PAYLOAD_VERSION}/${step.type}`];
  for (const name of fields) {
    const text = fieldText(step, name);
    if (!FIELD[name].test(text)) throw malformed(`${name} must be ${FIELD[name].rule}`);
    lines.push(`${FIELD[name].key}=${text}`);
  }
  // Every line ends with LF, including the last.
  return `${lines.join('\n')}\n`;
}

// Reads line 1 and returns the step type, or throws.
function parseHeader(line) {
  if (!line.startsWith(HEADER_PREFIX)) throw malformed('line 1 must be the minechain-step header');
  const rest = line.slice(HEADER_PREFIX.length);
  const slash = rest.indexOf('/');
  if (slash === -1) throw malformed('line 1 must be minechain-step/<version>/<type>');
  const version = rest.slice(0, slash);
  const type = rest.slice(slash + 1);
  if (version !== String(PAYLOAD_VERSION)) {
    // Its own code: a newer app may send a version this server does not know yet, which
    // is a different situation from a broken record.
    throw new SigningError(PAYLOAD_UNSUPPORTED_VERSION, `payload version ${/^[0-9]{1,4}$/.test(version) ? version : '(invalid)'} is not supported; this server reads version ${PAYLOAD_VERSION}`);
  }
  if (!Object.hasOwn(FIELDS_BY_TYPE, type)) throw malformed(`line 1 must name one of ${STEP_TYPES.join(', ')}`);
  return type;
}

// Checks that text is a valid, canonical version 1 payload and returns the step it
// describes. weightMg, latitude and longitude stay as text, so no value ever passes
// through a float: they go to PostgreSQL as exact bigint and numeric(9,6) text.
//
// The signature is verified over these same bytes in signatureService; this function only
// decides whether the bytes are a well-formed step.
export function parsePayload(text) {
  if (typeof text !== 'string' || text === '') throw malformed('payload must be non-empty text');
  if (!ALLOWED_BYTES.test(text)) {
    throw malformed('payload may contain only printable ASCII and LF (no spaces, CR, tabs or other characters)');
  }
  if (!text.endsWith('\n')) throw malformed('every line must end with LF, including the last');

  const lines = text.slice(0, -1).split('\n');
  const emptyAt = lines.indexOf('');
  if (emptyAt !== -1) throw malformed(`line ${emptyAt + 1} is empty`);

  const type = parseHeader(lines[0]);
  const fields = FIELDS_BY_TYPE[type];
  const body = lines.slice(1);
  if (body.length !== fields.length) {
    throw malformed(`a ${type} has ${fields.length + 1} lines; this payload has ${lines.length}`);
  }

  const step = { type };
  body.forEach((line, index) => {
    const lineNumber = index + 2;
    const name = fields[index];
    const { key, rule, test } = FIELD[name];
    const equals = line.indexOf('=');
    // The order is fixed, so each position expects exactly one key. A reordered, repeated
    // or misplaced line (such as mineral in a handoff) fails here.
    if (equals === -1 || line.slice(0, equals) !== key) {
      throw malformed(`line ${lineNumber} must be ${key}=...`);
    }
    const value = line.slice(equals + 1);
    if (!test(value)) throw malformed(`line ${lineNumber}: ${key} must be ${rule}`);
    step[name] = value;
  });

  // Belt and braces: the rules above admit one spelling only, so this cannot fail unless
  // someone later loosens a rule without noticing. If it ever did, the server would store
  // fields that are not byte-for-byte what was signed.
  if (canonicalise(step) !== text) throw new SigningError(PAYLOAD_NOT_CANONICAL, 'payload is not in canonical form');

  return step;
}
