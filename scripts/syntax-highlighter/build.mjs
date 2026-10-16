import { build } from 'esbuild';
import { copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const base = new URL('.', import.meta.url);
await build({
  entryPoints: [fileURLToPath(new URL('entry.js', base))],
  bundle: true, minify: true, format: 'iife', target: 'es2020',
  outfile: fileURLToPath(new URL('../../Sources/HerdrOrb/Resources/syntax-highlighter.js', base)),
  banner: { js: '/*! highlight.js 11.11.1 | MIT | See HighlightJS-LICENSE.txt */' },
});
await copyFile(new URL('node_modules/highlight.js/LICENSE', base), new URL('../../Sources/HerdrOrb/Resources/HighlightJS-LICENSE.txt', base));
