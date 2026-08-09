import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { SCHEMA_VERSION, currentVersion, migrate } from '../src/db.ts';
import { specDir } from '../src/paths.ts';
import { registry } from '../src/registry.ts';
import { seedDemoData } from '../src/seed.ts';
import { fieldAad } from '../src/crypto/envelope.ts';
import { cleanup, makeCore } from './helpers.ts';
import type { Field } from '../src/types.ts';

after(cleanup);

describe('schema', () => {
  test('is created from spec/schema.sql verbatim and records its version', async () => {
    const core = await makeCore();
    assert.equal(currentVersion(core.db), SCHEMA_VERSION);

    // Every CREATE TABLE in the spec must exist in the database.
    const ddl = readFileSync(join(specDir(), 'schema.sql'), 'utf8');
    const declared = [...ddl.matchAll(/CREATE (?:VIRTUAL )?TABLE (\w+)/g)].map((m) => m[1]);
    assert.ok(declared.length >= 15, 'sanity: found the tables in the DDL');
    for (const t of declared) {
      assert.ok(core.db.hasTable(t), `table ${t} is missing`);
    }
    core.close();
  });

  test('migrate() is idempotent', async () => {
    const core = await makeCore();
    assert.equal(migrate(core.db), SCHEMA_VERSION);
    assert.equal(migrate(core.db), SCHEMA_VERSION);
    core.close();
  });

  test('the CHECK constraints in the spec are live', async () => {
    const core = await makeCore();
    const thing = core.things.create({ title: 'x' });
    assert.throws(
      () =>
        core.db.run(
          `INSERT INTO field (id, thing_id, sort_order, kind, label, value_text, value_json, is_secret, created_at, updated_at)
           VALUES ('f1', ?, 1, 'text', 'l', 'a', '{}', 0, '2026-01-01', '2026-01-01')`,
          [thing.id],
        ),
      /CHECK/,
      'two value carriers must be rejected',
    );
    assert.throws(
      () =>
        core.db.run(
          `INSERT INTO field (id, thing_id, sort_order, kind, label, value_text, is_secret, created_at, updated_at)
           VALUES ('f2', ?, 1, 'secret', 'l', 'plaintext', 1, '2026-01-01', '2026-01-01')`,
          [thing.id],
        ),
      /CHECK/,
      'a secret must never hold plaintext',
    );
    core.close();
  });
});

describe('field-kind registry', () => {
  test('is loaded as data, and every variant names a declared kind', () => {
    const reg = registry();
    assert.ok(reg.variants().length > 30);
    for (const v of reg.variants()) {
      assert.ok(reg.hasKind(v.kind), `variant ${v.id} references unknown kind ${v.kind}`);
    }
  });

  test('secret variants default to is_secret', () => {
    const reg = registry();
    assert.equal(reg.defaultIsSecret('secret', 'password'), true);
    assert.equal(reg.defaultIsSecret('text', 'username'), false);
  });

  test('url variants auto-detect from the value', () => {
    const reg = registry();
    assert.equal(reg.detectUrlVariant('https://github.com/a/b'), 'github');
    assert.equal(reg.detectUrlVariant('https://youtu.be/xyz'), 'youtube');
    assert.equal(reg.detectUrlVariant('https://nothing.example/'), undefined);
  });

  test('validation regexes come from the registry', () => {
    const reg = registry();
    assert.equal(reg.validate('email', 'a@b.example'), true);
    assert.equal(reg.validate('email', 'not-an-email'), false);
    assert.equal(reg.validate('plain', 'anything'), true);
  });
});

describe('things, sections, fields', () => {
  test('create / update / trash / restore / purge', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Example Registrar' });
    assert.equal(core.things.get(t.id)?.title, 'Example Registrar');

    core.things.update(t.id, { title: 'Renamed', is_pinned: true });
    assert.equal(core.things.get(t.id)?.title, 'Renamed');
    assert.equal(core.things.pinned().length, 1);

    core.things.trashThing(t.id);
    assert.ok(core.things.get(t.id)?.deleted_at);
    assert.equal(core.things.list().length, 0);
    assert.equal(core.things.trash().length, 1);

    core.things.restore(t.id);
    assert.equal(core.things.list().length, 1);

    core.things.purge(t.id);
    assert.equal(core.things.get(t.id), undefined);
    core.close();
  });

  test('a reorder writes exactly ONE row', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Ordering' });
    const ids = ['a', 'b', 'c', 'd'].map(
      (label) => core.fields.create({ thingId: t.id, variant: 'plain', label }).id,
    );

    const before = core.db.all<Field>('SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order', [t.id]);
    assert.deepEqual(before.map((f) => f.label), ['a', 'b', 'c', 'd']);

    const changesBefore = core.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM change')!.n;
    core.fields.move(ids[3], 1); // drag 'd' between 'a' and 'b'
    const changesAfter = core.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM change')!.n;

    const after = core.db.all<Field>('SELECT * FROM field WHERE thing_id = ? ORDER BY sort_order', [t.id]);
    assert.deepEqual(after.map((f) => f.label), ['a', 'd', 'b', 'c']);
    assert.equal(changesAfter - changesBefore, 1, 'a reorder must be a single-row write');
    core.close();
  });

  test('fields move between sections', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Sections' });
    const s1 = core.sections.create(t.id, 'Links');
    const s2 = core.sections.create(t.id, 'On This Machine');
    const f = core.fields.create({ thingId: t.id, sectionId: s1.id, variant: 'plain', label: 'x' });
    core.fields.moveToSection(f.id, s2.id, 0);
    assert.equal(core.fields.get(f.id)?.section_id, s2.id);

    // Deleting a section leaves its fields alive, unfiled (ON DELETE SET NULL).
    core.sections.remove(s2.id);
    assert.equal(core.fields.get(f.id)?.section_id, null);
    core.close();
  });

  test('secrets are encrypted at rest and bound to their field', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({
      thingId: t.id,
      variant: 'password',
      label: 'Main account password',
      value: { kind: 'secret', value: 'not-a-real-password' },
    });

    const row = core.fields.get(f.id)!;
    assert.equal(row.is_secret, 1);
    assert.equal(row.value_text, null);
    assert.ok(row.value_cipher);
    assert.ok(
      !Buffer.from(row.value_cipher).toString('binary').includes('not-a-real-password'),
      'plaintext must not appear in the stored blob',
    );
    assert.equal(core.fields.revealSecret(f.id), 'not-a-real-password');

    // Move the ciphertext to another field: the AAD must refuse it.
    const other = core.fields.create({ thingId: t.id, variant: 'password', label: 'Other' });
    core.db.run('UPDATE field SET value_cipher = ? WHERE id = ?', [row.value_cipher, other.id]);
    assert.throws(() => core.fields.revealSecret(other.id), /authentication/);
    assert.ok(fieldAad(t.id, f.id).length > 0);
    core.close();
  });

  test('a plaintext write into a secret field is refused', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({ thingId: t.id, variant: 'password', label: 'Password' });
    assert.throws(() => core.fields.setValue(f.id, { kind: 'text', value: 'oops' }), /cannot store plaintext/);
    core.close();
  });

  test('secret VALUES never reach the search index; the label and marker do', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Example Registrar' });
    core.fields.create({
      thingId: t.id,
      variant: 'password',
      label: 'Main account password',
      value: { kind: 'secret', value: 'zebra-quartz-lantern' },
    });

    const row = core.db.get<Record<string, string>>('SELECT * FROM thing_fts WHERE thing_id = ?', [t.id])!;
    const all = Object.values(row).join(' ');
    assert.ok(!all.includes('zebra-quartz-lantern'), 'the secret value must not be indexed');
    assert.ok(all.includes('Main account password'), 'the label is indexed');
    assert.ok(row.markers.includes('has:password'), 'the marker is indexed');

    assert.equal(core.search('has:password').length, 1);
    assert.equal(core.search('zebra').length, 0, 'the value is unfindable');
    assert.equal(core.search('"Main account password"').length, 1);
    core.close();
  });

  test('a locked Thing contributes nothing, and unlocking restores it', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Private Records' });
    core.fields.create({ thingId: t.id, variant: 'plain', label: 'Detail', value: { kind: 'text', value: 'sensitive' } });
    assert.equal(core.search('private').length, 1);

    core.things.update(t.id, { is_locked: true });
    assert.equal(core.db.get('SELECT 1 AS x FROM thing_fts WHERE thing_id = ?', [t.id]), undefined);
    assert.equal(core.search('private').length, 0);
    assert.equal(core.search('is:locked').length, 1, 'the Locked view still lists it');

    core.things.update(t.id, { is_locked: false });
    assert.equal(core.search('private').length, 1);
    core.close();
  });

  test('collections are many-to-many', async () => {
    const core = await makeCore();
    const cf = core.things.create({ title: 'Cloudflare' });
    const dev = core.collections.create({ name: 'Development' });
    const nineteen = core.collections.create({ name: '1980' });
    core.collections.add(dev.id, cf.id);
    core.collections.add(nineteen.id, cf.id);
    core.collections.add(nineteen.id, cf.id); // idempotent

    assert.equal(core.collections.countOf(dev.id), 1);
    assert.equal(core.collections.countOf(nineteen.id), 1);
    assert.equal(core.collections.collectionsOf(cf.id).length, 2);
    assert.equal(core.search('collection:1980').length, 1);

    core.collections.removeMember(dev.id, cf.id);
    assert.equal(core.collections.countOf(dev.id), 0);
    assert.ok(core.things.get(cf.id), 'removing from a collection must not delete the Thing');
    core.close();
  });

  test('tags are shared, case-insensitive, and reindex their Things', async () => {
    const core = await makeCore();
    const a = core.things.create({ title: 'A' });
    const b = core.things.create({ title: 'B' });
    const t1 = core.tags.attach(a.id, 'Infrastructure');
    const t2 = core.tags.attach(b.id, 'infrastructure');
    assert.equal(t1.id, t2.id, 'tag names are case-insensitively unique');
    assert.equal(core.search('tag:infrastructure').length, 2);

    core.tags.detach(a.id, t1.id);
    assert.equal(core.search('tag:infrastructure').length, 1);
    core.close();
  });

  test('relations are fields, and backlinks are an index', async () => {
    const core = await makeCore();
    const site = core.things.create({ title: '1980 Website' });
    const cf = core.things.create({ title: 'Cloudflare' });
    core.fields.create({
      thingId: site.id,
      variant: 'relation',
      label: 'DNS',
      value: { kind: 'text', value: cf.id },
    });
    const back = core.things.referencedBy(cf.id);
    assert.deepEqual(back.map((t) => t.id), [site.id]);
    core.close();
  });

  test('templates deep-copy structure with empty values', async () => {
    const core = await makeCore();
    const t = core.newFromTemplate('account', 'New Account');
    const labels = core.fields.forThing(t.id).map((f) => f.label);
    assert.deepEqual(labels, ['Email', 'Username', 'Password', 'Website', 'Notes']);
    assert.ok(core.fields.forThing(t.id).every((f) => !f.value_text && !f.value_cipher));

    // Save-as-template then instantiate.
    core.fields.setValue(core.fields.forThing(t.id)[0].id, { kind: 'text', value: 'a@b.example' });
    const tpl = core.saveAsTemplate(t.id, 'My Account Template');
    assert.equal(core.things.get(tpl.id)?.is_template, 1);
    assert.equal(core.things.list().find((x) => x.id === tpl.id), undefined, 'templates stay out of listings');
    const made = core.newFromTemplate(tpl.id, 'From My Template');
    assert.equal(core.fields.forThing(made.id).length, 5);
    assert.equal(core.fields.forThing(made.id)[0].value_text, null, 'values start empty');
    core.close();
  });

  test('duplicating a Thing re-encrypts its secrets for the new field id', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    core.fields.create({
      thingId: t.id,
      variant: 'password',
      label: 'Password',
      value: { kind: 'secret', value: 'copy-me-not-real' },
    });
    const copy = core.duplicate(t.id, 'Account copy');
    const copied = core.fields.forThing(copy.id)[0];
    assert.equal(core.fields.revealSecret(copied.id), 'copy-me-not-real');
    const original = core.fields.forThing(t.id)[0];
    assert.notEqual(
      Buffer.from(copied.value_cipher!).toString('hex'),
      Buffer.from(original.value_cipher!).toString('hex'),
      'the envelope must differ — the AAD is bound to the new field id',
    );
    core.close();
  });

  test('smart views seed from the registry and resolve as real queries', async () => {
    const core = await makeCore();
    const n = core.ensureSmartViews();
    assert.ok(n > 10);
    assert.equal(core.ensureSmartViews(), 0, 'seeding is idempotent');
    const pinnedView = core.collections.byName('Pinned')!;
    assert.equal(pinnedView.is_smart, 1);
    const t = core.things.create({ title: 'Pinned Thing', isPinned: true });
    assert.deepEqual(core.search(pinnedView.smart_query!).map((x) => x.id), [t.id]);
    core.close();
  });

  test('the demo seed is fictional and produces a searchable library', async () => {
    const core = await makeCore();
    const res = seedDemoData(core);
    assert.ok(res.things > 0);
    assert.equal(seedDemoData(core).things, 0, 'seeding runs once');

    const all = core.db.all<{ value_text: string }>(
      'SELECT value_text FROM field WHERE value_text IS NOT NULL',
    );
    const text = all.map((r) => r.value_text).join(' ');
    assert.ok(!/@(gmail|outlook|yahoo)\./i.test(text), 'no real mail providers in seed data');

    assert.ok(core.search('registrar').length >= 1);
    assert.ok(core.search('has:password').length >= 1);
    assert.equal(core.search('demo-value-not-a-real-secret').length, 0, 'seeded secrets are not indexed');
    core.close();
  });
});
