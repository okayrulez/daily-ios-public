import { defineConfig } from 'vitest/config';
export default defineConfig({test:{root:import.meta.dirname,environment:'node',maxWorkers:1,
  include:['tests/firebase/*.test.ts'],testTimeout:30000,hookTimeout:30000}});
