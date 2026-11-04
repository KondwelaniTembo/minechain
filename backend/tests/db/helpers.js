import dotenv from 'dotenv';
import { beforeAll, afterAll, beforeEach, afterEach, expect } from 'vitest';
import { loadConfig } from '../../src/config.js';
import { createPool, createDb } from '../../src/db.js';

// SQLSTATE codes PostgreSQL puts on err.code. Asserting on the code, not the message,
// proves *which* rule rejected a row: a CHECK failing is not the same as a missing column.
export const PG_ERROR = {
  UNIQUE_VIOLATION: '23505',
  CHECK_VIOLATION: '23514',
  FOREIGN_KEY_VIOLATION: '23503',
  // ON DELETE RESTRICT reports this instead of 23503 when a referenced row is deleted.
  // NO ACTION (the default) would give 23503.
  RESTRICT_VIOLATION: '23001',
  // Writing to a GENERATED ALWAYS column, such as consignments.chain_id.
  GENERATED_ALWAYS: '428C9',
  // A value too big for the column type, such as 1000 in numeric(9,6). Raised before any
  // CHECK runs.
  NUMERIC_OUT_OF_RANGE: '22003',
  // Text that cannot be read as the column's type, such as 'not-an-ip' for inet.
  INVALID_TEXT_REPRESENTATION: '22P02',
  NOT_NULL_VIOLATION: '23502',
  RAISED_EXCEPTION: 'P0001',
};

// Goes through loadConfig with NODE_ENV forced to test, so the rules from step 2 apply
// here too: TEST_DATABASE_URL must be set and must differ from DATABASE_URL. A wrong
// .env can therefore never point the tests at development data.
export function testDatabaseUrl() {
  dotenv.config({ quiet: true });
  return loadConfig({ ...process.env, NODE_ENV: 'test' }).databaseUrl;
}

// Call once at the top of a test file. Each test gets its own connection inside an open
// transaction, which is rolled back afterwards, so every test starts from empty tables.
// That is faster than deleting rows and cannot forget a table.
export function useTestDb() {
  const handle = { db: null };
  let pool;
  let client;

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
  });

  beforeEach(async () => {
    client = await pool.connect();
    await client.query('BEGIN');
    // The same query helper the app uses. A single client has query() just like a pool,
    // so createDb works with it unchanged.
    handle.db = createDb(client);
  });

  afterEach(async () => {
    await client.query('ROLLBACK');
    client.release();
  });

  afterAll(async () => {
    await pool.end();
  });

  return handle;
}

// Runs a query that should be rejected and checks the SQLSTATE code.
// After any error, PostgreSQL refuses further statements in that transaction until it is
// rolled back. A savepoint rolls back just the failed statement, so the test can go on.
export async function expectPgError(db, text, params, code) {
  await db.query('SAVEPOINT expect_pg_error');
  try {
    await db.query(text, params);
  } catch (err) {
    await db.query('ROLLBACK TO SAVEPOINT expect_pg_error');
    expect(err.code, `PostgreSQL said: ${err.message}`).toBe(code);
    return err;
  }
  throw new Error(`Expected PostgreSQL error ${code}, but the query succeeded`);
}
