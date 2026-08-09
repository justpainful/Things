import type { CoreContext } from './context.ts';
import type { Attrs } from './oplog.ts';
import { decodeAttrs } from './oplog.ts';
import { compareVectors, mergeVectors, parseVector, stringifyVector } from './versionVector.ts';
import type { VersionVector } from './types.ts';
import type { Conflict, EntityType } from './types.ts';
import { compareHlc } from './hlc.ts';
import { uuidv7, nowIso } from './ids.ts';

/**
 * Conflict detection — docs/01-DATA-MODEL.md §5.
 *
 * The vision rejects last-write-wins, and correctly: a timestamp cannot tell
 * "later" from "concurrent". So each entity carries a version vector and the
 * decision is structural.
 *
 *   remote dominates local → apply remote
 *   local dominates remote → ignore remote
 *   equal                  → nothing to do
 *   neither                → genuine concurrency → record a conflict
 *
 * Because vectors live on **fields**, "phone edits Notes, PC edits Password"
 * is two different entities and never a conflict. Only a real same-field
 * collision surfaces *2 Versions*, and the higher-HLC value materialises
 * provisionally so the app stays usable while the choice is pending.
 */

export type ApplyOutcome = 'applied' | 'ignored' | 'conflict' | 'created';

export interface RemoteUpdate {
  entityType: EntityType;
  entityId: string;
  op: 'create' | 'update' | 'delete';
  attrs: Attrs;
  versionVector: VersionVector;
  hlc: string;
  deviceId: string;
}

export interface ApplyResult {
  outcome: ApplyOutcome;
  conflictId?: string;
}

/** The most recent HLC we hold locally for an entity. */
export function localHlc(ctx: CoreContext, entityId: string): string | null {
  const row = ctx.db.get<{ hlc: string }>(
    'SELECT hlc FROM change WHERE entity_id = ? ORDER BY hlc DESC LIMIT 1',
    [entityId],
  );
  return row?.hlc ?? null;
}

/** Which attributes the two sides actually disagree about. */
export function conflictingAttrs(local: Attrs, remote: Attrs): string[] {
  const out: string[] = [];
  for (const [k, v] of Object.entries(remote)) {
    if (k === 'updated_at' || k === 'version_vector') continue;
    const lv = local[k];
    if (lv instanceof Uint8Array && v instanceof Uint8Array) {
      if (!Buffer.from(lv).equals(Buffer.from(v))) out.push(k);
    } else if (lv !== v) {
      out.push(k);
    }
  }
  return out;
}

export function applyRemoteUpdate(ctx: CoreContext, update: RemoteUpdate): ApplyResult {
  const current = ctx.oplog.snapshot(update.entityType, update.entityId);

  // Nothing local: straightforward create.
  if (!current) {
    if (update.op === 'delete') return { outcome: 'ignored' };
    ctx.oplog.applyChange(
      {
        entityType: update.entityType,
        entityId: update.entityId,
        op: 'create',
        attrs: { ...update.attrs, version_vector: stringifyVector(update.versionVector) },
        prev: null,
      },
      { trackUndo: false },
    );
    return { outcome: 'created' };
  }

  const localVector = parseVector(current.version_vector as string);
  const relation = compareVectors(localVector, update.versionVector);

  if (relation === 'equal' || relation === 'dominates') return { outcome: 'ignored' };

  if (relation === 'dominated') {
    // Remote saw everything we have. Apply it.
    ctx.oplog.applyChange(
      {
        entityType: update.entityType,
        entityId: update.entityId,
        op: update.op === 'delete' ? 'delete' : 'update',
        attrs: update.op === 'delete' ? {} : { ...update.attrs, version_vector: stringifyVector(update.versionVector) },
        prev: current,
      },
      { trackUndo: false },
    );
    return { outcome: 'applied' };
  }

  // Genuinely concurrent.
  const disagreements = conflictingAttrs(current, update.attrs);
  if (disagreements.length === 0) {
    // Concurrent but identical content: merge the vectors and move on. This is
    // the common case for a reorder that both sides computed the same way.
    ctx.oplog.applyChange(
      {
        entityType: update.entityType,
        entityId: update.entityId,
        op: 'update',
        attrs: { version_vector: stringifyVector(mergeVectors(localVector, update.versionVector)) },
        prev: { version_vector: current.version_vector ?? null },
      },
      { trackUndo: false },
    );
    return { outcome: 'applied' };
  }

  const mine = localHlc(ctx, update.entityId);
  const remoteWins = mine === null || compareHlc(update.hlc, mine) > 0;

  const conflictId = uuidv7();
  ctx.db.run(
    `INSERT INTO conflict (id, entity_type, entity_id, version_a_json, version_b_json, detected_at)
     VALUES (?,?,?,?,?,?)`,
    [
      conflictId,
      update.entityType,
      update.entityId,
      JSON.stringify({
        source: 'local',
        deviceId: ctx.deviceId,
        hlc: mine,
        vector: localVector,
        attrs: pick(current, disagreements),
      }),
      JSON.stringify({
        source: 'remote',
        deviceId: update.deviceId,
        hlc: update.hlc,
        vector: update.versionVector,
        attrs: pick(update.attrs, disagreements),
      }),
      nowIso(),
    ],
  );

  // Materialise the higher-HLC value provisionally so the app stays usable.
  if (remoteWins) {
    ctx.oplog.applyChange(
      {
        entityType: update.entityType,
        entityId: update.entityId,
        op: 'update',
        attrs: {
          ...pick(update.attrs, disagreements),
          version_vector: stringifyVector(mergeVectors(localVector, update.versionVector)),
        },
        prev: pick(current, disagreements),
      },
      { trackUndo: false },
    );
  } else {
    ctx.oplog.applyChange(
      {
        entityType: update.entityType,
        entityId: update.entityId,
        op: 'update',
        attrs: { version_vector: stringifyVector(mergeVectors(localVector, update.versionVector)) },
        prev: { version_vector: current.version_vector ?? null },
      },
      { trackUndo: false },
    );
  }

  return { outcome: 'conflict', conflictId };
}

function pick(src: Attrs, keys: string[]): Attrs {
  const out: Attrs = {};
  for (const k of keys) out[k] = src[k] ?? null;
  return out;
}

export function openConflicts(ctx: CoreContext): Conflict[] {
  return ctx.db.all<Conflict>('SELECT * FROM conflict WHERE resolved_at IS NULL ORDER BY detected_at DESC');
}

export function resolveConflict(
  ctx: CoreContext,
  conflictId: string,
  resolution: 'a' | 'b' | 'both' | 'manual',
  manualAttrs?: Attrs,
): boolean {
  const c = ctx.db.get<Conflict>('SELECT * FROM conflict WHERE id = ?', [conflictId]);
  if (!c || c.resolved_at) return false;

  const a = JSON.parse(c.version_a_json) as { attrs: Record<string, unknown> };
  const b = JSON.parse(c.version_b_json) as { attrs: Record<string, unknown> };

  let attrs: Attrs | null = null;
  if (resolution === 'a') attrs = decodeAttrs(a.attrs);
  else if (resolution === 'b') attrs = decodeAttrs(b.attrs);
  else if (resolution === 'manual' && manualAttrs) attrs = manualAttrs;
  // 'both' keeps what is materialised and leaves the loser recorded in the log.

  if (attrs) {
    const current = ctx.oplog.snapshot(c.entity_type, c.entity_id);
    if (current) {
      ctx.oplog.applyChange({
        entityType: c.entity_type,
        entityId: c.entity_id,
        op: 'update',
        attrs,
        prev: pick(current, Object.keys(attrs)),
      });
    }
  }

  ctx.db.run('UPDATE conflict SET resolved_at = ?, resolution = ? WHERE id = ?', [
    nowIso(),
    resolution,
    conflictId,
  ]);
  return true;
}
