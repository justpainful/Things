import type { CoreContext } from '../context.ts';
import { createEntity, deleteEntity, updateEntity } from '../mutate.ts';
import { uuidv7 } from '../ids.ts';
import { listNeedsRebalance, orderAtEnd, orderForIndex, rebalance } from '../sortOrder.ts';
import { reindexThing } from '../search/indexer.ts';
import { fieldAad, open as openEnvelope, seal } from '../crypto/envelope.ts';
import type { Field } from '../types.ts';

/**
 * Fields — the heart of the model.
 *
 * Everything a Thing points at is a Field: relations, files, paths and tags
 * included. That uniformity is what gives ordering, sections, drag-and-drop
 * and "Add Field" one implementation instead of six.
 *
 * The storage column is looked up from `spec/field-kinds.json`, never branched
 * on here. A `password` and an `apiKey` differ in label, icon and copy wording
 * and in nothing else — if they differed in storage you would get two
 * encryption paths and two bugs.
 */

export type FieldValue =
  | { kind: 'text'; value: string }
  | { kind: 'json'; value: unknown }
  | { kind: 'secret'; value: string }
  | { kind: 'object'; hash: string }
  | { kind: 'fileRef'; id: string }
  | { kind: 'empty' };

export interface NewField {
  thingId: string;
  sectionId?: string | null;
  variant: string;
  label?: string;
  value?: FieldValue;
  isSecret?: boolean;
  atIndex?: number;
}

export interface FieldView extends Field {
  /** true when a secret value is present; the value itself is never included. */
  has_value: boolean;
}

export class FieldRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  get(id: string): Field | undefined {
    return this.ctx.db.get<Field>('SELECT * FROM field WHERE id = ?', [id]);
  }

  forThing(thingId: string): Field[] {
    return this.ctx.db.all<Field>('SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order', [thingId]);
  }

  create(input: NewField): Field {
    const reg = this.ctx.registry;
    const variant = reg.variant(input.variant);
    if (!variant) throw new Error(`unknown field variant: ${input.variant}`);
    const kind = variant.kind;
    const id = uuidv7();
    const orders = this.orders(input.thingId);
    const sort = input.atIndex === undefined ? orderAtEnd(orders) : orderForIndex(orders, input.atIndex);
    const isSecret = input.isSecret ?? reg.defaultIsSecret(kind, variant.id);

    return this.ctx.db.transaction(() => {
      const attrs = {
        thing_id: input.thingId,
        section_id: input.sectionId ?? null,
        sort_order: sort,
        kind,
        variant: variant.id,
        label: input.label ?? variant.label,
        value_text: null,
        value_json: null,
        value_cipher: null,
        object_hash: null,
        file_ref_id: null,
        is_secret: isSecret ? 1 : 0,
      };
      createEntity(this.ctx, 'field', id, attrs);
      if (input.value && input.value.kind !== 'empty') {
        this.setValue(id, input.value, { reindex: false });
      }
      reindexThing(this.ctx.db, input.thingId, this.ctx.registry);
      return this.get(id) as Field;
    });
  }

  /**
   * Write a value. Exactly one carrier column ends up non-NULL — the schema
   * CHECK enforces it, and this is the only place that decides which.
   */
  setValue(id: string, value: FieldValue, opts: { reindex?: boolean } = {}): Field | undefined {
    const field = this.get(id);
    if (!field) return undefined;

    const clear = {
      value_text: null as string | null,
      value_json: null as string | null,
      value_cipher: null as Uint8Array | null,
      object_hash: null as string | null,
      file_ref_id: null as string | null,
    };
    const attrs: Record<string, string | number | Uint8Array | null> = { ...clear };

    switch (value.kind) {
      case 'text':
        if (field.is_secret) throw new Error('a secret field cannot store plaintext');
        attrs.value_text = value.value;
        break;
      case 'json':
        if (field.is_secret) throw new Error('a secret field cannot store plaintext');
        attrs.value_json = JSON.stringify(value.value);
        break;
      case 'secret': {
        const dek = this.ctx.keyring.requireDek();
        attrs.value_cipher = seal(dek, value.value, fieldAad(field.thing_id, field.id));
        attrs.is_secret = 1;
        break;
      }
      case 'object':
        attrs.object_hash = value.hash;
        break;
      case 'fileRef':
        attrs.file_ref_id = value.id;
        break;
      case 'empty':
        break;
    }

    const run = () => {
      // Reference counting follows the field, not the object row.
      if (field.object_hash && field.object_hash !== attrs.object_hash) {
        this.ctx.objects.release(field.object_hash);
      }
      if (attrs.object_hash && attrs.object_hash !== field.object_hash) {
        this.ctx.objects.retain(attrs.object_hash as string);
      }
      updateEntity(this.ctx, 'field', id, attrs);
      if (opts.reindex !== false) reindexThing(this.ctx.db, field.thing_id, this.ctx.registry);
    };

    if (opts.reindex === false) run();
    else this.ctx.db.transaction(run);
    return this.get(id);
  }

  /**
   * Decrypt a secret. The AAD binds the ciphertext to `thing_id ‖ field_id`,
   * so a blob copied from another Thing fails authentication here rather than
   * being cheerfully decrypted in the wrong place.
   */
  revealSecret(id: string): string {
    const field = this.get(id);
    if (!field) throw new Error('no such field');
    if (!field.value_cipher) return '';
    const dek = this.ctx.keyring.requireDek();
    return openEnvelope(dek, field.value_cipher, fieldAad(field.thing_id, field.id)).toString('utf8');
  }

  rename(id: string, label: string): Field | undefined {
    return this.ctx.db.transaction(() => {
      updateEntity(this.ctx, 'field', id, { label });
      const f = this.get(id);
      if (f) reindexThing(this.ctx.db, f.thing_id, this.ctx.registry);
      return f;
    });
  }

  setVariant(id: string, variantId: string): Field | undefined {
    const variant = this.ctx.registry.variant(variantId);
    if (!variant) throw new Error(`unknown field variant: ${variantId}`);
    const field = this.get(id);
    if (!field) return undefined;
    if (variant.kind !== field.kind) {
      throw new Error(`cannot change a ${field.kind} field to a ${variant.kind} variant`);
    }
    return this.ctx.db.transaction(() => {
      updateEntity(this.ctx, 'field', id, { variant: variant.id });
      reindexThing(this.ctx.db, field.thing_id, this.ctx.registry);
      return this.get(id);
    });
  }

  moveToSection(id: string, sectionId: string | null, toIndex?: number): void {
    const f = this.get(id);
    if (!f) return;
    const siblings = this.forThing(f.thing_id).filter((x) => x.id !== id && x.section_id === sectionId);
    const sort =
      toIndex === undefined
        ? orderAtEnd(siblings.map((x) => x.sort_order))
        : orderForIndex(siblings.map((x) => x.sort_order), toIndex);
    updateEntity(this.ctx, 'field', id, { section_id: sectionId, sort_order: sort });
    this.rebalanceIfNeeded(f.thing_id);
  }

  /** Reorder within the current section. One row. */
  move(id: string, toIndex: number): void {
    const f = this.get(id);
    if (!f) return;
    this.moveToSection(id, f.section_id, toIndex);
  }

  remove(id: string): void {
    const f = this.get(id);
    if (!f) return;
    this.ctx.db.transaction(() => {
      if (f.object_hash) this.ctx.objects.release(f.object_hash);
      deleteEntity(this.ctx, 'field', id);
      reindexThing(this.ctx.db, f.thing_id, this.ctx.registry);
    });
  }

  private orders(thingId: string): number[] {
    return this.ctx.db.pluck<number>('SELECT sort_order FROM field WHERE thing_id = ?', [thingId]);
  }

  rebalanceIfNeeded(thingId: string): boolean {
    const fields = this.forThing(thingId);
    if (!listNeedsRebalance(fields.map((f) => f.sort_order))) return false;
    this.ctx.db.transaction(() => {
      for (const r of rebalance(fields)) updateEntity(this.ctx, 'field', r.id, { sort_order: r.sort_order });
    });
    return true;
  }

  /** "This link already exists in GitHub Project" — the url index, used on paste. */
  findByUrl(url: string): Field[] {
    return this.ctx.db.all<Field>(`SELECT * FROM field WHERE kind = 'url' AND value_text = ?`, [url]);
  }
}
