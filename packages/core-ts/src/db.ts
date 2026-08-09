import { DatabaseSync } from 'node:sqlite';
import { readFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { specDir } from './paths.ts';

/**
 * Schema init + migrations.
 *
 * `spec/schema.sql` is NORMATIVE and is executed **verbatim** — it is never
 * transcribed into TypeScript, because a transcription is a second source of
 * truth and the whole point of the cross-open conformance test is that there
 * is exactly one.
 *
 * `meta.schema_version` records which migration the file is at. Migration 1 is
 * the base schema; later migrations append to MIGRATIONS and are applied in
 * order inside a transaction.
 */

export const SCHEMA_VERSION = 1;

export type SqlValue = string | number | bigint | null | Uint8Array;

export interface Migration {
  version: number;
  name: string;
  up: (db: Db) => void;
}

/** Migrations beyond the base schema. Append only; never edit a shipped entry. */
export const MIGRATIONS: Migration[] = [];

export class Db {
  readonly raw: DatabaseSync;
  readonly path: string;
  private txDepth = 0;

  constructor(path: string) {
    this.path = path;
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.raw = new DatabaseSync(path);
    this.raw.exec('PRAGMA foreign_keys = ON');
    if (path !== ':memory:') this.raw.exec('PRAGMA journal_mode = WAL');
  }

  exec(sql: string): void {
    this.raw.exec(sql);
  }

  run(sql: string, params: SqlValue[] = []): { changes: number; lastInsertRowid: number | bigint } {
    const r = this.raw.prepare(sql).run(...params);
    return { changes: Number(r.changes), lastInsertRowid: r.lastInsertRowid };
  }

  get<T = Record<string, unknown>>(sql: string, params: SqlValue[] = []): T | undefined {
    return this.raw.prepare(sql).get(...params) as T | undefined;
  }

  all<T = Record<string, unknown>>(sql: string, params: SqlValue[] = []): T[] {
    return this.raw.prepare(sql).all(...params) as T[];
  }

  pluck<T = string>(sql: string, params: SqlValue[] = [], column?: string): T[] {
    const rows = this.all<Record<string, unknown>>(sql, params);
    return rows.map((r) => {
      const key = column ?? Object.keys(r)[0];
      return r[key] as T;
    });
  }

  /**
   * Re-entrant transaction. Repositories compose freely — `duplicate()` calls
   * `things.create()` which opens its own — so nesting uses SAVEPOINTs rather
   * than failing with "cannot start a transaction within a transaction".
   */
  transaction<T>(fn: () => T): T {
    const depth = this.txDepth++;
    const name = `things_sp_${depth}`;
    this.raw.exec(depth === 0 ? 'BEGIN' : `SAVEPOINT ${name}`);
    try {
      const out = fn();
      this.raw.exec(depth === 0 ? 'COMMIT' : `RELEASE ${name}`);
      return out;
    } catch (e) {
      try {
        this.raw.exec(depth === 0 ? 'ROLLBACK' : `ROLLBACK TO ${name}; RELEASE ${name}`);
      } catch {
        /* already unwound */
      }
      throw e;
    } finally {
      this.txDepth = depth;
    }
  }

  close(): void {
    try {
      this.raw.close();
    } catch {
      /* already closed */
    }
  }

  // ── meta helpers ──────────────────────────────────────────────────────────

  meta(key: string): string | null {
    const row = this.get<{ value: string }>('SELECT value FROM meta WHERE key = ?', [key]);
    return row ? row.value : null;
  }

  setMeta(key: string, value: string): void {
    this.run('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [
      key,
      value,
    ]);
  }

  hasTable(name: string): boolean {
    return !!this.get(`SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name = ?`, [name]);
  }
}

/** Read the normative DDL. Never inline it; never edit it here. */
export function readSchemaSql(): string {
  return readFileSync(join(specDir(), 'schema.sql'), 'utf8');
}

export interface OpenOptions {
  /** Skip creating the schema — used when opening a database we know is ready. */
  skipInit?: boolean;
}

export function openDatabase(path: string, opts: OpenOptions = {}): Db {
  const db = new Db(path);
  if (!opts.skipInit) initSchema(db);
  return db;
}

export function initSchema(db: Db): void {
  const fresh = !db.hasTable('meta');
  if (fresh) {
    db.exec(readSchemaSql());
    db.setMeta('schema_version', String(SCHEMA_VERSION));
    return;
  }
  migrate(db);
}

export function currentVersion(db: Db): number {
  const v = db.meta('schema_version');
  return v ? parseInt(v, 10) : 0;
}

export function migrate(db: Db): number {
  let version = currentVersion(db);
  const pending = MIGRATIONS.filter((m) => m.version > version).sort((a, b) => a.version - b.version);
  for (const m of pending) {
    db.transaction(() => {
      m.up(db);
      db.setMeta('schema_version', String(m.version));
    });
    version = m.version;
  }
  if (version < SCHEMA_VERSION) {
    db.setMeta('schema_version', String(SCHEMA_VERSION));
    version = SCHEMA_VERSION;
  }
  return version;
}
