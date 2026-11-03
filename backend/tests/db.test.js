import { describe, it, expect, vi } from 'vitest';
import { createDb, createPool } from '../src/db.js';

// A stand-in for pg.Pool that records calls, so these tests need no database.
function fakePool(result = { rows: [], rowCount: 0 }) {
  return {
    query: vi.fn().mockResolvedValue(result),
    end: vi.fn().mockResolvedValue(undefined),
  };
}

describe('createDb', () => {
  it('sends the SQL text and the values separately', async () => {
    const pool = fakePool();
    const db = createDb(pool);

    await db.query('SELECT * FROM users WHERE id = $1', ['user-1']);

    expect(pool.query).toHaveBeenCalledWith('SELECT * FROM users WHERE id = $1', ['user-1']);
  });

  it('defaults to no values when params are left out', async () => {
    const pool = fakePool();

    await createDb(pool).query('SELECT 1');

    expect(pool.query).toHaveBeenCalledWith('SELECT 1', []);
  });

  it('returns only rows and rowCount', async () => {
    const pool = fakePool({ rows: [{ id: 1 }], rowCount: 1, command: 'SELECT', fields: [] });

    const result = await createDb(pool).query('SELECT id FROM users');

    expect(result).toEqual({ rows: [{ id: 1 }], rowCount: 1 });
  });

  it.each([undefined, '', '   ', 42])('rejects query text %j', async (text) => {
    const pool = fakePool();

    await expect(createDb(pool).query(text)).rejects.toThrow(TypeError);
    expect(pool.query).not.toHaveBeenCalled();
  });

  it('rejects params that are not an array', async () => {
    const pool = fakePool();

    // A common slip: passing the value itself instead of [value].
    await expect(createDb(pool).query('SELECT * FROM users WHERE id = $1', 'user-1')).rejects.toThrow(
      /must be an array/,
    );
    expect(pool.query).not.toHaveBeenCalled();
  });

  it('passes database errors through to the caller', async () => {
    const pool = fakePool();
    pool.query.mockRejectedValue(new Error('relation "users" does not exist'));

    await expect(createDb(pool).query('SELECT * FROM users')).rejects.toThrow(/does not exist/);
  });

  it('close() shuts the pool down', async () => {
    const pool = fakePool();

    await createDb(pool).close();

    expect(pool.end).toHaveBeenCalledOnce();
  });
});

describe('createPool', () => {
  it('listens for idle connection errors so they cannot crash the server', async () => {
    // Safe offline: a pool only connects when the first query runs.
    const pool = createPool('postgresql://user:pass@localhost:5432/not_used');

    expect(pool.listenerCount('error')).toBe(1);

    await pool.end();
  });
});
