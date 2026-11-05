import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { useTestDb, testDatabaseUrl, PG_ERROR } from './helpers.js';
import { insertUser } from './fixtures.js';
import { createDb, createPool } from '../../src/db.js';

const t = useTestDb();

const countUsersNamed = async (db, username) =>
  (await db.query('SELECT count(*)::int AS n FROM users WHERE username = $1', [username])).rows[0].n;

describe('db.transaction inside the test transaction (savepoints)', () => {
  it('keeps the changes when fn succeeds', async () => {
    await t.db.transaction(async (tx) => {
      await insertUser(tx, { username: 'kept_user' });
    });

    expect(await countUsersNamed(t.db, 'kept_user')).toBe(1);
  });

  it('undoes every change when fn throws, and the outer transaction stays usable', async () => {
    await expect(
      t.db.transaction(async (tx) => {
        await insertUser(tx, { username: 'undone_user' });
        throw new Error('second step failed');
      }),
    ).rejects.toThrow('second step failed');

    // Without the savepoint, this query would fail with "current transaction is aborted".
    expect(await countUsersNamed(t.db, 'undone_user')).toBe(0);
  });

  it('recovers from a PostgreSQL error inside fn and keeps earlier work', async () => {
    await insertUser(t.db, { username: 'first_user' });

    const err = await t.db
      .transaction(async (tx) => {
        await insertUser(tx, { username: 'FIRST_USER' }); // same name, different case
      })
      .catch((e) => e);

    expect(err.code).toBe(PG_ERROR.UNIQUE_VIOLATION);
    expect(await countUsersNamed(t.db, 'first_user')).toBe(1);
  });

  it('undoes only the inner part when a nested transaction fails', async () => {
    await t.db.transaction(async (outer) => {
      await insertUser(outer, { username: 'outer_user' });
      await outer
        .transaction(async (inner) => {
          await insertUser(inner, { username: 'inner_user' });
          throw new Error('inner failed');
        })
        .catch(() => {});
    });

    expect(await countUsersNamed(t.db, 'outer_user')).toBe(1);
    expect(await countUsersNamed(t.db, 'inner_user')).toBe(0);
  });

  // Catches a savepoint left on the stack after an inner rollback. Every savepoint shares
  // one name, so the outer ROLLBACK TO would stop at the leftover inner one and keep
  // outer_user.
  it('undoes the outer part too when the outer transaction fails after a caught inner failure', async () => {
    await expect(
      t.db.transaction(async (outer) => {
        await insertUser(outer, { username: 'outer_user' });
        await outer
          .transaction(async (inner) => {
            await insertUser(inner, { username: 'inner_user' });
            throw new Error('inner failed');
          })
          .catch(() => {});
        throw new Error('outer failed');
      }),
    ).rejects.toThrow('outer failed');

    expect(await countUsersNamed(t.db, 'outer_user')).toBe(0);
    expect(await countUsersNamed(t.db, 'inner_user')).toBe(0);
  });
});

// These use a real pool, as the app does, so they really COMMIT to minechain_test. Each one
// uses a unique username and deletes its row afterwards.
describe('db.transaction on a real pool (BEGIN / COMMIT)', () => {
  let pool;
  let db;

  beforeAll(() => {
    pool = createPool(testDatabaseUrl());
    db = createDb(pool);
  });

  afterAll(async () => {
    await db.close();
  });

  const uniqueName = () => `pool_${randomUUID().slice(0, 8)}`;

  it('makes the changes visible to other connections only after COMMIT', async () => {
    const username = uniqueName();
    try {
      await db.transaction(async (tx) => {
        await insertUser(tx, { username });
        // db.query borrows a different connection from the pool, which cannot see
        // uncommitted work. This is transaction isolation at work.
        expect(await countUsersNamed(db, username)).toBe(0);
        expect(await countUsersNamed(tx, username)).toBe(1);
      });

      expect(await countUsersNamed(db, username)).toBe(1);
    } finally {
      await db.query('DELETE FROM users WHERE username = $1', [username]);
    }
  });

  it('leaves nothing behind when fn throws', async () => {
    const username = uniqueName();

    await expect(
      db.transaction(async (tx) => {
        await insertUser(tx, { username });
        throw new Error('stop here');
      }),
    ).rejects.toThrow('stop here');

    expect(await countUsersNamed(db, username)).toBe(0);
  });

  it('returns the connection to the pool afterwards, even after a failure', async () => {
    await db.transaction(async () => {}).catch(() => {});
    await db.transaction(async () => {
      throw new Error('fail');
    }).catch(() => {});

    // A connection that was never released would still be counted as in use.
    expect(pool.totalCount - pool.idleCount).toBe(0);
  });
});
