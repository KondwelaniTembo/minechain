import { describe, it, expect } from 'vitest';
import { publicKeyBodySchema } from '../src/schemas/auth.js';

// Shape of a fake base64 SPKI: 124 characters, as a 91-byte key takes. Not a real key; the
// schema does not decode it (signatureService does).
const KEY_TEXT = `MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE${'A'.repeat(86)}==`;

// Lists the fields that failed, so each test checks the rule it is about.
const failedFields = (input) => {
  const result = publicKeyBodySchema.safeParse(input);
  if (result.success) return [];
  return result.error.issues.flatMap((i) => (i.code === 'unrecognized_keys' ? i.keys : [i.path.join('.')]));
};

describe('publicKeyBodySchema', () => {
  it('accepts a base64 key and leaves it exactly as sent', () => {
    expect(KEY_TEXT).toHaveLength(124);
    expect(publicKeyBodySchema.parse({ publicKey: KEY_TEXT })).toEqual({ publicKey: KEY_TEXT });
  });

  it('does not trim, so the service sees exactly what the app sent', () => {
    // Strict base64 in signatureService refuses the spaces; quietly trimming here would
    // accept text the app never produced.
    expect(publicKeyBodySchema.parse({ publicKey: ` ${KEY_TEXT} ` }).publicKey).toBe(` ${KEY_TEXT} `);
  });

  it('accepts 200 characters, the cap', () => {
    expect(publicKeyBodySchema.safeParse({ publicKey: 'A'.repeat(200) }).success).toBe(true);
  });

  it.each([
    ['an empty key', { publicKey: '' }, ['publicKey']],
    ['a key over 200 characters', { publicKey: 'A'.repeat(201) }, ['publicKey']],
    ['a key that is not text', { publicKey: 12345 }, ['publicKey']],
    ['a key sent as an array of bytes', { publicKey: [48, 89, 48, 19] }, ['publicKey']],
    ['a request without a key', {}, ['publicKey']],
    ['no body at all', undefined, ['']],
  ])('refuses %s', (_label, input, fields) => {
    expect(failedFields(input)).toEqual(fields);
  });

  it.each([
    ['userId', { userId: '3f2b6c1e-0000-4000-8000-000000000001' }],
    ['fingerprint', { fingerprint: 'abc' }],
    ['privateKey', { privateKey: 'never-send-this' }],
  ])('refuses the extra field %s', (field, extra) => {
    expect(failedFields({ publicKey: KEY_TEXT, ...extra })).toEqual([field]);
  });
});
