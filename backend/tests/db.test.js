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

// A fake pool whose connect() hands out one fake connection. The connection records every
// statement, so the tests can check the exact BEGIN / COMMIT / ROLLBACK sequence.
function fakePoolWithClient({ failOn } = {}) {
  const statements = [];
  const client = {
    query: vi.fn(async (text) => {
      statements.push(text);
      if (failOn && text === failOn) throw new Error(`${failOn} failed`);
      return { rows: [], rowCount: 0 };
    }),
    release: vi.fn(),
  };
  const pool = { connect: vi.fn().mockResolvedValue(client), query: vi.fn(), end: vi.fn() };
  return { pool, client, statements };
}

describe('db.transaction on a pool', () => {
  it('runs fn between BEGIN and COMMIT on one connection, and returns its result', async () => {
    const { pool, client, statements } = fakePoolWithClient();

    const result = await createDb(pool).transaction(async (tx) => {
      await tx.query('INSERT INTO users DEFAULT VALUES');
      return 'saved';
    });

    expect(result).toBe('saved');
    expect(statements).toEqual(['BEGIN', 'INSERT INTO users DEFAULT VALUES', 'COMMIT']);
    // Every query went to the same connection, not to the pool.
    expect(pool.query).not.toHaveBeenCalled();
    expect(client.release).toHaveBeenCalledWith(undefined);
  });

  it('rolls back and passes the error on when fn throws', async () => {
    const { pool, client, statements } = fakePoolWithClient();

    await expect(
      createDb(pool).transaction(async (tx) => {
        await tx.query('INSERT INTO users DEFAULT VALUES');
        throw new Error('audit insert failed');
      }),
    ).rejects.toThrow('audit insert failed');

    expect(statements).toEqual(['BEGIN', 'INSERT INTO users DEFAULT VALUES', 'ROLLBACK']);
    expect(client.release).toHaveBeenCalledWith(undefined);
  });

  it('keeps the original error and discards the connection if ROLLBACK itself fails', async () => {
    const { pool, client } = fakePoolWithClient({ failOn: 'ROLLBACK' });

    await expect(
      createDb(pool).transaction(async () => {
        throw new Error('original problem');
      }),
    ).rejects.toThrow('original problem');

    // Passing an error to release() tells pg to destroy the connection, not reuse it.
    expect(client.release).toHaveBeenCalledWith(expect.objectContaining({ message: 'ROLLBACK failed' }));
  });

  it('gives fn a db whose own transaction() uses a savepoint', async () => {
    const { pool, statements } = fakePoolWithClient();

    await createDb(pool).transaction(async (tx) => {
      await tx.transaction(async (inner) => {
        await inner.query('SELECT 1');
      });
    });

    expect(statements).toEqual(['BEGIN', 'SAVEPOINT app_transaction', 'SELECT 1', 'RELEASE SAVEPOINT app_transaction', 'COMMIT']);
  });
});

describe('db.transaction inside an existing transaction', () => {
  function fakeConnection() {
    const statements = [];
    const connection = {
      query: vi.fn(async (text) => {
        statements.push(text);
        return { rows: [], rowCount: 0 };
      }),
    };
    return { db: createDb(connection, { inTransaction: true }), statements };
  }

  it('wraps fn in a savepoint and releases it on success', async () => {
    const { db, statements } = fakeConnection();

    await db.transaction(async (tx) => tx.query('SELECT 1'));

    expect(statements).toEqual(['SAVEPOINT app_transaction', 'SELECT 1', 'RELEASE SAVEPOINT app_transaction']);
  });

  it('rolls back to the savepoint, releases it, and passes the error on when fn throws', async () => {
    const { db, statements } = fakeConnection();

    await expect(
      db.transaction(async () => {
        throw new Error('nested failure');
      }),
    ).rejects.toThrow('nested failure');

    expect(statements).toEqual([
      'SAVEPOINT app_transaction',
      'ROLLBACK TO SAVEPOINT app_transaction',
      // Without this, the rolled-back savepoint would stay on the stack.
      'RELEASE SAVEPOINT app_transaction',
    ]);
  });

  it('refuses close(), which only makes sense for the pool', () => {
    const { db } = fakeConnection();

    expect(() => db.close()).toThrow(TypeError);
  });
});
