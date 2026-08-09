import { defineConfig } from 'vite';

/**
 * No framework plugin, no PostCSS pipeline, no CSS library.
 * The only build step is bundling hand-written TypeScript and CSS.
 *
 * `assetsInlineLimit: 0` keeps every asset a real file so the server's strict
 * CSP (`img-src 'self' data:`) never has to be widened for a bundler quirk.
 */
export default defineConfig({
  root: '.',
  base: '/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2022',
    cssCodeSplit: false,
    sourcemap: false,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: true,
    proxy: { '/api': 'http://127.0.0.1:6767' },
  },
});
