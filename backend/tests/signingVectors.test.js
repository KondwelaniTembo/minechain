import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { canonicalise, parsePayload, PAYLOAD_VERSION } from '../src/services/stepPayload.js';
import {
  verify,
  anchorHash,
  parsePublicKey,
  decodeSignature,
  ANCHOR_HASH_VERSION,
} from '../src/services/signatureService.js';
import { SigningError, SIGNING_ERROR_CODES } from '../src/services/signingError.js';

// Only READS the committed vectors (docs/signing-spec.md, section 9). It never regenerates
// them: the point is that these exact bytes, signatures and hashes stay fixed, so the
// Flutter tests and these tests check the same thing.
const VECTORS_URL = new URL('../../docs/signing-vectors.json', import.meta.url);

function loadVectors() {
  let text;
  try {
    text = readFileSync(VECTORS_URL, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') {
      throw new Error('docs/signing-vectors.json is missing: run `npm run make:signing-vectors` once and commit the file');
    }
    throw err;
  }
  return { text, vectors: JSON.parse(text) };
}

const { text: RAW, vectors: VECTORS } = loadVectors();

const ascii = (s) => Buffer.from(s, 'ascii');
const sha256Hex = (bytes) => createHash('sha256').update(bytes).digest('hex');

describe('signing-vectors.json: the file itself', () => {
  it('declares the versions this code implements', () => {
    expect(VECTORS).toMatchObject({
      format: 'minechain-signing-vectors',
      formatVersion: 1,
      payloadVersion: PAYLOAD_VERSION,
      anchorHashVersion: ANCHOR_HASH_VERSION,
    });
    expect(VECTORS.note).toMatch(/never regenerate/i);
  });

  it('has one positive vector per step type, and some of each negative kind', () => {
    expect(VECTORS.positive.map((v) => v.fields.type)).toEqual(['registration', 'handoff', 'purchase']);
    expect(VECTORS.negativePayloads.length).toBeGreaterThan(0);
    expect(VECTORS.negativeSignatures.length).toBeGreaterThan(0);
  });

  describe('contains no private key material', () => {
    it.each([
      ['the word PRIVATE', 'PRIVATE'],
      ['a PEM header', '-----BEGIN'],
      // How a PKCS8 P-256 private key starts in base64 (SEQUENCE, INTEGER 0, ...).
      ['a PKCS8 private key', 'MIGHAgEA'],
      // How a SEC1 ("EC PRIVATE KEY") structure starts in base64.
      ['a SEC1 EC private key', 'MHcCAQEE'],
    ])('no %s', (_label, needle) => {
      // Case-sensitive on purpose: base64 is case-sensitive, and PEM writes "PRIVATE KEY" in
      // capitals. The file's note mentions "the private key was discarded" in lower case.
      expect(RAW).not.toContain(needle);
    });

    // Walks every object in the file and collects its property names.
    const allKeys = (value, found = []) => {
      if (Array.isArray(value)) value.forEach((item) => allKeys(item, found));
      else if (value && typeof value === 'object') {
        for (const [key, inner] of Object.entries(value)) {
          found.push(key);
          allKeys(inner, found);
        }
      }
      return found;
    };

    it('no JWK "d" field, and no property named like a private key or secret', () => {
      const keys = allKeys(VECTORS);

      expect(keys).not.toContain('d');
      expect(keys.filter((k) => /private|secret|pkcs8|pem/i.test(k))).toEqual([]);
    });

    it('every stored key is a 91-byte P-256 public key, and there is only one', () => {
      const keys = [
        ...VECTORS.positive.map((v) => v.publicKey),
        ...VECTORS.negativeSignatures.map((v) => v.publicKey),
      ];
      for (const key of keys) {
        expect(Buffer.from(key, 'base64')).toHaveLength(91);
        expect(() => parsePublicKey(key)).not.toThrow();
      }
      expect(new Set(keys).size).toBe(1);
    });
  });
});

describe('signing-vectors.json: positive vectors', () => {
  const rows = VECTORS.positive.map((v) => [v.name, v]);

  it.each(rows)('%s: canonicalise(fields) gives exactly the stored payload', (_name, v) => {
    expect(canonicalise(v.fields)).toBe(v.payload);
  });

  it.each(rows)('%s: the stored hex and SHA-256 match the payload bytes', (_name, v) => {
    expect(ascii(v.payload).toString('hex')).toBe(v.payloadHex);
    expect(sha256Hex(ascii(v.payload))).toBe(v.payloadSha256);
    // The hex is the payload, so a consumer that only reads hex gets the same bytes.
    expect(Buffer.from(v.payloadHex, 'hex').toString('ascii')).toBe(v.payload);
  });

  it.each(rows)('%s: parsePayload round-trips', (_name, v) => {
    const parsed = parsePayload(v.payload);

    expect(parsed).toEqual(v.fields);
    expect(canonicalise(parsed)).toBe(v.payload);
  });

  it.each(rows)('%s: the fixed signature is DER and verifies', (_name, v) => {
    const signature = decodeSignature(v.signature);

    expect(signature[0]).toBe(0x30);
    expect(verify({ payload: v.payload, signature: v.signature, publicKey: v.publicKey })).toBe(true);
  });

  it.each(rows)('%s: the anchor hash matches', (_name, v) => {
    const hash = anchorHash({ payload: v.payload, signature: v.signature, publicKey: v.publicKey });

    expect(hash.toString('hex')).toBe(v.anchorHash);
  });
});

describe('signing-vectors.json: negative payloads', () => {
  it.each(VECTORS.negativePayloads.map((v) => [v.name, v]))('%s is refused with its code', (_name, v) => {
    expect(Object.keys(SIGNING_ERROR_CODES)).toContain(v.expectedError);

    let error;
    try {
      parsePayload(v.payload);
    } catch (err) {
      error = err;
    }
    expect(error, 'parsePayload should refuse this payload').toBeInstanceOf(SigningError);
    expect(error.code).toBe(v.expectedError);
  });
});

describe('signing-vectors.json: negative signatures', () => {
  it.each(VECTORS.negativeSignatures.map((v) => [v.name, v]))('%s: verify returns false', (_name, v) => {
    expect(v.expectedVerify).toBe(false);

    let result;
    expect(() => {
      result = verify({ payload: v.payload, signature: v.signature, publicKey: v.publicKey });
    }).not.toThrow();
    expect(result).toBe(false);
  });
});
