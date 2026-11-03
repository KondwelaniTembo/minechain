import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // The API runs on Node, so tests should not get browser globals like `window`.
    environment: 'node',
    include: ['tests/**/*.test.js'],
    // Database tests need PostgreSQL running, so they live behind `npm run test:db`
    // (vitest.db.config.js). `npm test` stays fast and works with no database.
    exclude: ['tests/db/**', 'node_modules/**'],
  },
});
