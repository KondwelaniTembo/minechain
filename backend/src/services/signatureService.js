// Keys, signatures and the anchor hash: docs/signing-spec.md, sections 2, 5 and 7.
// Only node:crypto, no extra packages. Pure: no database, no clock.
//
// Two kinds of failure, kept apart on purpose:
//   - malformed input (bad base64, a key that is not P-256, a payload that is not text)
//     throws a SigningError: the client sent something that is not even a candidate;
//   - a well-formed signature that does not match returns false: that is anomaly check 4,
//     which the sync service turns into a flagged step and an invalid_signature alert.
import { createHash, createPublicKey, verify as cryptoVerify } from 'node:crypto';
import { SigningError, SIGNING_ERROR_CODES } from './signingError.js';

const { KEY_INVALID, SIGNATURE_MALFORMED, PAYLOAD_MALFORMED } = SIGNING_ERROR_CODES;

// An uncompressed P-256 SubjectPublicKeyInfo in DER is always 91 bytes; the users and
// transactions migrations check the same length.
export const P256_SPKI_LENGTH = 91;
// The DER signature limits in the transactions_signature_der_length CHECK.
export const SIGNATURE_MIN_LENGTH = 8;
export const SIGNATURE_MAX_LENGTH = 72;

export const ANCHOR_HASH_VERSION = 1;
// 19 ASCII bytes, the start of every version 1 preimage (spec section 7).
const ANCHOR_PREFIX = Buffer.from('minechain-anchor/1\n', 'ascii');

// Standard base64 alphabet, padding only at the end. The length and re-encoding checks
// below do the rest.
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

// Buffer.from(text, 'base64') is forgiving: it skips spaces and line breaks, accepts the
// base64url letters - and _, and ignores missing padding and stray bits in the last
// character. So the text is decoded, encoded again, and must come back identical. One
// sequence of bytes then has exactly one accepted spelling. Returns null when it does not.
function decodeBase64Strict(text) {
  if (typeof text !== 'string' || text.length === 0 || text.length % 4 !== 0 || !BASE64.test(text)) {
    return null;
  }
  const bytes = Buffer.from(text, 'base64');
  return bytes.toString('base64') === text ? bytes : null;
}

// Keys and signatures arrive as base64 from the app, and as Buffers when read back from
// bytea columns. Both forms go through the same checks.
function toBytes(input) {
  if (Buffer.isBuffer(input)) return input;
  return decodeBase64Strict(input);
}

function keyInvalid(reason) {
  return new SigningError(KEY_INVALID, `public key ${reason}; expected a P-256 key as SPKI DER (${P256_SPKI_LENGTH} bytes, standard base64)`);
}

// Returns the key's exact SPKI bytes and a KeyObject for crypto.verify, or throws
// KEY_INVALID. Every check matters:
//   - 91 bytes: refuses compressed points (59 bytes), other curves and other key types;
//   - createPublicKey: refuses anything that is not SPKI DER, and points not on the curve;
//   - ec on prime256v1: refuses another curve or key type, should one ever be 91 bytes;
//   - re-export identical: refuses a second encoding of the same key, so the bytes stored
//     as signer_public_key and hashed into the anchor are the one canonical form.
function parseKey(input) {
  const bytes = toBytes(input);
  if (bytes === null) throw keyInvalid('is not a Buffer or strict standard base64');
  if (bytes.length !== P256_SPKI_LENGTH) throw keyInvalid(`is ${bytes.length} bytes`);

  let key;
  try {
    key = createPublicKey({ key: bytes, format: 'der', type: 'spki' });
  } catch {
    // OpenSSL's message is not passed on: it is about parsing internals, not the input.
    throw keyInvalid('is not valid SPKI DER');
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw keyInvalid('is not on the P-256 curve');
  }
  if (!key.export({ type: 'spki', format: 'der' }).equals(bytes)) {
    throw keyInvalid('is not in canonical SPKI DER form');
  }
  return { key, bytes };
}

// Validates a public key (base64 text or a Buffer) and returns a KeyObject.
export function parsePublicKey(input) {
  return parseKey(input).key;
}

// Decodes a signature (base64 text or a Buffer) to its bytes, or throws SIGNATURE_MALFORMED.
// Only the shape is checked here: whether the bytes are good DER is left to verify, which
// answers false rather than throwing, because a signature that fails is an anomaly to
// record, not a malformed request.
export function decodeSignature(input) {
  const bytes = toBytes(input);
  if (bytes === null) {
    throw new SigningError(SIGNATURE_MALFORMED, 'signature is not a Buffer or strict standard base64');
  }
  if (bytes.length < SIGNATURE_MIN_LENGTH || bytes.length > SIGNATURE_MAX_LENGTH) {
    throw new SigningError(
      SIGNATURE_MALFORMED,
      `signature is ${bytes.length} bytes; a DER P-256 signature is ${SIGNATURE_MIN_LENGTH} to ${SIGNATURE_MAX_LENGTH}`,
    );
  }
  return bytes;
}

function payloadBytes(payload) {
  if (typeof payload !== 'string') throw new SigningError(PAYLOAD_MALFORMED, 'payload must be text');
  // A valid payload is ASCII, so this is one byte per character. Parsing is not repeated
  // here: the sync service calls parsePayload, and verify must also work on stored rows.
  return Buffer.from(payload, 'utf8');
}

// True when signature is a valid ECDSA P-256 / SHA-256 signature, in DER, over the
// payload's bytes, by publicKey. The payload is not hashed first: SHA256withECDSA on the
// phone hashes it itself, and so does crypto.verify here.
//
// Returns false, never throws, for a wrong, garbled, truncated, raw r||s (P1363) or
// non-canonical DER signature. Throws a SigningError only for malformed input.
export function verify({ payload, signature, publicKey }) {
  const data = payloadBytes(payload);
  const { key } = parseKey(publicKey);
  const signatureBytes = decodeSignature(signature);

  try {
    // dsaEncoding 'der' is the default for EC keys; written out so it cannot change
    // silently. OpenSSL re-encodes the parsed signature and refuses it unless the bytes are
    // identical, so BER variants (such as an integer with an extra leading zero) fail.
    return cryptoVerify('sha256', data, { key, dsaEncoding: 'der' }, signatureBytes);
  } catch {
    // Some malformed DER makes OpenSSL report an error instead of a plain "no". Either way
    // the signature does not verify. The inputs were all checked above, so nothing else
    // that could throw here is a programming mistake being hidden.
    return false;
  }
}

function uint32BE(n) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(n);
  return bytes;
}

// The 32-byte anchor hash, version 1 (spec section 7):
//   SHA-256( "minechain-anchor/1\n"
//            || uint32_be(len(payload))   || payload
//            || uint32_be(len(publicKey)) || publicKey (SPKI DER)
//            || uint32_be(len(signature)) || signature (DER, as received) )
// The lengths keep the three parts apart, so no two different combinations hash the same
// bytes. The key and signature are included so the chain pins who signed, not only what.
// This must never change for version 1: anchored rows are re-hashed with it to detect
// tampering (contract spec, section 7).
export function anchorHash({ payload, signature, publicKey }) {
  const data = payloadBytes(payload);
  const { bytes: keyBytes } = parseKey(publicKey);
  const signatureBytes = decodeSignature(signature);

  return createHash('sha256')
    .update(ANCHOR_PREFIX)
    .update(uint32BE(data.length))
    .update(data)
    .update(uint32BE(keyBytes.length))
    .update(keyBytes)
    .update(uint32BE(signatureBytes.length))
    .update(signatureBytes)
    .digest();
}

// A short, exact name for a public key: the lower-case hex SHA-256 of its SPKI DER bytes
// (64 characters). Used in audit entries instead of the key itself, and shown to the app so
// it can tell whether the registered key is the one in its own Keystore. The key is
// validated first, so a fingerprint always names a real P-256 key in canonical form.
export function publicKeyFingerprint(input) {
  return spkiFingerprint(parseKey(input).bytes);
}

// The same fingerprint for key bytes that were validated when they were stored (a
// users.public_key or transactions.signer_public_key read back from the database). It does
// not validate again, on purpose: it runs on every /auth/me and every admin list, and a key
// that somehow failed validation there would turn each of those requests into a 500 and
// lock the user out. Showing its fingerprint is harmless; using it to verify is not, and
// verify always validates.
export function spkiFingerprint(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

// The same functions as one object, the shape the other services are built in. Nothing to
// configure yet; the factory leaves room for, say, a list of accepted hash versions.
export function createSignatureService() {
  return { parsePublicKey, publicKeyFingerprint, decodeSignature, verify, anchorHash };
}
