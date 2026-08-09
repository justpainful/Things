import type { Db } from '../db.ts';
import type { Registry } from '../registry.ts';
import type { Field, Thing } from '../types.ts';

/**
 * `thing_fts` maintenance.
 *
 * Two rules that are security properties, not UI preferences
 * (docs/02-SECURITY.md §5):
 *
 *  1. **A secret field's VALUE is never indexed.** It contributes its user
 *     authored label and its registry `marker` (`has:password`) and nothing
 *     else. That is what makes "show me Things that have a password, without
 *     revealing the password" work.
 *  2. **A locked Thing contributes nothing at all** while locked. Not its
 *     title, not its labels, not its markers.
 *
 * Both are enforced here, in one place, so no repository can forget.
 */

export interface IndexRow {
  thing_id: string;
  title: string;
  labels: string;
  values: string;
  notes: string;
  tags: string;
  urls: string;
  paths: string;
  filenames: string;
  collections: string;
  markers: string;
}

function plainTextFromRich(json: string | null): string {
  if (!json) return '';
  try {
    const parse = (n: unknown): string => {
      if (typeof n === 'string') return n;
      if (Array.isArray(n)) return n.map(parse).join(' ');
      if (n && typeof n === 'object') {
        const o = n as Record<string, unknown>;
        const own = typeof o.text === 'string' ? o.text : '';
        return [own, parse(o.content ?? o.children ?? [])].filter(Boolean).join(' ');
      }
      return '';
    };
    return parse(JSON.parse(json)).trim();
  } catch {
    return '';
  }
}

function filenameOf(field: Field): string {
  if (!field.value_json) return '';
  try {
    const o = JSON.parse(field.value_json) as { filename?: unknown };
    return typeof o.filename === 'string' ? o.filename : '';
  } catch {
    return '';
  }
}

export function buildIndexRow(
  db: Db,
  thing: Thing,
  reg: Registry,
): IndexRow | null {
  if (thing.deleted_at) return null;
  if (thing.is_locked) return null; // contributes nothing while locked

  const fields = db.all<Field>('SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order', [thing.id]);
  const tags = db.pluck<string>(
    'SELECT g.name FROM thing_tag tt JOIN tag g ON g.id = tt.tag_id WHERE tt.thing_id = ?',
    [thing.id],
  );
  const collections = db.pluck<string>(
    'SELECT c.name FROM collection_member cm JOIN collection c ON c.id = cm.collection_id WHERE cm.thing_id = ?',
    [thing.id],
  );
  const sections = db.pluck<string>(
    'SELECT title FROM section WHERE thing_id = ? AND title IS NOT NULL',
    [thing.id],
  );

  const labels: string[] = [...sections];
  const values: string[] = [];
  const notes: string[] = [];
  const urls: string[] = [];
  const paths: string[] = [];
  const filenames: string[] = [];
  const markers = new Set<string>();

  for (const f of fields) {
    labels.push(f.label);

    const marker = reg.markerFor(f.variant);
    if (marker) markers.add(marker);

    if (f.is_secret) {
      // Label + marker only. Never the value. Never the ciphertext.
      markers.add('has:secret');
      continue;
    }

    switch (f.kind) {
      case 'url':
        if (f.value_text) {
          urls.push(f.value_text);
          markers.add('has:url');
        }
        break;
      case 'path':
        markers.add('has:path');
        break;
      case 'richText':
        notes.push(plainTextFromRich(f.value_json));
        markers.add('has:note');
        break;
      case 'attachment':
        markers.add('has:file');
        break;
      case 'relation':
        markers.add('has:relation');
        break;
      default:
        if (f.value_text) values.push(f.value_text);
        break;
    }

    const fn = filenameOf(f);
    if (fn) filenames.push(fn);
  }

  for (const p of refPaths(db, thing.id)) paths.push(p);
  if (tags.length) markers.add('has:tag');
  if (thing.is_pinned) markers.add('is:pinned');
  if (thing.is_archived) markers.add('is:archived');

  return {
    thing_id: thing.id,
    title: thing.title,
    labels: labels.join(' ␟ '),
    values: values.join(' ␟ '),
    notes: notes.join(' ␟ '),
    tags: tags.join(' ␟ '),
    urls: urls.join(' ␟ '),
    paths: paths.join(' ␟ '),
    filenames: filenames.join(' ␟ '),
    collections: collections.join(' ␟ '),
    markers: [...markers].join(' '),
  };
}

function refPaths(db: Db, thingId: string): string[] {
  return db.pluck<string>(
    `SELECT fr.path FROM field f JOIN file_ref fr ON fr.id = f.file_ref_id WHERE f.thing_id = ?`,
    [thingId],
  );
}

export function removeFromIndex(db: Db, thingId: string): void {
  db.run('DELETE FROM thing_fts WHERE thing_id = ?', [thingId]);
}

export function reindexThing(db: Db, thingId: string, reg: Registry): void {
  removeFromIndex(db, thingId);
  const thing = db.get<Thing>('SELECT * FROM thing WHERE id = ?', [thingId]);
  if (!thing) return;
  const row = buildIndexRow(db, thing, reg);
  if (!row) return;
  db.run(
    // "values" is a reserved word in core SQL, so every column is quoted.
    `INSERT INTO thing_fts ("thing_id","title","labels","values","notes","tags","urls","paths","filenames","collections","markers")
     VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
    [
      row.thing_id,
      row.title,
      row.labels,
      row.values,
      row.notes,
      row.tags,
      row.urls,
      row.paths,
      row.filenames,
      row.collections,
      row.markers,
    ],
  );
}

/** Rebuild the whole index. Used after a restore, an import, or a lock change. */
export function reindexAll(db: Db, reg: Registry): number {
  db.run('DELETE FROM thing_fts', []);
  const ids = db.pluck<string>('SELECT id FROM thing');
  for (const id of ids) reindexThing(db, id, reg);
  return ids.length;
}
