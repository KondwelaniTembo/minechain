import { z } from 'zod';

// POST /sync/steps: a batch of signed custody steps from the phone's offline queue.
//
// The app sends 72 hours of work as consecutive batches, oldest first. 50 steps is about
// 25 kB, well inside the 100 kB body limit, and on 3G the round trips, not the bytes, are
// what cost time, so one batch beats 50 single requests (NFR-03, sync within 10 s).
export const SYNC_MAX_STEPS = 50;

// A real payload is about 250 characters (docs/signing-spec.md, section 3); 512 leaves room
// without letting one item carry a large string into the parser.
export const SYNC_MAX_PAYLOAD_LENGTH = 512;
// A DER P-256 signature is at most 72 bytes, which is 96 characters of base64.
export const SYNC_MAX_SIGNATURE_LENGTH = 100;

// Shape only. Neither value is trimmed or changed: the payload is the exact signed text, and
// the signature must be strict base64. Their content is checked per item by the sync
// service (parsePayload, decodeSignature), so one bad item is rejected on its own instead of
// failing the whole batch. Only a broken envelope, which is an app bug rather than bad data,
// refuses the whole request.
const signedStepSchema = z
  .object({
    payload: z
      .string()
      .min(1, 'is required')
      .max(SYNC_MAX_PAYLOAD_LENGTH, `must be at most ${SYNC_MAX_PAYLOAD_LENGTH} characters`),
    signature: z
      .string()
      .min(1, 'is required')
      .max(SYNC_MAX_SIGNATURE_LENGTH, `must be at most ${SYNC_MAX_SIGNATURE_LENGTH} characters`),
  })
  .strict();

// .strict() at both levels: nothing but the signed text and its signature reaches the
// service. In particular no actor, status or received time can be supplied: the actor is the
// logged-in user, and the server sets every other column itself.
export const syncStepsBodySchema = z
  .object({
    steps: z
      .array(signedStepSchema)
      .min(1, 'must have at least 1 step')
      .max(SYNC_MAX_STEPS, `must have at most ${SYNC_MAX_STEPS} steps`),
  })
  .strict();
