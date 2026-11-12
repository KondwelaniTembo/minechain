// Writes docs/signing-vectors.json, the fixed test vectors shared by the backend and the
// Flutter tests (docs/signing-spec.md, section 9). Run it ONCE, then commit the file:
//
//   npm run make:signing-vectors
//
// It refuses to overwrite an existing file. Regenerating would change every public key,
// signature and anchor hash, and the Flutter tests compare against the committed values,
// so a new file would silently invalidate them. --force exists only for the case where the
// file was never committed.
//
// The private key exists only in memory while this runs. It is never exported, written or
// printed: the vectors need only the public key, because a fixed signature can be checked
// with the public key alone. Nothing secret ends up in Git (CLAUDE.md).
import { writeFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { canonicalise, parsePayload, PAYLOAD_VERSION } from '../src/services/stepPayload.js';
import { anchorHash, verify, ANCHOR_HASH_VERSION } from '../src/services/signatureService.js';
import { SigningError } from '../src/services/signingError.js';

const OUTPUT = fileURLToPath(new URL('../../docs/signing-vectors.json', import.meta.url));
const FORCE_FLAG = '--force';

// ---------- the three steps (all ids fake; coordinates inside the ZCAS demo campus) ----------

const POSITIVE_FIELDS = [
  {
    name: 'registration',
    fields: {
      type: 'registration',
      stepId: '6f1d2c3a-0000-4000-8000-000000000101',
      actorId: '3f2b6c1e-0000-4000-8000-000000000101',
      qrCode: 'MC-DEMO-000001',
      mineral: 'gold',
      weightMg: '1500000',
      latitude: '-15.419012',
      longitude: '28.288105',
      capturedAt: '2026-11-10T08:00:00.000Z',
    },
  },
  {
    name: 'handoff',
    fields: {
      type: 'handoff',
      stepId: '6f1d2c3a-0000-4000-8000-000000000102',
      actorId: '3f2b6c1e-0000-4000-8000-000000000102',
      qrCode: 'MC-DEMO-000001',
      weightMg: '1495000',
      latitude: '-15.418900',
      longitude: '28.288700',
      capturedAt: '2026-11-10T14:30:05.250Z',
    },
  },
  {
    name: 'purchase',
    fields: {
      type: 'purchase',
      stepId: '6f1d2c3a-0000-4000-8000-000000000103',
      actorId: '3f2b6c1e-0000-4000-8000-000000000103',
      qrCode: 'MC-DEMO-000001',
      weightMg: '1494500',
      latitude: '-15.419300',
      longitude: '28.287800',
      capturedAt: '2026-11-11T09:15:00.000Z',
    },
  },
];

// ---------- helpers ----------

const sha256Hex = (bytes) => createHash('sha256').update(bytes).digest('hex');
const ascii = (text) => Buffer.from(text, 'ascii');

// Replaces one key=value line, leaving every other byte alone.
function withLine(payload, key, line) {
  const pattern = new RegExp(`^${key}=.*$`, 'm');
  if (!pattern.test(payload)) throw new Error(`internal: no ${key} line to replace`);
  return payload.replace(pattern, () => line);
}

// Every vector is checked here before anything is written, so a mistake in this script
// can never be committed as an "expected" value.
function check(condition, what) {
  if (!condition) throw new Error(`self-check failed: ${what}; nothing was written`);
}

function expectRefusal(payload, code, name) {
  try {
    parsePayload(payload);
  } catch (err) {
    check(err instanceof SigningError && err.code === code, `${name} should be refused with ${code}`);
    return;
  }
  check(false, `${name} should be refused, but it parsed`);
}

// ---------- building the vectors ----------

function buildVectors() {
  // A throwaway key, in memory only. Only the public half is ever exported.
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const publicKeyBase64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  // DER, as the Android Keystore's SHA256withECDSA produces.
  const signDer = (payload) => sign('sha256', ascii(payload), privateKey).toString('base64');

  const positive = POSITIVE_FIELDS.map(({ name, fields }) => {
    const payload = canonicalise(fields);
    const signature = signDer(payload);
    const vector = {
      name,
      fields,
      payload,
      payloadHex: ascii(payload).toString('hex'),
      payloadSha256: sha256Hex(ascii(payload)),
      publicKey: publicKeyBase64,
      signature,
      anchorHash: anchorHash({ payload, signature, publicKey: publicKeyBase64 }).toString('hex'),
    };
    check(JSON.stringify(parsePayload(payload)) === JSON.stringify(fields), `${name} round-trips`);
    check(verify({ payload, signature, publicKey: publicKeyBase64 }), `${name} signature verifies`);
    return vector;
  });

  const [registration, handoff] = positive;

  // Payloads that must be refused, each with the SigningError code expected.
  const negativePayloads = [
    {
      name: 'upper-case step_id',
      payload: withLine(registration.payload, 'step_id', `step_id=${registration.fields.stepId.toUpperCase()}`),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'negative zero latitude',
      payload: withLine(registration.payload, 'latitude', 'latitude=-0.000000'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'latitude with 7 decimals',
      payload: withLine(registration.payload, 'latitude', 'latitude=-15.4190123'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'captured_at without milliseconds',
      payload: withLine(registration.payload, 'captured_at', 'captured_at=2026-11-10T08:00:00Z'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'captured_at on 30 February',
      payload: withLine(registration.payload, 'captured_at', 'captured_at=2026-02-30T08:00:00.000Z'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'missing final LF',
      payload: registration.payload.slice(0, -1),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'CRLF line endings',
      payload: registration.payload.replaceAll('\n', '\r\n'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'mineral line on a handoff',
      payload: handoff.payload.replace('qr_code=MC-DEMO-000001\n', 'qr_code=MC-DEMO-000001\nmineral=gold\n'),
      expectedError: 'PAYLOAD_MALFORMED',
    },
    {
      name: 'version 2 header',
      payload: registration.payload.replace('minechain-step/1/registration', 'minechain-step/2/registration'),
      expectedError: 'PAYLOAD_UNSUPPORTED_VERSION',
    },
  ];
  for (const v of negativePayloads) expectRefusal(v.payload, v.expectedError, v.name);

  // Well-formed inputs whose signature must not verify: verify returns false.
  const p1363 = sign('sha256', ascii(registration.payload), { key: privateKey, dsaEncoding: 'ieee-p1363' });
  const negativeSignatures = [
    {
      name: 'tampered weight with the original signature',
      payload: withLine(registration.payload, 'weight_mg', 'weight_mg=1600000'),
      signature: registration.signature,
      publicKey: publicKeyBase64,
      expectedVerify: false,
    },
    {
      name: 'handoff signature under a purchase header',
      payload: handoff.payload.replace('minechain-step/1/handoff', 'minechain-step/1/purchase'),
      signature: handoff.signature,
      publicKey: publicKeyBase64,
      expectedVerify: false,
    },
    {
      name: 'raw r||s (IEEE P1363) signature instead of DER',
      payload: registration.payload,
      signature: p1363.toString('base64'),
      publicKey: publicKeyBase64,
      expectedVerify: false,
    },
  ];
  for (const v of negativeSignatures) {
    check(verify(v) === false, `${v.name} should not verify`);
  }

  return {
    format: 'minechain-signing-vectors',
    formatVersion: 1,
    payloadVersion: PAYLOAD_VERSION,
    anchorHashVersion: ANCHOR_HASH_VERSION,
    note:
      'Generated once by backend/scripts/make-signing-vectors.js and committed. NEVER regenerate it: ' +
      'the Flutter and backend tests compare against these exact values. The private key was ' +
      'discarded; only the public key is stored. All ids and codes are fake. See docs/signing-spec.md, section 9.',
    generatedAt: new Date().toISOString(),
    positive,
    negativePayloads,
    negativeSignatures,
  };
}

// ---------- main ----------

function main() {
  const args = process.argv.slice(2);
  const unknown = args.filter((arg) => arg !== FORCE_FLAG);
  if (unknown.length > 0) {
    console.error(`Unknown argument(s): ${unknown.join(' ')}. The only option is ${FORCE_FLAG}.`);
    return 1;
  }
  const force = args.includes(FORCE_FLAG);
  const shownPath = relative(process.cwd(), OUTPUT);

  let vectors;
  try {
    vectors = buildVectors();
  } catch (err) {
    // Our own messages only; they never contain keys or signatures.
    console.error(err.message);
    return 1;
  }

  try {
    // 'wx' creates the file and fails if it already exists, in one step, so there is no
    // gap between checking and writing.
    writeFileSync(OUTPUT, `${JSON.stringify(vectors, null, 2)}\n`, { encoding: 'utf8', flag: force ? 'w' : 'wx' });
  } catch (err) {
    if (err.code === 'EEXIST') {
      console.error(
        `${shownPath} already exists, so nothing was written. The committed vectors must never ` +
          'change: the backend and Flutter tests compare against them. Pass --force only if the ' +
          'file has never been committed.',
      );
      return 1;
    }
    console.error(`Could not write ${shownPath}: ${err.code ?? err.message}`);
    return 1;
  }

  console.log(
    `Wrote ${shownPath}: ${vectors.positive.length} positive vectors, ` +
      `${vectors.negativePayloads.length} negative payloads, ` +
      `${vectors.negativeSignatures.length} negative signatures.`,
  );
  return 0;
}

process.exitCode = main();
