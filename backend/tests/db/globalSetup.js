import { fileURLToPath } from 'node:url';
import { runner } from 'node-pg-migrate';
import { testDatabaseUrl } from './helpers.js';

// Vitest calls this once before the database tests. Running the migrations here means the
// test database always matches the latest schema, without remembering `npm run migrate:test`.
export default async function setup() {
  await runner({
    databaseUrl: testDatabaseUrl(),
    // Resolved from this file rather than the current folder, so it works wherever
    // Vitest is started from.
    dir: fileURLToPath(new URL('../../migrations', import.meta.url)),
    // Same table as the CLI, so `npm run migrate:test` and the tests share one history.
    migrationsTable: 'pgmigrations',
    direction: 'up',
    checkOrder: true,
    singleTransaction: true,
    // Skips dotfiles such as migrations/.gitkeep.
    ignorePattern: '\\..*',
    // Quiet when nothing is pending; a failed migration still throws and stops the run.
    log: () => {},
  });
}
