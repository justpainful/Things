import type { CoreContext } from '../context.ts';
import { createEntity, deleteEntity, updateEntity } from '../mutate.ts';
import { compositeId } from '../oplog.ts';
import { uuidv7, nowIso } from '../ids.ts';
import { orderAtEnd, orderForIndex } from '../sortOrder.ts';
import { reindexThing } from '../search/indexer.ts';
import type { Collection, Tag, Thing } from '../types.ts';

/**
 * Collections are many-to-many, which is what lets Cloudflare live in both
 * `Development` and `1980` with one copy of the data.
 *
 * A Saved Search is not a separate concept: it is a collection with
 * `is_smart = 1` and a `smart_query` in the search DSL. Smart Views ship as
 * seeded smart collections so the user can edit them and build their own.
 */

export class CollectionRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  get(id: string): Collection | undefined {
    return this.ctx.db.get<Collection>('SELECT * FROM collection WHERE id = ?', [id]);
  }

  byName(name: string): Collection | undefined {
    return this.ctx.db.get<Collection>('SELECT * FROM collection WHERE name = ? COLLATE NOCASE', [name]);
  }

  list(): Collection[] {
    return this.ctx.db.all<Collection>('SELECT * FROM collection ORDER BY sort_order, name COLLATE NOCASE');
  }

  smart(): Collection[] {
    return this.ctx.db.all<Collection>('SELECT * FROM collection WHERE is_smart = 1 ORDER BY sort_order');
  }

  manual(): Collection[] {
    return this.ctx.db.all<Collection>(
      'SELECT * FROM collection WHERE is_smart = 0 ORDER BY sort_order, name COLLATE NOCASE',
    );
  }

  create(input: {
    name: string;
    iconJson?: string | null;
    parentId?: string | null;
    isSmart?: boolean;
    isSystem?: boolean;
    smartQuery?: string | null;
    atIndex?: number;
  }): Collection {
    const id = uuidv7();
    const orders = this.ctx.db.pluck<number>('SELECT sort_order FROM collection');
    const sort = input.atIndex === undefined ? orderAtEnd(orders) : orderForIndex(orders, input.atIndex);
    createEntity(this.ctx, 'collection', id, {
      name: input.name,
      icon_json: input.iconJson ?? null,
      sort_order: sort,
      parent_id: input.parentId ?? null,
      is_smart: input.isSmart ? 1 : 0,
      is_system: input.isSystem ? 1 : 0,
      smart_query: input.isSmart ? input.smartQuery ?? '' : input.smartQuery ?? null,
    });
    return this.get(id) as Collection;
  }

  update(id: string, patch: Partial<Pick<Collection, 'name' | 'icon_json' | 'smart_query' | 'parent_id'>>): Collection | undefined {
    updateEntity(this.ctx, 'collection', id, patch as Record<string, string | number | null>);
    return this.get(id);
  }

  move(id: string, toIndex: number): void {
    const others = this.ctx.db.pluck<number>('SELECT sort_order FROM collection WHERE id != ?', [id]);
    updateEntity(this.ctx, 'collection', id, { sort_order: orderForIndex(others, toIndex) });
  }

  remove(id: string): void {
    this.ctx.db.transaction(() => {
      for (const m of this.ctx.db.all<{ thing_id: string }>(
        'SELECT thing_id FROM collection_member WHERE collection_id = ?',
        [id],
      )) {
        deleteEntity(this.ctx, 'member', compositeId(id, m.thing_id));
        reindexThing(this.ctx.db, m.thing_id, this.ctx.registry);
      }
      deleteEntity(this.ctx, 'collection', id);
    });
  }

  members(id: string): Thing[] {
    return this.ctx.db.all<Thing>(
      `SELECT t.* FROM collection_member cm JOIN thing t ON t.id = cm.thing_id
        WHERE cm.collection_id = ? AND t.deleted_at IS NULL
        ORDER BY cm.sort_order`,
      [id],
    );
  }

  collectionsOf(thingId: string): Collection[] {
    return this.ctx.db.all<Collection>(
      `SELECT c.* FROM collection_member cm JOIN collection c ON c.id = cm.collection_id
        WHERE cm.thing_id = ? ORDER BY c.name COLLATE NOCASE`,
      [thingId],
    );
  }

  add(collectionId: string, thingId: string, atIndex?: number): void {
    const exists = this.ctx.db.get(
      'SELECT 1 AS x FROM collection_member WHERE collection_id = ? AND thing_id = ?',
      [collectionId, thingId],
    );
    if (exists) return;
    const orders = this.ctx.db.pluck<number>('SELECT sort_order FROM collection_member WHERE collection_id = ?', [
      collectionId,
    ]);
    const sort = atIndex === undefined ? orderAtEnd(orders) : orderForIndex(orders, atIndex);
    this.ctx.db.transaction(() => {
      createEntity(this.ctx, 'member', compositeId(collectionId, thingId), {
        sort_order: sort,
        added_at: nowIso(),
      });
      reindexThing(this.ctx.db, thingId, this.ctx.registry);
    });
  }

  removeMember(collectionId: string, thingId: string): void {
    this.ctx.db.transaction(() => {
      deleteEntity(this.ctx, 'member', compositeId(collectionId, thingId));
      reindexThing(this.ctx.db, thingId, this.ctx.registry);
    });
  }

  reorderMember(collectionId: string, thingId: string, toIndex: number): void {
    const orders = this.ctx.db.pluck<number>(
      'SELECT sort_order FROM collection_member WHERE collection_id = ? AND thing_id != ?',
      [collectionId, thingId],
    );
    updateEntity(this.ctx, 'member', compositeId(collectionId, thingId), {
      sort_order: orderForIndex(orders, toIndex),
    });
  }

  countOf(collectionId: string): number {
    const r = this.ctx.db.get<{ n: number }>(
      `SELECT COUNT(*) AS n FROM collection_member cm JOIN thing t ON t.id = cm.thing_id
        WHERE cm.collection_id = ? AND t.deleted_at IS NULL`,
      [collectionId],
    );
    return r?.n ?? 0;
  }
}

export class TagRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  list(): (Tag & { count: number })[] {
    return this.ctx.db.all<Tag & { count: number }>(
      `SELECT g.*, (SELECT COUNT(*) FROM thing_tag tt JOIN thing t ON t.id = tt.thing_id
                     WHERE tt.tag_id = g.id AND t.deleted_at IS NULL) AS count
         FROM tag g ORDER BY g.name COLLATE NOCASE`,
    );
  }

  byName(name: string): Tag | undefined {
    return this.ctx.db.get<Tag>('SELECT * FROM tag WHERE name = ? COLLATE NOCASE', [name]);
  }

  ensure(name: string, color?: string | null): Tag {
    const existing = this.byName(name);
    if (existing) return existing;
    const id = uuidv7();
    createEntity(this.ctx, 'tag', id, { name, color: color ?? null });
    return this.ctx.db.get<Tag>('SELECT * FROM tag WHERE id = ?', [id]) as Tag;
  }

  forThing(thingId: string): Tag[] {
    return this.ctx.db.all<Tag>(
      'SELECT g.* FROM thing_tag tt JOIN tag g ON g.id = tt.tag_id WHERE tt.thing_id = ? ORDER BY g.name COLLATE NOCASE',
      [thingId],
    );
  }

  attach(thingId: string, name: string): Tag {
    const tag = this.ensure(name);
    const exists = this.ctx.db.get('SELECT 1 AS x FROM thing_tag WHERE thing_id = ? AND tag_id = ?', [
      thingId,
      tag.id,
    ]);
    if (!exists) {
      this.ctx.db.transaction(() => {
        createEntity(this.ctx, 'thing_tag', compositeId(thingId, tag.id), {});
        reindexThing(this.ctx.db, thingId, this.ctx.registry);
      });
    }
    return tag;
  }

  detach(thingId: string, tagId: string): void {
    this.ctx.db.transaction(() => {
      deleteEntity(this.ctx, 'thing_tag', compositeId(thingId, tagId));
      reindexThing(this.ctx.db, thingId, this.ctx.registry);
    });
  }

  rename(id: string, name: string): void {
    updateEntity(this.ctx, 'tag', id, { name });
    for (const t of this.ctx.db.pluck<string>('SELECT thing_id FROM thing_tag WHERE tag_id = ?', [id])) {
      reindexThing(this.ctx.db, t, this.ctx.registry);
    }
  }

  remove(id: string): void {
    const things = this.ctx.db.pluck<string>('SELECT thing_id FROM thing_tag WHERE tag_id = ?', [id]);
    this.ctx.db.transaction(() => {
      for (const t of things) deleteEntity(this.ctx, 'thing_tag', compositeId(t, id));
      deleteEntity(this.ctx, 'tag', id);
    });
    for (const t of things) reindexThing(this.ctx.db, t, this.ctx.registry);
  }
}
