/**
 * Fractional ordering — docs/01-DATA-MODEL.md §4.
 *
 * A reorder must be a ONE-ROW write. Renumbering 40 siblings would manufacture
 * 40 phantom conflicts on the next sync, which is the actual reason this is a
 * REAL column and not an INTEGER position.
 *
 * The only hard part is precision. IEEE-754 doubles run out of room after
 * roughly 50 consecutive "drop between these two" operations at the same spot.
 * `needsRebalance()` detects that *before* two rows collide, and `rebalance()`
 * renumbers the whole sibling list — a rare, explicit, batched operation
 * instead of an implicit one on every insert.
 */

/** Below this gap the next midpoint is no longer safely representable. */
export const MIN_GAP = 1e-6;

export const DEFAULT_STEP = 1;

/**
 * The sort_order for an item dropped between `prev` and `next`.
 * `null` means "no neighbour on that side" (start / end of list).
 */
export function orderBetween(prev: number | null, next: number | null): number {
  if (prev === null && next === null) return DEFAULT_STEP;
  if (prev === null) return (next as number) - DEFAULT_STEP;
  if (next === null) return prev + DEFAULT_STEP;
  if (!(next > prev)) {
    throw new RangeError(`orderBetween requires prev < next (got ${prev}, ${next})`);
  }
  return prev + (next - prev) / 2;
}

/** Order for appending to the end of a sibling list. */
export function orderAtEnd(orders: readonly number[]): number {
  if (orders.length === 0) return DEFAULT_STEP;
  return Math.max(...orders) + DEFAULT_STEP;
}

/** Order for prepending. */
export function orderAtStart(orders: readonly number[]): number {
  if (orders.length === 0) return DEFAULT_STEP;
  return Math.min(...orders) - DEFAULT_STEP;
}

/**
 * Order for moving an item to visual index `index` in a list whose CURRENT
 * orders are `orders` (ascending, excluding the item being moved).
 */
export function orderForIndex(orders: readonly number[], index: number): number {
  const sorted = [...orders].sort((a, b) => a - b);
  const i = Math.max(0, Math.min(index, sorted.length));
  const prev = i === 0 ? null : sorted[i - 1];
  const next = i >= sorted.length ? null : sorted[i];
  return orderBetween(prev, next);
}

/** True when the gap between two neighbours has degraded past usefulness. */
export function needsRebalance(prev: number | null, next: number | null): boolean {
  if (prev === null || next === null) return false;
  return next - prev < MIN_GAP;
}

/** True when any adjacent pair in a sibling list has degraded. */
export function listNeedsRebalance(orders: readonly number[]): boolean {
  const sorted = [...orders].sort((a, b) => a - b);
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] - sorted[i - 1] < MIN_GAP) return true;
  }
  return false;
}

/**
 * Renumber a sibling list to 1, 2, 3 … preserving the existing visual order.
 * Returns the new order for each input id, in input order.
 */
export function rebalance<T extends { id: string; sort_order: number }>(
  items: readonly T[],
): { id: string; sort_order: number }[] {
  const sorted = [...items].sort((a, b) => a.sort_order - b.sort_order || (a.id < b.id ? -1 : 1));
  return sorted.map((it, i) => ({ id: it.id, sort_order: (i + 1) * DEFAULT_STEP }));
}
