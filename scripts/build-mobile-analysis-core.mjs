import { build } from 'vite';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
await build({ configFile: false, root, build: {
  target: 'es2020', outDir: 'ios/DailyCore/Resources', emptyOutDir: false,
  minify: false,
  lib: { entry: 'src/shared/mobile-analysis-core.ts', name: 'DailyXAnalysis',
    formats: ['iife'], fileName: () => 'dailyx-analysis.js' },
} });
