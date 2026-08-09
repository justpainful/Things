import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer } from '../src/server.ts';
import type { ThingsServer } from '../src/server.ts';

const PIN = '135790';
const dirs: string[] = [];

let s: ThingsServer;
let token = '';

function url(path: string): string {
  return `http://127.0.0.1:${s.port}${path}`;
}

async function api<T = any>(
  method: string,
  path: string,
  body?: unknown,
  opts: { raw?: boolean; auth?: boolean } = {},
): Promise<{ status: number; data: T }> {
  const headers: Record<string, string> = {};
  if (opts.auth !== false && token) headers.authorization = `Bearer ${token}`;
  let payload: string | Uint8Array | undefined;
  if (body instanceof Uint8Array) {
    payload = body;
    headers['content-type'] = 'application/octet-stream';
  } else if (body !== undefined) {
    payload = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }
  const res = await fetch(url(path), { method, headers, body: payload });
  const text = await res.text();
  return { status: res.status, data: (text ? JSON.parse(text) : null) as T };
}

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'things-api-'));
  dirs.push(dir);
  process.env.THINGS_SEED = '0';
  s = await startServer({
    port: 0,
    startSync: false,
    forceFallbackDeviceSecret: true,
    config: { dataDir: dir, autoLockMs: 0 },
  });
});

after(async () => {
  await s.close();
  for (const d of dirs) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      /* sqlite handle */
    }
  }
});

describe('session', () => {
  test('starts unprovisioned and refuses every private route', async () => {
    const state = await api('GET', '/api/state', undefined, { auth: false });
    assert.equal(state.status, 200);
    assert.equal(state.data.provisioned, false);
    assert.equal(state.data.locked, true);

    const denied = await api('GET', '/api/things', undefined, { auth: false });
    assert.equal(denied.status, 423, 'locked, not merely unauthorized');
  });

  test('rejects a short PIN', async () => {
    const res = await api('POST', '/api/session/setup', { pin: '123' }, { auth: false });
    assert.equal(res.status, 400);
    assert.match(res.data.error, /at least 6 digits/);
  });

  test('sets up, issues a token, and unlocks', async () => {
    const setup = await api('POST', '/api/session/setup', { pin: PIN }, { auth: false });
    assert.equal(setup.status, 200);
    assert.ok(setup.data.token);
    token = setup.data.token;

    const ok = await api('GET', '/api/bootstrap');
    assert.equal(ok.status, 200);
    assert.ok(Array.isArray(ok.data.collections));
  });

  test('a wrong PIN is refused with an escalating delay, and never wipes', async () => {
    await api('POST', '/api/session/lock');
    const bad = await api('POST', '/api/session/unlock', { pin: '999999' }, { auth: false });
    assert.equal(bad.status, 401);
    assert.ok(bad.data.retryAfterMs >= 0);

    // The library is still there afterwards.
    const good = await api('POST', '/api/session/unlock', { pin: PIN }, { auth: false });
    if (good.status === 401) {
      // the delay ladder is active; wait it out
      await new Promise((r) => setTimeout(r, good.data.retryAfterMs + 50));
      const retry = await api('POST', '/api/session/unlock', { pin: PIN }, { auth: false });
      assert.equal(retry.status, 200);
      token = retry.data.token;
    } else {
      assert.equal(good.status, 200);
      token = good.data.token;
    }
  });

  test('a stale token stops working after a lock', async () => {
    const stale = token;
    await api('POST', '/api/session/lock');
    const res = await fetch(url('/api/things'), { headers: { authorization: `Bearer ${stale}` } });
    assert.equal(res.status, 423);
    const again = await api('POST', '/api/session/unlock', { pin: PIN }, { auth: false });
    token = again.data.token;
  });

  test('privacy mode is a display state and says so', async () => {
    const res = await api('POST', '/api/session/privacy', { enabled: true });
    assert.equal(res.data.privacyMode, true);
    await api('POST', '/api/session/privacy', { enabled: false });
  });
});

describe('things, fields and search over HTTP', () => {
  let thingId = '';
  let secretFieldId = '';

  test('creates a Thing', async () => {
    const res = await api('POST', '/api/things', { title: 'Example Registrar' });
    assert.equal(res.status, 201);
    thingId = res.data.id;
    assert.equal(res.data.title, 'Example Registrar');
    assert.deepEqual(res.data.fields, []);
  });

  test('creates it from a registry template', async () => {
    const res = await api('POST', '/api/things', { title: 'New Account', templateId: 'account' });
    assert.equal(res.status, 201);
    assert.deepEqual(res.data.fields.map((f: any) => f.label), ['Email', 'Username', 'Password', 'Website', 'Notes']);
    assert.equal(res.data.fields[2].isSecret, true, 'the Password field is secret by default');
  });

  test('adds fields, including a secret whose value never comes back', async () => {
    const plain = await api('POST', `/api/things/${thingId}/fields`, {
      variant: 'email',
      label: 'Email',
      value: 'demo.user@example.com',
    });
    assert.equal(plain.status, 201);
    assert.equal(plain.data.text, 'demo.user@example.com');
    assert.equal(plain.data.symbol, 'envelope');
    assert.deepEqual(plain.data.actions, ['copy', 'sendEmail']);

    const secret = await api('POST', `/api/things/${thingId}/fields`, {
      variant: 'password',
      label: 'Main account password',
      value: { secret: 'not-a-real-password' },
    });
    assert.equal(secret.status, 201);
    secretFieldId = secret.data.id;
    assert.equal(secret.data.isSecret, true);
    assert.equal(secret.data.hasValue, true);
    assert.equal(secret.data.text, null, 'a secret value must never be in a list response');

    const detail = await api('GET', `/api/things/${thingId}`);
    assert.equal(JSON.stringify(detail.data).includes('not-a-real-password'), false);
  });

  test('reveal is a separate, explicit request marked no-store', async () => {
    const res = await fetch(url(`/api/fields/${secretFieldId}/reveal`), {
      method: 'POST',
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(((await res.json()) as { value: string }).value, 'not-a-real-password');
  });

  test('rejects an unknown field type', async () => {
    const res = await api('POST', `/api/things/${thingId}/fields`, { variant: 'quantum-flux' });
    assert.equal(res.status, 400);
  });

  test('search finds the label and the marker but not the value', async () => {
    const byLabel = await api('GET', '/api/search?q=' + encodeURIComponent('"Main account password"'));
    assert.equal(byLabel.data.things.length, 1);

    const byMarker = await api('GET', '/api/search?q=has:password');
    assert.ok(byMarker.data.things.some((t: any) => t.id === thingId));

    const byValue = await api('GET', '/api/search?q=not-a-real-password');
    assert.equal(byValue.data.things.length, 0, 'the secret VALUE is unfindable');
  });

  test('sections and one-row reordering', async () => {
    const s1 = await api('POST', `/api/things/${thingId}/sections`, { title: 'Links' });
    assert.equal(s1.status, 201);
    const f = await api('POST', `/api/things/${thingId}/fields`, {
      variant: 'website',
      label: 'Website',
      sectionId: s1.data.id,
      value: 'https://registrar.example/',
    });
    assert.equal(f.data.sectionId, s1.data.id);

    const moved = await api('PATCH', `/api/fields/${f.data.id}`, { sectionId: null, index: 0 });
    assert.equal(moved.data.sectionId, null);
  });

  test('tags and collections', async () => {
    const tag = await api('POST', `/api/things/${thingId}/tags`, { name: 'infrastructure' });
    assert.equal(tag.status, 201);
    const col = await api('POST', '/api/collections', { name: 'Development' });
    await api('POST', `/api/collections/${col.data.id}/members`, { thingId });

    const found = await api('GET', '/api/things?q=' + encodeURIComponent('tag:infrastructure collection:Development'));
    assert.equal(found.data.things.length, 1);
  });

  test('history, undo and redo', async () => {
    await api('PATCH', `/api/things/${thingId}`, { title: 'Renamed Registrar' });
    const hist = await api('GET', `/api/things/${thingId}/history`);
    assert.ok(hist.data.days.length >= 1);
    const flat = hist.data.days.flatMap((d: any) => d.changes);
    assert.ok(flat.some((c: any) => c.summary === 'Renamed'));
    assert.equal(
      JSON.stringify(hist.data).includes('not-a-real-password'),
      false,
      'History must never carry a plaintext value',
    );

    const undo = await api('POST', '/api/undo');
    assert.equal(undo.data.applied, true);
    assert.equal((await api('GET', `/api/things/${thingId}`)).data.title, 'Example Registrar');

    await api('POST', '/api/redo');
    assert.equal((await api('GET', `/api/things/${thingId}`)).data.title, 'Renamed Registrar');
  });

  test('a locked Thing shows no preview in list rows', async () => {
    const t = await api('POST', '/api/things', { title: 'Private Records' });
    await api('POST', `/api/things/${t.data.id}/fields`, { variant: 'plain', label: 'Detail', value: 'sensitive' });
    await api('PATCH', `/api/things/${t.data.id}`, { isLocked: true });

    const list = await api('GET', '/api/things?q=is:locked');
    const row = list.data.things.find((x: any) => x.id === t.data.id);
    assert.ok(row);
    assert.equal(row.subtitle, '', 'a locked Thing must not leak content into a preview');
    assert.deepEqual(row.markers, []);
    assert.equal((await api('GET', '/api/things?q=sensitive')).data.things.length, 0);
  });

  test('trash, restore and purge', async () => {
    const t = await api('POST', '/api/things', { title: 'Temporary' });
    await api('DELETE', `/api/things/${t.data.id}`);
    assert.ok((await api('GET', '/api/trash')).data.things.some((x: any) => x.id === t.data.id));
    await api('POST', `/api/things/${t.data.id}/restore`);
    assert.equal((await api('GET', '/api/trash')).data.things.some((x: any) => x.id === t.data.id), false);
    await api('DELETE', `/api/things/${t.data.id}`);
    await api('DELETE', `/api/things/${t.data.id}/purge`);
    assert.equal((await api('GET', `/api/things/${t.data.id}`)).status, 404);
  });

  test('batch operations', async () => {
    const a = await api('POST', '/api/things', { title: 'Batch A' });
    const b = await api('POST', '/api/things', { title: 'Batch B' });
    const res = await api('POST', '/api/batch', { ids: [a.data.id, b.data.id], op: 'pin' });
    assert.equal(res.data.count, 2);
    const pinned = await api('GET', '/api/things?q=is:pinned');
    assert.ok(pinned.data.things.length >= 2);
  });
});

describe('objects and import', () => {
  test('uploads, dedupes, serves and range-reads', async () => {
    const bytes = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>');
    const up = await api('POST', '/api/objects?mime=image/svg%2Bxml', bytes);
    assert.equal(up.status, 201);
    assert.equal(up.data.deduped, false);

    const again = await api('POST', '/api/objects?mime=image/svg%2Bxml', bytes);
    assert.equal(again.data.hash, up.data.hash);
    assert.equal(again.data.deduped, true, 'content addressing dedupes on insert');

    const get = await fetch(url(`/api/objects/${up.data.hash}`), {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(get.status, 200);
    assert.equal(get.headers.get('cache-control'), 'private, no-store');
    assert.deepEqual(Buffer.from(await get.arrayBuffer()), bytes);

    const ranged = await fetch(url(`/api/objects/${up.data.hash}`), {
      headers: { authorization: `Bearer ${token}`, range: 'bytes=0-4' },
    });
    assert.equal(ranged.status, 206);
    assert.equal(Buffer.from(await ranged.arrayBuffer()).toString(), '<svg ');
  });

  test('import creates one Thing per file, or one Thing for all of them', async () => {
    const files = [];
    for (const name of ['alpha.svg', 'beta.svg', 'gamma.svg']) {
      const up = await api('POST', '/api/objects?mime=image/svg%2Bxml', Buffer.from(`<svg id="${name}"/>`));
      files.push({ hash: up.data.hash, filename: name, mime: 'image/svg+xml' });
    }

    const perFile = await api('POST', '/api/import', { mode: 'perFile', files });
    assert.equal(perFile.status, 201);
    assert.equal(perFile.data.created.length, 3);
    assert.deepEqual(perFile.data.things.map((t: any) => t.title), ['alpha', 'beta', 'gamma']);

    const single = await api('POST', '/api/import', { mode: 'single', title: 'Imported Set', files });
    assert.equal(single.data.created.length, 1);
    const detail = await api('GET', `/api/things/${single.data.created[0]}`);
    assert.equal(detail.data.fields.length, 3);
    assert.equal(detail.data.fields[0].variant, 'image');
  });

  test('object bytes accept the scoped cookie, and nothing else does', async () => {
    const up = await api('POST', '/api/objects?mime=text/plain', Buffer.from('cookie scope test'));
    const hash = up.data.hash;
    const cookie = `things_objects=${token}`;

    // No credentials at all.
    const bare = await fetch(url(`/api/objects/${hash}`));
    assert.ok(bare.status === 401 || bare.status === 423, 'unauthenticated object reads are refused');

    // The cookie alone is enough for a GET under /api/objects — that is what
    // makes <img src> work without a header.
    const viaCookie = await fetch(url(`/api/objects/${hash}`), { headers: { cookie } });
    assert.equal(viaCookie.status, 200);
    assert.equal(Buffer.from(await viaCookie.arrayBuffer()).toString(), 'cookie scope test');

    // …and it is enough for nothing else.
    const elsewhere = await fetch(url('/api/things'), { headers: { cookie } });
    assert.ok(elsewhere.status === 401 || elsewhere.status === 423, 'the cookie must not authorise other reads');

    const write = await fetch(url('/api/objects'), { method: 'POST', headers: { cookie }, body: 'x' });
    assert.ok(write.status === 401 || write.status === 423, 'the cookie must not authorise writes');
  });

  test('the gallery lists every attached image', async () => {
    const res = await api('GET', '/api/gallery');
    assert.ok(res.data.items.length >= 3);
    assert.ok(res.data.items.every((i: any) => typeof i.hash === 'string'));
  });
});

describe('registry and bootstrap', () => {
  test('serves field-kinds.json as data', async () => {
    const res = await api('GET', '/api/registry');
    assert.equal(res.status, 200);
    assert.ok(res.data.variants.length > 30);
    assert.ok(res.data.kinds.secret.alwaysSecret);
  });

  test('bootstrap carries the sidebar', async () => {
    const res = await api('GET', '/api/bootstrap');
    assert.ok(res.data.collections.some((c: any) => c.isSmart));
    assert.ok(res.data.templates.some((t: any) => t.id === 'account'));
    assert.ok(typeof res.data.counts.all === 'number');
  });

  test('an unknown endpoint 404s as JSON', async () => {
    const res = await api('GET', '/api/nope');
    assert.equal(res.status, 404);
    assert.ok(res.data.error);
  });
});
