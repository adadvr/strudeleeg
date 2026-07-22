import { build } from 'esbuild';
import { readFileSync } from 'fs';

// Read the @strudel/web entry point and its dist
const result = await build({
  entryPoints: ['entry.mjs'],
  bundle: true,
  format: 'iife',
  globalName: '__strudelExports',
  platform: 'browser',
  target: ['safari16'],    // macOS 14 uses Safari 16+ WebKit
  outfile: '../Sources/DemoStrudelApp/StrudelWeb/strudel-bundle.js',
  minify: false,           // keep readable for debugging
  sourcemap: false,
  // Some packages use dynamic imports that esbuild can't handle statically;
  // the AudioWorklet blob inline in superdough is already a data URI so it works
  define: {
    'process.env.NODE_ENV': '"production"',
  },
  logLevel: 'info',
});

console.log('Build done:', result);
