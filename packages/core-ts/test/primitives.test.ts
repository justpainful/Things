import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { uuidv7, uuidv7Time, isUuid } from '../src/ids.ts';
import { Hlc, compareHlc, formatHlc, parseHlc, maxHlc } from '../src/hlc.ts';
import {
  compareVectors,
  incrementVector,
  mergeVectors,
  parseVector,
  stringifyVector,
} from '../src/versionVector.ts';
import {
  MIN_GAP,
  listNeedsRebalance,
  needsRebalance,
  orderAtEnd,
  orderAtStart,
  orderBetween,
  orderForIndex,
  rebalance,
} from '../src/sortOrder.ts';

describe('uuidv7', () => {
  test('is well formed and version 7', () => {
    const id = uuidv7();
    assert.ok(isUuid(id));
    assert.equal(id[14], '7');
    assert.ok('89ab'.includes(id[19]));
  });

  test('sorts in creation order even within a millisecond', () => {
    const ids: string[] = [];
    for (let i = 0; i < 5000; i++) ids.push(uuidv7());
    const sorted = [...ids].sort();
    assert.deepEqual(sorted, ids, 'uuidv7 must be lexicographically monotonic');
    assert.equal(new Set(ids).size, ids.length, 'no duplicates');
  });

  test('embeds the timestamp', () => {
    // Far enough ahead that the monotonicity clamp below cannot interfere.
    const t = 4_000_000_000_000;
    assert.equal(uuidv7Time(uuidv7(t)), t);
  });

  test('never goes backwards when the clock does', () => {
    const a = uuidv7(4_100_000_000_000);
    const b = uuidv7(4_000_000_000_000);
    assert.ok(b > a, 'a backwards clock must not produce a smaller id');
    assert.equal(uuidv7Time(b), 4_100_000_000_000, 'the id is clamped to the last time seen');
  });
});

describe('HLC', () => {
  const DEV = '11111111-1111-7111-8111-111111111111';

  test('round-trips its wire format', () => {
    const s = formatHlc({ physical: '2026-08-09T21:14:03.412Z', counter: 7, device: DEV });
    assert.equal(s, `2026-08-09T21:14:03.412Z-0007-${DEV}`);
    assert.deepEqual(parseHlc(s), { physical: '2026-08-09T21:14:03.412Z', counter: 7, device: DEV });
  });

  test('is monotonic when the wall clock stalls', () => {
    let t = 1_754_000_000_000;
    const h = new Hlc(DEV, { clock: () => t });
    const seq = [h.now(), h.now(), h.now()];
    assert.deepEqual(seq, [...seq].sort(), 'must be sortable');
    assert.equal(parseHlc(seq[2]).counter, 2);
    t += 5;
    const later = h.now();
    assert.ok(later > seq[2]);
    assert.equal(parseHlc(later).counter, 0, 'counter resets when physical time advances');
  });

  test('is monotonic when the wall clock goes backwards', () => {
    let t = 1_754_000_000_000;
    const h = new Hlc(DEV, { clock: () => t });
    const a = h.now();
    t -= 60_000; // the phone's clock is a minute slow
    const b = h.now();
    assert.ok(compareHlc(b, a) > 0, 'a skewed clock must not silently win');
  });

  test('receive() folds in a remote timestamp', () => {
    let t = 1_754_000_000_000;
    const h = new Hlc(DEV, { clock: () => t });
    const local = h.now();
    const remote = formatHlc({
      physical: new Date(t + 10_000).toISOString(),
      counter: 3,
      device: '22222222-2222-7222-8222-222222222222',
    });
    const after = h.receive(remote);
    assert.ok(after > remote, 'receiving must move past the remote timestamp');
    assert.ok(after > local);
    assert.equal(parseHlc(after).counter, 4);
  });

  test('maxHlc handles nulls', () => {
    assert.equal(maxHlc(null, 'b'), 'b');
    assert.equal(maxHlc('a', null), 'a');
    assert.equal(maxHlc('a', 'b'), 'b');
  });
});

describe('version vectors', () => {
  const A = 'device-a';
  const B = 'device-b';

  test('equal / dominates / dominated / concurrent', () => {
    assert.equal(compareVectors({}, {}), 'equal');
    assert.equal(compareVectors({ [A]: 2 }, { [A]: 2 }), 'equal');
    assert.equal(compareVectors({ [A]: 3 }, { [A]: 2 }), 'dominates');
    assert.equal(compareVectors({ [A]: 2 }, { [A]: 3 }), 'dominated');
    assert.equal(compareVectors({ [A]: 2, [B]: 1 }, { [A]: 1, [B]: 2 }), 'concurrent');
  });

  test('a missing device counts as zero', () => {
    assert.equal(compareVectors({ [A]: 1 }, {}), 'dominates');
    assert.equal(compareVectors({ [A]: 1 }, { [B]: 1 }), 'concurrent');
  });

  test('merge takes the pointwise maximum', () => {
    assert.deepEqual(mergeVectors({ [A]: 3, [B]: 1 }, { [A]: 1, [B]: 5 }), { [A]: 3, [B]: 5 });
  });

  test('serialisation is canonical', () => {
    assert.equal(stringifyVector({ b: 1, a: 2 }), '{"a":2,"b":1}');
    assert.deepEqual(parseVector('{"a":2}'), { a: 2 });
    assert.deepEqual(parseVector('not json'), {});
    assert.deepEqual(parseVector(null), {});
    assert.deepEqual(parseVector('{"a":"nope"}'), {}, 'non-numeric counters are dropped');
  });

  test('increment creates the key when absent', () => {
    assert.deepEqual(incrementVector({}, A), { [A]: 1 });
    assert.deepEqual(incrementVector({ [A]: 4 }, A), { [A]: 5 });
  });
});

describe('fractional sort_order', () => {
  test('midpoint insertion', () => {
    assert.equal(orderBetween(2, 3), 2.5);
    assert.equal(orderBetween(null, null), 1);
    assert.equal(orderBetween(null, 5), 4);
    assert.equal(orderBetween(5, null), 6);
  });

  test('rejects an inverted pair', () => {
    assert.throws(() => orderBetween(3, 2), RangeError);
    assert.throws(() => orderBetween(3, 3), RangeError);
  });

  test('orderForIndex places correctly at both ends and the middle', () => {
    const orders = [1, 2, 3];
    assert.equal(orderForIndex(orders, 0), 0);
    assert.equal(orderForIndex(orders, 1), 1.5);
    assert.equal(orderForIndex(orders, 3), 4);
    assert.equal(orderForIndex(orders, 99), 4, 'index past the end clamps');
    assert.equal(orderForIndex([], 0), 1);
  });

  test('orderAtEnd / orderAtStart', () => {
    assert.equal(orderAtEnd([1, 5, 3]), 6);
    assert.equal(orderAtStart([1, 5, 3]), 0);
    assert.equal(orderAtEnd([]), 1);
  });

  test('repeated midpoint insertion eventually needs a rebalance', () => {
    let prev = 1;
    const next = 2;
    let steps = 0;
    while (!needsRebalance(prev, next) && steps < 200) {
      prev = orderBetween(prev, next);
      steps++;
    }
    assert.ok(steps < 200, 'must trip the rebalance guard, not spin forever');
    assert.ok(next - prev < MIN_GAP);
  });

  test('rebalance renumbers while preserving visual order', () => {
    const items = [
      { id: 'c', sort_order: 1.0000001 },
      { id: 'a', sort_order: 1 },
      { id: 'b', sort_order: 1.00000005 },
    ];
    assert.ok(listNeedsRebalance(items.map((i) => i.sort_order)));
    assert.deepEqual(rebalance(items), [
      { id: 'a', sort_order: 1 },
      { id: 'b', sort_order: 2 },
      { id: 'c', sort_order: 3 },
    ]);
  });

  test('a healthy list does not need rebalancing', () => {
    assert.equal(listNeedsRebalance([1, 2, 3]), false);
    assert.equal(needsRebalance(null, 3), false);
  });
});
