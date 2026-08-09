import type { Db, SqlValue } from './db.ts';
import { canonicalJson } from './canonicalJson.ts';
import { uuidv7, nowIso } from './ids.ts';
import type { Hlc } from './hlc.ts';
import type { Change, EntityType, Op } from './types.ts';

/**
 * The oplog — docs/01-DATA-MODEL.md §5.
 *
 * One table, four features. History, Restore, Undo/Redo and sync are the same
 * mechanism seen from four angles, which is why none of them can drift out of
 * agreement with the others.
 *
 * `attrs_json` holds ONLY the attributes that changed; `prev_json` holds their
 * prior values. That pair is what makes an inverse cheap enough to be the
 * implementation of both Undo and Restore.
 *
 * Secret values inside attrs/prev are ciphertext envelopes, base64-encoded —
 * never plaintext. Otherwise History becomes a plaintext log of every password
 * you ever changed, which docs/02-SECURITY.md §5 calls out by name.
 */

export type Attrs = Record<string, SqlValue>;

export interface ChangeInput {
  entityType: EntityType;
  entityId: string;
  op: Op;
  attrs: Attrs;
  prev?: Attrs | null;
}

export interface HistoryDay {
  date: string; // YYYY-MM-DD
  changes: Change[];
}

const TABLE_FOR: Record<EntityType, string> = {
  thing: 'thing',
  section: 'section',
  field: 'field',
  collection: 'collection',
  member: 'collection_member',
  tag: 'tag',
  thing_tag: 'thing_tag',
  file_ref: 'file_ref',
};

/** Composite-key entities encode their key as `a:b`. UUIDs never contain a colon, so the split is unambiguous. */
const COMPOSITE_KEYS: Partial<Record<EntityType, [string, string]>> = {
  member: ['collection_id', 'thing_id'],
  thing_tag: ['thing_id', 'tag_id'],
};

export const COMPOSITE_SEP = ':';

export function compositeId(a: string, b: string): string {
  return `${a}${COMPOSITE_SEP}${b}`;
}

export class Oplog {
  readonly db: Db;
  readonly deviceId: string;
  readonly hlc: Hlc;

  private undoStack: string[] = [];
  private redoStack: string[] = [];
  private columnCache = new Map<string, string[]>();

  constructor(db: Db, deviceId: string, hlc: Hlc) {
    this.db = db;
    this.deviceId = deviceId;
    this.hlc = hlc;
  }

  // ── append ────────────────────────────────────────────────────────────────

  /**
   * Record a mutation. Repos call this AFTER writing the materialised row, in
   * the same transaction.
   */
  append(input: ChangeInput, opts: { trackUndo?: boolean } = {}): Change {
    const change: Change = {
      id: uuidv7(),
      device_id: this.deviceId,
      hlc: this.hlc.now(),
      entity_type: input.entityType,
      entity_id: input.entityId,
      op: input.op,
      // Canonical JSON, NOT JSON.stringify — `spec/oplog.md` §2. A `change` row
      // crosses the wire verbatim, so its bytes are wire format: insertion
      // order would make the two cores emit different bytes for the same
      // change, and every byte-level use (hashing a row, signing a batch,
      // dedupe by content) would then disagree.
      attrs_json: canonicalJson(encodeAttrs(input.attrs)),
      prev_json: input.prev ? canonicalJson(encodeAttrs(input.prev)) : null,
      applied_at: nowIso(),
    };
    this.db.run(
      `INSERT INTO change (id, device_id, hlc, entity_type, entity_id, op, attrs_json, prev_json, applied_at)
       VALUES (?,?,?,?,?,?,?,?,?)`,
      [
        change.id,
        change.device_id,
        change.hlc,
        change.entity_type,
        change.entity_id,
        change.op,
        change.attrs_json,
        change.prev_json,
        change.applied_at,
      ],
    );
    this.db.setMeta('hlc_last', change.hlc);
    if (opts.trackUndo !== false) {
      this.undoStack.push(change.id);
      if (this.undoStack.length > 200) this.undoStack.shift();
      this.redoStack.length = 0;
    }
    return change;
  }

  // ── read ──────────────────────────────────────────────────────────────────

  get(changeId: string): Change | undefined {
    return this.db.get<Change>('SELECT * FROM change WHERE id = ?', [changeId]);
  }

  entityHistory(entityId: string, limit = 500): Change[] {
    return this.db.all<Change>('SELECT * FROM change WHERE entity_id = ? ORDER BY hlc DESC LIMIT ?', [
      entityId,
      limit,
    ]);
  }

  /**
   * History for a Thing: the Thing row plus every entity that belongs to it.
   * Renders as "Today · Changed password".
   */
  thingHistory(thingId: string, limit = 500): Change[] {
    return this.db.all<Change>(
      `SELECT * FROM change
        WHERE entity_id = ?
           OR entity_id IN (SELECT id FROM field   WHERE thing_id = ?)
           OR entity_id IN (SELECT id FROM section WHERE thing_id = ?)
        ORDER BY hlc DESC
        LIMIT ?`,
      [thingId, thingId, thingId, limit],
    );
  }

  /** Grouped by day, newest first — the shape the History screen renders. */
  groupByDay(changes: Change[]): HistoryDay[] {
    const days = new Map<string, Change[]>();
    for (const c of changes) {
      const day = c.applied_at.slice(0, 10);
      const list = days.get(day) ?? [];
      list.push(c);
      days.set(day, list);
    }
    return [...days.entries()]
      .sort((a, b) => (a[0] < b[0] ? 1 : -1))
      .map(([date, list]) => ({ date, changes: list }));
  }

  /** Everything after an HLC — the sync read path. */
  since(hlc: string, limit = 5000): Change[] {
    return this.db.all<Change>('SELECT * FROM change WHERE hlc > ? ORDER BY hlc ASC LIMIT ?', [hlc, limit]);
  }

  // ── apply / invert ────────────────────────────────────────────────────────

  /** Write a change's attributes into the materialised table, then record it. */
  applyChange(input: ChangeInput, opts: { trackUndo?: boolean } = {}): Change {
    this.materialise(input);
    return this.append(input, opts);
  }

  /**
   * The inverse of a change.
   *   create → delete
   *   delete → create from prev
   *   update → update back to prev
   */
  invert(c: Change): ChangeInput {
    const attrs = decodeAttrs(JSON.parse(c.attrs_json) as Record<string, unknown>);
    const prev = c.prev_json ? decodeAttrs(JSON.parse(c.prev_json) as Record<string, unknown>) : {};
    if (c.op === 'create') {
      return { entityType: c.entity_type, entityId: c.entity_id, op: 'delete', attrs: {}, prev: attrs };
    }
    if (c.op === 'delete') {
      return { entityType: c.entity_type, entityId: c.entity_id, op: 'create', attrs: prev, prev: null };
    }
    const back: Attrs = {};
    for (const k of Object.keys(attrs)) back[k] = k in prev ? prev[k] : null;
    return { entityType: c.entity_type, entityId: c.entity_id, op: 'update', attrs: back, prev: attrs };
  }

  // ── undo / redo ───────────────────────────────────────────────────────────

  canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  undo(): Change | null {
    const id = this.undoStack.pop();
    if (!id) return null;
    const c = this.get(id);
    if (!c) return this.undo();
    const applied = this.applyChange(this.invert(c), { trackUndo: false });
    this.redoStack.push(applied.id);
    return applied;
  }

  redo(): Change | null {
    const id = this.redoStack.pop();
    if (!id) return null;
    const c = this.get(id);
    if (!c) return this.redo();
    const applied = this.applyChange(this.invert(c), { trackUndo: false });
    this.undoStack.push(applied.id);
    return applied;
  }

  clearUndoHistory(): void {
    this.undoStack.length = 0;
    this.redoStack.length = 0;
  }

  // ── restore ───────────────────────────────────────────────────────────────

  /**
   * Restore an entity to the state it had *before* (`'before'`, the default —
   * the "put it back how it was" button next to a history entry) or *after*
   * (`'after'`) a given change.
   *
   * Restoring is itself history: it appends a new change rather than rewriting
   * the log. Never destructive.
   */
  restore(changeId: string, mode: 'before' | 'after' = 'before'): Change | null {
    const c = this.get(changeId);
    if (!c) return null;
    const input = mode === 'before' ? this.invert(c) : {
      entityType: c.entity_type,
      entityId: c.entity_id,
      op: 'update' as Op,
      attrs: decodeAttrs(JSON.parse(c.attrs_json) as Record<string, unknown>),
      prev: this.snapshot(c.entity_type, c.entity_id),
    };
    return this.applyChange(input);
  }

  /** Current column values for an entity — the `prev` half of a change. */
  snapshot(entityType: EntityType, entityId: string): Attrs | null {
    const table = TABLE_FOR[entityType];
    const composite = COMPOSITE_KEYS[entityType];
    let row: Record<string, SqlValue> | undefined;
    if (composite) {
      const [a, b] = entityId.split(COMPOSITE_SEP);
      row = this.db.get(`SELECT * FROM ${table} WHERE ${composite[0]} = ? AND ${composite[1]} = ?`, [a, b]);
    } else {
      row = this.db.get(`SELECT * FROM ${table} WHERE id = ?`, [entityId]);
    }
    return row ? (row as Attrs) : null;
  }

  // ── the fold ──────────────────────────────────────────────────────────────

  private columns(table: string): string[] {
    let cols = this.columnCache.get(table);
    if (!cols) {
      cols = this.db.all<{ name: string }>(`PRAGMA table_info(${table})`).map((r) => r.name);
      this.columnCache.set(table, cols);
    }
    return cols;
  }

  /** Write the change into the materialised table. Column names come from the
   *  live schema, never from a hand-maintained list. */
  private materialise(input: ChangeInput): void {
    const table = TABLE_FOR[input.entityType];
    const composite = COMPOSITE_KEYS[input.entityType];
    const cols = this.columns(table);

    if (input.op === 'delete') {
      if (composite) {
        const [a, b] = input.entityId.split(COMPOSITE_SEP);
        this.db.run(`DELETE FROM ${table} WHERE ${composite[0]} = ? AND ${composite[1]} = ?`, [a, b]);
      } else {
        this.db.run(`DELETE FROM ${table} WHERE id = ?`, [input.entityId]);
      }
      return;
    }

    const attrs: Attrs = { ...input.attrs };
    if (composite) {
      const [a, b] = input.entityId.split(COMPOSITE_SEP);
      attrs[composite[0]] = a;
      attrs[composite[1]] = b;
    } else if (cols.includes('id')) {
      attrs.id = input.entityId;
    }

    const usable = Object.keys(attrs).filter((k) => cols.includes(k));
    if (usable.length === 0) return;

    if (input.op === 'create') {
      const placeholders = usable.map(() => '?').join(',');
      this.db.run(
        `INSERT OR REPLACE INTO ${table} (${usable.map(quoteIdent).join(',')}) VALUES (${placeholders})`,
        usable.map((k) => attrs[k]),
      );
      return;
    }

    const setCols = usable.filter((k) => (composite ? !composite.includes(k) : k !== 'id'));
    if (setCols.length === 0) return;
    const assignments = setCols.map((k) => `${quoteIdent(k)} = ?`).join(', ');
    const params = setCols.map((k) => attrs[k]);
    if (composite) {
      const [a, b] = input.entityId.split(COMPOSITE_SEP);
      this.db.run(
        `UPDATE ${table} SET ${assignments} WHERE ${composite[0]} = ? AND ${composite[1]} = ?`,
        [...params, a, b],
      );
    } else {
      this.db.run(`UPDATE ${table} SET ${assignments} WHERE id = ?`, [...params, input.entityId]);
    }
  }
}

function quoteIdent(name: string): string {
  return `"${name.replace(/"/g, '""')}"`;
}

/** Blobs (secret envelopes, wrapped object keys) travel as base64 in the log. */
export function encodeAttrs(attrs: Attrs): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(attrs)) {
    if (v instanceof Uint8Array) out[k] = { $b64: Buffer.from(v).toString('base64') };
    else if (typeof v === 'bigint') out[k] = Number(v);
    else out[k] = v;
  }
  return out;
}

export function decodeAttrs(raw: Record<string, unknown>): Attrs {
  const out: Attrs = {};
  for (const [k, v] of Object.entries(raw)) {
    if (v && typeof v === 'object' && '$b64' in (v as Record<string, unknown>)) {
      out[k] = Buffer.from(String((v as Record<string, unknown>).$b64), 'base64');
    } else if (v === undefined) {
      out[k] = null;
    } else {
      out[k] = v as SqlValue;
    }
  }
  return out;
}
