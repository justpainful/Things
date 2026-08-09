import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { specDir } from './paths.ts';

/**
 * The field-kind registry is DATA, not code.
 *
 * Nothing in this file enumerates field types. Adding "Threads" is a one-line
 * change to spec/field-kinds.json and nothing here moves — that is the whole
 * point of the kind/variant split in docs/01-DATA-MODEL.md §2.
 */

export interface KindDef {
  storage: 'value_text' | 'value_json' | 'value_cipher' | 'object_hash' | 'file_ref_id' | 'thing_tag';
  alt?: string;
  multiline?: boolean;
  alwaysSecret?: boolean;
  values?: string[];
  format?: string;
  shape?: string;
  note?: string;
}

export interface ActionDef {
  label: string;
  gated?: boolean;
  deviceScoped?: boolean;
}

export interface VariantDef {
  id: string;
  kind: string;
  label: string;
  symbol: string;
  actions: string[];
  marker?: string;
  match?: string;
  validate?: string;
  gallery?: boolean;
  max?: number;
}

export interface TemplateDef {
  id: string;
  name: string;
  symbol: string;
  sections: { title: string | null; fields: { variant: string; label: string }[] }[];
}

export interface SmartViewDef {
  id: string;
  name: string;
  symbol: string;
  query: string;
}

export interface FieldKindRegistry {
  version: number;
  kinds: Record<string, KindDef>;
  actions: Record<string, ActionDef>;
  variants: VariantDef[];
  templates: TemplateDef[];
  smartViews: SmartViewDef[];
}

let cached: Registry | null = null;

export class Registry {
  readonly raw: FieldKindRegistry;
  private byVariant: Map<string, VariantDef>;
  private byKind: Map<string, VariantDef[]>;

  constructor(raw: FieldKindRegistry) {
    this.raw = raw;
    this.byVariant = new Map();
    this.byKind = new Map();
    for (const v of raw.variants) {
      this.byVariant.set(v.id, v);
      const list = this.byKind.get(v.kind) ?? [];
      list.push(v);
      this.byKind.set(v.kind, list);
    }
  }

  get version(): number {
    return this.raw.version;
  }

  /** Every base kind name the registry declares. */
  kinds(): string[] {
    return Object.keys(this.raw.kinds);
  }

  kind(name: string): KindDef | undefined {
    return this.raw.kinds[name];
  }

  hasKind(name: string): boolean {
    return Object.prototype.hasOwnProperty.call(this.raw.kinds, name);
  }

  variants(): VariantDef[] {
    return this.raw.variants;
  }

  variant(id: string | null | undefined): VariantDef | undefined {
    return id ? this.byVariant.get(id) : undefined;
  }

  variantsOfKind(kind: string): VariantDef[] {
    return this.byKind.get(kind) ?? [];
  }

  action(id: string): ActionDef | undefined {
    return this.raw.actions[id];
  }

  templates(): TemplateDef[] {
    return this.raw.templates;
  }

  template(id: string): TemplateDef | undefined {
    return this.raw.templates.find((t) => t.id === id);
  }

  smartViews(): SmartViewDef[] {
    return this.raw.smartViews;
  }

  /** Storage column a (kind, variant) pair writes into. */
  storageFor(kind: string): KindDef['storage'] | undefined {
    return this.raw.kinds[kind]?.storage;
  }

  /** Registry default for `field.is_secret`; the user can still override it. */
  defaultIsSecret(kind: string, variant: string | null | undefined): boolean {
    if (this.raw.kinds[kind]?.alwaysSecret) return true;
    const v = this.variant(variant);
    return Boolean(v && this.raw.kinds[v.kind]?.alwaysSecret);
  }

  /**
   * The search marker a field contributes. For a secret field this is ALL it
   * contributes besides its label — never the value. docs/02-SECURITY.md §5.
   */
  markerFor(variant: string | null | undefined): string | undefined {
    return this.variant(variant)?.marker;
  }

  /** Auto-detect a url variant from its value, e.g. github.com → 'github'. */
  detectUrlVariant(url: string): string | undefined {
    for (const v of this.variantsOfKind('url')) {
      if (!v.match) continue;
      try {
        if (new RegExp(v.match, 'i').test(url)) return v.id;
      } catch {
        /* a bad regex in the registry must not take the app down */
      }
    }
    return undefined;
  }

  /** Validate a value against the variant's regex, when it declares one. */
  validate(variant: string | null | undefined, value: string): boolean {
    const v = this.variant(variant);
    if (!v?.validate) return true;
    try {
      return new RegExp(v.validate).test(value);
    } catch {
      return true;
    }
  }
}

export function loadRegistry(path?: string): Registry {
  const file = path ?? join(specDir(), 'field-kinds.json');
  const raw = JSON.parse(readFileSync(file, 'utf8')) as FieldKindRegistry;
  return new Registry(raw);
}

/** Process-wide singleton; the registry is immutable data. */
export function registry(): Registry {
  if (!cached) cached = loadRegistry();
  return cached;
}

export function setRegistry(r: Registry): void {
  cached = r;
}
