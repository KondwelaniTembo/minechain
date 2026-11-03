import { defineConfig } from 'vitest/config';

// Config for `npm run test:db`: tests that run real SQL against minechain_test.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['tests/db/**/*.test.js'],
    // Runs once before any test file, and brings minechain_test up to the latest migration.
    globalSetup: ['tests/db/globalSetup.js'],
    // All files share one database. If two files ran at once, an uncommitted row in one
    // (for example a username) could block or clash with an insert in the other.
    fileParallelism: false,
  },
});
