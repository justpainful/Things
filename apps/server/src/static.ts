import { createReadStream, existsSync, statSync } from 'node:fs';
import { join, normalize, extname, sep } from 'node:path';
import type { ServerResponse } from 'node:http';

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
  '.map': 'application/json',
};

/**
 * A strict Content-Security-Policy. The app makes no external requests by
 * design (docs/02-SECURITY.md §7: "No outbound connections, ever"), so the
 * policy can simply say so — there is no CDN, no font host, no analytics.
 * `connect-src 'self'` means a compromised page still cannot exfiltrate.
 */
const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "media-src 'self' blob:",
  "font-src 'self'",
  "connect-src 'self'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "object-src 'none'",
].join('; ');

export function serveStatic(root: string, urlPath: string, res: ServerResponse): boolean {
  if (!existsSync(root)) return false;

  // Resolve inside root, then verify: normalize() alone is not a containment check.
  const rel = normalize(decodeURIComponent(urlPath)).replace(/^([/\\])+/, '');
  let file = join(root, rel);
  if (!file.startsWith(root + sep) && file !== root) return false;

  if (!existsSync(file) || statSync(file).isDirectory()) {
    // Single-page app: unknown paths fall back to index.html.
    file = join(root, 'index.html');
    if (!existsSync(file)) return false;
  }

  const type = TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream';
  const isHtml = type.startsWith('text/html');
  res.writeHead(200, {
    'content-type': type,
    'content-length': String(statSync(file).size),
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'content-security-policy': CSP,
    // The library is local and private; never let an intermediary hold it.
    'cache-control': isHtml ? 'no-store' : 'private, max-age=0, must-revalidate',
  });
  createReadStream(file).pipe(res);
  return true;
}

export function missingBuildPage(): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Things — web client not built</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 15px/1.6 system-ui, sans-serif; margin: 0; display: grid; place-items: center; min-block-size: 100dvh; }
  main { max-inline-size: 46ch; padding-inline: 2rem; }
  h1 { font-size: 1.3rem; margin-block-end: .5rem; }
  code { background: rgba(128,128,128,.18); padding: .15em .4em; border-radius: 4px; }
</style></head><body><main>
<h1>The web client has not been built yet.</h1>
<p>Run <code>npm run build</code> from the repository root, or start the server with
<code>npm run dev</code>, which builds the client and watches it for changes.</p>
</main></body></html>`;
}
