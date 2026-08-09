import type { CoreContext } from '../context.ts';
import { createEntity, deleteEntity, updateEntity } from '../mutate.ts';
import { uuidv7 } from '../ids.ts';
import { listNeedsRebalance, orderAtEnd, orderForIndex, rebalance } from '../sortOrder.ts';
import { reindexThing } from '../search/indexer.ts';
import type { Section } from '../types.ts';

export class SectionRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  get(id: string): Section | undefined {
    return this.ctx.db.get<Section>('SELECT * FROM section WHERE id = ?', [id]);
  }

  forThing(thingId: string): Section[] {
    return this.ctx.db.all<Section>('SELECT * FROM section WHERE thing_id = ? ORDER BY sort_order', [
      thingId,
    ]);
  }

  create(thingId: string, title: string | null, atIndex?: number): Section {
    const id = uuidv7();
    const orders = this.orders(thingId);
    const sort = atIndex === undefined ? orderAtEnd(orders) : orderForIndex(orders, atIndex);
    return this.ctx.db.transaction(() => {
      createEntity(this.ctx, 'section', id, { thing_id: thingId, title, sort_order: sort });
      reindexThing(this.ctx.db, thingId, this.ctx.registry);
      return this.get(id) as Section;
    });
  }

  rename(id: string, title: string | null): Section | undefined {
    return this.ctx.db.transaction(() => {
      updateEntity(this.ctx, 'section', id, { title });
      const s = this.get(id);
      if (s) reindexThing(this.ctx.db, s.thing_id, this.ctx.registry);
      return s;
    });
  }

  /**
   * Reorder. ONE row is written — that is the entire reason sort_order is a
   * REAL. See docs/01-DATA-MODEL.md §4.
   */
  move(id: string, toIndex: number): void {
    const s = this.get(id);
    if (!s) return;
    const siblings = this.forThing(s.thing_id).filter((x) => x.id !== id);
    const target = orderForIndex(siblings.map((x) => x.sort_order), toIndex);
    updateEntity(this.ctx, 'section', id, { sort_order: target });
    this.rebalanceIfNeeded(s.thing_id);
  }

  remove(id: string): void {
    const s = this.get(id);
    if (!s) return;
    this.ctx.db.transaction(() => {
      // section_id is ON DELETE SET NULL: the fields survive, unfiled.
      deleteEntity(this.ctx, 'section', id);
      reindexThing(this.ctx.db, s.thing_id, this.ctx.registry);
    });
  }

  private orders(thingId: string): number[] {
    return this.ctx.db.pluck<number>('SELECT sort_order FROM section WHERE thing_id = ?', [thingId]);
  }

  /** Precision degrades after ~50 inserts at the same spot; renumber then, not before. */
  rebalanceIfNeeded(thingId: string): boolean {
    const sections = this.forThing(thingId);
    if (!listNeedsRebalance(sections.map((s) => s.sort_order))) return false;
    this.ctx.db.transaction(() => {
      for (const r of rebalance(sections)) {
        updateEntity(this.ctx, 'section', r.id, { sort_order: r.sort_order });
      }
    });
    return true;
  }
}
