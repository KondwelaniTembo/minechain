import pg from 'pg';

export function createPool(connectionString) {
  // Creating a pool does not connect yet; connections open on the first query.
  const pool = new pg.Pool({
    connectionString,
    // pg's default is to wait forever for a connection, so a stopped database would make
    // requests (including /health) hang instead of failing with a clear error.
    connectionTimeoutMillis: 5000,
  });

  // If an idle connection drops (database restart, network blip), pg emits 'error' on the
  // pool. With no listener, Node treats that as an unhandled error and crashes the server.
  // Only the message is logged, because pg errors can echo query details.
  pool.on('error', (err) => {
    console.error('Idle PostgreSQL connection failed:', err.message);
  });

  return pool;
}

// The statement that opens a transaction, per isolation level. Fixed text, never built from
// input: an isolation level cannot be sent as a $1 parameter.
//   read committed:  PostgreSQL's default. Each statement sees what was committed before it
//                    started.
//   repeatable read: every statement sees the same snapshot, taken at the first query. Used
//                    by reports, so an export and its row count describe one moment.
const BEGIN_STATEMENTS = Object.freeze({
  'read committed': 'BEGIN',
  'repeatable read': 'BEGIN ISOLATION LEVEL REPEATABLE READ',
});

// The app depends on this small object rather than on pg itself, so tests can swap in a
// fake with the same methods and never need a running database.
//
// `executor` is either a pool or a single connection that is already inside a transaction
// (inTransaction: true). The DB tests use the second form, and so does the object that
// transaction() hands to its callback.
export function createDb(executor, { inTransaction = false } = {}) {
  const db = {
    async query(text, params = []) {
      if (typeof text !== 'string' || text.trim() === '') {
        throw new TypeError('Query text must be a non-empty SQL string');
      }
      // Values must travel separately from the SQL ($1, $2, ...) so PostgreSQL never
      // treats user input as SQL. Refusing anything but an array stops a value being
      // passed where the params should be.
      if (!Array.isArray(params)) {
        throw new TypeError('Query params must be an array, for example [userId]');
      }

      const result = await executor.query(text, params);
      // Only what callers need, which keeps fakes in tests simple.
      return { rows: result.rows, rowCount: result.rowCount };
    },

    // Runs fn(tx) so that everything it does through tx is saved together or not at all.
    // If fn throws, every change is undone and the error is passed on. Example: a new user
    // and its audit row, where saving one without the other would be wrong.
    // isolation: 'read committed' (the default) or 'repeatable read'.
    async transaction(fn, { isolation = 'read committed' } = {}) {
      // Object.hasOwn, not a truthy lookup: BEGIN_STATEMENTS.toString exists (inherited from
      // Object.prototype), so 'toString' or 'constructor' would otherwise pass as a level.
      if (typeof isolation !== 'string' || !Object.hasOwn(BEGIN_STATEMENTS, isolation)) {
        throw new TypeError(`Unknown isolation level; expected one of ${Object.keys(BEGIN_STATEMENTS).join(', ')}`);
      }
      const begin = BEGIN_STATEMENTS[isolation];

      if (inTransaction) {
        // A savepoint cannot change the isolation level: PostgreSQL only accepts it at the
        // start of a transaction, so the outer transaction's level applies. In the DB tests
        // that is the test's own READ COMMITTED transaction.
        // Already inside a transaction: a savepoint gives the same all-or-nothing result
        // for this part, and leaves the outer transaction usable after a failure.
        // One fixed name, written out in full: savepoint names cannot be sent as $1
        // parameters, so numbered names (sp_1, sp_2, ...) would mean building SQL from
        // strings. PostgreSQL allows a name to be reused, and RELEASE and ROLLBACK TO act
        // on the newest savepoint with that name, which is what nesting needs.
        await executor.query('SAVEPOINT app_transaction');
        try {
          const result = await fn(db);
          await executor.query('RELEASE SAVEPOINT app_transaction');
          return result;
        } catch (err) {
          await executor.query('ROLLBACK TO SAVEPOINT app_transaction');
          // ROLLBACK TO undoes the work but keeps the savepoint on the stack. Because every
          // savepoint shares one name, a leftover one would be taken for the outer
          // transaction's: the outer ROLLBACK TO or RELEASE would stop at it, and an outer
          // failure would keep rows written before it. Releasing it removes it.
          await executor.query('RELEASE SAVEPOINT app_transaction');
          throw err;
        }
      }

      // A transaction belongs to one connection, so all of fn's queries must use the same
      // one instead of whichever the pool hands out next.
      const client = await executor.connect();
      let brokenConnection;
      try {
        await client.query(begin);
        const result = await fn(createDb(client, { inTransaction: true }));
        await client.query('COMMIT');
        return result;
      } catch (err) {
        try {
          await client.query('ROLLBACK');
        } catch (rollbackErr) {
          // The connection itself failed. Keep the original error for the caller, and
          // tell the pool to discard this connection rather than reuse it.
          brokenConnection = rollbackErr;
        }
        throw err;
      } finally {
        client.release(brokenConnection);
      }
    },

    close() {
      if (inTransaction) {
        throw new TypeError('close() is only for the pool, not for a connection inside a transaction');
      }
      return executor.end();
    },
  };
  return db;
}
