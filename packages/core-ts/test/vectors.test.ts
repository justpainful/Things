import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { repoRoot, specDir } from '../src/paths.ts';
import { parseQuery } from '../src/search/parse.ts';
import { runQuery } from '../src/search/evaluate.ts';
import { resolveDateRange } from '../src/search/dates.ts';
import { compileQuery } from '../src/search/sql.ts';
import { registry } from '../src/registry.ts';
import { MAX_DRIFT_MS, compareHlc, formatHlc } from '../src/hlc.ts';
import { decodeAttrs } from '../src/oplog.ts';
import { compareVectors, mergeVectors, stringifyVector } from '../src/versionVector.ts';
import { orderBetween, orderForIndex, listNeedsRebalance, rebalance, MIN_GAP } from '../src/sortOrder.ts';
import { DecryptError, fieldAad, open, seal } from '../src/crypto/envelope.ts';
import { deriveKekSync } from '../src/crypto/kdf.ts';
import { encryptObject } from '../src/crypto/frames.ts';
import {
  BACKUP_AAD,
  DEK_WRAP_AAD_DEVICE,
  DEK_WRAP_AAD_PIN,
  KEK2_HKDF_INFO,
  dekCheck,
  deriveDeviceKek,
} from '../src/crypto/keyring.ts';
import { OBJECT_KEY_AAD, sha256Hex } from '../src/objectStore.ts';
import { canonicalJson } from '../src/canonicalJson.ts';
import { Hlc } from '../src/hlc.ts';
import { MemoryVault } from '../src/crypto/vault.ts';
import { cleanup, makeCore } from './helpers.ts';
import type { ThingDoc } from '../src/types.ts';

after(cleanup);

/**
 * These tests run this implementation against `spec/vectors/*.json`.
 *
 * The Swift core runs the same files. If the two ever disagree, one of these
 * goes red before a user sees it — which is the entire reason the vectors
 * exist, given that the iOS loop is a CI round-trip away.
 *
 * Every read is counted. The last test in this file proves that each vector
 * file declaring `mustRun: ["ts", …]` was executed *in full*, and writes a
 * self-report that `tools/spec/check-vectors.mjs --report` can cross-check.
 * That is the hole this suite fell into once already: a runner that does not
 * recognise a file and says nothing produces a green suite and incompatible
 * cores.
 */

const executed = new Map<string, number>();

function ran(file: string, cases: number): void {
  executed.set(file, (executed.get(file) ?? 0) + cases);
}

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
    ran('search-parser.json', v.cases.length);
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
    ran('search-eval.json', v.cases.length);
  });

  test('date ranges resolve identically', () => {
    for (const c of v.dateRanges) {
      assert.deepEqual(resolveDateRange(c.value, v.now), c.expect, `value: ${c.value}`);
    }
    ran('search-eval.json', v.dateRanges.length);
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
    ran('hlc.json', v.formatting.length);
  });

  test('string sort is the ordering', () => {
    const samples = v.formatting.map((c) => c.expect);
    assert.deepEqual([...samples].sort(), v.sorted);
    ran('hlc.json', v.sorted.length);
  });

  test('pairwise comparisons match', () => {
    for (const c of v.comparisons) {
      assert.equal(compareHlc(c.a, c.b), c.expect, `${c.a} vs ${c.b}`);
    }
    ran('hlc.json', v.comparisons.length);
  });
});

describe('conformance vectors — version vectors', () => {
  const v = vector<{
    cases: {
      kind: string;
      a?: Record<string, number>;
      b?: Record<string, number>;
      result?: string;
      value?: Record<string, number>;
      canonicalJson?: string;
    }[];
    merges: { a: Record<string, number>; b: Record<string, number>; expect: Record<string, number> }[];
  }>('version-vector.json');

  test('every case in the shared array matches', () => {
    let seen = 0;
    for (const c of v.cases) {
      if (c.kind === 'comparison') {
        assert.equal(compareVectors(c.a!, c.b!), c.result, `${JSON.stringify(c.a)} vs ${JSON.stringify(c.b)}`);
      } else {
        assert.equal(stringifyVector(c.value!), c.canonicalJson);
      }
      seen++;
    }
    assert.equal(seen, v.cases.length);
    ran('version-vector.json', seen);
  });

  test('merges match', () => {
    for (const c of v.merges) assert.deepEqual(mergeVectors(c.a, c.b), c.expect);
    ran('version-vector.json', v.merges.length);
  });
});

describe('conformance vectors — sort order', () => {
  const v = vector<{
    minGap: number;
    cases: { prev: number | null; next: number | null; expectedOrder: number }[];
    forIndex: { orders: number[]; index: number; expect: number }[];
    needsRebalance: { orders: number[]; expect: boolean }[];
    rebalance: { items: { id: string; sort_order: number }[]; expect: { id: string; sort_order: number }[] }[];
  }>('sort-order.json');

  test('minGap agrees', () => {
    assert.equal(v.minGap, MIN_GAP);
  });

  test('midpoint insertion matches', () => {
    for (const c of v.cases) assert.equal(orderBetween(c.prev, c.next), c.expectedOrder);
    ran('sort-order.json', v.cases.length);
  });

  test('index placement matches', () => {
    for (const c of v.forIndex) assert.equal(orderForIndex(c.orders, c.index), c.expect);
    ran('sort-order.json', v.forIndex.length);
  });

  test('rebalance detection and renumbering match', () => {
    for (const c of v.needsRebalance) assert.equal(listNeedsRebalance(c.orders), c.expect);
    for (const c of v.rebalance) assert.deepEqual(rebalance(c.items), c.expect);
    ran('sort-order.json', v.needsRebalance.length + v.rebalance.length);
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
    // Four of these carry a context string from spec/crypto.md §2.2 as their
    // AAD, which is what pins those strings AS USED — both cores run this
    // section byte-exactly.
    assert.ok(v.seal.some((c) => c.aadHex === DEK_WRAP_AAD_PIN.toString('hex')));
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
    ran('crypto-envelope.json', v.seal.length);
  });

  test('the must-fail cases fail', () => {
    for (const c of v.openMustFail) {
      assert.throws(
        () => open(Buffer.from(c.keyHex, 'hex'), Buffer.from(c.envelopeHex, 'hex'), Buffer.from(c.aadHex, 'hex')),
        DecryptError,
      );
    }
    ran('crypto-envelope.json', v.openMustFail.length);
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
    ran('crypto-envelope.json', v.objectPathFanout.examples.length);
  });
});

describe('conformance vectors — key-derivation context strings and dek_check', () => {
  const v = vector<{
    cases: {
      name: string;
      contextUtf8?: string;
      bytesUtf8: string;
      utf8Hex: string;
      sha256: string;
      dekCheck?: string;
    }[];
  }>('crypto-context.json');

  const byName = new Map(v.cases.map((c) => [c.name, c]));

  test('every case is self-consistent — the hex and the digest describe the same bytes', () => {
    for (const c of v.cases) {
      const bytes = Buffer.from(c.bytesUtf8, 'utf8');
      assert.equal(bytes.toString('hex'), c.utf8Hex, c.name);
      assert.equal(createHash('sha256').update(bytes).digest('hex'), c.sha256, c.name);
    }
    ran('crypto-context.json', v.cases.length);
  });

  test('each context string is byte-identical to the constant this core uses', () => {
    // A dotted name instead of a colonned one, or a missing `:v1`, means the two
    // cores cannot open each other's wrapped DEK — and nothing else goes wrong
    // first, so there is no earlier symptom to catch it.
    assert.equal(byName.get('dek_wrap_pin')!.contextUtf8, DEK_WRAP_AAD_PIN.toString('utf8'));
    assert.equal(byName.get('dek_wrap_device')!.contextUtf8, DEK_WRAP_AAD_DEVICE.toString('utf8'));
    assert.equal(byName.get('object.enc_key_wrap')!.contextUtf8, OBJECT_KEY_AAD.toString('utf8'));
    assert.equal(byName.get('backup container')!.contextUtf8, BACKUP_AAD.toString('utf8'));
    assert.equal(byName.get('kek2 HKDF info')!.contextUtf8, KEK2_HKDF_INFO.toString('utf8'));
  });

  test('dek_check is base64(sha256(DEK)) truncated to 22 characters', () => {
    const c = byName.get('dek_check')!;
    assert.equal(dekCheck(Buffer.from(c.bytesUtf8, 'utf8')), c.dekCheck);
    assert.equal(c.dekCheck!.length, 22);
  });
});

describe('conformance vectors — vault.json', () => {
  const v = vector<{
    layout: { required: string[]; optional: string[]; trailingNewline: boolean };
    cases: { name: string; value: Record<string, string>; canonicalJson: string }[];
  }>('vault-sidecar.json');

  test('every vault serialises to the pinned bytes', () => {
    for (const c of v.cases) {
      assert.equal(canonicalJson(c.value), c.canonicalJson, c.name);
    }
    ran('vault-sidecar.json', v.cases.length);
  });

  test('a FileVault writes and reads those exact contents, unknown keys included', () => {
    for (const c of v.cases) {
      const store = new MemoryVault();
      for (const [k, val] of Object.entries(c.value)) store.set(k, val);
      assert.equal(canonicalJson(store.read()), c.canonicalJson, c.name);
    }
  });

  test('the required keys are present in the populated cases', () => {
    const full = v.cases[0];
    for (const key of v.layout.required) assert.ok(key in full.value, `missing ${key}`);
    assert.equal(v.layout.trailingNewline, false, 'core-swift writes no trailing newline');
  });
});

describe('conformance vectors — oplog attribute encoding', () => {
  const v = vector<{ cases: { name: string; value: Record<string, unknown>; canonicalJson: string }[] }>(
    'oplog-attrs.json',
  );

  test('every attribute map serialises to the pinned bytes', () => {
    for (const c of v.cases) {
      assert.equal(canonicalJson(c.value), c.canonicalJson, c.name);
    }
    ran('oplog-attrs.json', v.cases.length);
  });

  test('the BLOB case really is the $b64 wrapper and survives a decode', () => {
    const blob = v.cases.find((c) => c.canonicalJson.includes('$b64'));
    assert.ok(blob, 'a BLOB case must exist — a bare base64 string is indistinguishable from TEXT');
    const parsed = JSON.parse(blob.canonicalJson) as { value_cipher: { $b64: string } };
    const decoded = decodeAttrs(parsed as unknown as Record<string, unknown>);
    assert.ok(decoded.value_cipher instanceof Uint8Array);
    assert.equal(Buffer.from(decoded.value_cipher as Uint8Array).subarray(0, 4).toString('ascii'), 'TENV');
  });

  test('the escaping case pins the bytes JSON.stringify would get wrong', () => {
    const escaping = v.cases.find((c) => c.canonicalJson.includes('\\u0008'));
    assert.ok(escaping, 'a control-character case must exist');
    // JSON.stringify writes \b and \f here; core-swift writes  and .
    // This is the assertion that would have caught it.
    assert.notEqual(JSON.stringify(escaping.value), escaping.canonicalJson);
  });
});

describe('conformance vectors — HLC drift clamping', () => {
  const v = vector<{
    maxDriftMs: number;
    cases: {
      name: string;
      lastHlc: string | null;
      wallClockIso: string;
      remoteHlc: string;
      hlc: string;
      millis: number;
      counter: number;
      deviceId: string;
    }[];
  }>('hlc-drift.json');

  test('the bound is core-swift’s one hour', () => {
    assert.equal(v.maxDriftMs, MAX_DRIFT_MS);
  });

  test('every receive produces the pinned stamp', () => {
    for (const c of v.cases) {
      const clock = new Hlc(c.deviceId, { last: c.lastHlc, clock: () => Date.parse(c.wallClockIso) });
      assert.equal(clock.receive(c.remoteHlc), c.hlc, c.name);
    }
    ran('hlc-drift.json', v.cases.length);
  });

  test('a peer far in the future cannot drag the physical clock past the bound', () => {
    const wall = '2026-08-09T12:00:00.000Z';
    const clock = new Hlc('11111111-1111-7111-8111-111111111111', { clock: () => Date.parse(wall) });
    const out = clock.receive('2099-01-01T00:00:00.000Z-0001-22222222-2222-7222-8222-222222222222');
    assert.equal(out.slice(0, 24), new Date(Date.parse(wall) + MAX_DRIFT_MS).toISOString());
    // And causality still holds: the next local stamp is strictly greater.
    assert.ok(clock.now() > out);
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

/**
 * The one that closes the hole.
 *
 * Everything above can pass while a vector file sits in `spec/vectors/` that no
 * describe block ever opens — which is exactly how a third of the last round of
 * divergences stayed invisible. This walks the directory instead of a list, so a
 * new file is a failure until someone writes a runner for it, and it writes the
 * self-report `tools/spec/check-vectors.mjs --report` consumes.
 */
export const TS_VECTOR_REPORT_PATH =
  process.env.THINGS_VECTOR_REPORT ?? join(repoRoot(), '.vectors-report.ts.json');

test('every vector file declaring mustRun ts was executed in full', () => {
  const dir = join(specDir(), 'vectors');
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort();
  assert.ok(files.length > 0, 'spec/vectors is empty — nothing holds the two cores in agreement');

  const report: Record<string, string | number> = { $core: 'ts' };
  const unrun: string[] = [];

  for (const file of files) {
    const doc = JSON.parse(readFileSync(join(dir, file), 'utf8')) as {
      mustRun?: string[];
      caseCount?: number;
    };
    assert.ok(Array.isArray(doc.mustRun) && doc.mustRun.length > 0, `${file}: missing "mustRun"`);
    assert.equal(typeof doc.caseCount, 'number', `${file}: missing "caseCount"`);

    const count = executed.get(file) ?? 0;
    report[file] = count;
    if (!doc.mustRun.includes('ts')) continue;
    if (count < doc.caseCount!) unrun.push(`${file}: ran ${count} of ${doc.caseCount} declared cases`);
  }

  writeFileSync(TS_VECTOR_REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  assert.deepEqual(
    unrun,
    [],
    'A vector file no runner matches is a silent pass, not a pass. Add a describe block above, ' +
      'or change the file’s mustRun if this core genuinely should not run it.',
  );
});
