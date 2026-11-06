// The one error type for everything in docs/signing-spec.md: payloads (stepPayload.js) and,
// from 5c, keys and signatures (signatureService.js). One class, so the sync service can
// tell "this record is malformed" apart from a database or programming fault with a single
// instanceof check.
//
// Messages name the field and the rule, never the value: a payload carries GPS positions
// and ids, and these errors may be logged.
export const SIGNING_ERROR_CODES = Object.freeze({
  // The header names a format version this server does not read.
  PAYLOAD_UNSUPPORTED_VERSION: 'PAYLOAD_UNSUPPORTED_VERSION',
  // Not a valid payload: a forbidden byte, a missing or misplaced line, a value outside its
  // grammar.
  PAYLOAD_MALFORMED: 'PAYLOAD_MALFORMED',
  // Every rule passed, yet writing the fields back out gave different bytes. The grammar
  // should make this impossible; it is a final check against a future edit getting the
  // rules out of step.
  PAYLOAD_NOT_CANONICAL: 'PAYLOAD_NOT_CANONICAL',
  // Used from 5c.
  KEY_INVALID: 'KEY_INVALID',
  SIGNATURE_MALFORMED: 'SIGNATURE_MALFORMED',
});

export class SigningError extends Error {
  constructor(code, message) {
    if (!Object.hasOwn(SIGNING_ERROR_CODES, code)) {
      // A typo in a code would otherwise reach the client as an unknown, unstable code.
      throw new TypeError(`Unknown signing error code: ${code}`);
    }
    super(message);
    this.name = 'SigningError';
    this.code = code;
  }
}
