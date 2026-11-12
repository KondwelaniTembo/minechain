import { describe, it, expect } from 'vitest';
import {
  syncStepsBodySchema,
  SYNC_MAX_STEPS,
  SYNC_MAX_PAYLOAD_LENGTH,
  SYNC_MAX_SIGNATURE_LENGTH,
} from '../src/schemas/sync.js';

// Shapes only: the schema never parses the payload or decodes the signature, so these are
// placeholders, not a real signed step.
const STEP = Object.freeze({
  payload: 'minechain-step/1/handoff\nstep_id=6f1d2c3a-0000-4000-8000-000000000002\n',
  signature: 'MEUCIQ-FAKE-SIGNATURE==',
});
const steps = (n) => Array.from({ length: n }, () => ({ ...STEP }));

// Lists the fields that failed, so each test checks the rule it is about.
const failedFields = (input) => {
  const result = syncStepsBodySchema.safeParse(input);
  if (result.success) return [];
  return result.error.issues.flatMap((i) =>
    i.code === 'unrecognized_keys' ? i.keys.map((k) => [...i.path, k].join('.')) : [i.path.join('.')],
  );
};

describe('syncStepsBodySchema', () => {
  describe('accepts', () => {
    it('one step, leaving payload and signature exactly as sent', () => {
      expect(syncStepsBodySchema.parse({ steps: [STEP] })).toEqual({ steps: [STEP] });
    });

    it(`${SYNC_MAX_STEPS} steps, the most in one batch`, () => {
      expect(syncStepsBodySchema.safeParse({ steps: steps(SYNC_MAX_STEPS) }).success).toBe(true);
    });

    it('the longest payload and signature allowed', () => {
      const step = { payload: 'a'.repeat(SYNC_MAX_PAYLOAD_LENGTH), signature: 'A'.repeat(SYNC_MAX_SIGNATURE_LENGTH) };

      expect(syncStepsBodySchema.safeParse({ steps: [step] }).success).toBe(true);
    });

    it('does not trim: the payload is the exact signed text', () => {
      const step = { payload: ` ${STEP.payload} `, signature: ` ${STEP.signature} ` };

      expect(syncStepsBodySchema.parse({ steps: [step] })).toEqual({ steps: [step] });
    });

    it('content it cannot judge, which the sync service rejects per item instead', () => {
      // Not a payload and not base64, but the envelope is fine, so the batch goes through and
      // only this item is rejected later.
      expect(syncStepsBodySchema.safeParse({ steps: [{ payload: 'hello', signature: '!!' }] }).success).toBe(true);
    });
  });

  describe('refuses the whole request when the envelope is broken', () => {
    it.each([
      ['an empty batch', { steps: [] }, ['steps']],
      [`${SYNC_MAX_STEPS + 1} steps`, { steps: steps(SYNC_MAX_STEPS + 1) }, ['steps']],
      ['no steps field', {}, ['steps']],
      ['steps that is not a list', { steps: STEP }, ['steps']],
      ['no body at all', undefined, ['']],
      ['an extra top-level field', { steps: [STEP], deviceId: 'abc' }, ['deviceId']],
    ])('%s', (_label, input, fields) => {
      expect(failedFields(input)).toEqual(fields);
    });

    it.each([
      ['an empty payload', { ...STEP, payload: '' }, ['steps.0.payload']],
      ['a payload over the limit', { ...STEP, payload: 'a'.repeat(SYNC_MAX_PAYLOAD_LENGTH + 1) }, ['steps.0.payload']],
      ['a payload that is not text', { ...STEP, payload: 42 }, ['steps.0.payload']],
      ['an empty signature', { ...STEP, signature: '' }, ['steps.0.signature']],
      ['a signature over the limit', { ...STEP, signature: 'A'.repeat(SYNC_MAX_SIGNATURE_LENGTH + 1) }, ['steps.0.signature']],
      ['a missing signature', { payload: STEP.payload }, ['steps.0.signature']],
    ])('an item with %s', (_label, item, fields) => {
      expect(failedFields({ steps: [item] })).toEqual(fields);
    });

    it.each([
      ['actorId', { actorId: '3f2b6c1e-0000-4000-8000-000000000002' }],
      ['receivedAt', { receivedAt: '2026-11-10T08:00:00.000Z' }],
      ['reviewStatus', { reviewStatus: 'passed' }],
    ])('an item with the extra field %s, which only the server may set', (field, extra) => {
      expect(failedFields({ steps: [{ ...STEP, ...extra }] })).toEqual([`steps.0.${field}`]);
    });

    it('names the position of the bad item', () => {
      const batch = [{ ...STEP }, { ...STEP }, { ...STEP, payload: '' }];

      expect(failedFields({ steps: batch })).toEqual(['steps.2.payload']);
    });
  });

  it('keeps the batch small enough for the 100 kB body limit', () => {
    // The largest valid body, as JSON, must fit with room to spare.
    const body = { steps: Array.from({ length: SYNC_MAX_STEPS }, () => ({
      payload: 'a'.repeat(SYNC_MAX_PAYLOAD_LENGTH),
      signature: 'A'.repeat(SYNC_MAX_SIGNATURE_LENGTH),
    })) };

    expect(Buffer.byteLength(JSON.stringify(body))).toBeLessThan(100 * 1024);
  });
});
