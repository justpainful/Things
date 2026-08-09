import { join } from 'node:path';
import { hostname } from 'node:os';
import { mkdirSync } from 'node:fs';
import { Db, openDatabase } from './db.ts';
import { registry as defaultRegistry } from './registry.ts';
import type { Registry } from './registry.ts';
import { Hlc } from './hlc.ts';
import { Oplog } from './oplog.ts';
import { Keyring } from './crypto/keyring.ts';
import { FileVault, MirroredVault, migrateVaultFromMeta, vaultPathFor } from './crypto/vault.ts';
import type { VaultMigration } from './crypto/vault.ts';
import { DeviceSecretStore } from './crypto/deviceSecret.ts';
import { ObjectStore } from './objectStore.ts';
import { ThingRepo } from './repos/things.ts';
import { SectionRepo } from './repos/sections.ts';
import { FieldRepo } from './repos/fields.ts';
import { CollectionRepo, TagRepo } from './repos/collections.ts';
import { DeviceRepo, FileRefRepo } from './repos/fileRefs.ts';
import type { CoreContext } from './context.ts';
import { uuidv7, nowIso } from './ids.ts';
import { parseQuery } from './search/parse.ts';
import type { Query } from './search/parse.ts';
import { compileQuery } from './search/sql.ts';
import { reindexAll } from './search/indexer.ts';
import type { Field, Thing, ThingDoc } from './types.ts';

export interface CoreOptions {
  dataDir: string;
  deviceName?: string;
  registry?: Registry;
  /** Tests force the file-based device wrapper so they never touch the real DPAPI store. */
  forceFallbackDeviceSecret?: boolean;
}

export interface SearchOptions {
  limit?: number;
  offset?: number;
  collectionId?: string;
  includeTrashed?: boolean;
  includeArchived?: boolean;
  includeTemplates?: boolean;
  now?: string;
}

/**
 * `Core` is the whole library assembled. It owns the database, the key
 * hierarchy, the oplog and the repositories, and it is the only object the
 * server needs to hold.
 */
export class Core {
  readonly db: Db;
  readonly registry: Registry;
  /** `vault.json` — the unencrypted sidecar holding the wrapped DEK. */
  readonly vault: FileVault;
  /** What, if anything, was lifted out of the old `meta` rows at open time. */
  readonly vaultMigration: VaultMigration;
  readonly keyring: Keyring;
  readonly hlc: Hlc;
  readonly oplog: Oplog;
  readonly objects: ObjectStore;
  readonly deviceId: string;
  readonly dataDir: string;

  readonly things: ThingRepo;
  readonly sections: SectionRepo;
  readonly fields: FieldRepo;
  readonly collections: CollectionRepo;
  readonly tags: TagRepo;
  readonly fileRefs: FileRefRepo;
  readonly devices: DeviceRepo;

  readonly ctx: CoreContext;

  private constructor(opts: CoreOptions) {
    this.dataDir = opts.dataDir;
    mkdirSync(opts.dataDir, { recursive: true });
    this.db = openDatabase(join(opts.dataDir, 'things.sqlite'));
    this.registry = opts.registry ?? defaultRegistry();

    let deviceId = this.db.meta('device_id');
    if (!deviceId) {
      deviceId = uuidv7();
      this.db.setMeta('device_id', deviceId);
    }
    this.deviceId = deviceId;

    this.hlc = new Hlc(deviceId, { last: this.db.meta('hlc_last') });
    this.oplog = new Oplog(this.db, deviceId, this.hlc);

    /**
     * Key material lives in `vault.json` beside the database, NOT in `meta` —
     * `spec/crypto.md` §3.1. `meta` is inside the SQLCipher database that these
     * very rows are needed to unlock, so storing them there is a circle that
     * only stays invisible while the database is unencrypted.
     *
     * `meta` keeps a mirror of the four keys `core-swift` mirrors, for a future
     * self-describing backup container. It is never read to unlock.
     */
    const metaStore = {
      get: (k: string) => this.db.meta(k),
      set: (k: string, v: string | null) => {
        if (v === null) this.db.run('DELETE FROM meta WHERE key = ?', [k]);
        else this.db.setMeta(k, v);
      },
    };
    this.vault = new FileVault(vaultPathFor(opts.dataDir));
    this.vaultMigration = migrateVaultFromMeta(metaStore, this.vault);
    this.keyring = new Keyring(
      new MirroredVault(this.vault, metaStore),
      new DeviceSecretStore({
        dir: join(opts.dataDir, 'keys'),
        forceFallback: opts.forceFallbackDeviceSecret,
      }),
    );
    this.objects = new ObjectStore(join(opts.dataDir, 'objects'), this.db, this.keyring);

    this.ctx = {
      db: this.db,
      registry: this.registry,
      deviceId,
      hlc: this.hlc,
      oplog: this.oplog,
      keyring: this.keyring,
      objects: this.objects,
      now: () => nowIso(),
    };

    this.things = new ThingRepo(this.ctx);
    this.sections = new SectionRepo(this.ctx);
    this.fields = new FieldRepo(this.ctx);
    this.collections = new CollectionRepo(this.ctx);
    this.tags = new TagRepo(this.ctx);
    this.fileRefs = new FileRefRepo(this.ctx);
    this.devices = new DeviceRepo(this.ctx);

    this.devices.ensureSelf(deviceId, opts.deviceName ?? hostname(), 'windows');
    if (!this.db.meta('trash_retention_days')) this.db.setMeta('trash_retention_days', '30');
  }

  static open(opts: CoreOptions): Core {
    return new Core(opts);
  }

  close(): void {
    this.keyring.lock();
    this.db.close();
  }

  // ── search ────────────────────────────────────────────────────────────────

  search(input: string | Query, opts: SearchOptions = {}): Thing[] {
    const q = typeof input === 'string' ? parseQuery(input) : input;
    const compiled = compileQuery(q, {
      registry: this.registry,
      now: opts.now ?? nowIso(),
      limit: opts.limit ?? 200,
      offset: opts.offset,
      collectionId: opts.collectionId,
      includeTrashed: opts.includeTrashed,
      includeArchived: opts.includeArchived,
      includeTemplates: opts.includeTemplates,
    });
    const ids = this.db.pluck<string>(compiled.sql, compiled.params);
    if (ids.length === 0) return [];
    const rows = this.db.all<Thing>(
      `SELECT * FROM thing WHERE id IN (${ids.map(() => '?').join(',')})`,
      ids,
    );
    const byId = new Map(rows.map((r) => [r.id, r]));
    return ids.map((id) => byId.get(id)).filter((t): t is Thing => !!t);
  }

  reindex(): number {
    return reindexAll(this.db, this.registry);
  }

  /**
   * The denormalised document the in-memory evaluator works against. Also what
   * a smart collection preview and the conformance vectors use.
   */
  buildDoc(thing: Thing): ThingDoc {
    const fields = this.fields.forThing(thing.id);
    const tags = this.tags.forThing(thing.id).map((t) => t.name);
    const collections = this.collections.collectionsOf(thing.id).map((c) => c.name);
    const text: string[] = [];
    const markers = new Set<string>();
    const devices = new Set<string>();
    let maxSize = 0;
    let missing = false;

    for (const f of fields) {
      text.push(f.label);
      const marker = this.registry.markerFor(f.variant);
      if (marker) markers.add(marker);
      if (f.is_secret) {
        markers.add('has:secret');
        continue;
      }
      if (f.kind === 'url' && f.value_text) markers.add('has:url');
      if (f.kind === 'path') markers.add('has:path');
      if (f.kind === 'richText') markers.add('has:note');
      if (f.kind === 'attachment') markers.add('has:file');
      if (f.kind === 'relation') markers.add('has:relation');
      if (f.value_text) text.push(f.value_text);
      if (f.value_json) text.push(stripJson(f.value_json));
      if (f.object_hash) {
        const o = this.objects.row(f.object_hash);
        if (o) maxSize = Math.max(maxSize, o.byte_size);
      }
      if (f.file_ref_id) {
        const ref = this.fileRefs.get(f.file_ref_id);
        if (ref) {
          text.push(ref.path);
          if (ref.status === 'missing') missing = true;
          const dev = this.devices.get(ref.device_id);
          if (dev) devices.add(dev.name);
        }
      }
    }
    if (tags.length) markers.add('has:tag');

    const conflict = this.db.get<{ n: number }>(
      `SELECT COUNT(*) AS n FROM conflict
        WHERE resolved_at IS NULL AND (entity_id = ? OR entity_id IN (SELECT id FROM field WHERE thing_id = ?))`,
      [thing.id, thing.id],
    );

    return {
      id: thing.id,
      title: thing.title,
      text,
      tags,
      collections,
      markers: [...markers],
      devices: [...devices],
      created_at: thing.created_at,
      updated_at: thing.updated_at,
      is_pinned: !!thing.is_pinned,
      is_locked: !!thing.is_locked,
      is_archived: !!thing.is_archived,
      is_template: !!thing.is_template,
      is_trashed: !!thing.deleted_at,
      has_missing_file: missing,
      has_conflict: (conflict?.n ?? 0) > 0,
      max_object_size: maxSize,
    };
  }

  // ── templates ─────────────────────────────────────────────────────────────

  /**
   * A Template is a Thing with `is_template = 1`. "New from Template" deep
   * copies sections and fields with empty values — no separate editor, no
   * second schema. docs/01-DATA-MODEL.md §8.
   */
  newFromTemplate(templateId: string, title: string): Thing {
    // Registry templates (seeded, id = 'account', 'server', …)
    const def = this.registry.template(templateId);
    if (def) {
      return this.db.transaction(() => {
        const thing = this.things.create({ title, iconJson: JSON.stringify({ type: 'symbol', value: def.symbol }) });
        for (const s of def.sections) {
          const section = s.title === null ? null : this.sections.create(thing.id, s.title);
          for (const f of s.fields) {
            this.fields.create({
              thingId: thing.id,
              sectionId: section?.id ?? null,
              variant: f.variant,
              label: f.label,
            });
          }
        }
        return thing;
      });
    }

    // User templates: a real Thing with is_template = 1.
    const source = this.things.get(templateId);
    if (!source) throw new Error(`unknown template: ${templateId}`);
    return this.duplicate(source.id, title, { blankValues: true, asTemplate: false });
  }

  saveAsTemplate(thingId: string, name: string): Thing {
    return this.duplicate(thingId, name, { blankValues: true, asTemplate: true });
  }

  duplicate(
    thingId: string,
    title: string,
    opts: { blankValues?: boolean; asTemplate?: boolean } = {},
  ): Thing {
    const source = this.things.get(thingId);
    if (!source) throw new Error('no such Thing');
    return this.db.transaction(() => {
      const copy = this.things.create({
        title,
        iconJson: source.icon_json,
        coverObject: source.cover_object,
        isTemplate: opts.asTemplate,
      });
      const sectionMap = new Map<string, string>();
      for (const s of this.sections.forThing(thingId)) {
        sectionMap.set(s.id, this.sections.create(copy.id, s.title).id);
      }
      for (const f of this.fields.forThing(thingId)) {
        const created = this.fields.create({
          thingId: copy.id,
          sectionId: f.section_id ? sectionMap.get(f.section_id) ?? null : null,
          variant: f.variant ?? this.registry.variantsOfKind(f.kind)[0]?.id ?? 'plain',
          label: f.label,
          isSecret: !!f.is_secret,
        });
        if (!opts.blankValues) this.copyValue(f, created);
      }
      if (!opts.asTemplate) {
        for (const t of this.tags.forThing(thingId)) this.tags.attach(copy.id, t.name);
      }
      return this.things.get(copy.id) as Thing;
    });
  }

  private copyValue(from: Field, to: Field): void {
    if (from.value_cipher) {
      // Re-encrypt: the AAD binds ciphertext to thing_id ‖ field_id, so a raw
      // copy would be undecryptable in its new home. That is the point.
      const plain = this.fields.revealSecret(from.id);
      this.fields.setValue(to.id, { kind: 'secret', value: plain }, { reindex: false });
      return;
    }
    if (from.value_text !== null) this.fields.setValue(to.id, { kind: 'text', value: from.value_text }, { reindex: false });
    else if (from.value_json !== null) {
      this.fields.setValue(to.id, { kind: 'json', value: JSON.parse(from.value_json) }, { reindex: false });
    } else if (from.object_hash) this.fields.setValue(to.id, { kind: 'object', hash: from.object_hash }, { reindex: false });
    else if (from.file_ref_id) this.fields.setValue(to.id, { kind: 'fileRef', id: from.file_ref_id }, { reindex: false });
  }

  // ── smart views ───────────────────────────────────────────────────────────

  /** Seed the Smart Views from the registry, once. They are editable afterwards. */
  ensureSmartViews(): number {
    let created = 0;
    for (const [i, v] of this.registry.smartViews().entries()) {
      if (this.collections.byName(v.name)) continue;
      this.collections.create({
        name: v.name,
        iconJson: JSON.stringify({ type: 'symbol', value: v.symbol }),
        isSmart: true,
        isSystem: true,
        smartQuery: v.query,
        atIndex: i,
      });
      created++;
    }
    return created;
  }
}

function stripJson(json: string): string {
  try {
    const walk = (n: unknown): string => {
      if (typeof n === 'string') return n;
      if (typeof n === 'number' || typeof n === 'boolean') return String(n);
      if (Array.isArray(n)) return n.map(walk).join(' ');
      if (n && typeof n === 'object') return Object.values(n as Record<string, unknown>).map(walk).join(' ');
      return '';
    };
    return walk(JSON.parse(json));
  } catch {
    return '';
  }
}
