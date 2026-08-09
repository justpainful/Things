import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { sha256Hex } from '../src/objectStore.ts';
import { FRAME_SIZE } from '../src/crypto/frames.ts';
import { cleanup, makeCore } from './helpers.ts';

after(cleanup);

describe('content-addressed object store', () => {
  test('hashes PLAINTEXT and fans out the path', async () => {
    const core = await makeCore();
    const bytes = Buffer.from('hello objects');
    const put = core.objects.put(bytes, { mimeType: 'text/plain' });

    assert.equal(put.hash, sha256Hex(bytes));
    assert.equal(put.deduped, false);
    assert.equal(
      core.objects.pathFor(put.hash),
      join(core.dataDir, 'objects', put.hash.slice(0, 2), put.hash.slice(2, 4), put.hash),
    );
    assert.ok(existsSync(core.objects.pathFor(put.hash)));
    core.close();
  });

  test('the bytes on disk are ciphertext, and read() returns the plaintext', async () => {
    const core = await makeCore();
    const bytes = Buffer.from('a recognisable plaintext marker');
    const put = core.objects.put(bytes);
    const onDisk = (await import('node:fs')).readFileSync(core.objects.pathFor(put.hash));
    assert.ok(!onDisk.includes('recognisable'), 'objects are encrypted at rest');
    assert.equal(onDisk.subarray(0, 4).toString('ascii'), 'TOBJ');
    assert.deepEqual(core.objects.read(put.hash), bytes);
    core.close();
  });

  test('dedupes on insert — "this file is already in Things" is a primary-key hit', async () => {
    const core = await makeCore();
    const bytes = randomBytes(4096);
    const a = core.objects.put(bytes);
    const b = core.objects.put(Buffer.from(bytes));
    assert.equal(a.hash, b.hash);
    assert.equal(b.deduped, true);
    assert.equal(core.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM object')!.n, 1);
    core.close();
  });

  test('the same object in two Things is stored once and ref-counted twice', async () => {
    const core = await makeCore();
    const bytes = Buffer.from('shared logo bytes');
    const put = core.objects.put(bytes);

    const t1 = core.things.create({ title: 'One' });
    const t2 = core.things.create({ title: 'Two' });
    const f1 = core.fields.create({ thingId: t1.id, variant: 'logo', label: 'logo.png' });
    const f2 = core.fields.create({ thingId: t2.id, variant: 'logo', label: 'avatar.png' });
    core.fields.setValue(f1.id, { kind: 'object', hash: put.hash });
    core.fields.setValue(f2.id, { kind: 'object', hash: put.hash });

    core.objects.recount();
    assert.equal(core.objects.row(put.hash)?.ref_count, 2);

    core.fields.remove(f1.id);
    core.objects.recount();
    assert.equal(core.objects.row(put.hash)?.ref_count, 1);
    assert.ok(existsSync(core.objects.pathFor(put.hash)), 'still referenced, still on disk');

    core.fields.remove(f2.id);
    const gc = core.objects.gc();
    assert.equal(gc.removed, 1);
    assert.equal(existsSync(core.objects.pathFor(put.hash)), false);
    core.close();
  });

  test('range reads work across frames', async () => {
    const core = await makeCore();
    const bytes = randomBytes(FRAME_SIZE + 5000);
    const put = core.objects.put(bytes);
    const got = core.objects.readRange(put.hash, FRAME_SIZE - 10, 40);
    assert.deepEqual(got, bytes.subarray(FRAME_SIZE - 10, FRAME_SIZE + 30));
    core.close();
  });

  test('put() refuses to run while locked', async () => {
    const core = await makeCore();
    core.keyring.lock();
    assert.throws(() => core.objects.put(Buffer.from('x')), /locked/);
    core.close();
  });

  test('gc leaves referenced objects alone', async () => {
    const core = await makeCore();
    const keep = core.objects.put(Buffer.from('keep me'));
    const drop = core.objects.put(Buffer.from('drop me'));
    const t = core.things.create({ title: 'T' });
    const f = core.fields.create({ thingId: t.id, variant: 'attachment', label: 'file' });
    core.fields.setValue(f.id, { kind: 'object', hash: keep.hash });

    const res = core.objects.gc();
    assert.equal(res.removed, 1);
    assert.ok(core.objects.row(keep.hash));
    assert.equal(core.objects.row(drop.hash), undefined);
    core.close();
  });
});
