import type { Core, Field, Section, Thing } from '@things/core';

/**
 * Wire shapes.
 *
 * The single rule here: **a secret value never enters a response body.** A
 * field says whether it holds one; revealing it is a separate, deliberate
 * request. docs/02-SECURITY.md §5.
 */

export interface FieldView {
  id: string;
  sectionId: string | null;
  sortOrder: number;
  kind: string;
  variant: string | null;
  label: string;
  isSecret: boolean;
  hasValue: boolean;
  text: string | null;
  json: unknown;
  objectHash: string | null;
  object: { hash: string; byteSize: number; mimeType: string | null; width: number | null; height: number | null } | null;
  fileRef: { id: string; path: string; deviceId: string; deviceName: string; isDirectory: boolean; status: string; isThisDevice: boolean } | null;
  symbol: string;
  actions: string[];
  marker: string | null;
  gallery: boolean;
  updatedAt: string;
}

export interface ThingView {
  id: string;
  title: string;
  icon: unknown;
  coverObject: string | null;
  isPinned: boolean;
  isLocked: boolean;
  isArchived: boolean;
  isTemplate: boolean;
  createdAt: string;
  updatedAt: string;
  viewedAt: string | null;
  deletedAt: string | null;
  tags: { id: string; name: string; color: string | null }[];
  collections: { id: string; name: string }[];
  sections: { id: string; title: string | null; sortOrder: number }[];
  fields: FieldView[];
  backlinks: { id: string; title: string }[];
  markers: string[];
}

export interface ThingSummary {
  id: string;
  title: string;
  icon: unknown;
  isPinned: boolean;
  isLocked: boolean;
  isArchived: boolean;
  updatedAt: string;
  createdAt: string;
  deletedAt: string | null;
  subtitle: string;
  markers: string[];
  tags: string[];
  coverObject: string | null;
  fieldCount: number;
}

function parseIcon(json: string | null): unknown {
  if (!json) return null;
  try {
    return JSON.parse(json);
  } catch {
    return null;
  }
}

export function fieldView(core: Core, f: Field): FieldView {
  const variant = core.registry.variant(f.variant);
  const object = f.object_hash ? core.objects.row(f.object_hash) : undefined;
  const ref = f.file_ref_id ? core.fileRefs.get(f.file_ref_id) : undefined;
  const device = ref ? core.devices.get(ref.device_id) : undefined;

  return {
    id: f.id,
    sectionId: f.section_id,
    sortOrder: f.sort_order,
    kind: f.kind,
    variant: f.variant,
    label: f.label,
    isSecret: !!f.is_secret,
    // A secret says only that it exists.
    hasValue: !!(f.value_text || f.value_json || f.value_cipher || f.object_hash || f.file_ref_id),
    text: f.is_secret ? null : f.value_text,
    json: f.is_secret || !f.value_json ? null : safeJson(f.value_json),
    objectHash: f.object_hash,
    object: object
      ? {
          hash: object.hash,
          byteSize: object.byte_size,
          mimeType: object.mime_type,
          width: object.width,
          height: object.height,
        }
      : null,
    fileRef: ref
      ? {
          id: ref.id,
          path: ref.path,
          deviceId: ref.device_id,
          deviceName: device?.name ?? 'Unknown device',
          isDirectory: !!ref.is_directory,
          status: ref.status,
          isThisDevice: ref.device_id === core.deviceId,
        }
      : null,
    symbol: variant?.symbol ?? 'textformat',
    actions: variant?.actions ?? [],
    marker: variant?.marker ?? null,
    gallery: !!variant?.gallery,
    updatedAt: f.updated_at,
  };
}

export function thingView(core: Core, thing: Thing): ThingView {
  const sections: Section[] = core.sections.forThing(thing.id);
  const fields = core.fields.forThing(thing.id);
  return {
    id: thing.id,
    title: thing.title,
    icon: parseIcon(thing.icon_json),
    coverObject: thing.cover_object,
    isPinned: !!thing.is_pinned,
    isLocked: !!thing.is_locked,
    isArchived: !!thing.is_archived,
    isTemplate: !!thing.is_template,
    createdAt: thing.created_at,
    updatedAt: thing.updated_at,
    viewedAt: thing.viewed_at,
    deletedAt: thing.deleted_at,
    tags: core.tags.forThing(thing.id).map((t) => ({ id: t.id, name: t.name, color: t.color })),
    collections: core.collections.collectionsOf(thing.id).map((c) => ({ id: c.id, name: c.name })),
    sections: sections.map((s) => ({ id: s.id, title: s.title, sortOrder: s.sort_order })),
    fields: fields.map((f) => fieldView(core, f)),
    backlinks: core.things.referencedBy(thing.id).map((t) => ({ id: t.id, title: t.title })),
    markers: core.buildDoc(thing).markers,
  };
}

/**
 * The list-row shape. A locked Thing gets no subtitle and no tags — it must
 * not leak content into a preview.
 */
export function thingSummary(core: Core, thing: Thing): ThingSummary {
  const locked = !!thing.is_locked;
  const fields = locked ? [] : core.fields.forThing(thing.id);
  const doc = core.buildDoc(thing);

  let subtitle = '';
  if (!locked) {
    const firstText = fields.find((f) => !f.is_secret && f.value_text);
    subtitle = firstText?.value_text ?? '';
  }

  return {
    id: thing.id,
    title: thing.title,
    icon: parseIcon(thing.icon_json),
    isPinned: !!thing.is_pinned,
    isLocked: locked,
    isArchived: !!thing.is_archived,
    updatedAt: thing.updated_at,
    createdAt: thing.created_at,
    deletedAt: thing.deleted_at,
    subtitle,
    markers: locked ? [] : doc.markers,
    tags: locked ? [] : doc.tags,
    coverObject: thing.cover_object,
    fieldCount: locked ? 0 : fields.length,
  };
}

function safeJson(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}
