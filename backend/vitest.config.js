import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // The API runs on Node, so tests should not get browser globals like `window`.
    environment: 'node',
    include: ['tests/**/*.test.js'],
  },
});
