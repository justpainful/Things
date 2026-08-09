import { Core, openConflicts, resolveConflict, seedDemoData } from '@things/core';
import type { Thing } from '@things/core';
import { Router, badRequest, notFound } from './router.ts';
import type { Ctx } from './router.ts';
import type { Session } from './session.ts';
import { fieldView, thingSummary, thingView } from './views.ts';
import type { ServerConfig } from './config.ts';

export interface ApiDeps {
  core: Core;
  session: Session;
  config: ServerConfig;
}

/** Routes reachable while locked. Everything else requires a bearer token. */
export const PUBLIC_ROUTES = new Set([
  'GET /api/state',
  'POST /api/session/setup',
  'POST /api/session/unlock',
  'POST /api/session/unlock-device',
]);

export function buildApi(deps: ApiDeps): Router {
  const { core, session, config } = deps;
  const r = new Router();

  const thingOr404 = (id: string): Thing => {
    const t = core.things.get(id);
    if (!t) throw notFound('No such Thing');
    return t;
  };

  // ── session ───────────────────────────────────────────────────────────────

  /** Every session response has the same shape, so the client can replace its
   *  copy wholesale without losing a field it did not ask about. */
  const fullState = () => ({
    ...session.state(),
    deviceName: core.devices.self()?.name ?? 'This PC',
    version: 1,
  });

  r.get('/api/state', (c) => c.sendJson(200, fullState()));

  r.post('/api/session/setup', async (c) => {
    const { pin } = await c.json<{ pin: string }>();
    const res = await session.setup(pin).catch((e: Error) => {
      throw badRequest(e.message);
    });
    core.ensureSmartViews();
    if (process.env.THINGS_SEED !== '0') seedDemoData(core);
    c.sendJson(200, { ...res, state: fullState() }, { 'set-cookie': session.cookieHeader });
  });

  r.post('/api/session/unlock', async (c) => {
    const { pin } = await c.json<{ pin: string }>();
    if (typeof pin !== 'string') throw badRequest('A PIN is required.');
    const res = await session.unlock(pin);
    if ('token' in res) {
      core.things.purgeExpired(config.trashRetentionDays);
      c.sendJson(200, { ...res, state: fullState() }, { 'set-cookie': session.cookieHeader });
    } else {
      c.sendJson(401, { error: 'That PIN is not right.', ...res, state: fullState() });
    }
  });

  r.post('/api/session/unlock-device', (c) => {
    const res = session.unlockWithDevice();
    if (!res) {
      c.sendJson(401, { error: 'The device wrapper is unavailable. Use your PIN.', state: fullState() });
      return;
    }
    c.sendJson(200, { ...res, state: fullState() }, { 'set-cookie': session.cookieHeader });
  });

  r.post('/api/session/lock', (c) => {
    session.lock();
    c.sendJson(200, fullState(), { 'set-cookie': session.cookieHeader });
  });

  r.post('/api/session/privacy', async (c) => {
    const { enabled } = await c.json<{ enabled: boolean }>();
    session.privacyMode = !!enabled;
    c.sendJson(200, fullState(), { 'set-cookie': session.cookieHeader });
  });

  r.post('/api/session/autolock', async (c) => {
    const { ms } = await c.json<{ ms: number }>();
    session.autoLockMs = Math.max(0, Number(ms) || 0);
    c.sendJson(200, fullState(), { 'set-cookie': session.cookieHeader });
  });

  r.post('/api/session/pin', async (c) => {
    const { currentPin, newPin } = await c.json<{ currentPin: string; newPin: string }>();
    const ok = await session.changePin(currentPin, newPin).catch((e: Error) => {
      throw badRequest(e.message);
    });
    if (!ok) throw badRequest('That current PIN is not right.');
    c.sendJson(200, { ok: true });
  });

  // ── bootstrap ─────────────────────────────────────────────────────────────

  r.get('/api/registry', (c) => c.sendJson(200, core.registry.raw));

  r.get('/api/bootstrap', (c) => {
    const collections = core.collections.list();
    c.sendJson(200, {
      device: core.devices.self(),
      collections: collections.map((col) => ({
        id: col.id,
        name: col.name,
        icon: safeJson(col.icon_json),
        isSmart: !!col.is_smart,
        isSystem: !!col.is_system,
        smartQuery: col.smart_query,
        count: col.is_smart
          ? core.search(col.smart_query ?? '', { limit: 9999 }).length
          : core.collections.countOf(col.id),
      })),
      tags: core.tags.list().map((t) => ({ id: t.id, name: t.name, color: t.color, count: t.count })),
      counts: {
        all: core.things.list({ limit: 100000 }).length,
        pinned: core.things.pinned().length,
        trash: core.things.trash().length,
        templates: core.things.templates().length,
        conflicts: openConflicts(core.ctx).length,
        objects: core.objects.totalBytes(),
      },
      templates: [
        ...core.registry.templates().map((t) => ({ id: t.id, name: t.name, symbol: t.symbol, builtin: true })),
        ...core.things.templates().map((t) => ({ id: t.id, name: t.title, symbol: 'doc.on.doc', builtin: false })),
      ],
      undo: { canUndo: core.oplog.canUndo(), canRedo: core.oplog.canRedo() },
    });
  });

  // ── things ────────────────────────────────────────────────────────────────

  r.get('/api/things', (c) => {
    const q = c.query.get('q') ?? '';
    const results = core.search(q, {
      limit: Number(c.query.get('limit') ?? 300),
      offset: Number(c.query.get('offset') ?? 0),
      collectionId: c.query.get('collection') ?? undefined,
      includeTrashed: c.query.get('trashed') === '1',
      includeArchived: c.query.get('archived') === '1',
      includeTemplates: c.query.get('templates') === '1',
    });
    c.sendJson(200, { query: q, things: results.map((t) => thingSummary(core, t)) });
  });

  r.post('/api/things', async (c) => {
    const body = await c.json<{ title?: string; templateId?: string; collectionId?: string }>();
    const title = (body.title ?? '').trim() || 'Untitled';
    const thing = body.templateId ? core.newFromTemplate(body.templateId, title) : core.things.create({ title });
    if (body.collectionId) core.collections.add(body.collectionId, thing.id);
    c.sendJson(201, thingView(core, core.things.get(thing.id)!));
  });

  r.get('/api/things/:id', (c) => {
    const t = thingOr404(c.params.id);
    c.sendJson(200, thingView(core, t));
  });

  r.patch('/api/things/:id', async (c) => {
    thingOr404(c.params.id);
    const body = await c.json<Record<string, unknown>>();
    core.things.update(c.params.id, {
      ...(typeof body.title === 'string' ? { title: body.title } : {}),
      ...(body.icon !== undefined ? { icon_json: body.icon === null ? null : JSON.stringify(body.icon) } : {}),
      ...(body.coverObject !== undefined ? { cover_object: body.coverObject as string | null } : {}),
      ...(body.isPinned !== undefined ? { is_pinned: !!body.isPinned } : {}),
      ...(body.isLocked !== undefined ? { is_locked: !!body.isLocked } : {}),
      ...(body.isArchived !== undefined ? { is_archived: !!body.isArchived } : {}),
    });
    c.sendJson(200, thingView(core, core.things.get(c.params.id)!));
  });

  r.post('/api/things/:id/view', (c) => {
    thingOr404(c.params.id);
    core.things.touch(c.params.id);
    c.sendJson(200, { ok: true });
  });

  r.delete('/api/things/:id', (c) => {
    thingOr404(c.params.id);
    core.things.trashThing(c.params.id);
    c.sendJson(200, { ok: true });
  });

  r.post('/api/things/:id/restore', (c) => {
    thingOr404(c.params.id);
    core.things.restore(c.params.id);
    c.sendJson(200, { ok: true });
  });

  r.delete('/api/things/:id/purge', (c) => {
    thingOr404(c.params.id);
    core.things.purge(c.params.id);
    core.objects.gc();
    c.sendJson(200, { ok: true });
  });

  r.post('/api/things/:id/duplicate', async (c) => {
    const t = thingOr404(c.params.id);
    const body = await c.json<{ title?: string }>();
    const copy = core.duplicate(t.id, body.title ?? `${t.title} copy`);
    c.sendJson(201, thingView(core, copy));
  });

  r.post('/api/things/:id/template', async (c) => {
    const t = thingOr404(c.params.id);
    const body = await c.json<{ name?: string }>();
    const tpl = core.saveAsTemplate(t.id, body.name ?? t.title);
    c.sendJson(201, thingView(core, tpl));
  });

  r.get('/api/things/:id/history', (c) => {
    thingOr404(c.params.id);
    const changes = core.oplog.thingHistory(c.params.id);
    c.sendJson(200, {
      days: core.oplog.groupByDay(changes).map((d) => ({
        date: d.date,
        changes: d.changes.map((ch) => ({
          id: ch.id,
          hlc: ch.hlc,
          appliedAt: ch.applied_at,
          entityType: ch.entity_type,
          entityId: ch.entity_id,
          op: ch.op,
          // Attribute NAMES only: History must never become a plaintext log.
          attrs: Object.keys(JSON.parse(ch.attrs_json) as Record<string, unknown>),
          summary: describeChange(core, ch.entity_type, ch.entity_id, ch.op, ch.attrs_json),
          canRestore: ch.prev_json !== null,
        })),
      })),
    });
  });

  r.post('/api/history/:changeId/restore', async (c) => {
    const body = await c.json<{ mode?: 'before' | 'after' }>();
    const applied = core.oplog.restore(c.params.changeId, body.mode ?? 'before');
    if (!applied) throw notFound('No such change');
    c.sendJson(200, { ok: true });
  });

  r.post('/api/undo', (c) => {
    const ch = core.oplog.undo();
    c.sendJson(200, { applied: !!ch, canUndo: core.oplog.canUndo(), canRedo: core.oplog.canRedo() });
  });

  r.post('/api/redo', (c) => {
    const ch = core.oplog.redo();
    c.sendJson(200, { applied: !!ch, canUndo: core.oplog.canUndo(), canRedo: core.oplog.canRedo() });
  });

  // ── sections ──────────────────────────────────────────────────────────────

  r.post('/api/things/:id/sections', async (c) => {
    thingOr404(c.params.id);
    const body = await c.json<{ title?: string | null; index?: number }>();
    const s = core.sections.create(c.params.id, body.title ?? null, body.index);
    c.sendJson(201, { id: s.id, title: s.title, sortOrder: s.sort_order });
  });

  r.patch('/api/sections/:id', async (c) => {
    const body = await c.json<{ title?: string | null; index?: number }>();
    if (body.title !== undefined) core.sections.rename(c.params.id, body.title);
    if (body.index !== undefined) core.sections.move(c.params.id, body.index);
    const s = core.sections.get(c.params.id);
    if (!s) throw notFound('No such section');
    c.sendJson(200, { id: s.id, title: s.title, sortOrder: s.sort_order });
  });

  r.delete('/api/sections/:id', (c) => {
    core.sections.remove(c.params.id);
    c.sendJson(200, { ok: true });
  });

  // ── fields ────────────────────────────────────────────────────────────────

  r.post('/api/things/:id/fields', async (c) => {
    thingOr404(c.params.id);
    const body = await c.json<{
      variant: string;
      label?: string;
      sectionId?: string | null;
      index?: number;
      value?: unknown;
    }>();
    if (!core.registry.variant(body.variant)) throw badRequest(`Unknown field type: ${body.variant}`);
    const f = core.fields.create({
      thingId: c.params.id,
      variant: body.variant,
      label: body.label,
      sectionId: body.sectionId ?? null,
      atIndex: body.index,
    });
    if (body.value !== undefined && body.value !== null) applyValue(core, f.id, body.value);
    c.sendJson(201, fieldView(core, core.fields.get(f.id)!));
  });

  r.patch('/api/fields/:id', async (c) => {
    const existing = core.fields.get(c.params.id);
    if (!existing) throw notFound('No such field');
    const body = await c.json<{
      label?: string;
      variant?: string;
      value?: unknown;
      sectionId?: string | null;
      index?: number;
    }>();
    if (body.label !== undefined) core.fields.rename(c.params.id, body.label);
    if (body.variant !== undefined) core.fields.setVariant(c.params.id, body.variant);
    if (body.value !== undefined) applyValue(core, c.params.id, body.value);
    if (body.sectionId !== undefined || body.index !== undefined) {
      core.fields.moveToSection(
        c.params.id,
        body.sectionId !== undefined ? body.sectionId : existing.section_id,
        body.index,
      );
    }
    c.sendJson(200, fieldView(core, core.fields.get(c.params.id)!));
  });

  r.delete('/api/fields/:id', (c) => {
    core.fields.remove(c.params.id);
    c.sendJson(200, { ok: true });
  });

  /**
   * The one endpoint that returns a secret, and only for one field at a time.
   * No-store so it never lands in a disk cache.
   */
  r.post('/api/fields/:id/reveal', (c) => {
    const f = core.fields.get(c.params.id);
    if (!f) throw notFound('No such field');
    if (!f.is_secret) throw badRequest('That field is not a secret.');
    c.send(200, JSON.stringify({ value: core.fields.revealSecret(c.params.id) }), {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    });
  });

  // ── collections & tags ────────────────────────────────────────────────────

  r.get('/api/collections', (c) => {
    c.sendJson(
      200,
      core.collections.list().map((col) => ({
        id: col.id,
        name: col.name,
        icon: safeJson(col.icon_json),
        isSmart: !!col.is_smart,
        isSystem: !!col.is_system,
        smartQuery: col.smart_query,
        count: col.is_smart ? core.search(col.smart_query ?? '', { limit: 9999 }).length : core.collections.countOf(col.id),
      })),
    );
  });

  r.post('/api/collections', async (c) => {
    const body = await c.json<{ name: string; smartQuery?: string; icon?: unknown }>();
    if (!body.name?.trim()) throw badRequest('A collection needs a name.');
    const col = core.collections.create({
      name: body.name.trim(),
      iconJson: body.icon ? JSON.stringify(body.icon) : null,
      isSmart: !!body.smartQuery,
      smartQuery: body.smartQuery ?? null,
    });
    c.sendJson(201, { id: col.id, name: col.name });
  });

  r.patch('/api/collections/:id', async (c) => {
    const body = await c.json<{ name?: string; smartQuery?: string; icon?: unknown }>();
    core.collections.update(c.params.id, {
      ...(body.name !== undefined ? { name: body.name } : {}),
      ...(body.smartQuery !== undefined ? { smart_query: body.smartQuery } : {}),
      ...(body.icon !== undefined ? { icon_json: body.icon ? JSON.stringify(body.icon) : null } : {}),
    });
    c.sendJson(200, { ok: true });
  });

  r.delete('/api/collections/:id', (c) => {
    core.collections.remove(c.params.id);
    c.sendJson(200, { ok: true });
  });

  r.post('/api/collections/:id/members', async (c) => {
    const body = await c.json<{ thingId?: string; thingIds?: string[] }>();
    const ids = body.thingIds ?? (body.thingId ? [body.thingId] : []);
    for (const id of ids) core.collections.add(c.params.id, id);
    c.sendJson(200, { ok: true, added: ids.length });
  });

  r.delete('/api/collections/:id/members/:thingId', (c) => {
    core.collections.removeMember(c.params.id, c.params.thingId);
    c.sendJson(200, { ok: true });
  });

  r.get('/api/tags', (c) => c.sendJson(200, core.tags.list()));

  r.post('/api/things/:id/tags', async (c) => {
    thingOr404(c.params.id);
    const body = await c.json<{ name: string }>();
    if (!body.name?.trim()) throw badRequest('A tag needs a name.');
    const tag = core.tags.attach(c.params.id, body.name.trim());
    c.sendJson(201, { id: tag.id, name: tag.name });
  });

  r.delete('/api/things/:id/tags/:tagId', (c) => {
    core.tags.detach(c.params.id, c.params.tagId);
    c.sendJson(200, { ok: true });
  });

  // ── search ────────────────────────────────────────────────────────────────

  r.get('/api/search', (c) => {
    const q = c.query.get('q') ?? '';
    const results = core.search(q, { limit: Number(c.query.get('limit') ?? 100) });
    c.sendJson(200, {
      query: q,
      things: results.map((t) => thingSummary(core, t)),
      suggestions: {
        tags: core.tags.list().slice(0, 20).map((t) => t.name),
        collections: core.collections.list().map((col) => col.name),
        markers: [...new Set(core.registry.variants().map((v) => v.marker).filter(Boolean))],
      },
    });
  });

  // ── objects ───────────────────────────────────────────────────────────────

  r.post('/api/objects', async (c) => {
    const bytes = await c.body();
    if (bytes.length === 0) throw badRequest('Empty upload');
    const put = core.objects.put(bytes, {
      mimeType: c.query.get('mime') || c.req.headers['content-type'] || null,
    });
    c.sendJson(201, { hash: put.hash, byteSize: put.byteSize, deduped: put.deduped });
  });

  r.get('/api/objects/:hash', (c) => {
    const row = core.objects.row(c.params.hash);
    if (!row) throw notFound('No such file');
    const type = row.mime_type ?? 'application/octet-stream';

    const range = c.req.headers.range;
    if (range) {
      const m = /bytes=(\d*)-(\d*)/.exec(range);
      if (m) {
        const start = m[1] ? parseInt(m[1], 10) : 0;
        const end = m[2] ? parseInt(m[2], 10) : row.byte_size - 1;
        const length = Math.min(end, row.byte_size - 1) - start + 1;
        // Framed encryption is what makes this cheap: seeking a video does not
        // decrypt the whole file.
        const chunk = core.objects.readRange(c.params.hash, start, length);
        c.sendBytes(206, chunk, type, {
          'content-range': `bytes ${start}-${start + chunk.length - 1}/${row.byte_size}`,
          'accept-ranges': 'bytes',
          'cache-control': 'private, no-store',
        });
        return;
      }
    }
    c.sendBytes(200, core.objects.read(c.params.hash), type, {
      'accept-ranges': 'bytes',
      'cache-control': 'private, no-store',
      'content-disposition': `inline; filename="${c.params.hash.slice(0, 12)}"`,
    });
  });

  /**
   * Thumbnails.
   *
   * DEVIATION, documented: the plan's `thumbnail` table assumes a downscaled
   * copy. Generating one needs an image decoder, and this project forbids
   * native modules and CDN dependencies. Since every byte is local and the
   * browser scales images for free, the endpoint serves the original and the
   * client renders it into a fixed box. The table stays in the schema for the
   * iOS side, which has ImageIO.
   */
  r.get('/api/objects/:hash/thumbnail', (c) => {
    const row = core.objects.row(c.params.hash);
    if (!row) throw notFound('No such file');
    c.sendBytes(200, core.objects.read(c.params.hash), row.mime_type ?? 'application/octet-stream', {
      'cache-control': 'private, no-store',
    });
  });

  r.get('/api/gallery', (c) => {
    const things = core.search(c.query.get('q') ?? 'type:image', { limit: 500 });
    const items: unknown[] = [];
    for (const t of things) {
      if (t.is_locked) continue;
      for (const f of core.fields.forThing(t.id)) {
        if (!f.object_hash) continue;
        const o = core.objects.row(f.object_hash);
        if (!o) continue;
        items.push({
          fieldId: f.id,
          thingId: t.id,
          thingTitle: t.title,
          label: f.label,
          hash: o.hash,
          byteSize: o.byte_size,
          mimeType: o.mime_type,
          width: o.width,
          height: o.height,
          updatedAt: f.updated_at,
        });
      }
    }
    c.sendJson(200, { items });
  });

  // ── import ────────────────────────────────────────────────────────────────

  /**
   * Drag-and-drop import. The client uploads bytes first (dedupe happens
   * there), then calls this with the manifest and a mode:
   *
   *   'perFile'  → 50 files become 50 Things
   *   'single'   → 50 files become 50 attachment fields on one Thing
   */
  r.post('/api/import', async (c) => {
    const body = await c.json<{
      mode: 'perFile' | 'single';
      thingId?: string;
      title?: string;
      collectionId?: string;
      files: { hash: string; filename: string; mime?: string | null }[];
    }>();
    if (!Array.isArray(body.files) || body.files.length === 0) throw badRequest('Nothing to import.');

    const created: string[] = [];
    core.db.transaction(() => {
      if (body.mode === 'single') {
        const target = body.thingId
          ? thingOr404(body.thingId)
          : core.things.create({ title: body.title?.trim() || 'Imported Files' });
        for (const f of body.files) attach(core, target.id, f);
        created.push(target.id);
        if (body.collectionId) core.collections.add(body.collectionId, target.id);
      } else {
        for (const f of body.files) {
          const t = core.things.create({ title: stripExtension(f.filename) });
          attach(core, t.id, f);
          if (body.collectionId) core.collections.add(body.collectionId, t.id);
          created.push(t.id);
        }
      }
    });
    c.sendJson(201, { created, things: created.map((id) => thingSummary(core, core.things.get(id)!)) });
  });

  // ── batch ─────────────────────────────────────────────────────────────────

  r.post('/api/batch', async (c) => {
    const body = await c.json<{
      ids: string[];
      op: 'pin' | 'unpin' | 'trash' | 'restore' | 'archive' | 'unarchive' | 'tag' | 'untag' | 'collect' | 'lock' | 'unlock';
      value?: string;
    }>();
    const ids = body.ids ?? [];
    core.db.transaction(() => {
      for (const id of ids) {
        switch (body.op) {
          case 'pin':
            core.things.update(id, { is_pinned: true });
            break;
          case 'unpin':
            core.things.update(id, { is_pinned: false });
            break;
          case 'lock':
            core.things.update(id, { is_locked: true });
            break;
          case 'unlock':
            core.things.update(id, { is_locked: false });
            break;
          case 'archive':
            core.things.update(id, { is_archived: true });
            break;
          case 'unarchive':
            core.things.update(id, { is_archived: false });
            break;
          case 'trash':
            core.things.trashThing(id);
            break;
          case 'restore':
            core.things.restore(id);
            break;
          case 'tag':
            if (body.value) core.tags.attach(id, body.value);
            break;
          case 'untag':
            if (body.value) {
              const tag = core.tags.byName(body.value);
              if (tag) core.tags.detach(id, tag.id);
            }
            break;
          case 'collect':
            if (body.value) core.collections.add(body.value, id);
            break;
        }
      }
    });
    c.sendJson(200, { ok: true, count: ids.length });
  });

  // ── trash, templates, conflicts, maintenance ──────────────────────────────

  r.get('/api/trash', (c) => {
    c.sendJson(200, {
      retentionDays: config.trashRetentionDays,
      things: core.things.trash().map((t) => thingSummary(core, t)),
    });
  });

  r.post('/api/trash/empty', (c) => {
    const ids = core.things.trash().map((t) => t.id);
    for (const id of ids) core.things.purge(id);
    const gc = core.objects.gc();
    c.sendJson(200, { purged: ids.length, filesRemoved: gc.removed });
  });

  r.get('/api/templates', (c) => {
    c.sendJson(200, [
      ...core.registry.templates().map((t) => ({ id: t.id, name: t.name, symbol: t.symbol, builtin: true })),
      ...core.things.templates().map((t) => ({ id: t.id, name: t.title, symbol: 'doc.on.doc', builtin: false })),
    ]);
  });

  r.get('/api/conflicts', (c) => {
    c.sendJson(
      200,
      openConflicts(core.ctx).map((cf) => ({
        id: cf.id,
        entityType: cf.entity_type,
        entityId: cf.entity_id,
        detectedAt: cf.detected_at,
        a: safeJson(cf.version_a_json),
        b: safeJson(cf.version_b_json),
      })),
    );
  });

  r.post('/api/conflicts/:id/resolve', async (c) => {
    const body = await c.json<{ resolution: 'a' | 'b' | 'both' | 'manual' }>();
    const ok = resolveConflict(core.ctx, c.params.id, body.resolution);
    if (!ok) throw notFound('No such open conflict');
    c.sendJson(200, { ok: true });
  });

  r.get('/api/missing-files', (c) => {
    c.sendJson(200, core.fileRefs.missing());
  });

  r.post('/api/maintenance/rescan', (c) => {
    const res = core.fileRefs.refreshLocal();
    core.reindex();
    c.sendJson(200, res);
  });

  r.post('/api/maintenance/gc', (c) => c.sendJson(200, core.objects.gc()));

  return r;
}

// ── helpers ─────────────────────────────────────────────────────────────────

function applyValue(core: Core, fieldId: string, value: unknown): void {
  const f = core.fields.get(fieldId);
  if (!f) throw notFound('No such field');

  if (value === null) {
    core.fields.setValue(fieldId, { kind: 'empty' });
    return;
  }
  if (typeof value === 'object') {
    const v = value as Record<string, unknown>;
    if (typeof v.objectHash === 'string') {
      core.fields.setValue(fieldId, { kind: 'object', hash: v.objectHash });
      return;
    }
    if (typeof v.path === 'string') {
      const ref = core.fileRefs.create({ path: v.path, isDirectory: !!v.isDirectory });
      core.fields.setValue(fieldId, { kind: 'fileRef', id: ref.id });
      return;
    }
    if ('json' in v) {
      core.fields.setValue(fieldId, { kind: 'json', value: v.json });
      return;
    }
    if (typeof v.secret === 'string') {
      core.fields.setValue(fieldId, { kind: 'secret', value: v.secret });
      return;
    }
    if (typeof v.text === 'string') {
      core.fields.setValue(fieldId, { kind: 'text', value: v.text });
      return;
    }
    core.fields.setValue(fieldId, { kind: 'json', value: v });
    return;
  }
  const text = String(value);
  if (f.is_secret) core.fields.setValue(fieldId, { kind: 'secret', value: text });
  else core.fields.setValue(fieldId, { kind: 'text', value: text });
}

function attach(core: Core, thingId: string, file: { hash: string; filename: string; mime?: string | null }): void {
  const variant = variantForMime(file.mime ?? null, file.filename);
  const f = core.fields.create({ thingId, variant, label: file.filename });
  core.fields.setValue(f.id, { kind: 'object', hash: file.hash });
  // The original filename belongs to the FIELD, not the object: the same PNG
  // can be logo.png in one Thing and avatar.png in another.
  core.db.run('UPDATE field SET value_json = NULL WHERE id = ?', [f.id]);
}

function variantForMime(mime: string | null, filename: string): string {
  const m = (mime ?? '').toLowerCase();
  const ext = filename.split('.').pop()?.toLowerCase() ?? '';
  if (m.startsWith('image/') || ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'avif'].includes(ext)) return 'image';
  if (m.startsWith('video/') || ['mp4', 'mov', 'mkv', 'webm'].includes(ext)) return 'video';
  if (m.startsWith('audio/') || ['mp3', 'wav', 'flac', 'm4a'].includes(ext)) return 'audio';
  if (m === 'application/pdf' || ext === 'pdf') return 'pdf';
  return 'attachment';
}

function stripExtension(name: string): string {
  const base = name.replace(/^.*[\\/]/, '');
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(0, dot) : base;
}

function describeChange(
  core: Core,
  entityType: string,
  entityId: string,
  op: string,
  attrsJson: string,
): string {
  const attrs = Object.keys(JSON.parse(attrsJson) as Record<string, unknown>).filter(
    (k) => k !== 'updated_at' && k !== 'version_vector',
  );
  const label =
    entityType === 'field'
      ? core.fields.get(entityId)?.label ?? 'a field'
      : entityType === 'section'
        ? core.sections.get(entityId)?.title ?? 'a section'
        : 'this Thing';

  if (op === 'create') return `Added ${label}`;
  if (op === 'delete') return `Removed ${label}`;
  if (attrs.length === 1 && attrs[0] === 'deleted_at') return 'Moved to Recently Deleted';
  if (attrs.includes('sort_order')) return `Reordered ${label}`;
  if (attrs.includes('value_cipher')) return `Changed ${label}`;
  if (attrs.includes('title')) return 'Renamed';
  return `Changed ${label}`;
}

function safeJson(s: string | null): unknown {
  if (!s) return null;
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}
