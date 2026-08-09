/**
 * The search query DSL — docs/01-DATA-MODEL.md §6.
 *
 *   tag:1980  type:image  has:password  collection:1980  device:RAEID-PC
 *   modified:this-week  created:2026-08  is:locked  is:pinned
 *   size:>50mb  sort:created  "exact phrase"  -excluded  bare text
 *
 * Operators are sugar the filter chips generate. The user never has to learn
 * them; the power user never has to leave the keyboard.
 *
 * The parser is deliberately clock-free and database-free: it produces a plain
 * JSON AST. Relative dates like `this-week` stay symbolic and are resolved by
 * the evaluator against an injected `now`, so `spec/vectors/search-parser.json`
 * has stable expected output forever.
 */

export type FilterKey =
  | 'tag'
  | 'type'
  | 'has'
  | 'collection'
  | 'device'
  | 'modified'
  | 'created'
  | 'is'
  | 'size';

export type CompareOp = 'eq' | 'gt' | 'gte' | 'lt' | 'lte';

export type SortField = 'created' | 'modified' | 'title' | 'size' | 'viewed';
export type SortDirection = 'asc' | 'desc';

export interface TextTerm {
  kind: 'text';
  value: string;
  /** true when the term came from "quotes" — matched as a contiguous phrase. */
  phrase: boolean;
  negated: boolean;
}

export interface FilterTerm {
  kind: 'filter';
  key: FilterKey;
  op: CompareOp;
  value: string;
  negated: boolean;
}

export type Term = TextTerm | FilterTerm;

export interface SortSpec {
  field: SortField;
  direction: SortDirection;
}

export interface Query {
  terms: Term[];
  sort: SortSpec | null;
}

const FILTER_KEYS: FilterKey[] = [
  'tag',
  'type',
  'has',
  'collection',
  'device',
  'modified',
  'created',
  'is',
  'size',
];

const SORT_FIELDS: SortField[] = ['created', 'modified', 'title', 'size', 'viewed'];

const SORT_DEFAULT_DIRECTION: Record<SortField, SortDirection> = {
  created: 'desc',
  modified: 'desc',
  viewed: 'desc',
  size: 'desc',
  title: 'asc',
};

interface RawToken {
  text: string;
  quoted: boolean;
}

/**
 * Split on whitespace, honouring "double quotes" and backslash escapes.
 * A quoted run keeps its `quoted` flag even when it is the value half of a
 * `key:"…"` pair, which is how `collection:"Home Lab"` works.
 */
export function tokenize(input: string): RawToken[] {
  const out: RawToken[] = [];
  let buf = '';
  let quoted = false;
  let sawQuote = false;
  let started = false;

  const flush = () => {
    if (started) out.push({ text: buf, quoted: sawQuote });
    buf = '';
    quoted = false;
    sawQuote = false;
    started = false;
  };

  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (c === '\\' && i + 1 < input.length) {
      buf += input[++i];
      started = true;
      continue;
    }
    if (c === '"') {
      quoted = !quoted;
      sawQuote = true;
      started = true;
      continue;
    }
    if (!quoted && /\s/.test(c)) {
      flush();
      continue;
    }
    buf += c;
    started = true;
  }
  flush();
  return out;
}

function isFilterKey(v: string): v is FilterKey {
  return (FILTER_KEYS as string[]).includes(v);
}

/** Strip a leading comparison operator: `>50mb` → { op:'gt', rest:'50mb' }. */
function splitOp(value: string): { op: CompareOp; rest: string } {
  if (value.startsWith('>=')) return { op: 'gte', rest: value.slice(2) };
  if (value.startsWith('<=')) return { op: 'lte', rest: value.slice(2) };
  if (value.startsWith('>')) return { op: 'gt', rest: value.slice(1) };
  if (value.startsWith('<')) return { op: 'lt', rest: value.slice(1) };
  if (value.startsWith('=')) return { op: 'eq', rest: value.slice(1) };
  return { op: 'eq', rest: value };
}

const SIZE_UNITS: Record<string, number> = {
  b: 1,
  kb: 1024,
  k: 1024,
  mb: 1024 ** 2,
  m: 1024 ** 2,
  gb: 1024 ** 3,
  g: 1024 ** 3,
  tb: 1024 ** 4,
  t: 1024 ** 4,
};

/** `50mb` → 52428800. Returns null when the text is not a size. 1024-based. */
export function parseSize(text: string): number | null {
  const m = /^(\d+(?:\.\d+)?)\s*(b|kb|k|mb|m|gb|g|tb|t)?$/i.exec(text.trim());
  if (!m) return null;
  const n = parseFloat(m[1]);
  const unit = (m[2] ?? 'b').toLowerCase();
  const mult = SIZE_UNITS[unit];
  if (mult === undefined) return null;
  return Math.round(n * mult);
}

function parseSort(value: string): SortSpec | null {
  // sort:created · sort:created.asc · sort:title.desc
  const [rawField, rawDir] = value.toLowerCase().split('.');
  const field = SORT_FIELDS.find((f) => f === rawField);
  if (!field) return null;
  const direction: SortDirection =
    rawDir === 'asc' || rawDir === 'desc' ? rawDir : SORT_DEFAULT_DIRECTION[field];
  return { field, direction };
}

export function parseQuery(input: string): Query {
  const terms: Term[] = [];
  let sort: SortSpec | null = null;

  for (const tok of tokenize(input)) {
    let text = tok.text;
    if (!text) continue;

    let negated = false;
    if (!tok.quoted && text.startsWith('-') && text.length > 1) {
      negated = true;
      text = text.slice(1);
    } else if (tok.quoted && text.startsWith('-') && text.length > 1) {
      // -"exact phrase"  →  the '-' survived tokenisation outside the quotes
      negated = true;
      text = text.slice(1);
    }

    const colon = tok.quoted ? -1 : text.indexOf(':');
    const key = colon > 0 ? text.slice(0, colon).toLowerCase() : '';

    if (colon > 0 && key === 'sort') {
      const s = parseSort(text.slice(colon + 1));
      if (s) {
        sort = s;
        continue;
      }
      // Unknown sort field falls through to free text rather than being dropped.
    }

    if (colon > 0 && isFilterKey(key)) {
      const rawValue = text.slice(colon + 1);
      if (rawValue === '') {
        terms.push({ kind: 'text', value: text, phrase: false, negated });
        continue;
      }
      const { op, rest } = splitOp(rawValue);
      let value = stripQuotes(rest);
      if (key === 'size') {
        const bytes = parseSize(value);
        if (bytes === null) {
          terms.push({ kind: 'text', value: text, phrase: false, negated });
          continue;
        }
        value = String(bytes);
      } else {
        value = value.toLowerCase();
      }
      terms.push({ kind: 'filter', key, op, value, negated });
      continue;
    }

    terms.push({ kind: 'text', value: stripQuotes(text), phrase: tok.quoted, negated });
  }

  return { terms, sort };
}

function stripQuotes(v: string): string {
  return v.replace(/^"|"$/g, '');
}

/** Render an AST back to DSL text — the filter chips round-trip through this. */
export function stringifyQuery(q: Query): string {
  const parts: string[] = [];
  for (const t of q.terms) {
    const neg = t.negated ? '-' : '';
    if (t.kind === 'text') {
      parts.push(neg + (t.phrase || /\s/.test(t.value) ? `"${t.value}"` : t.value));
    } else {
      const op = t.op === 'eq' ? '' : t.op === 'gt' ? '>' : t.op === 'gte' ? '>=' : t.op === 'lt' ? '<' : '<=';
      const value = /\s/.test(t.value) ? `"${t.value}"` : t.value;
      parts.push(`${neg}${t.key}:${op}${value}`);
    }
  }
  if (q.sort) {
    const def = SORT_DEFAULT_DIRECTION[q.sort.field];
    parts.push(q.sort.direction === def ? `sort:${q.sort.field}` : `sort:${q.sort.field}.${q.sort.direction}`);
  }
  return parts.join(' ');
}

export const SEARCH_FILTER_KEYS = FILTER_KEYS;
export const SEARCH_SORT_FIELDS = SORT_FIELDS;
export { SORT_DEFAULT_DIRECTION };
