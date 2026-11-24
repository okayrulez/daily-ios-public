import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { root: import.meta.dirname, environment: 'node', maxWorkers: 2,
  include: ['tests/*.test.ts'] } });
