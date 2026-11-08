import { randomBytes, randomUUID } from 'node:crypto';

// Valid example rows for the DB tests. Each test overrides only the field it is about, so a
// failure points at a single rule. All values are fake.
// Every insert is one fixed statement with every column as a parameter, so no test builds
// SQL from strings.

// Well-formed, but hashes nothing.
export const FAKE_ARGON2_HASH = '$argon2id$v=19$m=19456,t=2,p=1$ZmFrZXNhbHQ$ZmFrZWhhc2g';

// A valid UUID that no row will ever have, for "points at nothing" tests.
export const MISSING_ID = '00000000-0000-4000-8000-000000000000';

// The parts of loadConfig's result that createServices needs. The secret is fake and only
// long enough to pass the 43-character rule; it is never used outside tests.
export const FAKE_CONFIG = Object.freeze({
  jwtSecret: 'test-only-jwt-secret-never-used-in-production-0000',
  jwtExpiresInSeconds: 3600,
});

// A small triangle near Kasempa, as [lat, lng] corners.
export const SAMPLE_BOUNDARY = [
  [-13.45, 25.82],
  [-13.47, 25.86],
  [-13.49, 25.81],
];

let counter = 0;
const next = () => {
  counter += 1;
  return counter;
};

// ---------- users ----------

export function validUser(overrides = {}) {
  return {
    username: `user_${next()}`,
    full_name: 'Test User',
    licence_number: null,
    password_hash: FAKE_ARGON2_HASH,
    role: 'miner',
    status: 'pending',
    status_reason: null,
    public_key: null,
    actor_ref: randomBytes(32),
    approved_by: null,
    approved_at: null,
    ...overrides,
  };
}

// Returns the statement instead of running it, so a test can pass it to expectPgError.
export function userInsert(overrides) {
  const u = validUser(overrides);
  return {
    text: `
      INSERT INTO users (username, full_name, licence_number, password_hash, role, status,
                         status_reason, public_key, actor_ref, approved_by, approved_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      RETURNING *`,
    params: [
      u.username, u.full_name, u.licence_number, u.password_hash, u.role, u.status,
      u.status_reason, u.public_key, u.actor_ref, u.approved_by, u.approved_at,
    ],
  };
}

export async function insertUser(db, overrides) {
  const { text, params } = userInsert(overrides);
  const { rows } = await db.query(text, params);
  return rows[0];
}

// ---------- gps_zones ----------

export function zoneInsert(overrides) {
  const z = {
    name: `Zone ${next()}`,
    licence_number: null,
    boundary: SAMPLE_BOUNDARY,
    status: 'active',
    created_by: null,
    ...overrides,
  };
  return {
    text: `
      INSERT INTO gps_zones (name, licence_number, boundary, status, created_by)
      VALUES ($1, $2, $3, $4, $5)
      RETURNING *`,
    // pg sends a JS array as a PostgreSQL array ('{...}'), not as JSON, so the boundary
    // is turned into a JSON string first.
    params: [z.name, z.licence_number, JSON.stringify(z.boundary), z.status, z.created_by],
  };
}

// Creates an admin to own the zone unless created_by is given.
export async function insertZone(db, overrides = {}) {
  const createdBy = overrides.created_by ?? (await insertUser(db, { role: 'admin', status: 'active' })).id;
  const { text, params } = zoneInsert({ ...overrides, created_by: createdBy });
  const { rows } = await db.query(text, params);
  return rows[0];
}

// ---------- consignments ----------

export function consignmentInsert(overrides) {
  const c = {
    qr_code: `MC-2026-${String(next()).padStart(6, '0')}`,
    mineral_type: 'gold',
    miner_id: null,
    stage: 'registered',
    ...overrides,
  };
  return {
    text: `
      INSERT INTO consignments (qr_code, mineral_type, miner_id, stage)
      VALUES ($1, $2, $3, $4)
      RETURNING *`,
    params: [c.qr_code, c.mineral_type, c.miner_id, c.stage],
  };
}

// Creates a miner to own the consignment unless miner_id is given.
export async function insertConsignment(db, overrides = {}) {
  const minerId = overrides.miner_id ?? (await insertUser(db, { role: 'miner', status: 'active' })).id;
  const { text, params } = consignmentInsert({ ...overrides, miner_id: minerId });
  const { rows } = await db.query(text, params);
  return rows[0];
}

// ---------- transactions ----------

// Two fixed statements, written out in full. The second is how offline sync will insert:
// a retry of the same signed record does nothing instead of creating a second row.
const INSERT_TRANSACTION = `
  INSERT INTO transactions (
    consignment_id, actor_id, type, idempotency_key, weight_mg, latitude, longitude, zone_id,
    captured_at, signed_payload, signature, signer_public_key, data_hash, hash_version,
    review_status, anchor_status, chain_tx_hash, block_number, anchor_attempts, anchor_error,
    anchored_at, anchor_nonce, anchor_submitted_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
          $19, $20, $21, $22, $23)
  RETURNING *`;
const INSERT_TRANSACTION_IDEMPOTENT = `
  INSERT INTO transactions (
    consignment_id, actor_id, type, idempotency_key, weight_mg, latitude, longitude, zone_id,
    captured_at, signed_payload, signature, signer_public_key, data_hash, hash_version,
    review_status, anchor_status, chain_tx_hash, block_number, anchor_attempts, anchor_error,
    anchored_at, anchor_nonce, anchor_submitted_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
          $19, $20, $21, $22, $23)
  ON CONFLICT ON CONSTRAINT transactions_idempotency_key_unique DO NOTHING
  RETURNING *`;

// A valid, accepted registration that has not been anchored yet. consignment_id and
// actor_id must be supplied; insertTransaction fills them in.
export function transactionInsert(overrides, { onConflictDoNothing = false } = {}) {
  const idempotencyKey = overrides.idempotency_key ?? randomUUID();
  const tx = {
    type: 'registration',
    weight_mg: '1500000', // 1.5 kg; bigint goes in as a string to avoid precision loss
    latitude: -13.45,
    longitude: 25.82,
    zone_id: null,
    captured_at: new Date('2026-11-01T08:00:00Z'),
    signed_payload: JSON.stringify({ idempotencyKey, weightMg: '1500000', lat: -13.45, lng: 25.82 }),
    signature: randomBytes(70),
    signer_public_key: randomBytes(91),
    data_hash: randomBytes(32),
    hash_version: 1,
    review_status: 'passed',
    anchor_status: 'pending',
    chain_tx_hash: null,
    block_number: null,
    anchor_attempts: 0,
    anchor_error: null,
    anchored_at: null,
    anchor_nonce: null,
    anchor_submitted_at: null,
    ...overrides,
    idempotency_key: idempotencyKey,
  };
  return {
    text: onConflictDoNothing ? INSERT_TRANSACTION_IDEMPOTENT : INSERT_TRANSACTION,
    params: [
      tx.consignment_id, tx.actor_id, tx.type, tx.idempotency_key, tx.weight_mg, tx.latitude,
      tx.longitude, tx.zone_id, tx.captured_at, tx.signed_payload, tx.signature,
      tx.signer_public_key, tx.data_hash, tx.hash_version, tx.review_status, tx.anchor_status,
      tx.chain_tx_hash, tx.block_number, tx.anchor_attempts, tx.anchor_error, tx.anchored_at,
      tx.anchor_nonce, tx.anchor_submitted_at,
    ],
  };
}

// Creates the consignment (and its miner, who becomes the actor) unless they are given.
export async function transactionParents(db, overrides = {}) {
  let consignmentId = overrides.consignment_id;
  let actorId = overrides.actor_id;
  if (!consignmentId) {
    const consignment = await insertConsignment(db, actorId ? { miner_id: actorId } : {});
    consignmentId = consignment.id;
    actorId ??= consignment.miner_id;
  }
  actorId ??= (await insertUser(db, { role: 'miner', status: 'active' })).id;
  return { consignment_id: consignmentId, actor_id: actorId };
}

export async function insertTransaction(db, overrides = {}) {
  const parents = await transactionParents(db, overrides);
  const { text, params } = transactionInsert({ ...overrides, ...parents });
  const { rows } = await db.query(text, params);
  return rows[0];
}

// ---------- alerts ----------

// An open quantity_discrepancy alert. transaction_id must be supplied; insertAlert fills
// it in.
export function alertInsert(overrides) {
  const a = {
    type: 'quantity_discrepancy',
    severity: 'medium',
    details: { expectedWeightMg: '1500000', actualWeightMg: '1200000' },
    status: 'open',
    reviewed_by: null,
    review_notes: null,
    reviewed_at: null,
    ...overrides,
  };
  return {
    text: `
      INSERT INTO alerts (transaction_id, type, severity, details, status, reviewed_by,
                          review_notes, reviewed_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      RETURNING *`,
    // Always JSON.stringify: pg would send an array as a PostgreSQL array, not as JSON.
    params: [
      a.transaction_id, a.type, a.severity, JSON.stringify(a.details), a.status,
      a.reviewed_by, a.review_notes, a.reviewed_at,
    ],
  };
}

// Creates a step to attach the alert to unless transaction_id is given.
export async function insertAlert(db, overrides = {}) {
  const transactionId = overrides.transaction_id ?? (await insertTransaction(db)).id;
  const { text, params } = alertInsert({ ...overrides, transaction_id: transactionId });
  const { rows } = await db.query(text, params);
  return rows[0];
}

// ---------- audit_logs ----------

// A system entry with no actor or entity.
export function auditInsert(overrides) {
  const e = {
    actor_id: null,
    action: 'user.login',
    entity_type: null,
    entity_id: null,
    details: {},
    ip_address: null,
    ...overrides,
  };
  return {
    text: `
      INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details, ip_address)
      VALUES ($1, $2, $3, $4, $5, $6)
      RETURNING *`,
    params: [e.actor_id, e.action, e.entity_type, e.entity_id, JSON.stringify(e.details), e.ip_address],
  };
}

export async function insertAudit(db, overrides) {
  const { text, params } = auditInsert(overrides);
  const { rows } = await db.query(text, params);
  return rows[0];
}
