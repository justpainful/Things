import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { canonicalJson } from '../canonicalJson.ts';
import type { KeyringStore } from './keyring.ts';

/**
 * `vault.json` — the unencrypted sidecar that holds the wrapped DEK.
 * `spec/crypto.md` §3. NORMATIVE.
 *
 * The wrapped DEK cannot live in the `meta` table, and this is not a stylistic
 * preference: reading `meta` requires opening the database, opening the
 * database requires the DEK, and obtaining the DEK requires reading `meta`.
 * That circle is only invisible today because the Windows database is not yet
 * keyed with SQLCipher. It becomes a library that cannot be opened on the day
 * it is.
 *
 *     <library root>/
 *       things.sqlite   SQLCipher, keyed by the raw DEK
 *       vault.json      ← this file: salts, KDF parameters, wrapped DEKs
 *       objects/        TOBJ containers
 *
 * Publishing the salt and the wrapped DEK leaks nothing (§3.3): the salt was
 * never secret, `dek_wrap_pin` is AES-256-GCM behind a memory-hard KDF, and
 * `dek_wrap_device` derives from a secret that is not in the folder at all.
 *
 * Shape rules, all of which the two cores depend on:
 *   * a flat object, string keys to **string** values only;
 *   * unknown keys are PRESERVED on write — two cores and two app versions
 *     share this file, so it is always read-modify-write, never rebuilt from a
 *     struct;
 *   * keys are sorted so the file diffs cleanly (`core-swift` writes its
 *     canonical JSON here; this writes the same bytes);
 *   * written atomically, because a torn `vault.json` is a lost library.
 */

export const VAULT_FILENAME = 'vault.json';

export type VaultContents = Record<string, string>;

export class FileVault implements KeyringStore {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }

  exists(): boolean {
    return existsSync(this.path);
  }

  /** The whole file. Non-string values are ignored, matching `core-swift`. */
  read(): VaultContents {
    if (!existsSync(this.path)) return {};
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(this.path, 'utf8'));
    } catch {
      return {};
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out: VaultContents = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === 'string') out[k] = v;
    }
    return out;
  }

  get(key: string): string | null {
    const value = this.read()[key];
    return value === undefined ? null : value;
  }

  /** Read-modify-write the whole object. `null` deletes the key. */
  set(key: string, value: string | null): void {
    const contents = this.read();
    if (value === null) delete contents[key];
    else contents[key] = value;
    this.write(contents);
  }

  write(contents: VaultContents): void {
    mkdirSync(dirname(this.path), { recursive: true });
    // No trailing newline: `core-swift`'s FileVaultStorage writes
    // `canonicalJSON` and nothing else, and this file is one both cores
    // rewrite. Byte-identical output means a `vault.json` touched by the phone
    // and then by the PC produces no spurious diff.
    const body = canonicalJson(contents);
    const temp = `${this.path}.tmp`;
    writeFileSync(temp, body, { encoding: 'utf8', mode: 0o600 });
    try {
      renameSync(temp, this.path);
    } catch (e) {
      try {
        unlinkSync(temp);
      } catch {
        /* nothing to clean up */
      }
      throw e;
    }
  }
}

/** In-memory vault — tests, and any caller that does not want a file. */
export class MemoryVault implements KeyringStore {
  private contents: VaultContents = {};

  read(): VaultContents {
    return { ...this.contents };
  }

  get(key: string): string | null {
    const value = this.contents[key];
    return value === undefined ? null : value;
  }

  set(key: string, value: string | null): void {
    if (value === null) delete this.contents[key];
    else this.contents[key] = value;
  }
}

/**
 * The keys `core-swift`'s `Vault.mirrorIntoDatabase` copies into `meta` once the
 * library is open. The mirror exists for a future self-describing backup
 * container; it is NEVER read to unlock, and the two cores mirror the same set
 * so a database written by one does not look half-populated to the other.
 */
export const MIRRORED_KEYS = ['kdf_salt', 'kdf_params', 'dek_wrap_pin', 'dek_wrap_device'] as const;

/**
 * Writes through to the sidecar and, for the mirrored subset, also to `meta`.
 * Reads come from the sidecar only — that is what "never the source of truth"
 * means in practice.
 */
export class MirroredVault implements KeyringStore {
  constructor(
    private readonly primary: KeyringStore,
    private readonly mirror: KeyringStore,
  ) {}

  get(key: string): string | null {
    return this.primary.get(key);
  }

  set(key: string, value: string | null): void {
    this.primary.set(key, value);
    if ((MIRRORED_KEYS as readonly string[]).includes(key)) {
      try {
        this.mirror.set(key, value);
      } catch {
        // The mirror is a convenience. A library that cannot write it still
        // unlocks; a library that cannot write the sidecar does not, which is
        // why only this half is swallowed.
      }
    }
  }
}

export interface VaultMigration {
  migrated: boolean;
  keys: string[];
}

/** Everything that has ever been key material, in the order the file lists it. */
const VAULT_KEYS = [
  'kdf_salt',
  'kdf_params',
  'dek_wrap_pin',
  'dek_wrap_device',
  'dek_check',
  'failed_pin_attempts',
] as const;

/**
 * One-way migration for a library created by the code that kept key material in
 * `meta`. Runs before the keyring is constructed, and only when the sidecar has
 * no PIN wrapper of its own, so it can never overwrite a good `vault.json`.
 *
 * The `meta` rows are deliberately left in place: `spec/crypto.md` §3.1 allows
 * them as a mirror, and deleting them would strand a developer who rolls the
 * build back before opening the library again.
 */
export function migrateVaultFromMeta(meta: KeyringStore, vault: KeyringStore): VaultMigration {
  if (vault.get('dek_wrap_pin')) return { migrated: false, keys: [] };
  if (!meta.get('dek_wrap_pin')) return { migrated: false, keys: [] };

  const keys: string[] = [];
  for (const key of VAULT_KEYS) {
    const value = meta.get(key);
    // The old code wrote '' for "device wrapping failed". The sidecar spells
    // that as an absent key, which is a normal state and not an error.
    if (value === null || value === '') continue;
    vault.set(key, value);
    keys.push(key);
  }
  return { migrated: keys.length > 0, keys };
}

export function vaultPathFor(dataDir: string): string {
  return join(dataDir, VAULT_FILENAME);
}
