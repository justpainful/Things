import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { Db } from './db.ts';
import type { Keyring } from './crypto/keyring.ts';
import { open as openEnvelope, seal } from './crypto/envelope.ts';
import { decryptObject, decryptRange, encryptObject, newNoncePrefix } from './crypto/frames.ts';
import { nowIso } from './ids.ts';
import type { ObjectRow } from './types.ts';

/**
 * Content-addressed object store — docs/01-DATA-MODEL.md §3.
 *
 *   hash  = SHA-256 of the **plaintext** bytes, lowercase hex
 *   path  = objects/<hash[0:2]>/<hash[2:4]>/<hash>
 *   bytes = AES-256-GCM, per-object random key, 1 MiB frames
 *
 * Hashing plaintext rather than ciphertext is what preserves dedupe even
 * though every object gets a unique random key — "this file is already stored
 * in Things" becomes a primary-key hit. Reference counting is on the object
 * row, and the file only disappears when `gc()` is run explicitly.
 */

export const OBJECT_KEY_AAD = Buffer.from('things:object-key:v1', 'utf8');

export interface PutResult {
  hash: string;
  deduped: boolean;
  byteSize: number;
}

export interface PutMeta {
  mimeType?: string | null;
  width?: number | null;
  height?: number | null;
  durationMs?: number | null;
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(Buffer.from(bytes)).digest('hex');
}

export class ObjectStore {
  readonly root: string;
  private db: Db;
  private keyring: Keyring;

  constructor(root: string, db: Db, keyring: Keyring) {
    this.root = root;
    this.db = db;
    this.keyring = keyring;
  }

  pathFor(hash: string): string {
    return join(this.root, hash.slice(0, 2), hash.slice(2, 4), hash);
  }

  row(hash: string): ObjectRow | undefined {
    return this.db.get<ObjectRow>('SELECT * FROM object WHERE hash = ?', [hash]);
  }

  exists(hash: string): boolean {
    return !!this.row(hash) && existsSync(this.pathFor(hash));
  }

  /** Insert bytes. Deduplicates on the plaintext hash. */
  put(bytes: Uint8Array, meta: PutMeta = {}): PutResult {
    const hash = sha256Hex(bytes);
    const existing = this.row(hash);
    if (existing && existsSync(this.pathFor(hash))) {
      return { hash, deduped: true, byteSize: existing.byte_size };
    }

    const dek = this.keyring.requireDek();
    const objectKey = randomBytes(32);
    const noncePrefix = newNoncePrefix();
    const file = encryptObject(objectKey, bytes, noncePrefix);
    const wrapped = seal(dek, objectKey, OBJECT_KEY_AAD);
    objectKey.fill(0);

    const path = this.pathFor(hash);
    mkdirSync(join(this.root, hash.slice(0, 2), hash.slice(2, 4)), { recursive: true });
    writeFileSync(path, file);

    if (!existing) {
      this.db.run(
        `INSERT INTO object (hash, byte_size, mime_type, width, height, duration_ms,
                             enc_key_wrap, enc_nonce, ref_count, created_at)
         VALUES (?,?,?,?,?,?,?,?,0,?)`,
        [
          hash,
          bytes.length,
          meta.mimeType ?? null,
          meta.width ?? null,
          meta.height ?? null,
          meta.durationMs ?? null,
          wrapped,
          noncePrefix,
          nowIso(),
        ],
      );
    } else {
      this.db.run('UPDATE object SET enc_key_wrap = ?, enc_nonce = ? WHERE hash = ?', [
        wrapped,
        noncePrefix,
        hash,
      ]);
    }
    return { hash, deduped: false, byteSize: bytes.length };
  }

  private objectKey(row: ObjectRow): Buffer {
    const dek = this.keyring.requireDek();
    return openEnvelope(dek, row.enc_key_wrap, OBJECT_KEY_AAD);
  }

  read(hash: string): Buffer {
    const row = this.row(hash);
    if (!row) throw new Error(`unknown object ${hash}`);
    const path = this.pathFor(hash);
    if (!existsSync(path)) throw new Error(`object bytes missing for ${hash}`);
    const key = this.objectKey(row);
    try {
      return decryptObject(key, readFileSync(path));
    } finally {
      key.fill(0);
    }
  }

  /** Decrypt only [start, start+length) — this is why objects are framed. */
  readRange(hash: string, start: number, length: number): Buffer {
    const row = this.row(hash);
    if (!row) throw new Error(`unknown object ${hash}`);
    const key = this.objectKey(row);
    try {
      return decryptRange(key, readFileSync(this.pathFor(hash)), start, length);
    } finally {
      key.fill(0);
    }
  }

  retain(hash: string): void {
    this.db.run('UPDATE object SET ref_count = ref_count + 1 WHERE hash = ?', [hash]);
  }

  release(hash: string): void {
    this.db.run('UPDATE object SET ref_count = MAX(0, ref_count - 1) WHERE hash = ?', [hash]);
  }

  /** Recount references from the live field table — the authoritative answer. */
  recount(): void {
    this.db.run(
      `UPDATE object SET ref_count = (
         SELECT COUNT(*) FROM field f WHERE f.object_hash = object.hash
       ) + (
         SELECT COUNT(*) FROM thing t WHERE t.cover_object = object.hash
       )`,
    );
  }

  orphans(): ObjectRow[] {
    return this.db.all<ObjectRow>('SELECT * FROM object WHERE ref_count = 0');
  }

  /** Delete unreferenced objects. Never implicit — Trash retention runs first. */
  gc(): { removed: number; bytes: number } {
    this.recount();
    let removed = 0;
    let bytes = 0;
    for (const o of this.orphans()) {
      const path = this.pathFor(o.hash);
      try {
        if (existsSync(path)) {
          bytes += statSync(path).size;
          rmSync(path);
        }
      } catch {
        continue;
      }
      this.db.run('DELETE FROM object WHERE hash = ?', [o.hash]);
      removed++;
    }
    return { removed, bytes };
  }

  totalBytes(): number {
    const r = this.db.get<{ n: number }>('SELECT COALESCE(SUM(byte_size),0) AS n FROM object');
    return r?.n ?? 0;
  }
}
