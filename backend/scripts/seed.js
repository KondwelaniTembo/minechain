// `npm run seed` (development) or `npm run seed -- --production-admin-only` (production).
// The "--" matters: without it, npm takes the flag as its own option and the script never
// sees it, and in production the seed then refuses to run.
//
// This file only connects things and turns the result into an exit code. All the rules
// live in src/seed/seed.js, where the database tests can reach them.
import dotenv from 'dotenv';
import { loadConfig } from '../src/config.js';
import { createPool, createDb } from '../src/db.js';
import { runSeed, SeedError } from '../src/seed/seed.js';

// Loads backend/.env locally. On Render the variables come from the dashboard instead.
dotenv.config({ quiet: true });

// Database errors are reported by SQLSTATE code and constraint name only. A PostgreSQL
// error's detail can echo values ("Key (...)=(...) already exists"), the problem tracked
// in Issue #3, so it is never printed here.
function describeUnexpected(err) {
  if (err.code) {
    return `Database or connection error ${err.code}${err.constraint ? ` (constraint ${err.constraint})` : ''}.`;
  }
  // Not from PostgreSQL: a bug in our own code, whose messages never contain a password.
  return `${err.name}: ${err.message}`;
}

async function main() {
  let config;
  try {
    // The same validated settings as the server, including which database to use.
    config = loadConfig(process.env);
  } catch (err) {
    // Lists variable names and rules only, never values.
    console.error(err.message);
    return 1;
  }

  // The test database is filled and emptied by the tests themselves, inside transactions
  // that roll back. Committed seed rows there could never be removed (audit_logs is
  // append-only) and would upset the tests' counts.
  if (config.nodeEnv === 'test') {
    console.error('Refusing to seed while NODE_ENV is test. The database tests call runSeed directly.');
    return 1;
  }

  const db = createDb(createPool(config.databaseUrl));
  try {
    await runSeed({ db, env: process.env, args: process.argv.slice(2) });
    return 0;
  } catch (err) {
    if (err instanceof SeedError) {
      console.error(err.message);
    } else {
      console.error(`Seed failed. Its transaction was rolled back, so nothing was saved. ${describeUnexpected(err)}`);
    }
    return 1;
  } finally {
    await db.close();
  }
}

// exitCode rather than process.exit(), so the pool finishes closing before Node exits.
process.exitCode = await main();
