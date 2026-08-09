/**
 * `npm run dev` in apps/server.
 *
 * Builds the web client, keeps a Vite watcher running so edits rebuild into
 * apps/web/dist, and then starts the service. One command, a usable app at
 * http://localhost:6767.
 *
 * Windows detail worth knowing: `npm` is a `.cmd` shim, and Node refuses to
 * spawn `.cmd` without `shell: true` (the fix for CVE-2024-27980). But
 * `shell: true` also re-parses the command string, which mangles
 * `C:\Program Files\nodejs\node.exe` at the first space. So the shell is used
 * for npm and *only* for npm; the server itself is spawned directly.
 */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..', '..');
const webDir = join(repoRoot, 'apps', 'web');
const distIndex = join(webDir, 'dist', 'index.html');
const isWindows = process.platform === 'win32';
const npm = isWindows ? 'npm.cmd' : 'npm';

const children = [];

function runNpm(args, opts = {}) {
  const child = spawn(npm, args, { stdio: 'inherit', shell: isWindows, ...opts });
  children.push(child);
  return child;
}

function runNode(args, opts = {}) {
  const child = spawn(process.execPath, args, { stdio: 'inherit', shell: false, ...opts });
  children.push(child);
  return child;
}

function shutdown(code = 0) {
  for (const child of children) {
    try {
      child.kill();
    } catch {
      /* already gone */
    }
  }
  process.exit(code);
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => shutdown(0));

if (!existsSync(distIndex)) {
  console.log('[things] building the web client…');
  await new Promise((done, fail) => {
    const build = runNpm(['run', 'build'], { cwd: webDir });
    build.on('exit', (code) => (code === 0 ? done() : fail(new Error(`vite build exited ${code}`))));
    build.on('error', fail);
  });
}

console.log('[things] watching the web client for changes…');
runNpm(['run', 'watch'], { cwd: webDir });

const server = runNode([join(here, '..', 'src', 'index.ts')], { cwd: repoRoot });
server.on('exit', (code) => shutdown(code ?? 0));
