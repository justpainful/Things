import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { applyRemoteUpdate, openConflicts, resolveConflict } from '../src/conflicts.ts';
import { parseVector, stringifyVector } from '../src/versionVector.ts';
import { cleanup, makeCore } from './helpers.ts';
import type { Change } from '../src/types.ts';

after(cleanup);

describe('oplog', () => {
  test('every mutation appends a change with changed attrs only', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'First' });
    core.things.update(t.id, { title: 'Second' });

    const changes = core.oplog.entityHistory(t.id);
    assert.equal(changes.length, 2);
    assert.equal(changes[0].op, 'update');
    assert.equal(changes[1].op, 'create');

    const attrs = JSON.parse(changes[0].attrs_json) as Record<string, unknown>;
    assert.deepEqual(Object.keys(attrs).sort(), ['title', 'updated_at', 'version_vector']);
    assert.equal(attrs.title, 'Second');
    const prev = JSON.parse(changes[0].prev_json!) as Record<string, unknown>;
    assert.equal(prev.title, 'First');
    core.close();
  });

  test('a no-op update writes nothing', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Same' });
    const before = core.oplog.entityHistory(t.id).length;
    core.things.update(t.id, { title: 'Same' });
    assert.equal(core.oplog.entityHistory(t.id).length, before);
    core.close();
  });

  test('the version vector increments per device on every write', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'A' });
    assert.deepEqual(parseVector(core.things.get(t.id)!.version_vector), { [core.deviceId]: 1 });
    core.things.update(t.id, { title: 'B' });
    assert.deepEqual(parseVector(core.things.get(t.id)!.version_vector), { [core.deviceId]: 2 });
    core.close();
  });

  test('HLCs are strictly increasing across the whole log', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'A' });
    for (let i = 0; i < 30; i++) core.things.update(t.id, { title: `T${i}` });
    const hlcs = core.db.pluck<string>('SELECT hlc FROM change ORDER BY rowid');
    assert.deepEqual(hlcs, [...hlcs].sort(), 'the log must sort by HLC in insertion order');
    assert.equal(new Set(hlcs).size, hlcs.length, 'no duplicate HLCs');
    core.close();
  });

  test('thing history spans the Thing and its fields, grouped by day', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({ thingId: t.id, variant: 'plain', label: 'User' });
    core.fields.setValue(f.id, { kind: 'text', value: 'demo' });

    const changes = core.oplog.thingHistory(t.id);
    assert.ok(changes.some((c) => c.entity_type === 'thing'));
    assert.ok(changes.some((c) => c.entity_type === 'field'));

    const days = core.oplog.groupByDay(changes);
    assert.equal(days.length, 1);
    assert.equal(days[0].date, changes[0].applied_at.slice(0, 10));
    assert.equal(days[0].changes.length, changes.length);
    core.close();
  });

  test('undo and redo walk the same mechanism', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Original' });
    core.things.update(t.id, { title: 'Edited' });
    assert.equal(core.things.get(t.id)?.title, 'Edited');

    assert.ok(core.oplog.canUndo());
    core.oplog.undo();
    assert.equal(core.things.get(t.id)?.title, 'Original');

    assert.ok(core.oplog.canRedo());
    core.oplog.redo();
    assert.equal(core.things.get(t.id)?.title, 'Edited');

    // Undoing a create removes the row; redoing brings it back.
    const t2 = core.things.create({ title: 'Ephemeral' });
    core.oplog.undo();
    assert.equal(core.things.get(t2.id), undefined);
    core.oplog.redo();
    assert.equal(core.things.get(t2.id)?.title, 'Ephemeral');
    core.close();
  });

  test('undo is never destructive — it appends', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'A' });
    core.things.update(t.id, { title: 'B' });
    const before = core.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM change')!.n;
    core.oplog.undo();
    const after = core.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM change')!.n;
    assert.equal(after, before + 1, 'undo adds history rather than deleting it');
    core.close();
  });

  test('a new edit clears the redo stack', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'A' });
    core.things.update(t.id, { title: 'B' });
    core.oplog.undo();
    assert.ok(core.oplog.canRedo());
    core.things.update(t.id, { title: 'C' });
    assert.equal(core.oplog.canRedo(), false);
    core.close();
  });

  test('restore puts a field back to a previous value', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({ thingId: t.id, variant: 'plain', label: 'User', value: { kind: 'text', value: 'v1' } });
    core.fields.setValue(f.id, { kind: 'text', value: 'v2' });
    core.fields.setValue(f.id, { kind: 'text', value: 'v3' });
    assert.equal(core.fields.get(f.id)?.value_text, 'v3');

    const history = core.oplog.entityHistory(f.id);
    const toV2 = history.find(
      (c: Change) => (JSON.parse(c.attrs_json) as { value_text?: string }).value_text === 'v2',
    )!;
    core.oplog.restore(toV2.id, 'before');
    assert.equal(core.fields.get(f.id)?.value_text, 'v1');

    core.oplog.restore(toV2.id, 'after');
    assert.equal(core.fields.get(f.id)?.value_text, 'v2');
    core.close();
  });

  test('sync read: everything after an HLC', async () => {
    const core = await makeCore();
    core.things.create({ title: 'one' });
    const mark = core.db.pluck<string>('SELECT hlc FROM change ORDER BY hlc DESC LIMIT 1')[0];
    core.things.create({ title: 'two' });
    const after = core.oplog.since(mark);
    assert.ok(after.length > 0);
    assert.ok(after.every((c) => c.hlc > mark));
    core.close();
  });
});

describe('conflicts', () => {
  const REMOTE = '99999999-9999-7999-8999-999999999999';

  test('a dominating remote update applies', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Local' });
    const local = parseVector(core.things.get(t.id)!.version_vector);

    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'thing',
      entityId: t.id,
      op: 'update',
      attrs: { title: 'Remote' },
      versionVector: { ...local, [REMOTE]: 1 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });
    assert.equal(res.outcome, 'applied');
    assert.equal(core.things.get(t.id)?.title, 'Remote');
    assert.equal(openConflicts(core.ctx).length, 0);
    core.close();
  });

  test('a dominated remote update is ignored', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Local' });
    core.things.update(t.id, { title: 'Local 2' });

    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'thing',
      entityId: t.id,
      op: 'update',
      attrs: { title: 'Stale' },
      versionVector: { [core.deviceId]: 1 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });
    assert.equal(res.outcome, 'ignored');
    assert.equal(core.things.get(t.id)?.title, 'Local 2');
    core.close();
  });

  test('concurrent edits to the SAME field create a conflict and show the higher HLC', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({ thingId: t.id, variant: 'plain', label: 'Notes', value: { kind: 'text', value: 'local edit' } });

    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'field',
      entityId: f.id,
      op: 'update',
      attrs: { value_text: 'remote edit' },
      // neither dominates: local has our counter, remote has its own
      versionVector: { [REMOTE]: 3 },
      hlc: core.hlc.now(), // later than ours
      deviceId: REMOTE,
    });

    assert.equal(res.outcome, 'conflict');
    const open = openConflicts(core.ctx);
    assert.equal(open.length, 1);
    assert.equal(open[0].entity_id, f.id);
    assert.equal(
      core.fields.get(f.id)?.value_text,
      'remote edit',
      'the higher-HLC value materialises provisionally so the app stays usable',
    );

    // The vectors are merged so the conflict is not re-detected forever.
    const merged = parseVector(core.fields.get(f.id)!.version_vector);
    assert.equal(merged[REMOTE], 3);
    core.close();
  });

  test('concurrent edits to DIFFERENT fields both apply — the vision case', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const notes = core.fields.create({ thingId: t.id, variant: 'plain', label: 'Notes', value: { kind: 'text', value: 'phone note' } });
    const password = core.fields.create({ thingId: t.id, variant: 'password', label: 'Password' });

    // The PC edited only the password, concurrently.
    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'field',
      entityId: password.id,
      op: 'update',
      attrs: { value_text: null, label: 'Password (PC)' },
      versionVector: { [REMOTE]: 2 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });

    assert.equal(res.outcome, 'conflict', 'same entity, concurrent vectors');
    assert.equal(core.fields.get(notes.id)?.value_text, 'phone note', 'the other field is untouched');
    assert.equal(openConflicts(core.ctx).length, 1, 'only the field that actually collided conflicts');
    core.close();
  });

  test('concurrent but identical content merges without a conflict', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Same' });
    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'thing',
      entityId: t.id,
      op: 'update',
      attrs: { title: 'Same' },
      versionVector: { [REMOTE]: 1 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });
    assert.equal(res.outcome, 'applied');
    assert.equal(openConflicts(core.ctx).length, 0);
    core.close();
  });

  test('an unknown entity is created outright', async () => {
    const core = await makeCore();
    const id = '01890000-0000-7000-8000-0000000000ff';
    const res = applyRemoteUpdate(core.ctx, {
      entityType: 'thing',
      entityId: id,
      op: 'create',
      attrs: {
        title: 'From the phone',
        created_at: '2026-08-09T00:00:00.000Z',
        updated_at: '2026-08-09T00:00:00.000Z',
        version_vector: stringifyVector({ [REMOTE]: 1 }),
      },
      versionVector: { [REMOTE]: 1 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });
    assert.equal(res.outcome, 'created');
    assert.equal(core.things.get(id)?.title, 'From the phone');
    core.close();
  });

  test('resolving a conflict picks a side and closes it', async () => {
    const core = await makeCore();
    const t = core.things.create({ title: 'Account' });
    const f = core.fields.create({ thingId: t.id, variant: 'plain', label: 'Notes', value: { kind: 'text', value: 'mine' } });
    applyRemoteUpdate(core.ctx, {
      entityType: 'field',
      entityId: f.id,
      op: 'update',
      attrs: { value_text: 'theirs' },
      versionVector: { [REMOTE]: 3 },
      hlc: core.hlc.now(),
      deviceId: REMOTE,
    });
    const c = openConflicts(core.ctx)[0];
    assert.ok(resolveConflict(core.ctx, c.id, 'a'), 'keep the local version');
    assert.equal(core.fields.get(f.id)?.value_text, 'mine');
    assert.equal(openConflicts(core.ctx).length, 0);
    assert.equal(resolveConflict(core.ctx, c.id, 'a'), false, 'resolving twice is a no-op');
    core.close();
  });
});
