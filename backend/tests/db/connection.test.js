import { describe, it, expect } from 'vitest';
import { useTestDb, expectPgError, testDatabaseUrl, PG_ERROR } from './helpers.js';

const t = useTestDb();

describe('test database setup', () => {
  it('is connected to the test database named in TEST_DATABASE_URL', async () => {
    const expectedName = new URL(testDatabaseUrl()).pathname.slice(1);

    const { rows } = await t.db.query('SELECT current_database() AS name');

    expect(rows[0].name).toBe(expectedName);
  });

  it('has been migrated, so the migrations history table exists', async () => {
    const { rows } = await t.db.query("SELECT to_regclass('public.pgmigrations') AS tbl");

    expect(rows[0].tbl).toBe('pgmigrations');
  });

  // These two tests share a table name. The second only passes if the first was rolled
  // back, which proves that tests are isolated from each other.
  it('rolls back what a test creates (part 1: create)', async () => {
    await t.db.query('CREATE TABLE isolation_probe (id int)');
  });

  it('rolls back what a test creates (part 2: it is gone)', async () => {
    const { rows } = await t.db.query("SELECT to_regclass('public.isolation_probe') AS tbl");

    expect(rows[0].tbl).toBeNull();
  });

  it('expectPgError checks the error code and lets the test continue', async () => {
    await expectPgError(t.db, 'SELECT 1 / 0', [], '22012'); // division_by_zero

    // Without the savepoint, this would fail with "current transaction is aborted".
    const { rows } = await t.db.query('SELECT 1 AS ok');
    expect(rows[0].ok).toBe(1);
  });

  it('expectPgError fails when the query succeeds', async () => {
    await expect(expectPgError(t.db, 'SELECT 1', [], PG_ERROR.CHECK_VIOLATION)).rejects.toThrow(
      /but the query succeeded/,
    );
  });
});
