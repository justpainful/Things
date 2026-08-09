import type { CoreContext } from './context.ts';
import type { Attrs } from './oplog.ts';
import type { Change, EntityType } from './types.ts';
import { incrementVector, parseVector, stringifyVector } from './versionVector.ts';

/**
 * The single write path.
 *
 * Every mutation in the system goes through these three functions, which is
 * what guarantees the four invariants that would otherwise be forgotten in one
 * repository out of seven:
 *
 *   1. a `change` row is appended for every write;
 *   2. `prev_json` carries the real prior values, so Undo and Restore work;
 *   3. `updated_at` is refreshed;
 *   4. the entity's **version vector is incremented for this device**, which is
 *      what later makes concurrent-edit detection possible at all.
 */

function hasColumn(ctx: CoreContext, table: string, column: string): boolean {
  return ctx.db.all<{ name: string }>(`PRAGMA table_info(${table})`).some((c) => c.name === column);
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

export function createEntity(
  ctx: CoreContext,
  entityType: EntityType,
  entityId: string,
  attrs: Attrs,
): Change {
  const table = TABLE_FOR[entityType];
  const full: Attrs = { ...attrs };
  const now = ctx.now();
  if (hasColumn(ctx, table, 'created_at') && full.created_at == null) full.created_at = now;
  if (hasColumn(ctx, table, 'updated_at')) full.updated_at = now;
  if (hasColumn(ctx, table, 'version_vector')) {
    full.version_vector = stringifyVector(incrementVector({}, ctx.deviceId));
  }
  return ctx.oplog.applyChange({ entityType, entityId, op: 'create', attrs: full, prev: null });
}

/**
 * Apply a patch. Returns null when nothing actually changed — a no-op write
 * would otherwise pollute History with empty entries and manufacture sync
 * traffic out of nothing.
 */
export function updateEntity(
  ctx: CoreContext,
  entityType: EntityType,
  entityId: string,
  patch: Attrs,
): Change | null {
  const table = TABLE_FOR[entityType];
  const current = ctx.oplog.snapshot(entityType, entityId);
  if (!current) return null;

  const attrs: Attrs = {};
  const prev: Attrs = {};
  for (const [k, v] of Object.entries(patch)) {
    if (sameValue(current[k], v)) continue;
    attrs[k] = v;
    prev[k] = current[k] ?? null;
  }
  if (Object.keys(attrs).length === 0) return null;

  if (hasColumn(ctx, table, 'updated_at')) {
    attrs.updated_at = ctx.now();
    prev.updated_at = current.updated_at ?? null;
  }
  if (hasColumn(ctx, table, 'version_vector')) {
    const vv = incrementVector(parseVector(current.version_vector as string), ctx.deviceId);
    attrs.version_vector = stringifyVector(vv);
    prev.version_vector = current.version_vector ?? null;
  }
  return ctx.oplog.applyChange({ entityType, entityId, op: 'update', attrs, prev });
}

export function deleteEntity(ctx: CoreContext, entityType: EntityType, entityId: string): Change | null {
  const current = ctx.oplog.snapshot(entityType, entityId);
  if (!current) return null;
  return ctx.oplog.applyChange({ entityType, entityId, op: 'delete', attrs: {}, prev: current });
}

function sameValue(a: unknown, b: unknown): boolean {
  if (a instanceof Uint8Array && b instanceof Uint8Array) {
    return Buffer.from(a).equals(Buffer.from(b));
  }
  if (a === null && b === undefined) return true;
  if (a === undefined && b === null) return true;
  return a === b;
}
