/**
 * Things core — shared types.
 *
 * These mirror `spec/schema.sql` exactly. The schema is normative; if the two
 * ever disagree, the schema wins and this file is the bug.
 */

export type Platform = 'ios' | 'windows';

export type EntityType =
  | 'thing'
  | 'section'
  | 'field'
  | 'collection'
  | 'member'
  | 'tag'
  | 'thing_tag'
  | 'file_ref';

export type Op = 'create' | 'update' | 'delete';

/** The closed set of base kinds. Loaded from spec/field-kinds.json, never hardcoded as a list. */
export type FieldKind = string;

/** `{deviceId: counter}` — see docs/01-DATA-MODEL.md §5. */
export type VersionVector = Record<string, number>;

export interface Device {
  id: string;
  name: string;
  platform: Platform;
  public_key: Uint8Array | null;
  paired_at: string | null;
  last_seen_at: string | null;
  is_self: number;
}

export interface Thing {
  id: string;
  title: string;
  icon_json: string | null;
  cover_object: string | null;
  is_pinned: number;
  is_locked: number;
  is_archived: number;
  is_template: number;
  created_at: string;
  updated_at: string;
  viewed_at: string | null;
  deleted_at: string | null;
  version_vector: string;
}

export interface Section {
  id: string;
  thing_id: string;
  title: string | null;
  sort_order: number;
  created_at: string;
  updated_at: string;
  version_vector: string;
}

export interface Field {
  id: string;
  thing_id: string;
  section_id: string | null;
  sort_order: number;
  kind: FieldKind;
  variant: string | null;
  label: string;
  value_text: string | null;
  value_json: string | null;
  value_cipher: Uint8Array | null;
  object_hash: string | null;
  file_ref_id: string | null;
  is_secret: number;
  created_at: string;
  updated_at: string;
  version_vector: string;
}

export interface ObjectRow {
  hash: string;
  byte_size: number;
  mime_type: string | null;
  width: number | null;
  height: number | null;
  duration_ms: number | null;
  enc_key_wrap: Uint8Array;
  enc_nonce: Uint8Array;
  ref_count: number;
  created_at: string;
}

export interface FileRef {
  id: string;
  device_id: string;
  path: string;
  is_directory: number;
  size_at_link: number | null;
  mtime_at_link: string | null;
  content_hash: string | null;
  last_seen_at: string | null;
  status: 'present' | 'missing' | 'unknown';
  created_at: string;
}

export interface Collection {
  id: string;
  name: string;
  icon_json: string | null;
  sort_order: number;
  parent_id: string | null;
  is_smart: number;
  is_system: number;
  smart_query: string | null;
  created_at: string;
  updated_at: string;
  version_vector: string;
}

export interface Tag {
  id: string;
  name: string;
  color: string | null;
  created_at: string;
}

export interface Change {
  id: string;
  device_id: string;
  hlc: string;
  entity_type: EntityType;
  entity_id: string;
  op: Op;
  attrs_json: string;
  prev_json: string | null;
  applied_at: string;
}

export interface Conflict {
  id: string;
  entity_type: EntityType;
  entity_id: string;
  version_a_json: string;
  version_b_json: string;
  detected_at: string;
  resolved_at: string | null;
  resolution: 'a' | 'b' | 'both' | 'manual' | null;
}

/**
 * The denormalised view of a Thing that the in-memory search evaluator works
 * against. Language-neutral on purpose: the conformance vectors describe
 * documents in exactly this shape, so the Swift core can evaluate the same
 * queries against the same inputs.
 */
export interface ThingDoc {
  id: string;
  title: string;
  /** Free text: titles, labels, non-secret values, notes, filenames. */
  text: string[];
  tags: string[];
  collections: string[];
  /** Markers from field-kinds.json plus derived ones: has:password, type:image, … */
  markers: string[];
  devices: string[];
  created_at: string;
  updated_at: string;
  is_pinned: boolean;
  is_locked: boolean;
  is_archived: boolean;
  is_template: boolean;
  is_trashed: boolean;
  has_missing_file: boolean;
  has_conflict: boolean;
  /** Largest attached object in bytes; 0 when the Thing has no objects. */
  max_object_size: number;
}
