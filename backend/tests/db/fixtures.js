import { randomBytes } from 'node:crypto';

// Valid example rows for the DB tests. Each test overrides only the field it is about, so a
// failure points at a single rule. All values are fake.
// Every insert is one fixed statement with every column as a parameter, so no test builds
// SQL from strings.

// Well-formed, but hashes nothing.
export const FAKE_ARGON2_HASH = '$argon2id$v=19$m=19456,t=2,p=1$ZmFrZXNhbHQ$ZmFrZWhhc2g';

// A valid UUID that no row will ever have, for "points at nothing" tests.
export const MISSING_ID = '00000000-0000-4000-8000-000000000000';

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
