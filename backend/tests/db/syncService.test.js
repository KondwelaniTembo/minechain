import { describe, it, expect } from 'vitest';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { FAKE_CONFIG, insertUser } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createSyncService } from '../../src/services/syncService.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createSignatureService, anchorHash, spkiFingerprint } from '../../src/services/signatureService.js';
import { canonicalise } from '../../src/services/stepPayload.js';

const t = useTestDb();

// The real services, as createServices wires them, on the test's own connection.
const sync = () => createServices({ db: t.db, config: FAKE_CONFIG }).sync;

// TEST-NET-3 (RFC 5737): reserved for documentation, never a real client.
const IP = '203.0.113.21';

// A phone: a throwaway P-256 key pair in memory. The public half is stored on the user, as
// PUT /auth/me/public-key would store it; the private half only ever signs here.
function newPhone() {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { spki: publicKey.export({ type: 'spki', format: 'der' }), privateKey };
}

// SHA256withECDSA over the payload bytes, DER, base64: what the Android app sends.
const signWith = (phone, payload) => sign('sha256', Buffer.from(payload, 'utf8'), phone.privateKey).toString('base64');

let counter = 0;
// A registration's fields, each call with its own step id and custody record. All fake.
function registrationFor(user, overrides = {}) {
  counter += 1;
  const n = String(counter).padStart(6, '0');
  return {
    type: 'registration',
    stepId: `6f1d2c3a-0000-4000-8000-${String(counter).padStart(12, '0')}`,
    actorId: user.id,
    qrCode: `MC-TEST-${n}`,
    mineral: 'gold',
    weightMg: '1500000',
    latitude: '-15.419751',
    longitude: '28.287496',
    capturedAt: '2026-11-10T08:00:00.000Z',
    ...overrides,
  };
}

// The item the app sends: the canonical payload and its signature.
function itemFor(phone, fields) {
  const payload = canonicalise(fields);
  return { payload, signature: signWith(phone, payload) };
}

// An active user with a registered device key.
async function userWithPhone(role = 'miner') {
  const phone = newPhone();
  const row = await insertUser(t.db, { role, status: 'active', public_key: phone.spki });
  return { user: { id: row.id, role }, phone };
}

async function counts() {
  const { rows } = await t.db.query(`
    SELECT (SELECT count(*)::int FROM consignments) AS consignments,
           (SELECT count(*)::int FROM transactions) AS steps,
           (SELECT count(*)::int FROM alerts)       AS alerts,
           (SELECT count(*)::int FROM audit_logs WHERE action = 'transaction.create') AS audits`);
  return rows[0];
}
const NOTHING = { consignments: 0, steps: 0, alerts: 0, audits: 0 };

// The result of syncing a single item.
async function syncOne(user, item, options = { ipAddress: IP }) {
  const results = await sync().syncSteps(user, [item], options);
  expect(results).toHaveLength(1);
  return results[0];
}

describe('syncSteps: a valid registration', () => {
  it('creates the consignment and the step, and answers created', async () => {
    const { user, phone } = await userWithPhone();
    const fields = registrationFor(user);

    const res = await syncOne(user, itemFor(phone, fields));

    expect(res).toEqual({
      index: 0,
      stepId: fields.stepId,
      outcome: 'created',
      transactionId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      reviewStatus: 'passed',
    });
    const { rows } = await t.db.query('SELECT qr_code, mineral_type, miner_id, stage FROM consignments');
    expect(rows).toEqual([{ qr_code: fields.qrCode, mineral_type: 'gold', miner_id: user.id, stage: 'registered' }]);
  });

  it('stores every value exactly as signed, and the evidence beside it', async () => {
    const { user, phone } = await userWithPhone();
    const fields = registrationFor(user, { weightMg: '1234567', latitude: '-15.419012', longitude: '28.288105' });
    const item = itemFor(phone, fields);

    const { transactionId } = await syncOne(user, item);

    const { rows } = await t.db.query('SELECT * FROM transactions WHERE id = $1', [transactionId]);
    const step = rows[0];
    // pg returns bigint and numeric as text, so these show exactly what PostgreSQL holds.
    expect(step.weight_mg).toBe('1234567');
    expect(step.latitude).toBe('-15.419012');
    expect(step.longitude).toBe('28.288105');
    expect(step.captured_at.toISOString()).toBe(fields.capturedAt);
    expect(step.type).toBe('registration');
    expect(step.actor_id).toBe(user.id);
    expect(step.idempotency_key).toBe(fields.stepId);
    expect(step.signed_payload).toBe(item.payload);
    expect(step.signature.equals(Buffer.from(item.signature, 'base64'))).toBe(true);
    expect(step.signer_public_key.equals(phone.spki)).toBe(true);
    expect(step.data_hash.equals(anchorHash({ payload: item.payload, signature: item.signature, publicKey: phone.spki }))).toBe(true);
    expect(step.hash_version).toBe(1);
    expect(step.review_status).toBe('passed');
    expect(step.anchor_status).toBe('pending');
    expect(step.zone_id).toBeNull();
  });

  it('takes received_at from the database, never from the request', async () => {
    const { user, phone } = await userWithPhone();

    const { transactionId } = await syncOne(user, itemFor(phone, registrationFor(user)));

    // Inside one transaction now() is fixed, so the column's default equals it exactly.
    const { rows } = await t.db.query('SELECT received_at = now() AS from_db FROM transactions WHERE id = $1', [transactionId]);
    expect(rows[0].from_db).toBe(true);
  });

  it('writes one transaction.create audit entry with the type and review status', async () => {
    const { user, phone } = await userWithPhone();

    const { transactionId } = await syncOne(user, itemFor(phone, registrationFor(user)));

    const { rows } = await t.db.query(
      "SELECT actor_id, entity_type, entity_id, details, ip_address FROM audit_logs WHERE action = 'transaction.create'",
    );
    expect(rows).toEqual([
      {
        actor_id: user.id,
        entity_type: 'transaction',
        entity_id: transactionId,
        details: { type: 'registration', reviewStatus: 'passed' },
        ip_address: IP,
      },
    ]);
  });

  it('raises no alert for a step that passes', async () => {
    const { user, phone } = await userWithPhone();

    await syncOne(user, itemFor(phone, registrationFor(user)));

    expect((await counts()).alerts).toBe(0);
  });
});

describe('syncSteps: retries and step-id conflicts', () => {
  it('answers duplicate for the same item again, with the stored id, and writes nothing', async () => {
    const { user, phone } = await userWithPhone();
    const item = itemFor(phone, registrationFor(user));
    const first = await syncOne(user, item);
    const before = await counts();

    const again = await syncOne(user, item);

    expect(again).toEqual({
      index: 0,
      stepId: first.stepId,
      outcome: 'duplicate',
      transactionId: first.transactionId,
      reviewStatus: 'passed',
    });
    expect(await counts()).toEqual(before);
  });

  it('rejects a different record that reuses a step id with STEP_ID_CONFLICT', async () => {
    const { user, phone } = await userWithPhone();
    const fields = registrationFor(user);
    await syncOne(user, itemFor(phone, fields));
    const before = await counts();

    // Same step id, a different weight, properly signed: a different record.
    const res = await syncOne(user, itemFor(phone, { ...fields, weightMg: '1600000' }));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'STEP_ID_CONFLICT', stepId: fields.stepId });
    expect(res.message).toEqual(expect.any(String));
    expect(await counts()).toEqual(before);
  });

  it('treats the same step id from two different users as two steps', async () => {
    // The uniqueness rule is per actor, so one user's ids can never block another's.
    const a = await userWithPhone();
    const b = await userWithPhone();
    const stepId = '6f1d2c3a-0000-4000-8000-0000000a0001';

    const first = await syncOne(a.user, itemFor(a.phone, registrationFor(a.user, { stepId })));
    const second = await syncOne(b.user, itemFor(b.phone, registrationFor(b.user, { stepId })));

    expect([first.outcome, second.outcome]).toEqual(['created', 'created']);
  });
});

describe('syncSteps: rejected and deferred items store nothing', () => {
  it('rejects a record signed for another account with ACTOR_MISMATCH', async () => {
    const { user, phone } = await userWithPhone();
    const other = await insertUser(t.db, { role: 'miner', status: 'active' });

    const res = await syncOne(user, itemFor(phone, registrationFor(user, { actorId: other.id })));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'ACTOR_MISMATCH' });
    expect(await counts()).toEqual(NOTHING);
  });

  it.each(['transporter', 'buyer'])('rejects a registration from a %s with STEP_NOT_ALLOWED_FOR_ROLE', async (role) => {
    const { user, phone } = await userWithPhone(role);

    const res = await syncOne(user, itemFor(phone, registrationFor(user)));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'STEP_NOT_ALLOWED_FOR_ROLE' });
    expect(await counts()).toEqual(NOTHING);
  });

  it('defers a step from an account with no device key with NO_DEVICE_KEY', async () => {
    const phone = newPhone();
    const row = await insertUser(t.db, { role: 'miner', status: 'active' });
    const user = { id: row.id, role: 'miner' };

    const res = await syncOne(user, itemFor(phone, registrationFor(user)));

    expect(res).toMatchObject({ outcome: 'deferred', code: 'NO_DEVICE_KEY' });
    expect(await counts()).toEqual(NOTHING);
  });

  it('accepts the same item once the key is registered (deferred, then created)', async () => {
    const phone = newPhone();
    const row = await insertUser(t.db, { role: 'miner', status: 'active' });
    const user = { id: row.id, role: 'miner' };
    const item = itemFor(phone, registrationFor(user));
    expect((await syncOne(user, item)).outcome).toBe('deferred');

    await t.db.query('UPDATE users SET public_key = $1 WHERE id = $2', [phone.spki, user.id]);

    expect((await syncOne(user, item)).outcome).toBe('created');
  });

  it.each([
    ['text that is not a payload', 'hello', 'PAYLOAD_MALFORMED'],
    ['a payload with CRLF line endings', (p) => p.replaceAll('\n', '\r\n'), 'PAYLOAD_MALFORMED'],
    ['a version 2 header', (p) => p.replace('minechain-step/1/', 'minechain-step/2/'), 'PAYLOAD_UNSUPPORTED_VERSION'],
  ])('rejects %s with %s, and no step id', async (_label, change, code) => {
    const { user, phone } = await userWithPhone();
    const item = itemFor(phone, registrationFor(user));
    const payload = typeof change === 'function' ? change(item.payload) : change;

    const res = await syncOne(user, { ...item, payload });

    expect(res).toMatchObject({ outcome: 'rejected', code, stepId: null });
    expect(await counts()).toEqual(NOTHING);
  });

  it.each([
    ['not base64', () => 'not base64!'],
    // Always invalid: the length is no longer a multiple of 4. (Removing padding would not
    // work for every signature, because a 72-byte one has none.)
    ['base64 with a character missing', (s) => s.slice(0, -1)],
    ['too short to be a signature', () => 'AAAA'],
  ])('rejects a signature that is %s with SIGNATURE_MALFORMED, keeping the step id', async (_label, change) => {
    const { user, phone } = await userWithPhone();
    const fields = registrationFor(user);
    const item = itemFor(phone, fields);
    const signature = change(item.signature);

    const res = await syncOne(user, { ...item, signature });

    expect(res).toMatchObject({ outcome: 'rejected', code: 'SIGNATURE_MALFORMED', stepId: fields.stepId });
    expect(await counts()).toEqual(NOTHING);
  });

  it('rejects a second registration of the same custody record with QR_CODE_ALREADY_REGISTERED', async () => {
    const first = await userWithPhone();
    const second = await userWithPhone();
    const qrCode = 'MC-TEST-SHARED';
    await syncOne(first.user, itemFor(first.phone, registrationFor(first.user, { qrCode })));
    const before = await counts();

    const res = await syncOne(second.user, itemFor(second.phone, registrationFor(second.user, { qrCode })));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'QR_CODE_ALREADY_REGISTERED' });
    expect(await counts()).toEqual(before);
    const { rows } = await t.db.query('SELECT miner_id FROM consignments WHERE qr_code = $1', [qrCode]);
    expect(rows).toEqual([{ miner_id: first.user.id }]);
  });

  it('rejects the same miner registering the same record again under a new step id', async () => {
    const { user, phone } = await userWithPhone();
    const qrCode = 'MC-TEST-AGAIN';
    await syncOne(user, itemFor(phone, registrationFor(user, { qrCode })));

    const res = await syncOne(user, itemFor(phone, registrationFor(user, { qrCode })));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'QR_CODE_ALREADY_REGISTERED' });
  });

  it.each([
    ['handoff', 'transporter'],
    ['purchase', 'buyer'],
  ])('defers a %s with STEP_TYPE_NOT_YET_SUPPORTED until handoffs and purchases are built', async (type, role) => {
    const { user, phone } = await userWithPhone(role);
    const { mineral: _m, ...rest } = registrationFor(user);

    const res = await syncOne(user, itemFor(phone, { ...rest, type }));

    expect(res).toMatchObject({ outcome: 'deferred', code: 'STEP_TYPE_NOT_YET_SUPPORTED' });
    expect(await counts()).toEqual(NOTHING);
  });
});

describe('syncSteps: a signature that does not verify', () => {
  async function syncBadSignature() {
    const { user, phone } = await userWithPhone();
    const fields = registrationFor(user);
    const payload = canonicalise(fields);
    // Signed by another phone: well-formed, but not by this account's registered key.
    const stranger = newPhone();
    const res = await syncOne(user, { payload, signature: signWith(stranger, payload) });
    return { user, phone, fields, res };
  }

  it('stores the step as flagged and answers flagged INVALID_SIGNATURE', async () => {
    const { fields, res } = await syncBadSignature();

    expect(res).toMatchObject({
      outcome: 'flagged',
      code: 'INVALID_SIGNATURE',
      stepId: fields.stepId,
      reviewStatus: 'flagged',
      alerts: ['invalid_signature'],
    });
    const { rows } = await t.db.query('SELECT review_status, anchor_status FROM transactions WHERE id = $1', [res.transactionId]);
    expect(rows[0]).toEqual({ review_status: 'flagged', anchor_status: 'pending' });
  });

  it('opens one high invalid_signature alert naming the registered key by fingerprint', async () => {
    const { phone, res } = await syncBadSignature();

    const { rows } = await t.db.query('SELECT type, severity, status, details FROM alerts WHERE transaction_id = $1', [
      res.transactionId,
    ]);
    expect(rows).toEqual([
      { type: 'invalid_signature', severity: 'high', status: 'open', details: { keyFingerprint: spkiFingerprint(phone.spki) } },
    ]);
  });

  it('still creates the consignment, which the open alert holds', async () => {
    const { fields } = await syncBadSignature();

    const { rows } = await t.db.query(
      `SELECT EXISTS (SELECT 1 FROM alerts a JOIN transactions s ON s.id = a.transaction_id
                       WHERE s.consignment_id = c.id AND a.status = 'open') AS held
         FROM consignments c WHERE c.qr_code = $1`,
      [fields.qrCode],
    );
    expect(rows).toEqual([{ held: true }]);
  });

  it('audits the stored step with reviewStatus flagged', async () => {
    const { res } = await syncBadSignature();

    const { rows } = await t.db.query("SELECT details FROM audit_logs WHERE action = 'transaction.create' AND entity_id = $1", [
      res.transactionId,
    ]);
    expect(rows[0].details).toEqual({ type: 'registration', reviewStatus: 'flagged' });
  });

  it('can never be sent to the chain while flagged', async () => {
    const { res } = await syncBadSignature();

    // The anchoring worker's move. transactions_anchor_only_if_approved refuses it.
    const err = await expectPgError(
      t.db,
      "UPDATE transactions SET anchor_status = 'submitted', chain_tx_hash = $1 WHERE id = $2",
      [randomBytes(32), res.transactionId],
      PG_ERROR.CHECK_VIOLATION,
    );
    expect(err.constraint).toBe('transactions_anchor_only_if_approved');
  });

  it('answers a resend of the same flagged item as duplicate, still flagged', async () => {
    const { user } = await userWithPhone();
    const payload = canonicalise(registrationFor(user));
    // Signed by a phone that is not the registered one.
    const item = { payload, signature: signWith(newPhone(), payload) };
    const first = await syncOne(user, item);

    const again = await syncOne(user, item);

    expect(again).toMatchObject({ outcome: 'duplicate', transactionId: first.transactionId, reviewStatus: 'flagged' });
  });
});

describe('syncSteps: batches', () => {
  it('answers each item in order, and one bad item does not stop the others', async () => {
    const { user, phone } = await userWithPhone();
    const first = itemFor(phone, registrationFor(user));
    const second = itemFor(phone, registrationFor(user));

    const results = await sync().syncSteps(user, [first, { payload: 'hello', signature: first.signature }, second, first], {
      ipAddress: IP,
    });

    expect(results.map((r) => [r.index, r.outcome])).toEqual([
      [0, 'created'],
      [1, 'rejected'],
      [2, 'created'],
      [3, 'duplicate'],
    ]);
    expect(results[3].transactionId).toBe(results[0].transactionId);
    expect(await counts()).toMatchObject({ consignments: 2, steps: 2, audits: 2 });
  });

  it('returns an empty list for an empty batch (the route refuses one before it gets here)', async () => {
    const { user } = await userWithPhone();

    expect(await sync().syncSteps(user, [])).toEqual([]);
  });
});

describe('syncSteps: database faults', () => {
  it('saves nothing for an item whose audit entry cannot be written, and throws', async () => {
    const { user, phone } = await userWithPhone();
    const failingAudit = {
      record: async () => {
        throw new Error('audit unavailable');
      },
    };
    const service = createSyncService({ db: t.db, signatures: createSignatureService(), audit: failingAudit });
    const start = () => service.syncSteps(user, [itemFor(phone, registrationFor(user))]);

    // Started inside expect, so the rejection is always handled.
    await expect(start()).rejects.toThrow('audit unavailable');

    // The consignment, the step and any alert were rolled back with the failed entry.
    expect(await counts()).toEqual(NOTHING);
  });

  it('keeps the items committed before a fault, which come back as duplicate on resend', async () => {
    const { user, phone } = await userWithPhone();
    const good = itemFor(phone, registrationFor(user));
    let calls = 0;
    // Fails on the second stored item only.
    const realAudit = createAuditService();
    const flakyAudit = {
      record: async (db, entry) => {
        calls += 1;
        if (calls === 2) throw new Error('audit unavailable');
        return realAudit.record(db, entry);
      },
    };
    const service = createSyncService({ db: t.db, signatures: createSignatureService(), audit: flakyAudit });
    const start = () => service.syncSteps(user, [good, itemFor(phone, registrationFor(user))]);

    await expect(start()).rejects.toThrow('audit unavailable');

    expect((await counts()).steps).toBe(1);
    const [resent] = await sync().syncSteps(user, [good]);
    expect(resent.outcome).toBe('duplicate');
  });
});
