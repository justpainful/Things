import type { CoreContext } from '../context.ts';
import { createEntity, deleteEntity, updateEntity } from '../mutate.ts';
import { uuidv7, nowIso } from '../ids.ts';
import { reindexThing, removeFromIndex } from '../search/indexer.ts';
import type { Thing } from '../types.ts';

export interface NewThing {
  title: string;
  iconJson?: string | null;
  isPinned?: boolean;
  isLocked?: boolean;
  isTemplate?: boolean;
  coverObject?: string | null;
}

export interface ThingPatch {
  title?: string;
  icon_json?: string | null;
  cover_object?: string | null;
  is_pinned?: boolean;
  is_locked?: boolean;
  is_archived?: boolean;
  is_template?: boolean;
}

export class ThingRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  get(id: string): Thing | undefined {
    return this.ctx.db.get<Thing>('SELECT * FROM thing WHERE id = ?', [id]);
  }

  list(opts: { limit?: number; offset?: number; includeArchived?: boolean } = {}): Thing[] {
    return this.ctx.db.all<Thing>(
      `SELECT * FROM thing
        WHERE deleted_at IS NULL AND is_template = 0
          ${opts.includeArchived ? '' : 'AND is_archived = 0'}
        ORDER BY is_pinned DESC, updated_at DESC
        LIMIT ? OFFSET ?`,
      [opts.limit ?? 200, opts.offset ?? 0],
    );
  }

  pinned(): Thing[] {
    return this.ctx.db.all<Thing>(
      'SELECT * FROM thing WHERE is_pinned = 1 AND deleted_at IS NULL AND is_template = 0 ORDER BY updated_at DESC',
    );
  }

  recents(limit = 20): Thing[] {
    return this.ctx.db.all<Thing>(
      `SELECT * FROM thing WHERE viewed_at IS NOT NULL AND deleted_at IS NULL AND is_template = 0
        ORDER BY viewed_at DESC LIMIT ?`,
      [limit],
    );
  }

  templates(): Thing[] {
    return this.ctx.db.all<Thing>(
      'SELECT * FROM thing WHERE is_template = 1 AND deleted_at IS NULL ORDER BY title COLLATE NOCASE',
    );
  }

  trash(): Thing[] {
    return this.ctx.db.all<Thing>('SELECT * FROM thing WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC');
  }

  create(input: NewThing): Thing {
    const id = uuidv7();
    return this.ctx.db.transaction(() => {
      createEntity(this.ctx, 'thing', id, {
        title: input.title,
        icon_json: input.iconJson ?? null,
        cover_object: input.coverObject ?? null,
        is_pinned: input.isPinned ? 1 : 0,
        is_locked: input.isLocked ? 1 : 0,
        is_archived: 0,
        is_template: input.isTemplate ? 1 : 0,
        viewed_at: null,
        deleted_at: null,
      });
      reindexThing(this.ctx.db, id, this.ctx.registry);
      return this.get(id) as Thing;
    });
  }

  update(id: string, patch: ThingPatch): Thing | undefined {
    return this.ctx.db.transaction(() => {
      const attrs: Record<string, string | number | null> = {};
      if (patch.title !== undefined) attrs.title = patch.title;
      if (patch.icon_json !== undefined) attrs.icon_json = patch.icon_json;
      if (patch.cover_object !== undefined) attrs.cover_object = patch.cover_object;
      if (patch.is_pinned !== undefined) attrs.is_pinned = patch.is_pinned ? 1 : 0;
      if (patch.is_locked !== undefined) attrs.is_locked = patch.is_locked ? 1 : 0;
      if (patch.is_archived !== undefined) attrs.is_archived = patch.is_archived ? 1 : 0;
      if (patch.is_template !== undefined) attrs.is_template = patch.is_template ? 1 : 0;
      updateEntity(this.ctx, 'thing', id, attrs);
      // Locking or unlocking changes what the Thing contributes to search.
      reindexThing(this.ctx.db, id, this.ctx.registry);
      return this.get(id);
    });
  }

  /** Recents is driven by viewed_at, which is local state and not worth an oplog entry. */
  touch(id: string): void {
    this.ctx.db.run('UPDATE thing SET viewed_at = ? WHERE id = ?', [nowIso(), id]);
  }

  /** Soft delete → Recently Deleted. */
  trashThing(id: string): void {
    this.ctx.db.transaction(() => {
      updateEntity(this.ctx, 'thing', id, { deleted_at: this.ctx.now() });
      removeFromIndex(this.ctx.db, id);
    });
  }

  restore(id: string): void {
    this.ctx.db.transaction(() => {
      updateEntity(this.ctx, 'thing', id, { deleted_at: null });
      reindexThing(this.ctx.db, id, this.ctx.registry);
    });
  }

  /** Permanent. The only destructive operation in the model. */
  purge(id: string): void {
    this.ctx.db.transaction(() => {
      for (const f of this.ctx.db.all<{ id: string }>('SELECT id FROM field WHERE thing_id = ?', [id])) {
        deleteEntity(this.ctx, 'field', f.id);
      }
      for (const s of this.ctx.db.all<{ id: string }>('SELECT id FROM section WHERE thing_id = ?', [id])) {
        deleteEntity(this.ctx, 'section', s.id);
      }
      deleteEntity(this.ctx, 'thing', id);
      removeFromIndex(this.ctx.db, id);
    });
  }

  /** Empty Trash for anything past the retention window. */
  purgeExpired(retentionDays: number): number {
    const cutoff = new Date(Date.now() - retentionDays * 86_400_000).toISOString();
    const ids = this.ctx.db.pluck<string>(
      'SELECT id FROM thing WHERE deleted_at IS NOT NULL AND deleted_at < ?',
      [cutoff],
    );
    for (const id of ids) this.purge(id);
    return ids.length;
  }

  /** Things referencing this one through a relation field — the backlink index. */
  referencedBy(id: string): Thing[] {
    return this.ctx.db.all<Thing>(
      `SELECT DISTINCT t.* FROM field f JOIN thing t ON t.id = f.thing_id
        WHERE f.kind = 'relation' AND f.value_text = ? AND t.deleted_at IS NULL`,
      [id],
    );
  }
}
