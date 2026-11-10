import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { useTestDb } from './helpers.js';
import { insertUser } from './fixtures.js';
import { auth, bindRealStack, loggedInSigner, stepItem, syncSteps } from './realStackHelpers.js';
import { TRANSACTION_COLUMNS, AUDIT_TRAIL_COLUMNS } from '../../src/services/reportService.js';
import { ZCAS_CAMPUS_BOUNDARY } from '../../src/seed/seedData.js';

// Reports (FR-09, FR-13) through the whole stack: accounts made through the API, real P-256
// signatures synced over HTTP, then CSV downloads, parsed back here. stepItem's coordinates
// (-15.419012, 28.288105) are inside the ZCAS campus polygon, and its capture time is
// 2026-11-10T08:00:00.000Z, so every report asks for that one day.

const t = useTestDb();
const { realStack } = bindRealStack(t);

const DAY = 'from=2026-11-10&to=2026-11-10';
const FORMULA = '=HYPERLINK("http://x","y")';

// Every item gets a random step id, as in flaggedChain.test.js.
const item = (party, type, qrCode, overrides = {}) => stepItem(party, type, qrCode, { stepId: randomUUID(), ...overrides });

// Capture times in custody order, all on 2026-11-10. stepItem gives every step the same
// default time, and the report orders by captured_at and then by id (a random uuid), so
// steps that share a time would come out in a different order on each run.
const CAPTURED_AT = Object.freeze({
  registration: '2026-11-10T08:00:00.000Z',
  handoff: '2026-11-10T09:00:00.000Z',
  purchase: '2026-11-10T10:00:00.000Z',
});

// Reads the body as raw bytes, so the test sees exactly what was sent, BOM included.
const asBytes = (res, callback) => {
  const chunks = [];
  res.on('data', (chunk) => chunks.push(chunk));
  res.on('end', () => callback(null, Buffer.concat(chunks)));
};
const download = (app, token, path) => auth(request(app).get(path), token).buffer(true).parse(asBytes);

// A small RFC 4180 reader for the tests: quoted fields, "" for a quote, CRLF between
// records. Written here rather than taken from a library, so the test does not trust the
// same assumptions as the code it checks. Returns the header row and the data rows as
// objects keyed by header.
function parseCsv(bytes) {
  const BOM = '\uFEFF';
  const text = bytes.toString('utf8');
  expect(text.startsWith(BOM)).toBe(true);
  const records = [];
  let record = [];
  let field = '';
  let inQuotes = false;
  for (let i = BOM.length; i < text.length; i += 1) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (c === '"') {
        inQuotes = false;
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ',') {
      record.push(field);
      field = '';
    } else if (c === '\r' && text[i + 1] === '\n') {
      record.push(field);
      records.push(record);
      record = [];
      field = '';
      i += 1;
    } else {
      throw new Error(`unexpected character outside quotes at ${i}`);
    }
  }
  expect(record).toEqual([]);
  const [header, ...rows] = records;
  return { header, rows: rows.map((r) => Object.fromEntries(header.map((h, i) => [h, r[i]]))) };
}

// The stack, an active admin, the campus zone created through the API, an officer, and the
// people who sign steps, all through the API.
async function setup() {
  const { app, tokenFor } = realStack();
  const admin = await insertUser(t.db, { role: 'admin', status: 'active' });
  const adminToken = await tokenFor({ id: admin.id, role: 'admin' });
  const zone = await auth(request(app).post('/admin/zones'), adminToken).send({ name: 'ZCAS Campus (reports)', boundary: ZCAS_CAMPUS_BOUNDARY });
  expect(zone.status).toBe(201);
  const officer = await insertUser(t.db, { role: 'officer', status: 'active' });
  const officerToken = await tokenFor({ id: officer.id, role: 'officer' });
  return { app, adminToken, officer, officerToken };
}

// Registration, handoff and purchase of one consignment, synced in custody order.
async function journey(app, { miner, transporter, buyer }, qrCode) {
  for (const [party, type] of [
    [miner, 'registration'],
    [transporter, 'handoff'],
    [buyer, 'purchase'],
  ]) {
    const res = await syncSteps(app, party, [item(party, type, qrCode, { capturedAt: CAPTURED_AT[type] })]);
    expect(res.status).toBe(200);
    expect(res.body.results[0].outcome).toBe('created');
  }
}

describe('reports through the real stack', () => {
  it('an officer downloads every step; a buyer downloads only the consignment they bought', async () => {
    const { app, adminToken, officerToken } = await setup();
    const miner = await loggedInSigner(app, adminToken, 'miner');
    const transporter = await loggedInSigner(app, adminToken, 'transporter');
    const buyer = await loggedInSigner(app, adminToken, 'buyer');
    const otherBuyer = await loggedInSigner(app, adminToken, 'buyer');
    const mine = `MC-REPORT-${randomUUID()}`;
    const theirs = `MC-REPORT-${randomUUID()}`;
    await journey(app, { miner, transporter, buyer }, mine);
    await journey(app, { miner, transporter, buyer: otherBuyer }, theirs);

    // ---------- the officer: every step ----------
    const res = await download(app, officerToken, `/reports/transactions?${DAY}`);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('text/csv; charset=utf-8');
    expect(res.headers['content-disposition']).toBe('attachment; filename="minechain-transactions-2026-11-10-to-2026-11-10.csv"');
    expect(res.headers['cache-control']).toBe('no-store');
    const officerCsv = parseCsv(res.body);
    expect(officerCsv.header).toEqual(TRANSACTION_COLUMNS.map((c) => c.header));
    expect(officerCsv.rows).toHaveLength(6);

    const registration = officerCsv.rows.find((r) => r.qr_code === mine && r.step_type === 'registration');
    expect(registration).toMatchObject({
      mineral: 'gold',
      consignment_stage: 'purchased',
      actor_username: miner.username,
      actor_role: 'miner',
      actor_licence_number: '',
      weight_mg: '1500000',
      weight_kg: '1.500000',
      latitude: '-15.419012',
      longitude: '28.288105',
      zone_name: 'ZCAS Campus (reports)',
      captured_at_utc: '2026-11-10T08:00:00.000Z',
      review_status: 'passed',
      anchor_status: 'pending',
      chain_tx_hash: '',
      block_number: '',
      anchored_at_utc: '',
    });
    expect(registration.received_at_utc).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    expect(registration.data_hash).toMatch(/^0x[0-9a-f]{64}$/);

    // ---------- the buyer: only the consignment they bought ----------
    const buyerRes = await download(app, buyer.token, `/reports/transactions?${DAY}`);

    expect(buyerRes.status).toBe(200);
    const buyerCsv = parseCsv(buyerRes.body);
    expect(buyerCsv.rows.map((r) => [r.qr_code, r.step_type])).toEqual([
      [mine, 'registration'],
      [mine, 'handoff'],
      [mine, 'purchase'],
    ]);
    expect(buyerCsv.rows.filter((r) => r.step_type === 'purchase').map((r) => r.actor_username)).toEqual([buyer.username]);
    expect(buyerRes.body.toString('utf8')).not.toContain(theirs);
    expect(buyerRes.body.toString('utf8')).not.toContain(otherBuyer.username);

    // ---------- both exports were recorded ----------
    const { rows: audits } = await t.db.query(
      "SELECT actor_id, details->>'scope' AS scope, (details->>'rowCount')::int AS row_count FROM audit_logs WHERE action = 'report.transactions_export' ORDER BY id",
    );
    expect(audits.map((a) => [a.scope, a.row_count])).toEqual([
      ['all', 6],
      ['own_purchases', 3],
    ]);
    expect(audits[1].actor_id).toBe(buyer.user.id);
  });

  it('neutralises a formula typed as a licence number at registration, end to end', async () => {
    const { app, adminToken, officerToken } = await setup();
    // POST /auth/register accepts any text of 1 to 50 characters as a licence number, so this
    // is what anyone requesting an account can put in front of an officer.
    const miner = await loggedInSigner(app, adminToken, 'miner', { licenceNumber: FORMULA });
    const { rows: stored } = await t.db.query('SELECT licence_number FROM users WHERE id = $1', [miner.user.id]);
    expect(stored[0].licence_number).toBe(FORMULA);
    const registered = await syncSteps(app, miner, [item(miner, 'registration', `MC-FORMULA-${randomUUID()}`)]);
    expect(registered.body.results[0].outcome).toBe('created');

    const res = await download(app, officerToken, `/reports/transactions?${DAY}`);

    expect(res.status).toBe(200);
    // The exact bytes of the cell: a quote mark in front, and every " doubled.
    expect(res.body.toString('utf8')).toContain('"\'=HYPERLINK(""http://x"",""y"")"');
    // Read back, the cell is the original text with the quote mark in front.
    const { rows } = parseCsv(res.body);
    expect(rows.map((r) => r.actor_licence_number)).toEqual([`'${FORMULA}`]);
  });

  it("an officer downloads one consignment's audit trail", async () => {
    const { app, adminToken, officer, officerToken } = await setup();
    const miner = await loggedInSigner(app, adminToken, 'miner');
    const qrCode = `MC-TRAIL-${randomUUID()}`;
    const registered = await syncSteps(app, miner, [item(miner, 'registration', qrCode)]);
    expect(registered.body.results[0].outcome).toBe('created');
    const { rows: consignments } = await t.db.query('SELECT id FROM consignments WHERE qr_code = $1', [qrCode]);
    const consignmentId = consignments[0].id;

    const res = await download(app, officerToken, `/reports/audit-trail?consignmentId=${consignmentId}`);

    expect(res.status).toBe(200);
    expect(res.headers['content-disposition']).toBe(`attachment; filename="minechain-audit-trail-consignment-${consignmentId}.csv"`);
    const csv = parseCsv(res.body);
    expect(csv.header).toEqual(AUDIT_TRAIL_COLUMNS.map((c) => c.header));
    expect(csv.rows.map((r) => [r.event, r.qr_code, r.actor_username])).toEqual([['step_recorded', qrCode, miner.username]]);

    const { rows: audits } = await t.db.query(
      "SELECT actor_id, entity_type, entity_id FROM audit_logs WHERE action = 'report.audit_trail_export'",
    );
    expect(audits).toEqual([{ actor_id: officer.id, entity_type: 'consignment', entity_id: consignmentId }]);
  });

  it('refuses the audit trail to a buyer through the real stack', async () => {
    const { app, adminToken } = await setup();
    const buyer = await loggedInSigner(app, adminToken, 'buyer');

    const res = await auth(request(app).get(`/reports/audit-trail?consignmentId=${randomUUID()}`), buyer.token);

    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
});
