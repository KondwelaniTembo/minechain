import { describe, it, expect, beforeEach } from 'vitest';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { useTestDb, expectPgError, PG_ERROR } from './helpers.js';
import { FAKE_CONFIG, insertUser, insertCampusZone } from './fixtures.js';
import { createServices } from '../../src/services/index.js';
import { createSyncService } from '../../src/services/syncService.js';
import { createAuditService } from '../../src/services/auditService.js';
import { createSignatureService, anchorHash, spkiFingerprint } from '../../src/services/signatureService.js';
import { canonicalise } from '../../src/services/stepPayload.js';

const t = useTestDb();

// Every test starts with the active campus zone, which holds all the coordinates used here,
// so only tests about the GPS rule (tests/db/anomalyRules.test.js) see a registration
// outside every zone. Runs after useTestDb's BEGIN, so it is rolled back with the test.
let campus;
beforeEach(async () => {
  campus = await insertCampusZone(t.db);
});

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
    // The point is on campus, so the step records that zone.
    expect(step.zone_id).toBe(campus.id);
  });

  it('takes received_at from the database, never from the request', async () => {
    const { user, phone } = await userWithPhone();

    const { transactionId } = await syncOne(user, itemFor(phone, registrationFor(user)));

    // The whole test is one transaction, started before this step was synced. now() is
    // that start and clock_timestamp() is the time of this query, so a time the database
    // set during the test lies between the two. A time taken from the request (the phone's
    // capturedAt, 2026-11-01) would not.
    const { rows } = await t.db.query(
      'SELECT received_at >= now() AND received_at <= clock_timestamp() AS from_db FROM transactions WHERE id = $1',
      [transactionId],
    );
    expect(rows[0].from_db).toBe(true);
  });

  it("sets received_at at the INSERT, later than its transaction's start", async () => {
    const { user, phone } = await userWithPhone();

    const { transactionId } = await syncOne(user, itemFor(phone, registrationFor(user)));

    // Strictly later: the user and phone were created inside this transaction before the
    // sync, so time has passed since it started. The column's default, now(), would be
    // equal (the bug fixed on 9 Nov).
    const { rows } = await t.db.query('SELECT received_at > now() AS after_start FROM transactions WHERE id = $1', [transactionId]);
    expect(rows[0].after_start).toBe(true);
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

});

// Until 9 Nov these were rejected with QR_CODE_ALREADY_REGISTERED. The duplicate rule now
// keeps them as evidence (tests/db/anomalyRules.test.js has the details).
describe('syncSteps: a second registration of the same custody record', () => {
  it('is stored as a flagged duplicate on the existing consignment, which keeps its miner', async () => {
    const first = await userWithPhone();
    const second = await userWithPhone();
    const qrCode = 'MC-TEST-SHARED';
    await syncOne(first.user, itemFor(first.phone, registrationFor(first.user, { qrCode })));
    const before = await counts();

    const res = await syncOne(second.user, itemFor(second.phone, registrationFor(second.user, { qrCode })));

    expect(res).toMatchObject({ outcome: 'flagged', code: 'DUPLICATE_CONSIGNMENT', alerts: ['duplicate_consignment'] });
    // A new step, alert and audit entry; no new consignment.
    expect(await counts()).toEqual({ ...before, steps: before.steps + 1, alerts: before.alerts + 1, audits: before.audits + 1 });
    const { rows } = await t.db.query('SELECT miner_id FROM consignments WHERE qr_code = $1', [qrCode]);
    expect(rows).toEqual([{ miner_id: first.user.id }]);
  });

  it('is flagged too when the same miner registers the same record again under a new step id', async () => {
    const { user, phone } = await userWithPhone();
    const qrCode = 'MC-TEST-AGAIN';
    await syncOne(user, itemFor(phone, registrationFor(user, { qrCode })));

    const res = await syncOne(user, itemFor(phone, registrationFor(user, { qrCode })));

    expect(res).toMatchObject({ outcome: 'flagged', code: 'DUPLICATE_CONSIGNMENT' });
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

// ---------- handoffs and purchases ----------

// A handoff's or purchase's fields for a consignment's custody record. No mineral: only a
// registration signs it.
function custodyFor(user, type, qrCode, overrides = {}) {
  const { mineral: _mineral, ...fields } = registrationFor(user);
  return { ...fields, type, qrCode, ...overrides };
}

// A miner registers a new consignment; returns its custody record code.
async function registered() {
  const miner = await userWithPhone('miner');
  const fields = registrationFor(miner.user);
  const res = await syncOne(miner.user, itemFor(miner.phone, fields));
  expect(res.outcome).toBe('created');
  return { miner, qrCode: fields.qrCode };
}

async function stageOf(qrCode) {
  const { rows } = await t.db.query('SELECT stage FROM consignments WHERE qr_code = $1', [qrCode]);
  return rows[0]?.stage;
}

// In custody order, by type rather than by received_at, so a test's expected list never
// depends on timing.
async function stepsOf(qrCode) {
  const { rows } = await t.db.query(
    `SELECT s.type, s.review_status, s.anchor_status
       FROM transactions s JOIN consignments c ON c.id = s.consignment_id
      WHERE c.qr_code = $1
      ORDER BY CASE s.type WHEN 'registration' THEN 1 WHEN 'handoff' THEN 2 ELSE 3 END`,
    [qrCode],
  );
  return rows;
}

// A transporter's handoff, or a buyer's purchase, synced for one custody record.
async function custody(role, type, qrCode, overrides = {}) {
  const party = await userWithPhone(role);
  const fields = custodyFor(party.user, type, qrCode, overrides);
  const item = itemFor(party.phone, fields);
  const res = await syncOne(party.user, item);
  return { ...party, fields, item, res };
}
const handoff = (qrCode, overrides) => custody('transporter', 'handoff', qrCode, overrides);
const purchase = (qrCode, overrides) => custody('buyer', 'purchase', qrCode, overrides);

describe('syncSteps: handoffs', () => {
  it('stores a handoff on a registered consignment and moves it to in_transit', async () => {
    const { qrCode } = await registered();

    const { res, user } = await handoff(qrCode, { weightMg: '1495000' });

    expect(res).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect(await stageOf(qrCode)).toBe('in_transit');
    const { rows } = await t.db.query(
      'SELECT s.type, s.actor_id, s.weight_mg, c.qr_code FROM transactions s JOIN consignments c ON c.id = s.consignment_id WHERE s.id = $1',
      [res.transactionId],
    );
    expect(rows[0]).toEqual({ type: 'handoff', actor_id: user.id, weight_mg: '1495000', qr_code: qrCode });
  });

  it('gives registration, handoff and purchase increasing received_at, in custody order', async () => {
    // What the anchoring worker's ordering relies on. With now() all three were equal
    // inside one test transaction, and the order was left to the uuid tie-break.
    const { qrCode } = await registered();
    await handoff(qrCode);
    await purchase(qrCode);

    const { rows } = await t.db.query(
      `SELECT s.type FROM transactions s JOIN consignments c ON c.id = s.consignment_id
        WHERE c.qr_code = $1 ORDER BY s.received_at`,
      [qrCode],
    );
    expect(rows.map((r) => r.type)).toEqual(['registration', 'handoff', 'purchase']);
    const { rows: [distinct] } = await t.db.query(
      `SELECT count(DISTINCT s.received_at)::int AS n FROM transactions s
         JOIN consignments c ON c.id = s.consignment_id WHERE c.qr_code = $1`,
      [qrCode],
    );
    expect(distinct.n).toBe(3);
  });

  it('allows a second handoff at in_transit (a relay), and the stage stays in_transit', async () => {
    const { qrCode } = await registered();
    await handoff(qrCode);

    const { res } = await handoff(qrCode);

    expect(res.outcome).toBe('created');
    expect(await stageOf(qrCode)).toBe('in_transit');
    expect((await stepsOf(qrCode)).map((s) => s.type)).toEqual(['registration', 'handoff', 'handoff']);
  });

  it('audits the handoff with its type', async () => {
    const { qrCode } = await registered();

    const { res } = await handoff(qrCode);

    const { rows } = await t.db.query("SELECT details FROM audit_logs WHERE action = 'transaction.create' AND entity_id = $1", [
      res.transactionId,
    ]);
    expect(rows[0].details).toEqual({ type: 'handoff', reviewStatus: 'passed' });
  });

  it('rejects a handoff signed by a miner with STEP_NOT_ALLOWED_FOR_ROLE', async () => {
    const { miner, qrCode } = await registered();
    const before = await counts();

    const res = await syncOne(miner.user, itemFor(miner.phone, custodyFor(miner.user, 'handoff', qrCode)));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'STEP_NOT_ALLOWED_FOR_ROLE' });
    expect(await counts()).toEqual(before);
  });
});

describe('syncSteps: purchases', () => {
  it('stores a purchase on a consignment in transit and moves it to purchased', async () => {
    const { qrCode } = await registered();
    await handoff(qrCode);

    const { res } = await purchase(qrCode);

    expect(res).toMatchObject({ outcome: 'created', reviewStatus: 'passed' });
    expect(await stageOf(qrCode)).toBe('purchased');
  });

  it('defers a purchase while the consignment is still registered with STAGE_NOT_READY', async () => {
    // Most likely the transporter has not synced the handoff yet.
    const { qrCode } = await registered();
    const before = await counts();

    const { res } = await purchase(qrCode);

    expect(res).toMatchObject({ outcome: 'deferred', code: 'STAGE_NOT_READY' });
    expect(res.message).toEqual(expect.any(String));
    expect(await counts()).toEqual(before);
    expect(await stageOf(qrCode)).toBe('registered');
  });

  it('accepts the deferred purchase unchanged once the handoff has arrived', async () => {
    const { qrCode } = await registered();
    const buyer = await purchase(qrCode);
    expect(buyer.res.outcome).toBe('deferred');
    await handoff(qrCode);

    const again = await syncOne(buyer.user, buyer.item);

    expect(again.outcome).toBe('created');
    expect(await stageOf(qrCode)).toBe('purchased');
  });

  it('rejects a purchase signed by a transporter with STEP_NOT_ALLOWED_FOR_ROLE', async () => {
    const { qrCode } = await registered();
    const transporter = await userWithPhone('transporter');

    const res = await syncOne(transporter.user, itemFor(transporter.phone, custodyFor(transporter.user, 'purchase', qrCode)));

    expect(res).toMatchObject({ outcome: 'rejected', code: 'STEP_NOT_ALLOWED_FOR_ROLE' });
  });
});

describe('syncSteps: out-of-order arrival', () => {
  it('defers a handoff whose consignment has not reached the server, then accepts it after the registration', async () => {
    const miner = await userWithPhone('miner');
    const registration = registrationFor(miner.user);
    const transporter = await userWithPhone('transporter');
    const handoffItem = itemFor(transporter.phone, custodyFor(transporter.user, 'handoff', registration.qrCode));

    // The transporter's phone reaches a network first.
    const early = await syncOne(transporter.user, handoffItem);
    expect(early).toMatchObject({ outcome: 'deferred', code: 'CONSIGNMENT_NOT_FOUND' });
    expect(await counts()).toEqual(NOTHING);

    // Then the miner syncs, and the transporter's app resends the same item unchanged.
    await syncOne(miner.user, itemFor(miner.phone, registration));
    const later = await syncOne(transporter.user, handoffItem);

    expect(later.outcome).toBe('created');
    expect(await stageOf(registration.qrCode)).toBe('in_transit');
  });

  it('defers a purchase for an unknown custody record with CONSIGNMENT_NOT_FOUND', async () => {
    const { res } = await purchase('MC-TEST-UNKNOWN');

    expect(res).toMatchObject({ outcome: 'deferred', code: 'CONSIGNMENT_NOT_FOUND' });
    expect(await counts()).toEqual(NOTHING);
  });
});

describe('syncSteps: after the purchase', () => {
  async function purchased() {
    const { qrCode } = await registered();
    const transporter = await handoff(qrCode);
    const buyer = await purchase(qrCode);
    expect(await stageOf(qrCode)).toBe('purchased');
    return { qrCode, transporter, buyer };
  }

  // Until 9 Nov these were rejected with CONSIGNMENT_CLOSED. The handoff-order rule now keeps
  // them as evidence.
  it.each([
    ['a handoff', handoff, 'medium'],
    ['a second purchase', purchase, 'high'],
  ])('stores %s as flagged HANDOFF_ORDER, and the consignment stays purchased', async (_label, step, severity) => {
    const { qrCode } = await purchased();
    const before = await counts();

    const { res } = await step(qrCode);

    expect(res).toMatchObject({ outcome: 'flagged', code: 'HANDOFF_ORDER', alerts: ['handoff_order'] });
    expect(await counts()).toEqual({ ...before, steps: before.steps + 1, alerts: before.alerts + 1, audits: before.audits + 1 });
    expect(await stageOf(qrCode)).toBe('purchased');
    const { rows } = await t.db.query('SELECT severity FROM alerts WHERE transaction_id = $1', [res.transactionId]);
    expect(rows).toEqual([{ severity }]);
  });

  it('still answers duplicate for a resend of an earlier handoff, because retries are checked first', async () => {
    const { transporter } = await purchased();
    const before = await counts();

    const again = await syncOne(transporter.user, transporter.item);

    expect(again).toMatchObject({ outcome: 'duplicate', transactionId: transporter.res.transactionId });
    expect(await counts()).toEqual(before);
  });

  it('still answers duplicate for a resend of the purchase itself', async () => {
    const { buyer } = await purchased();

    const again = await syncOne(buyer.user, buyer.item);

    expect(again).toMatchObject({ outcome: 'duplicate', transactionId: buyer.res.transactionId });
  });
});

describe('syncSteps: flagged custody steps', () => {
  // A handoff signed by a phone that is not the transporter's registered one.
  async function flaggedHandoff(qrCode) {
    const transporter = await userWithPhone('transporter');
    const payload = canonicalise(custodyFor(transporter.user, 'handoff', qrCode));
    const res = await syncOne(transporter.user, { payload, signature: signWith(newPhone(), payload) });
    return { ...transporter, res };
  }

  it('stores a flagged handoff with its alert, and leaves the stage unchanged', async () => {
    const { qrCode } = await registered();

    const { res } = await flaggedHandoff(qrCode);

    expect(res).toMatchObject({ outcome: 'flagged', code: 'INVALID_SIGNATURE', reviewStatus: 'flagged' });
    expect(await stageOf(qrCode)).toBe('registered');
    const { rows } = await t.db.query('SELECT type, status FROM alerts WHERE transaction_id = $1', [res.transactionId]);
    expect(rows).toEqual([{ type: 'invalid_signature', status: 'open' }]);
  });

  it('still stores later steps on the held consignment normally (the worker skips held ones)', async () => {
    const { qrCode } = await registered();
    await flaggedHandoff(qrCode);

    const { res } = await handoff(qrCode);

    expect(res.outcome).toBe('created');
    expect(await stageOf(qrCode)).toBe('in_transit');
  });

  it('leaves a consignment in transit there after a flagged purchase, so a genuine purchase can follow', async () => {
    const { qrCode } = await registered();
    await handoff(qrCode);
    const buyer = await userWithPhone('buyer');
    const payload = canonicalise(custodyFor(buyer.user, 'purchase', qrCode));

    const flagged = await syncOne(buyer.user, { payload, signature: signWith(newPhone(), payload) });
    expect(flagged.outcome).toBe('flagged');
    expect(await stageOf(qrCode)).toBe('in_transit');

    // The partial unique index counts only passed or cleared purchases, so this is allowed.
    const { res } = await purchase(qrCode);
    expect(res.outcome).toBe('created');
    expect(await stageOf(qrCode)).toBe('purchased');
  });
});

describe('syncSteps: the full custody chain', () => {
  it('records miner, transporter and buyer as three passed steps, ending purchased', async () => {
    const miner = await userWithPhone('miner');
    const transporter = await userWithPhone('transporter');
    const buyer = await userWithPhone('buyer');
    const registration = registrationFor(miner.user, { weightMg: '1500000' });
    const { qrCode } = registration;

    const results = [
      await syncOne(miner.user, itemFor(miner.phone, registration)),
      await syncOne(transporter.user, itemFor(transporter.phone, custodyFor(transporter.user, 'handoff', qrCode, { weightMg: '1495000' }))),
      await syncOne(buyer.user, itemFor(buyer.phone, custodyFor(buyer.user, 'purchase', qrCode, { weightMg: '1494500' }))),
    ];

    expect(results.map((r) => [r.outcome, r.reviewStatus])).toEqual([
      ['created', 'passed'],
      ['created', 'passed'],
      ['created', 'passed'],
    ]);
    expect(await stageOf(qrCode)).toBe('purchased');
    expect(await stepsOf(qrCode)).toEqual([
      { type: 'registration', review_status: 'passed', anchor_status: 'pending' },
      { type: 'handoff', review_status: 'passed', anchor_status: 'pending' },
      { type: 'purchase', review_status: 'passed', anchor_status: 'pending' },
    ]);
    // Each step was signed by, and stored for, the person who performed it.
    const { rows } = await t.db.query(
      `SELECT s.type, s.actor_id FROM transactions s JOIN consignments c ON c.id = s.consignment_id
        WHERE c.qr_code = $1 ORDER BY s.type`,
      [qrCode],
    );
    expect(Object.fromEntries(rows.map((r) => [r.type, r.actor_id]))).toEqual({
      registration: miner.user.id,
      handoff: transporter.user.id,
      purchase: buyer.user.id,
    });
    expect((await counts()).audits).toBe(3);
  });
});
