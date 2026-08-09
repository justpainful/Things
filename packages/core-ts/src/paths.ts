import { dirname, join, resolve } from 'node:path';
import { existsSync } from 'node:fs';

/**
 * Locate `spec/` — the normative directory. Walk up from this file until a
 * directory containing both `schema.sql` and `field-kinds.json` appears.
 * Overridable with THINGS_SPEC_DIR so a packaged build can relocate it.
 */
export function specDir(): string {
  const override = process.env.THINGS_SPEC_DIR;
  if (override) return resolve(override);

  let dir = import.meta.dirname;
  for (let i = 0; i < 8; i++) {
    const candidate = join(dir, 'spec');
    if (existsSync(join(candidate, 'schema.sql')) && existsSync(join(candidate, 'field-kinds.json'))) {
      return candidate;
    }
    const up = dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  throw new Error(
    'Could not locate spec/ (needs schema.sql + field-kinds.json). Set THINGS_SPEC_DIR.',
  );
}

export function repoRoot(): string {
  return dirname(specDir());
}
