import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { specDir } from '../src/paths.ts';
import { parseQuery } from '../src/search/parse.ts';
import { runQuery } from '../src/search/evaluate.ts';
import { resolveDateRange } from '../src/search/dates.ts';
import { compileQuery } from '../src/search/sql.ts';
import { registry } from '../src/registry.ts';
import { compareHlc, formatHlc } from '../src/hlc.ts';
import { compareVectors, mergeVectors, stringifyVector } from '../src/versionVector.ts';
import { orderBetween, orderForIndex, listNeedsRebalance, rebalance, MIN_GAP } from '../src/sortOrder.ts';
import { DecryptError, fieldAad, open, seal } from '../src/crypto/envelope.ts';
import { deriveKekSync } from '../src/crypto/kdf.ts';
import { encryptObject } from '../src/crypto/frames.ts';
import { deriveDeviceKek } from '../src/crypto/keyring.ts';
import { sha256Hex } from '../src/objectStore.ts';
import { cleanup, makeCore } from './helpers.ts';
import type { ThingDoc } from '../src/types.ts';

after(cleanup);

/**
 * These tests run this implementation against `spec/vectors/*.json`.
 *
 * The Swift core runs the same files. If the two ever disagree, one of these
 * goes red before a user sees it — which is the entire reason the vectors
 * exist, given that the iOS loop is a CI round-trip away.
 */

function vector<T>(name: string): T {
  return JSON.parse(readFileSync(join(specDir(), 'vectors', name), 'utf8')) as T;
}

describe('conformance vectors — search parser', () => {
  const v = vector<{ cases: { input: string; expect: unknown }[] }>('search-parser.json');

  test('every case parses to the pinned AST', () => {
    assert.ok(v.cases.length >= 25);
    for (const c of v.cases) {
      assert.deepEqual(parseQuery(c.input), c.expect, `input: ${JSON.stringify(c.input)}`);
    }
  });
});

describe('conformance vectors — search evaluator', () => {
  const v = vector<{
    now: string;
    docs: ThingDoc[];
    cases: { query: string; expect: string[] }[];
    dateRanges: { value: string; expect: unknown }[];
  }>('search-eval.json');

  test('every query returns the pinned ids in the pinned order', () => {
    for (const c of v.cases) {
      const got = runQuery(parseQuery(c.query), v.docs, { now: v.now }).map((d) => d.id);
      assert.deepEqual(got, c.expect, `query: ${JSON.stringify(c.query)}`);
    }
  });

  test('date ranges resolve identically', () => {
    for (const c of v.dateRanges) {
      assert.deepEqual(resolveDateRange(c.value, v.now), c.expect, `value: ${c.value}`);
    }
  });

  test('a locked Thing is present in the fixtures and is excluded from content search', () => {
    const locked = v.docs.find((d) => d.is_locked);
    assert.ok(locked, 'the fixtures must exercise the locked case');
    const contentCase = v.cases.find((c) => c.query === 'has:secret')!;
    assert.ok(!contentCase.expect.includes(locked.id));
    const lockedCase = v.cases.find((c) => c.query === 'is:locked')!;
    assert.ok(lockedCase.expect.includes(locked.id));
  });
});

describe('conformance vectors — HLC', () => {
  const v = vector<{
    formatting: { parts: { physical: string; counter: number; device: string }; expect: string }[];
    sorted: string[];
    comparisons: { a: string; b: string; expect: number }[];
  }>('hlc.json');

  test('formatting matches', () => {
    for (const c of v.formatting) assert.equal(formatHlc(c.parts), c.expect);
  });

  test('string sort is the ordering', () => {
    const samples = v.formatting.map((c) => c.expect);
    assert.deepEqual([...samples].sort(), v.sorted);
  });

  test('pairwise comparisons match', () => {
    for (const c of v.comparisons) {
      assert.equal(compareHlc(c.a, c.b), c.expect, `${c.a} vs ${c.b}`);
    }
  });
});

describe('conformance vectors — version vectors', () => {
  const v = vector<{
    comparisons: { a: Record<string, number>; b: Record<string, number>; expect: string }[];
    merges: { a: Record<string, number>; b: Record<string, number>; expect: Record<string, number> }[];
    canonicalJson: { vector: Record<string, number>; expect: string }[];
  }>('version-vector.json');

  test('comparisons match', () => {
    for (const c of v.comparisons) {
      assert.equal(compareVectors(c.a, c.b), c.expect, `${JSON.stringify(c.a)} vs ${JSON.stringify(c.b)}`);
    }
  });

  test('merges match', () => {
    for (const c of v.merges) assert.deepEqual(mergeVectors(c.a, c.b), c.expect);
  });

  test('canonical serialisation matches', () => {
    for (const c of v.canonicalJson) assert.equal(stringifyVector(c.vector), c.expect);
  });
});

describe('conformance vectors — sort order', () => {
  const v = vector<{
    minGap: number;
    between: { prev: number | null; next: number | null; expect: number }[];
    forIndex: { orders: number[]; index: number; expect: number }[];
    needsRebalance: { orders: number[]; expect: boolean }[];
    rebalance: { items: { id: string; sort_order: number }[]; expect: { id: string; sort_order: number }[] }[];
  }>('sort-order.json');

  test('minGap agrees', () => {
    assert.equal(v.minGap, MIN_GAP);
  });

  test('midpoint insertion matches', () => {
    for (const c of v.between) assert.equal(orderBetween(c.prev, c.next), c.expect);
  });

  test('index placement matches', () => {
    for (const c of v.forIndex) assert.equal(orderForIndex(c.orders, c.index), c.expect);
  });

  test('rebalance detection and renumbering match', () => {
    for (const c of v.needsRebalance) assert.equal(listNeedsRebalance(c.orders), c.expect);
    for (const c of v.rebalance) assert.deepEqual(rebalance(c.items), c.expect);
  });
});

describe('conformance vectors — crypto envelope', () => {
  const v = vector<{
    envelopeLayout: Record<string, unknown>;
    fieldAad: { thingId: string; fieldId: string; expectHex: string };
    seal: { keyHex: string; nonceHex: string; aadHex: string; plaintextUtf8: string; expectHex: string }[];
    openMustFail: { envelopeHex: string; keyHex: string; aadHex: string }[];
    kdf: {
      production: { N: number; r: number; p: number; dkLen: number };
      cases: {
        params: { N: number; r: number; p: number; dkLen: number };
        passwordUtf8: string;
        saltHex: string;
        expectHex: string;
      }[];
    };
    deviceKek: { deviceSecretHex: string; saltHex: string; expectHex: string };
    objectFrames: { cases: { keyHex: string; noncePrefixHex: string; plaintextUtf8: string; expectHex: string }[] };
    objectPathFanout: { examples: { plaintextUtf8: string; hash: string; path: string }[] };
  }>('crypto-envelope.json');

  test('the AAD rule matches', () => {
    assert.equal(fieldAad(v.fieldAad.thingId, v.fieldAad.fieldId).toString('hex'), v.fieldAad.expectHex);
  });

  test('sealing with a fixed nonce is byte-exact', () => {
    for (const c of v.seal) {
      const got = seal(
        Buffer.from(c.keyHex, 'hex'),
        c.plaintextUtf8,
        Buffer.from(c.aadHex, 'hex'),
        { nonce: Buffer.from(c.nonceHex, 'hex') },
      );
      assert.equal(got.toString('hex'), c.expectHex, `plaintext: ${JSON.stringify(c.plaintextUtf8)}`);
      assert.equal(
        open(Buffer.from(c.keyHex, 'hex'), got, Buffer.from(c.aadHex, 'hex')).toString('utf8'),
        c.plaintextUtf8,
      );
    }
  });

  test('the must-fail cases fail', () => {
    for (const c of v.openMustFail) {
      assert.throws(
        () => open(Buffer.from(c.keyHex, 'hex'), Buffer.from(c.envelopeHex, 'hex'), Buffer.from(c.aadHex, 'hex')),
        DecryptError,
      );
    }
  });

  test('the production KDF parameters are the OWASP ones', () => {
    assert.deepEqual(v.kdf.production, { N: 65536, r: 8, p: 2, dkLen: 32 });
  });

  test('scrypt derivation is byte-exact', () => {
    for (const c of v.kdf.cases) {
      const got = deriveKekSync(c.passwordUtf8, Buffer.from(c.saltHex, 'hex'), {
        algorithm: 'scrypt',
        ...c.params,
      });
      assert.equal(got.toString('hex'), c.expectHex);
    }
  });

  test('the device KEK derivation is byte-exact', () => {
    assert.equal(
      deriveDeviceKek(Buffer.from(v.deviceKek.deviceSecretHex, 'hex'), Buffer.from(v.deviceKek.saltHex, 'hex')).toString('hex'),
      v.deviceKek.expectHex,
    );
  });

  test('object framing is byte-exact', () => {
    for (const c of v.objectFrames.cases) {
      const got = encryptObject(
        Buffer.from(c.keyHex, 'hex'),
        Buffer.from(c.plaintextUtf8, 'utf8'),
        Buffer.from(c.noncePrefixHex, 'hex'),
      );
      assert.equal(got.toString('hex'), c.expectHex);
    }
  });

  test('the object path fanout matches', () => {
    for (const e of v.objectPathFanout.examples) {
      const hash = sha256Hex(Buffer.from(e.plaintextUtf8, 'utf8'));
      assert.equal(hash, e.hash);
      assert.equal(`objects/${hash.slice(0, 2)}/${hash.slice(2, 4)}/${hash}`, e.path);
    }
  });
});

describe('the SQL compiler agrees with the in-memory evaluator', () => {
  test('same queries, same results, over a real database', async () => {
    const core = await makeCore();

    const registrar = core.things.create({ title: 'Example Registrar', isPinned: true });
    core.fields.create({ thingId: registrar.id, variant: 'website', label: 'Website', value: { kind: 'text', value: 'https://registrar.example/' } });
    core.fields.create({ thingId: registrar.id, variant: 'password', label: 'Main account password', value: { kind: 'secret', value: 'not-real' } });
    core.tags.attach(registrar.id, 'infrastructure');
    const dev = core.collections.create({ name: 'Development' });
    core.collections.add(dev.id, registrar.id);

    const project = core.things.create({ title: 'Sample Project' });
    core.fields.create({ thingId: project.id, variant: 'github', label: 'Repository', value: { kind: 'text', value: 'https://github.example/demo' } });

    const locked = core.things.create({ title: 'Private Records' });
    core.fields.create({ thingId: locked.id, variant: 'secret', label: 'Recovery phrase', value: { kind: 'secret', value: 'not-real' } });
    core.things.update(locked.id, { is_locked: true });

    const trashed = core.things.create({ title: 'Gone' });
    core.things.trashThing(trashed.id);

    const now = '2026-08-09T12:00:00.000Z';
    const docs = core.db
      .all<{ id: string }>('SELECT id FROM thing')
      .map((r) => core.buildDoc(core.things.get(r.id)!));

    const queries = [
      '',
      'registrar',
      'tag:infrastructure',
      '-has:tag',
      'has:password',
      'has:url',
      'collection:Development',
      'is:pinned',
      'is:locked',
      'is:trashed',
      'sort:title',
      'private',
    ];

    for (const q of queries) {
      const parsed = parseQuery(q);
      const compiled = compileQuery(parsed, { registry: registry(), now });
      const sqlIds = core.db.pluck<string>(compiled.sql, compiled.params);
      const memIds = runQuery(parsed, docs, { now }).map((d) => d.id);
      assert.deepEqual(
        [...sqlIds].sort(),
        [...memIds].sort(),
        `SQL and in-memory evaluation disagree for: ${JSON.stringify(q)}`,
      );
    }
    core.close();
  });
});
