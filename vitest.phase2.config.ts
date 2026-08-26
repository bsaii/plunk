import {defineConfig} from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['apps/api/src/queue/__tests__/**/*.test.ts'],
  },
});
