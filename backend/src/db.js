import pg from 'pg';

export function createPool(connectionString) {
  // Creating a pool does not connect yet; connections open on the first query.
  const pool = new pg.Pool({ connectionString });

  // If an idle connection drops (database restart, network blip), pg emits 'error' on the
  // pool. With no listener, Node treats that as an unhandled error and crashes the server.
  // Only the message is logged, because pg errors can echo query details.
  pool.on('error', (err) => {
    console.error('Idle PostgreSQL connection failed:', err.message);
  });

  return pool;
}

// The app depends on this small object rather than on pg itself, so tests can swap in a
// fake with the same two methods and never need a running database.
export function createDb(pool) {
  return {
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

      const result = await pool.query(text, params);
      // Only what callers need, which keeps fakes in tests simple.
      return { rows: result.rows, rowCount: result.rowCount };
    },

    close() {
      return pool.end();
    },
  };
}
