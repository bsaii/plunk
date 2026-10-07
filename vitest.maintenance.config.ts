import path from 'node:path';
import {defineConfig} from 'vitest/config';

// Focused unit tests: no production credentials, database or Redis required.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['apps/api/src/jobs/__tests__/maintenance-*.test.ts'],
  },
  resolve: {
    alias: {
      '@plunk/db': path.resolve(__dirname, './packages/db/src'),
      '@plunk/types': path.resolve(__dirname, './packages/types/src'),
    },
  },
});
