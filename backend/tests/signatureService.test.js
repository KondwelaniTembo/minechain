import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, randomBytes, sign, ECDH } from 'node:crypto';
import {
  parsePublicKey,
  decodeSignature,
  verify,
  anchorHash,
  createSignatureService,
} from '../src/services/signatureService.js';
import { canonicalise } from '../src/services/stepPayload.js';
import { SigningError } from '../src/services/signingError.js';

// ---------- keys, made once per file (RSA in particular is slow) ----------

const p256 = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const otherP256 = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const secp256k1 = generateKeyPairSync('ec', { namedCurve: 'secp256k1' });
const ed25519 = generateKeyPairSync('ed25519');
const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });

const spki = (pair) => pair.publicKey.export({ type: 'spki', format: 'der' });
const SPKI = spki(p256);
const SPKI_B64 = SPKI.toString('base64');

// The order of the P-256 group, for making the high-S twin of a signature.
const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

// ---------- payloads (all ids fake) ----------

const HANDOFF = {
  type: 'handoff',
  stepId: '6f1d2c3a-0000-4000-8000-000000000002',
  actorId: '3f2b6c1e-0000-4000-8000-000000000002',
  qrCode: 'MC-2026-000123',
  weightMg: '1495000',
  latitude: '-15.390012',
  longitude: '28.322540',
  capturedAt: '2026-11-10T14:30:05.250Z',
};
const PAYLOAD = canonicalise({
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

// What the phone does: SHA256withECDSA over the payload bytes, DER output. Node's default
// encoding for EC keys is DER, the same as the Android Keystore.
const signDer = (payload, privateKey = p256.privateKey) => sign('sha256', Buffer.from(payload, 'utf8'), privateKey);
const SIGNATURE = signDer(PAYLOAD);
const SIGNATURE_B64 = SIGNATURE.toString('base64');

// ---------- DER by hand, independent of the service ----------

// Reads SEQUENCE { INTEGER r, INTEGER s } from a short-form DER signature (every P-256
// signature fits short form: at most 72 bytes). Used while test tables are built, outside
// any test, so it throws plainly instead of using expect.
function readDer(der) {
  if (der[0] !== 0x30 || der[2] !== 0x02) throw new Error('test setup: not a DER ECDSA signature');
  const rLength = der[3];
  const r = der.subarray(4, 4 + rLength);
  const sLength = der[5 + rLength];
  const s = der.subarray(6 + rLength, 6 + rLength + sLength);
  return { r, s };
}

// A positive integer as minimal DER content bytes: big-endian, with one 0x00 in front only
// when the top bit is set (otherwise it would read as negative).
function integerBytes(value) {
  let hex = value.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  const bytes = Buffer.from(hex, 'hex');
  return bytes[0] & 0x80 ? Buffer.concat([Buffer.from([0]), bytes]) : bytes;
}

function writeDer(r, s) {
  const body = Buffer.concat([Buffer.from([0x02, r.length]), r, Buffer.from([0x02, s.length]), s]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
}

const toBigInt = (bytes) => BigInt(`0x${bytes.toString('hex')}`);

// Signs until the DER signature leaves room for one extra byte within the 72-byte limit,
// so a padded copy is still a candidate signature rather than refused for its length.
function signatureWithRoom(payload) {
  for (;;) {
    const der = signDer(payload);
    if (der.length <= 71) return der;
  }
}

// ---------- small helpers ----------

// Runs fn and returns what it threw (a function, not a value, so the error is caught here).
function refusal(fn) {
  try {
    fn();
  } catch (err) {
    return err;
  }
  throw new Error('expected a refusal, but nothing was thrown');
}

// Changes the last character of one line of the payload, keeping every other byte.
function tamperLine(payload, index) {
  const lines = payload.slice(0, -1).split('\n');
  const line = lines[index];
  const last = line.at(-1);
  lines[index] = line.slice(0, -1) + (last === '7' ? '8' : '7');
  return `${lines.join('\n')}\n`;
}

const flipByte = (bytes, index) => {
  const copy = Buffer.from(bytes);
  copy[index] ^= 0x01;
  return copy;
};

const verifies = (overrides = {}) =>
  verify({ payload: PAYLOAD, signature: SIGNATURE_B64, publicKey: SPKI_B64, ...overrides });

// ---------- tests ----------

describe('verify: genuine signatures', () => {
  it('accepts a DER signature over the payload, given as base64', () => {
    expect(verifies()).toBe(true);
  });

  it('accepts the signature and key as Buffers, as read back from bytea columns', () => {
    expect(verifies({ signature: SIGNATURE, publicKey: SPKI })).toBe(true);
  });

  it('accepts a signature of every step type', () => {
    for (const type of ['handoff', 'purchase']) {
      const payload = canonicalise({ ...HANDOFF, type });

      expect(verify({ payload, signature: signDer(payload), publicKey: SPKI })).toBe(true);
    }
  });

  it('is also reachable through createSignatureService', () => {
    const service = createSignatureService();

    expect(service.verify({ payload: PAYLOAD, signature: SIGNATURE, publicKey: SPKI })).toBe(true);
  });
});

describe('verify: a changed payload', () => {
  const lineCount = PAYLOAD.slice(0, -1).split('\n').length;

  it.each(Array.from({ length: lineCount }, (_, i) => [i + 1, PAYLOAD.slice(0, -1).split('\n')[i].split('=')[0], i]))(
    'fails when line %i (%s) changes by one character',
    (_line, _key, index) => {
      const tampered = tamperLine(PAYLOAD, index);

      expect(tampered).not.toBe(PAYLOAD);
      expect(verifies({ payload: tampered })).toBe(false);
    },
  );

  it('fails when the same body is presented under another type header', () => {
    // A handoff and a purchase have identical bodies, so only the header tells them apart.
    const handoff = canonicalise(HANDOFF);
    const signature = signDer(handoff);
    const asPurchase = handoff.replace('minechain-step/1/handoff', 'minechain-step/1/purchase');

    expect(verify({ payload: handoff, signature, publicKey: SPKI })).toBe(true);
    expect(verify({ payload: asPurchase, signature, publicKey: SPKI })).toBe(false);
  });

  it('fails without the final LF', () => {
    expect(verifies({ payload: PAYLOAD.slice(0, -1) })).toBe(false);
  });
});

describe('verify: wrong or broken signatures return false and never throw', () => {
  const truncated = SIGNATURE.subarray(0, SIGNATURE.length - 1);
  const p1363 = sign('sha256', Buffer.from(PAYLOAD), { key: p256.privateKey, dsaEncoding: 'ieee-p1363' });

  // An integer with an extra leading zero byte is valid BER but not DER.
  const padded = (() => {
    const der = signatureWithRoom(PAYLOAD);
    const { r, s } = readDer(der);
    return writeDer(Buffer.concat([Buffer.from([0]), r]), s);
  })();

  it.each([
    ['a signature by another P-256 key', { signature: signDer(PAYLOAD, otherP256.privateKey) }],
    ['the right signature checked against another key', { publicKey: spki(otherP256) }],
    ['a raw 64-byte r||s (IEEE P1363) signature', { signature: p1363 }],
    ['non-canonical DER (an integer padded with a zero byte)', { signature: padded }],
    ['a signature missing its last byte', { signature: truncated }],
    ['a signature with one bit flipped in s', { signature: flipByte(SIGNATURE, SIGNATURE.length - 1) }],
    ['a signature with one bit flipped in the DER header', { signature: flipByte(SIGNATURE, 0) }],
    ['70 random bytes', { signature: randomBytes(70) }],
    ['a signature over a different payload', { signature: signDer(tamperLine(PAYLOAD, 5)) }],
  ])('%s', (_label, overrides) => {
    let result;
    expect(() => {
      result = verifies(overrides);
    }).not.toThrow();
    expect(result).toBe(false);
  });

  it('really does build the padded signature from the genuine one', () => {
    // Guards the test above: without the padding byte the same r and s verify.
    const der = signatureWithRoom(PAYLOAD);
    const { r, s } = readDer(der);

    expect(verifies({ signature: writeDer(r, s) })).toBe(true);
    expect(verifies({ signature: writeDer(Buffer.concat([Buffer.from([0]), r]), s) })).toBe(false);
  });

  it('gives P1363 the expected 64 bytes, so it is a candidate and not refused for length', () => {
    expect(p1363).toHaveLength(64);
  });
});

describe('verify: the high-S twin (malleability)', () => {
  const { r, s } = readDer(SIGNATURE);
  const twin = writeDer(integerBytes(toBigInt(r)), integerBytes(P256_N - toBigInt(s)));

  it('is a different signature that also verifies, which is why signatures are never identifiers', () => {
    expect(twin.equals(SIGNATURE)).toBe(false);
    expect(verifies({ signature: twin })).toBe(true);
  });

  it('has a different anchor hash, so a replay of it with the same step_id gets 409', () => {
    const original = anchorHash({ payload: PAYLOAD, signature: SIGNATURE, publicKey: SPKI });
    const ofTwin = anchorHash({ payload: PAYLOAD, signature: twin, publicKey: SPKI });

    expect(ofTwin.equals(original)).toBe(false);
  });
});

describe('verify: malformed input throws', () => {
  it.each([
    ['a Buffer', Buffer.from(PAYLOAD)],
    ['undefined', undefined],
    ['a number', 42],
  ])('refuses a payload that is %s instead of text', (_label, payload) => {
    const err = refusal(() => verifies({ payload }));

    expect(err).toBeInstanceOf(SigningError);
    expect(err.code).toBe('PAYLOAD_MALFORMED');
  });

  it('refuses a signature that is not strict base64', () => {
    expect(refusal(() => verifies({ signature: `${SIGNATURE_B64} ` })).code).toBe('SIGNATURE_MALFORMED');
  });

  it('refuses an empty signature as malformed: 0 bytes is not a DER P-256 signature at all', () => {
    expect(refusal(() => verifies({ signature: Buffer.alloc(0) })).code).toBe('SIGNATURE_MALFORMED');
  });

  it('refuses a key that is not P-256', () => {
    expect(refusal(() => verifies({ publicKey: spki(secp256k1) })).code).toBe('KEY_INVALID');
  });
});

describe('parsePublicKey', () => {
  it('accepts a P-256 SPKI as base64 or as a Buffer', () => {
    for (const input of [SPKI_B64, SPKI]) {
      const key = parsePublicKey(input);

      expect(key.asymmetricKeyType).toBe('ec');
      expect(key.asymmetricKeyDetails.namedCurve).toBe('prime256v1');
    }
  });

  // The compressed form of the same P-256 key: SPKI header for a 33-byte point, then the point.
  const compressed = (() => {
    const point = SPKI.subarray(SPKI.length - 65);
    const short = ECDH.convertKey(point, 'prime256v1', undefined, undefined, 'compressed');
    const header = Buffer.from('3039301306072a8648ce3d020106082a8648ce3d030107032200', 'hex');
    return Buffer.concat([header, short]);
  })();

  it.each([
    ['secp256k1', spki(secp256k1)],
    ['Ed25519', spki(ed25519)],
    ['RSA', spki(rsa)],
    ['compressed P-256', compressed],
    ['a truncated key', SPKI.subarray(0, 90)],
    ['a key with a byte added', Buffer.concat([SPKI, Buffer.from([0])])],
    ['91 random bytes', randomBytes(91)],
    ['a key with one byte flipped in the point', flipByte(SPKI, SPKI.length - 1)],
    ['a key with one byte flipped in the curve id', flipByte(SPKI, 20)],
    ['an empty Buffer', Buffer.alloc(0)],
  ])('refuses %s', (_label, input) => {
    const err = refusal(() => parsePublicKey(input));

    expect(err).toBeInstanceOf(SigningError);
    expect(err.code).toBe('KEY_INVALID');
  });

  it('refuses the key as PEM text instead of DER', () => {
    const pem = p256.publicKey.export({ type: 'spki', format: 'pem' });

    expect(refusal(() => parsePublicKey(pem)).code).toBe('KEY_INVALID');
  });

  it.each([
    ['without padding', SPKI_B64.replace(/=+$/, '')],
    ['as base64url', SPKI.toString('base64url')],
    ['with a line break inside', `${SPKI_B64.slice(0, 64)}\n${SPKI_B64.slice(64)}`],
    ['with a trailing space', `${SPKI_B64} `],
  ])('refuses the base64 %s', (_label, input) => {
    expect(refusal(() => parsePublicKey(input)).code).toBe('KEY_INVALID');
  });

  it.each([
    ['undefined', undefined],
    ['a number', 91],
    ['a Uint8Array that is not a Buffer', new Uint8Array(91)],
  ])('refuses %s', (_label, input) => {
    expect(refusal(() => parsePublicKey(input)).code).toBe('KEY_INVALID');
  });

  it('checks that the test keys really are the lengths that make each one fail', () => {
    // Documents why most of the refusals above are caught: only P-256 uncompressed is 91.
    expect(SPKI).toHaveLength(91);
    expect(compressed).toHaveLength(59);
    expect(spki(secp256k1)).toHaveLength(88);
    expect(spki(ed25519)).toHaveLength(44);
  });
});

describe('decodeSignature', () => {
  // Bytes chosen so their base64 uses both + and /, the two letters base64url replaces.
  const BYTES = Buffer.from([0xfb, 0xff, 0xbf, 0xfb, 0xff, 0xbf, 0xfb, 0xff]);
  const TEXT = '+/+/+/+/+/8=';

  it('decodes strict standard base64', () => {
    expect(BYTES.toString('base64')).toBe(TEXT);
    expect(decodeSignature(TEXT).equals(BYTES)).toBe(true);
  });

  it('accepts a Buffer as it is', () => {
    expect(decodeSignature(SIGNATURE).equals(SIGNATURE)).toBe(true);
  });

  it.each([
    ['base64url letters', '-_-_-_-_-_8='],
    ['missing padding', '+/+/+/+/+/8'],
    ['a space inside', '+/+/ +/+/+/8='],
    ['a line break inside', '+/+/+/+/\n+/8='],
    ['a trailing line break', `${TEXT}\n`],
    // Decodes to the same bytes, but the last character carries stray bits, so it is a
    // second spelling of the same signature.
    ['stray bits in the last character', '+/+/+/+/+/9='],
    ['too much padding', '+/+/+/+/+/8=='],
    ['an empty string', ''],
  ])('refuses %s', (_label, input) => {
    const err = refusal(() => decodeSignature(input));

    expect(err).toBeInstanceOf(SigningError);
    expect(err.code).toBe('SIGNATURE_MALFORMED');
  });

  it.each([
    ['7 bytes', Buffer.alloc(7, 1)],
    ['73 bytes', Buffer.alloc(73, 1)],
    ['0 bytes', Buffer.alloc(0)],
  ])('refuses %s, outside the DER length limits', (_label, bytes) => {
    expect(refusal(() => decodeSignature(bytes)).code).toBe('SIGNATURE_MALFORMED');
    expect(refusal(() => decodeSignature(bytes.toString('base64') || 'AA==')).code).toBe('SIGNATURE_MALFORMED');
  });

  it.each([
    ['8 bytes', 8],
    ['72 bytes', 72],
  ])('accepts %s, the limits themselves', (_label, length) => {
    expect(decodeSignature(Buffer.alloc(length, 1))).toHaveLength(length);
  });
});

describe('anchorHash, version 1', () => {
  // The preimage built by hand from section 7 of the spec, not with the service's code.
  function expectedHash(payload, key, signature) {
    const prefix = Buffer.from('minechain-anchor/1\n', 'ascii');
    const length = (n) => {
      const b = Buffer.alloc(4);
      b.writeUInt32BE(n);
      return b;
    };
    const payloadBytes = Buffer.from(payload, 'ascii');
    const preimage = Buffer.concat([
      prefix,
      length(payloadBytes.length),
      payloadBytes,
      length(key.length),
      key,
      length(signature.length),
      signature,
    ]);
    // Guards the hand-built preimage itself against a slip in this test.
    expect(prefix).toHaveLength(19);
    expect(preimage).toHaveLength(19 + 4 + payloadBytes.length + 4 + 91 + 4 + signature.length);
    return createHash('sha256').update(preimage).digest();
  }

  it('is SHA-256 of the prefix and the three length-prefixed parts', () => {
    const hash = anchorHash({ payload: PAYLOAD, signature: SIGNATURE_B64, publicKey: SPKI_B64 });

    expect(hash).toHaveLength(32);
    expect(hash.equals(expectedHash(PAYLOAD, SPKI, SIGNATURE))).toBe(true);
  });

  it('writes the lengths big-endian', () => {
    // The payload is under 256 bytes, so its big-endian length is 00 00 00 nn and a
    // little-endian one would be nn 00 00 00: a different preimage, so a different hash.
    const bytes = Buffer.from(PAYLOAD, 'ascii');
    expect(bytes.length).toBeLessThan(256);
    const littleEndian = Buffer.alloc(4);
    littleEndian.writeUInt32LE(bytes.length);
    const wrong = createHash('sha256')
      .update(Buffer.concat([Buffer.from('minechain-anchor/1\n'), littleEndian, bytes]))
      .update(Buffer.concat([Buffer.from([0, 0, 0, 91]), SPKI]))
      .update(Buffer.concat([Buffer.from([0, 0, 0, SIGNATURE.length]), SIGNATURE]))
      .digest();

    expect(anchorHash({ payload: PAYLOAD, signature: SIGNATURE, publicKey: SPKI }).equals(wrong)).toBe(false);
  });

  it('gives the same hash for base64 and Buffer inputs', () => {
    const fromText = anchorHash({ payload: PAYLOAD, signature: SIGNATURE_B64, publicKey: SPKI_B64 });
    const fromBytes = anchorHash({ payload: PAYLOAD, signature: SIGNATURE, publicKey: SPKI });

    expect(fromText.equals(fromBytes)).toBe(true);
  });

  it.each([
    ['the payload', { payload: tamperLine(PAYLOAD, 5) }],
    ['the key', { publicKey: spki(otherP256) }],
    ['the signature', { signature: signDer(PAYLOAD) }],
  ])('changes when %s changes', (_label, overrides) => {
    const base = { payload: PAYLOAD, signature: SIGNATURE, publicKey: SPKI };
    const changed = { ...base, ...overrides };

    expect(anchorHash(changed).equals(anchorHash(base))).toBe(false);
    expect(anchorHash(changed).equals(expectedHash(changed.payload, Buffer.from(changed.publicKey), Buffer.from(changed.signature)))).toBe(true);
  });

  it('refuses malformed input like verify does', () => {
    expect(refusal(() => anchorHash({ payload: PAYLOAD, signature: SIGNATURE, publicKey: spki(rsa) })).code).toBe('KEY_INVALID');
    expect(refusal(() => anchorHash({ payload: PAYLOAD, signature: 'not base64!', publicKey: SPKI })).code).toBe(
      'SIGNATURE_MALFORMED',
    );
    expect(refusal(() => anchorHash({ payload: Buffer.from(PAYLOAD), signature: SIGNATURE, publicKey: SPKI })).code).toBe(
      'PAYLOAD_MALFORMED',
    );
  });
});
