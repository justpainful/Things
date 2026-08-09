import type { CompareOp, FilterTerm, Query, SortSpec, TextTerm } from './parse.ts';
import { resolveDateRange } from './dates.ts';
import type { ThingDoc } from '../types.ts';

/**
 * The in-memory evaluator.
 *
 * This is the semantics of record: `spec/vectors/search-parser.json` pins
 * parser output, and `spec/vectors/search-eval.json` pins what those ASTs
 * *mean* against a fixed set of documents. The SQL compiler in `sql.ts` must
 * agree with this function, and a test asserts that it does.
 *
 * Normative matching rules:
 *  · Terms are ANDed. `-term` excludes.
 *  · A bare word is a **prefix** match against any token, case- and
 *    diacritic-insensitive. `"a quoted phrase"` is a contiguous substring
 *    match against the normalised text of one field.
 *  · A **locked** Thing contributes nothing to content search: it is excluded
 *    from any query containing free text or a has:/type: filter. It remains
 *    reachable through `is:locked`, `tag:` and `collection:`, where the UI
 *    shows it without a preview. docs/02-SECURITY.md §5.
 */

export interface EvalOptions {
  now: string;
  includeTrashed?: boolean;
  includeArchived?: boolean;
  includeTemplates?: boolean;
}

const COMBINING_MARKS = /\p{M}/gu;
const WORD_SPLIT = /[^\p{L}\p{N}_]+/u;

/** Mirrors FTS5 `unicode61 remove_diacritics 2` closely enough to agree with it. */
export function normalize(s: string): string {
  return s.normalize('NFD').replace(COMBINING_MARKS, '').toLowerCase();
}

function fieldsOf(doc: ThingDoc): string[] {
  return [doc.title, ...doc.text, ...doc.tags, ...doc.collections];
}

function tokensOf(doc: ThingDoc): string[] {
  return normalize(fieldsOf(doc).join(' ')).split(WORD_SPLIT).filter(Boolean);
}

function compare(actual: number, op: CompareOp, expected: number): boolean {
  switch (op) {
    case 'eq':
      return actual === expected;
    case 'gt':
      return actual > expected;
    case 'gte':
      return actual >= expected;
    case 'lt':
      return actual < expected;
    case 'lte':
      return actual <= expected;
  }
}

function dateMatches(value: string, op: CompareOp, at: string | null, now: string): boolean {
  if (!at) return false;
  const range = resolveDateRange(value, now);
  if (!range) return false;
  switch (op) {
    case 'eq':
      return at >= range.from && at < range.to;
    case 'gte':
      return at >= range.from;
    case 'gt':
      return at >= range.to;
    case 'lt':
      return at < range.from;
    case 'lte':
      return at < range.to;
  }
}

function matchText(term: TextTerm, doc: ThingDoc): boolean {
  const needle = normalize(term.value);
  if (!needle) return true;
  if (term.phrase) return fieldsOf(doc).some((f) => normalize(f).includes(needle));
  return tokensOf(doc).some((t) => t.startsWith(needle));
}

function matchFilter(term: FilterTerm, doc: ThingDoc, opts: EvalOptions): boolean {
  const v = term.value;
  switch (term.key) {
    case 'tag':
      return doc.tags.some((t) => normalize(t) === normalize(v));
    case 'collection':
      return doc.collections.some((c) => normalize(c) === normalize(v));
    case 'device':
      return doc.devices.some((d) => normalize(d) === normalize(v));
    case 'type':
      return doc.markers.includes(`type:${v}`);
    case 'has':
      return doc.markers.includes(`has:${v}`) || (v === 'tag' && doc.tags.length > 0);
    case 'is':
      return matchIs(v, doc);
    case 'size':
      return compare(doc.max_object_size, term.op, Number(v));
    case 'created':
      return dateMatches(v, term.op, doc.created_at, opts.now);
    case 'modified':
      return dateMatches(v, term.op, doc.updated_at, opts.now);
  }
}

function matchIs(v: string, doc: ThingDoc): boolean {
  switch (v) {
    case 'pinned':
      return doc.is_pinned;
    case 'locked':
      return doc.is_locked;
    case 'archived':
      return doc.is_archived;
    case 'template':
      return doc.is_template;
    case 'trashed':
    case 'deleted':
      return doc.is_trashed;
    case 'missing':
      return doc.has_missing_file;
    case 'conflicted':
      return doc.has_conflict;
    case 'untagged':
      return doc.tags.length === 0;
    default:
      return false;
  }
}

/** True when the query reads Thing *content* rather than just its flags. */
export function queryTouchesContent(q: Query): boolean {
  return q.terms.some(
    (t) => t.kind === 'text' || (t.kind === 'filter' && (t.key === 'has' || t.key === 'type')),
  );
}

function wantsFlag(q: Query, value: string): boolean {
  return q.terms.some((t) => t.kind === 'filter' && t.key === 'is' && t.value === value && !t.negated);
}

export function matchDoc(q: Query, doc: ThingDoc, opts: EvalOptions): boolean {
  // Implicit scope. Trash, archive and templates are separate places in the UI
  // and must not bleed into ordinary results.
  if (doc.is_trashed && !opts.includeTrashed && !wantsFlag(q, 'trashed') && !wantsFlag(q, 'deleted')) {
    return false;
  }
  if (doc.is_template && !opts.includeTemplates && !wantsFlag(q, 'template')) return false;
  if (doc.is_archived && !opts.includeArchived && !wantsFlag(q, 'archived')) return false;

  if (doc.is_locked && queryTouchesContent(q)) return false;

  for (const term of q.terms) {
    const hit = term.kind === 'text' ? matchText(term, doc) : matchFilter(term, doc, opts);
    if (term.negated ? hit : !hit) return false;
  }
  return true;
}

export function sortDocs(docs: ThingDoc[], sort: SortSpec | null): ThingDoc[] {
  const s: SortSpec = sort ?? { field: 'modified', direction: 'desc' };
  const dir = s.direction === 'asc' ? 1 : -1;
  const key = (d: ThingDoc): string | number => {
    switch (s.field) {
      case 'created':
        return d.created_at;
      case 'modified':
      case 'viewed':
        return d.updated_at;
      case 'title':
        return normalize(d.title);
      case 'size':
        return d.max_object_size;
    }
  };
  return [...docs].sort((a, b) => {
    const ka = key(a);
    const kb = key(b);
    if (ka < kb) return -1 * dir;
    if (ka > kb) return 1 * dir;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

export function runQuery(q: Query, docs: ThingDoc[], opts: EvalOptions): ThingDoc[] {
  return sortDocs(
    docs.filter((d) => matchDoc(q, d, opts)),
    q.sort,
  );
}
