import type { FilterTerm, Query, TextTerm } from './parse.ts';
import { resolveDateRange } from './dates.ts';
import { queryTouchesContent } from './evaluate.ts';
import type { Registry } from '../registry.ts';

/**
 * Compile a parsed query to SQL over the materialised tables.
 *
 * Free text goes through `thing_fts`; everything else is answered structurally,
 * which is both faster and exact. The two paths must agree with `matchDoc()`
 * in evaluate.ts — a test asserts that against the same fixtures.
 */

export interface CompiledQuery {
  sql: string;
  params: (string | number)[];
}

export interface CompileOptions {
  registry: Registry;
  now: string;
  includeTrashed?: boolean;
  includeArchived?: boolean;
  includeTemplates?: boolean;
  limit?: number;
  offset?: number;
  /** Restrict to a single collection (the sidebar's Collection view). */
  collectionId?: string;
}

function ftsMatchExpr(term: TextTerm): string {
  const escaped = term.value.replace(/"/g, '""');
  return term.phrase ? `"${escaped}"` : `"${escaped}"*`;
}

function wantsFlag(q: Query, value: string): boolean {
  return q.terms.some((t) => t.kind === 'filter' && t.key === 'is' && t.value === value && !t.negated);
}

/**
 * Which variants carry a given marker. Read from the registry — never a
 * hardcoded list — plus kind-level fallbacks for the markers the registry does
 * not spell out per-variant (`has:url`, `has:path`, `has:note`).
 */
function markerPredicate(
  reg: Registry,
  marker: string,
  params: (string | number)[],
): string | null {
  const variants = reg.variants().filter((v) => v.marker === marker).map((v) => v.id);
  const kinds: string[] = [];

  if (marker === 'has:url') kinds.push('url');
  if (marker === 'has:path') kinds.push('path');
  if (marker === 'has:note') kinds.push('richText');
  if (marker === 'has:file') kinds.push('attachment');
  if (marker === 'has:secret' || marker === 'has:password' || marker === 'has:key') {
    // secret markers are variant-scoped; do not widen to the whole kind
  }
  if (marker === 'has:tag') {
    return `EXISTS (SELECT 1 FROM thing_tag tt WHERE tt.thing_id = t.id)`;
  }
  if (marker === 'has:relation') kinds.push('relation');

  if (variants.length === 0 && kinds.length === 0) return null;

  const clauses: string[] = [];
  if (variants.length) {
    clauses.push(`f.variant IN (${variants.map(() => '?').join(',')})`);
    params.push(...variants);
  }
  if (kinds.length) {
    clauses.push(`f.kind IN (${kinds.map(() => '?').join(',')})`);
    params.push(...kinds);
  }
  return `EXISTS (SELECT 1 FROM field f WHERE f.thing_id = t.id AND (${clauses.join(' OR ')}))`;
}

function filterPredicate(
  term: FilterTerm,
  opts: CompileOptions,
  params: (string | number)[],
): string | null {
  const reg = opts.registry;
  switch (term.key) {
    case 'tag':
      params.push(term.value);
      return `EXISTS (SELECT 1 FROM thing_tag tt JOIN tag g ON g.id = tt.tag_id
              WHERE tt.thing_id = t.id AND g.name = ? COLLATE NOCASE)`;
    case 'collection':
      params.push(term.value);
      return `EXISTS (SELECT 1 FROM collection_member cm JOIN collection c ON c.id = cm.collection_id
              WHERE cm.thing_id = t.id AND c.name = ? COLLATE NOCASE)`;
    case 'device':
      params.push(term.value);
      return `EXISTS (SELECT 1 FROM field f JOIN file_ref fr ON fr.id = f.file_ref_id
              JOIN device d ON d.id = fr.device_id
              WHERE f.thing_id = t.id AND d.name = ? COLLATE NOCASE)`;
    case 'type':
      return markerPredicate(reg, `type:${term.value}`, params);
    case 'has':
      return markerPredicate(reg, `has:${term.value}`, params);
    case 'is':
      return isPredicate(term.value);
    case 'size': {
      const op = sqlOp(term.op);
      params.push(Number(term.value));
      return `EXISTS (SELECT 1 FROM field f JOIN object o ON o.hash = f.object_hash
              WHERE f.thing_id = t.id AND o.byte_size ${op} ?)`;
    }
    case 'created':
    case 'modified': {
      const col = term.key === 'created' ? 't.created_at' : 't.updated_at';
      const range = resolveDateRange(term.value, opts.now);
      if (!range) return null;
      switch (term.op) {
        case 'eq':
          params.push(range.from, range.to);
          return `(${col} >= ? AND ${col} < ?)`;
        case 'gte':
          params.push(range.from);
          return `${col} >= ?`;
        case 'gt':
          params.push(range.to);
          return `${col} >= ?`;
        case 'lt':
          params.push(range.from);
          return `${col} < ?`;
        case 'lte':
          params.push(range.to);
          return `${col} < ?`;
      }
      return null;
    }
  }
}

function sqlOp(op: FilterTerm['op']): string {
  return op === 'eq' ? '=' : op === 'gt' ? '>' : op === 'gte' ? '>=' : op === 'lt' ? '<' : '<=';
}

function isPredicate(value: string): string | null {
  switch (value) {
    case 'pinned':
      return 't.is_pinned = 1';
    case 'locked':
      return 't.is_locked = 1';
    case 'archived':
      return 't.is_archived = 1';
    case 'template':
      return 't.is_template = 1';
    case 'trashed':
    case 'deleted':
      return 't.deleted_at IS NOT NULL';
    case 'untagged':
      return 'NOT EXISTS (SELECT 1 FROM thing_tag tt WHERE tt.thing_id = t.id)';
    case 'missing':
      return `EXISTS (SELECT 1 FROM field f JOIN file_ref fr ON fr.id = f.file_ref_id
              WHERE f.thing_id = t.id AND fr.status = 'missing')`;
    case 'conflicted':
      return `EXISTS (SELECT 1 FROM conflict cf WHERE cf.resolved_at IS NULL
              AND (cf.entity_id = t.id
                   OR cf.entity_id IN (SELECT f.id FROM field f WHERE f.thing_id = t.id)))`;
    default:
      return null;
  }
}

const SORT_COLUMNS: Record<string, string> = {
  created: 't.created_at',
  modified: 't.updated_at',
  viewed: 't.viewed_at',
  title: 't.title COLLATE NOCASE',
  size: '(SELECT MAX(o.byte_size) FROM field f JOIN object o ON o.hash = f.object_hash WHERE f.thing_id = t.id)',
};

export function compileQuery(q: Query, opts: CompileOptions): CompiledQuery {
  const where: string[] = [];
  const params: (string | number)[] = [];

  // Implicit scope
  if (!opts.includeTrashed && !wantsFlag(q, 'trashed') && !wantsFlag(q, 'deleted')) {
    where.push('t.deleted_at IS NULL');
  }
  if (!opts.includeTemplates && !wantsFlag(q, 'template')) where.push('t.is_template = 0');
  if (!opts.includeArchived && !wantsFlag(q, 'archived')) where.push('t.is_archived = 0');

  // Locked Things contribute nothing to content search.
  if (queryTouchesContent(q)) where.push('t.is_locked = 0');

  if (opts.collectionId) {
    where.push('EXISTS (SELECT 1 FROM collection_member cm WHERE cm.thing_id = t.id AND cm.collection_id = ?)');
    params.push(opts.collectionId);
  }

  for (const term of q.terms) {
    let predicate: string | null;
    if (term.kind === 'text') {
      predicate = `t.id IN (SELECT thing_id FROM thing_fts WHERE thing_fts MATCH ?)`;
      params.push(ftsMatchExpr(term));
    } else {
      const before = params.length;
      predicate = filterPredicate(term, opts, params);
      if (predicate === null) {
        // Unresolvable filter (e.g. an unknown is: value). Drop the params it
        // pushed and make the term unsatisfiable rather than silently ignored.
        params.length = before;
        predicate = term.negated ? '1 = 1' : '1 = 0';
        where.push(predicate);
        continue;
      }
    }
    where.push(term.negated ? `NOT (${predicate})` : predicate);
  }

  const sortField = q.sort?.field ?? 'modified';
  const dir = (q.sort?.direction ?? 'desc').toUpperCase();
  const col = SORT_COLUMNS[sortField] ?? SORT_COLUMNS.modified;

  let sql =
    `SELECT t.id FROM thing t` +
    (where.length ? ` WHERE ${where.join(' AND ')}` : '') +
    ` ORDER BY t.is_pinned DESC, ${col} ${dir}, t.id ASC`;

  if (opts.limit !== undefined) {
    sql += ` LIMIT ${Math.max(0, Math.floor(opts.limit))}`;
    if (opts.offset) sql += ` OFFSET ${Math.max(0, Math.floor(opts.offset))}`;
  }
  return { sql, params };
}
