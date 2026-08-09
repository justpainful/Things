import { canonicalJson } from './canonicalJson.ts';
import type { VersionVector } from './types.ts';

/**
 * Version vectors — `{deviceId: counter}`.
 *
 * docs/01-DATA-MODEL.md §5:
 *   A dominates B  → A saw B      → apply A
 *   B dominates A  → B saw A      → keep B
 *   neither        → concurrent   → conflict
 *
 * Timestamps cannot make that distinction, which is why last-write-wins was
 * rejected. Vectors live on the *field* row, so "phone edits Notes, PC edits
 * Password" is two entities and never a conflict.
 */

export type VectorRelation = 'equal' | 'dominates' | 'dominated' | 'concurrent';

export function emptyVector(): VersionVector {
  return {};
}

export function parseVector(json: string | null | undefined): VersionVector {
  if (!json) return {};
  try {
    const v = JSON.parse(json) as unknown;
    if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
    const out: VersionVector = {};
    for (const [k, n] of Object.entries(v as Record<string, unknown>)) {
      if (typeof n === 'number' && Number.isFinite(n)) out[k] = n;
    }
    return out;
  } catch {
    return {};
  }
}

/**
 * Canonical serialisation (`spec/oplog.md` §2), so two equal vectors are equal
 * strings on both cores — one rule for every JSON column, not a second local one.
 */
export function stringifyVector(v: VersionVector): string {
  return canonicalJson(v);
}

export function incrementVector(v: VersionVector, deviceId: string): VersionVector {
  return { ...v, [deviceId]: (v[deviceId] ?? 0) + 1 };
}

export function mergeVectors(a: VersionVector, b: VersionVector): VersionVector {
  const out: VersionVector = { ...a };
  for (const [k, n] of Object.entries(b)) out[k] = Math.max(out[k] ?? 0, n);
  return out;
}

export function compareVectors(a: VersionVector, b: VersionVector): VectorRelation {
  let aGreater = false;
  let bGreater = false;
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    const av = a[k] ?? 0;
    const bv = b[k] ?? 0;
    if (av > bv) aGreater = true;
    else if (bv > av) bGreater = true;
    if (aGreater && bGreater) return 'concurrent';
  }
  if (!aGreater && !bGreater) return 'equal';
  return aGreater ? 'dominates' : 'dominated';
}

export function dominates(a: VersionVector, b: VersionVector): boolean {
  const r = compareVectors(a, b);
  return r === 'dominates' || r === 'equal';
}

export function isConcurrent(a: VersionVector, b: VersionVector): boolean {
  return compareVectors(a, b) === 'concurrent';
}
