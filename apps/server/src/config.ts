import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export interface ServerConfig {
  dataDir: string;
  webRoot: string;
  autoLockMs: number;
  trashRetentionDays: number;
}

/** Repo root, found by walking up from this file until package.json + spec/ appear. */
export function repoRoot(): string {
  let dir = fileURLToPath(new URL('.', import.meta.url));
  for (let i = 0; i < 8; i++) {
    if (existsSync(join(dir, 'spec', 'schema.sql')) && existsSync(join(dir, 'package.json'))) return dir;
    dir = resolve(dir, '..');
  }
  return process.cwd();
}

export function loadConfig(): ServerConfig {
  return {
    // Never inside the repo: docs/02-SECURITY.md §8 and .gitignore both assume
    // real data lives outside the working tree.
    dataDir: process.env.THINGS_DATA_DIR
      ? resolve(process.env.THINGS_DATA_DIR)
      : join(homedir(), 'ThingsData'),
    webRoot: process.env.THINGS_WEB_ROOT
      ? resolve(process.env.THINGS_WEB_ROOT)
      : join(repoRoot(), 'apps', 'web', 'dist'),
    autoLockMs: Number(process.env.THINGS_AUTOLOCK_MS ?? 15 * 60 * 1000),
    trashRetentionDays: Number(process.env.THINGS_TRASH_DAYS ?? 30),
  };
}
