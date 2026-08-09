/**
 * Generate `spec/vectors/*.json`.
 *
 * These files are the contract between the TypeScript core and the Swift core.
 * They are deliberately language-neutral: inputs and expected outputs as plain
 * JSON, no code, no serialised objects, no floating-point traps beyond the ones
 * the format genuinely has. Both test suites read the same bytes.
 *
 *     node packages/core-ts/scripts/gen-vectors.ts
 *
 * Re-running must be a no-op unless behaviour changed — the outputs are
 * deterministic, which is why every nonce, salt and key below is fixed.
 */

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { specDir } from '../src/paths.ts';
import { canonicalJson } from '../src/canonicalJson.ts';
import { parseQuery } from '../src/search/parse.ts';
import { runQuery } from '../src/search/evaluate.ts';
import { resolveDateRange } from '../src/search/dates.ts';
import { Hlc, compareHlc, formatHlc, parseHlc } from '../src/hlc.ts';
import { compareVectors, mergeVectors, stringifyVector } from '../src/versionVector.ts';
import { orderBetween, orderForIndex, listNeedsRebalance, rebalance, MIN_GAP } from '../src/sortOrder.ts';
import { fieldAad, seal } from '../src/crypto/envelope.ts';
import { deriveKekSync } from '../src/crypto/kdf.ts';
import { encryptObject } from '../src/crypto/frames.ts';
import { dekCheck, deriveDeviceKek } from '../src/crypto/keyring.ts';
import { sha256Hex } from '../src/objectStore.ts';
import type { ThingDoc } from '../src/types.ts';

const OUT = join(specDir(), 'vectors');
mkdirSync(OUT, { recursive: true });

type Core = 'ts' | 'swift';

/**
 * Counts cases exactly the way `tools/spec/check-vectors.mjs` does: a top-level
 * `cases` array if there is one, otherwise the sum of every other top-level
 * array. Computed here rather than hand-written so `caseCount` cannot rot.
 */
function countCases(doc: Record<string, unknown>): number {
  if (Array.isArray(doc.cases)) return doc.cases.length;
  let n = 0;
  for (const [key, value] of Object.entries(doc)) {
    if (key.startsWith('$') || key === 'mustRun' || key === 'caseCount' || key === 'version') continue;
    if (Array.isArray(value)) n += value.length;
  }
  return n;
}

/**
 * `mustRun` and `caseCount` are not decoration. A conformance runner that does
 * not recognise a file used to skip it in silence — green suite, incompatible
 * cores. These two fields let CI (and each core's own suite) prove that every
 * file was executed and that all of its cases ran.
 */
function write(name: string, mustRun: Core[], data: Record<string, unknown>): void {
  const doc = { ...data, mustRun, caseCount: countCases(data) };
  if (doc.caseCount === 0) throw new Error(`${name} contains no recognisable cases`);
  writeFileSync(join(OUT, name), `${JSON.stringify(doc, null, 2)}\n`, 'utf8');
  console.log(`wrote spec/vectors/${name} (${doc.caseCount} cases, run by ${mustRun.join(' + ')})`);
}

// ── search parser ───────────────────────────────────────────────────────────

const PARSER_INPUTS = [
  '',
  'cloudflare',
  'Cloudflare Dashboard',
  '"exact phrase"',
  '-draft',
  '-"exact phrase"',
  'tag:1980',
  'TAG:Infrastructure',
  'type:image',
  'has:password',
  'has:file collection:1980',
  'collection:"Home Lab"',
  'device:RAEID-PC',
  'modified:this-week',
  'created:2026-08',
  'created:>2026-01-01',
  'created:<=2026-12-31',
  'is:locked',
  'is:pinned -is:archived',
  'size:>50mb',
  'size:<=1kb',
  'size:100',
  'size:huge',
  'sort:created',
  'sort:title',
  'sort:title.desc',
  'sort:nonsense',
  'tag:1980 type:file -has:tag "1980 Website" sort:modified',
  'colour:red',
  'a\\ b',
  'has:',
];

write('search-parser.json', ['ts'], {
  $comment:
    'Search DSL parser conformance. Input string → AST. The AST is clock-free: relative dates stay symbolic and are resolved by the evaluator against an injected `now`.',
  $swiftCoverage:
    "NOT RUN BY core-swift. Its generic dispatcher only descends into a top-level `cases`/`vectors`/`tests`/`examples` array (this file has one) and then only asserts when a case carries `expected`/`parsed`/`ast` — these carry `expect`, so every case scores zero assertions and the file is reported as unmatched. Fixing it means teaching ConformanceVectorTests.checkSearchQuery to read `expect`, or reshaping the AST here to Swift's terms/phrases/excluded/filters spelling. The search DSL is a local query language, not wire format, so this is a UX divergence rather than a data one — which is why it is declared ts-only and loud rather than quietly claimed.",
  version: 1,
  cases: PARSER_INPUTS.map((input) => ({ input, expect: parseQuery(input) })),
});

// ── search evaluator ────────────────────────────────────────────────────────

const NOW = '2026-08-09T12:00:00.000Z';

function doc(over: Partial<ThingDoc> & { id: string }): ThingDoc {
  return {
    title: 'Untitled',
    text: [],
    tags: [],
    collections: [],
    markers: [],
    devices: [],
    created_at: '2026-08-01T00:00:00.000Z',
    updated_at: '2026-08-08T00:00:00.000Z',
    is_pinned: false,
    is_locked: false,
    is_archived: false,
    is_template: false,
    is_trashed: false,
    has_missing_file: false,
    has_conflict: false,
    max_object_size: 0,
    ...over,
  };
}

const DOCS: ThingDoc[] = [
  doc({
    id: 'd1',
    title: 'Example Registrar',
    text: ['Main account password', 'Website', 'https://registrar.example/'],
    tags: ['infrastructure', 'billing'],
    collections: ['Development'],
    markers: ['has:password', 'has:url', 'has:secret', 'has:tag'],
    devices: [],
    created_at: '2026-08-05T10:00:00.000Z',
    updated_at: '2026-08-09T09:00:00.000Z',
    is_pinned: true,
  }),
  doc({
    id: 'd2',
    title: 'Sample Project',
    text: ['Repository', 'Working folder', 'D:\\Demo\\SampleProject'],
    tags: ['active'],
    collections: ['Development'],
    markers: ['has:url', 'has:path', 'has:note', 'has:tag'],
    devices: ['RAEID-PC'],
    created_at: '2026-07-20T00:00:00.000Z',
    updated_at: '2026-08-03T00:00:00.000Z',
  }),
  doc({
    id: 'd3',
    title: 'Placeholder Artwork',
    text: ['Placeholder 1', 'Placeholder 2'],
    collections: ['Media'],
    markers: ['type:image', 'has:file'],
    created_at: '2026-06-01T00:00:00.000Z',
    updated_at: '2026-06-02T00:00:00.000Z',
    max_object_size: 62 * 1024 * 1024,
  }),
  doc({
    id: 'd4',
    title: 'Private Records',
    text: ['Recovery phrase'],
    tags: ['personal'],
    markers: ['has:secret'],
    is_locked: true,
  }),
  doc({ id: 'd5', title: 'Café Registrar', text: ['diacritics test'] }),
  doc({ id: 'd6', title: 'Deleted Thing', is_trashed: true }),
  doc({ id: 'd7', title: 'Account Template', is_template: true }),
  doc({ id: 'd8', title: 'Old Archive', is_archived: true }),
];

const EVAL_QUERIES = [
  '',
  'registrar',
  'cafe',
  '"Main account password"',
  'tag:infrastructure',
  '-has:tag',
  'has:password',
  'type:image',
  'size:>50mb',
  'collection:Development',
  'device:RAEID-PC',
  'is:pinned',
  'is:locked',
  'is:trashed',
  'is:template',
  'modified:today',
  'created:2026-08',
  'created:<2026-07',
  'sort:title',
  'sort:created.asc',
  'registrar -tag:billing',
  'private',
  'has:secret',
  'tag:personal',
];

write('search-eval.json', ['ts'], {
  $comment:
    'Search evaluator conformance. Fixed documents + fixed `now` → the exact list of matching ids, in result order. Note d4: a locked Thing contributes nothing to content search but stays reachable via is:locked and tag:.',
  $swiftCoverage:
    'NOT RUN BY core-swift, for the same reason as search-parser.json: the cases carry `expect`, and no Swift runner reads that key. core-swift has no in-memory evaluator to run them against either. Declared ts-only rather than claimed.',
  version: 1,
  now: NOW,
  docs: DOCS,
  cases: EVAL_QUERIES.map((query) => ({
    query,
    expect: runQuery(parseQuery(query), DOCS, { now: NOW }).map((d) => d.id),
  })),
  dateRanges: [
    'today',
    'yesterday',
    'this-week',
    'last-week',
    'this-month',
    'last-month',
    'this-year',
    '7d',
    '2026',
    '2026-08',
    '2026-08-09',
    'someday',
  ].map((value) => ({ value, expect: resolveDateRange(value, NOW) })),
});

// ── HLC ─────────────────────────────────────────────────────────────────────

const DEV_A = '11111111-1111-7111-8111-111111111111';
const DEV_B = '22222222-2222-7222-8222-222222222222';

const HLC_SAMPLES = [
  formatHlc({ physical: '2026-08-09T21:14:03.412Z', counter: 0, device: DEV_A }),
  formatHlc({ physical: '2026-08-09T21:14:03.412Z', counter: 1, device: DEV_A }),
  formatHlc({ physical: '2026-08-09T21:14:03.412Z', counter: 1, device: DEV_B }),
  formatHlc({ physical: '2026-08-09T21:14:03.413Z', counter: 0, device: DEV_A }),
  formatHlc({ physical: '2026-08-09T21:14:04.000Z', counter: 0, device: DEV_A }),
  formatHlc({ physical: '2026-08-10T00:00:00.000Z', counter: 65535, device: DEV_A }),
];

write('hlc.json', ['ts', 'swift'], {
  $comment:
    'Hybrid logical clock. Format: <ISO-8601 UTC ms>-<counter, 4 lowercase hex digits>-<deviceId>. Plain string comparison IS the ordering.',
  $swiftCoverage:
    'Fully run by ConformanceVectorTests.testHLCVectors — a named runner that knows this file’s shape and fails loudly, not the generic dispatcher.',
  version: 1,
  format: '{physical}-{counter:04x}-{deviceId}',
  formatting: HLC_SAMPLES.map((hlc) => ({ parts: parseHlc(hlc), expect: hlc })),
  sorted: [...HLC_SAMPLES].sort(),
  comparisons: HLC_SAMPLES.flatMap((a, i) =>
    HLC_SAMPLES.slice(i + 1).map((b) => ({ a, b, expect: compareHlc(a, b) })),
  ),
});

// ── version vectors ─────────────────────────────────────────────────────────

const VV_PAIRS: [Record<string, number>, Record<string, number>][] = [
  [{}, {}],
  [{ a: 1 }, { a: 1 }],
  [{ a: 2 }, { a: 1 }],
  [{ a: 1 }, { a: 2 }],
  [{ a: 1 }, {}],
  [{ a: 1 }, { b: 1 }],
  [{ a: 2, b: 1 }, { a: 1, b: 2 }],
  [{ a: 2, b: 2 }, { a: 1, b: 2 }],
  [{ a: 1, b: 1, c: 1 }, { a: 1, b: 1 }],
];

const VV_CANONICAL: Record<string, number>[] = [{ b: 1, a: 2 }, {}];

write('version-vector.json', ['ts', 'swift'], {
  $comment:
    'Version vector comparison. A missing device counts as zero. `dominates` means A saw B; `concurrent` is the only case that produces a conflict.',
  $swiftCoverage:
    'The `cases` array is run by core-swift: comparison entries hit checkVersionVector (which reads `result`), canonicalJson entries hit checkCanonicalJSON (which reads `value` + `canonicalJson`). RESHAPED — the comparison cases used to live under a `comparisons` key with an `expect` field, which no Swift runner reads, so the whole file was silently skipped. No expected VALUE changed; only the spelling the Swift dispatcher needs to find them. `merges` below remains ts-only: core-swift has no merge runner.',
  version: 1,
  cases: [
    ...VV_PAIRS.map(([a, b]) => ({ kind: 'comparison', a, b, result: compareVectors(a, b) })),
    ...VV_CANONICAL.map((vector) => ({
      kind: 'canonicalJson',
      value: vector,
      canonicalJson: stringifyVector(vector),
    })),
  ],
  merges: VV_PAIRS.map(([a, b]) => ({ a, b, expect: mergeVectors(a, b) })),
});

// ── sort order ──────────────────────────────────────────────────────────────

const BETWEEN: [number | null, number | null][] = [
  [null, null],
  [null, 5],
  [5, null],
  [2, 3],
  [1, 2],
  [1.5, 2],
  [0, 1],
  [-1, 1],
];

write('sort-order.json', ['ts', 'swift'], {
  $comment:
    'Fractional sort_order. A reorder must be a single-row write; rebalancing is explicit and only happens when the gap degrades below minGap.',
  $swiftCoverage:
    'The `cases` array is run by core-swift’s checkFractionalOrder, which reads `prev`/`next` and `expectedOrder`. RESHAPED — these midpoints used to live under `between` with an `expect` field, which no Swift runner reads, so the file was silently skipped even though FractionalOrder and its runner both already existed. No expected VALUE changed. `forIndex`, `needsRebalance` and `rebalance` stay ts-only: core-swift has no runner for them.',
  version: 1,
  minGap: MIN_GAP,
  defaultStep: 1,
  cases: BETWEEN.map(([prev, next]) => ({ prev, next, expectedOrder: orderBetween(prev, next) })),
  forIndex: [
    { orders: [], index: 0 },
    { orders: [1, 2, 3], index: 0 },
    { orders: [1, 2, 3], index: 1 },
    { orders: [1, 2, 3], index: 2 },
    { orders: [1, 2, 3], index: 3 },
    { orders: [1, 2, 3], index: 99 },
    { orders: [3, 1, 2], index: 1 },
  ].map((c) => ({ ...c, expect: orderForIndex(c.orders, c.index) })),
  needsRebalance: [
    { orders: [1, 2, 3], expect: listNeedsRebalance([1, 2, 3]) },
    { orders: [1, 1.0000001, 2], expect: listNeedsRebalance([1, 1.0000001, 2]) },
  ],
  rebalance: [
    {
      items: [
        { id: 'c', sort_order: 1.0000001 },
        { id: 'a', sort_order: 1 },
        { id: 'b', sort_order: 1.00000005 },
      ],
      expect: rebalance([
        { id: 'c', sort_order: 1.0000001 },
        { id: 'a', sort_order: 1 },
        { id: 'b', sort_order: 1.00000005 },
      ]),
    },
  ],
});

// ── crypto envelope ─────────────────────────────────────────────────────────

const KEY = Buffer.alloc(32);
for (let i = 0; i < 32; i++) KEY[i] = i;
const NONCE = Buffer.from('000102030405060708090a0b', 'hex');
const THING_ID = '01890000-0000-7000-8000-00000000aaaa';
const FIELD_ID = '01890000-0000-7000-8000-00000000bbbb';
const OTHER_FIELD_ID = '01890000-0000-7000-8000-00000000cccc';

const OBJECT_KEY = Buffer.alloc(32, 0x5a);
const OBJECT_NONCE_PREFIX = Buffer.from('1122334455667788', 'hex');
const OBJECT_PLAINTEXT = Buffer.from('things object frame vector', 'utf8');

/**
 * The context strings from `spec/crypto.md` §2.2. They are the caller AAD of
 * every wrapped key, which makes them wire format: they are what stops a
 * PIN-wrapped DEK being presented as a device-wrapped one, or an object key
 * being presented as a DEK.
 *
 * They get `seal` cases below rather than a table of their own because `seal`
 * is byte-exact and is already executed by BOTH cores. A table of strings would
 * only pin the strings; a sealed envelope pins the strings *as used*.
 */
const CONTEXTS: { name: string; context: string }[] = [
  { name: 'dek_wrap_pin', context: 'things:dek-wrap:pin:v1' },
  { name: 'dek_wrap_device', context: 'things:dek-wrap:device:v1' },
  { name: 'object.enc_key_wrap', context: 'things:object-key:v1' },
  { name: 'backup container', context: 'things:backup:v1' },
];

/**
 * A stand-in DEK whose bytes are also printable ASCII, so the same 32 bytes can
 * be expressed as `plaintextUtf8` in a seal case, as `bytesUtf8` in a hash case,
 * and as the wrapped key in the vault sidecar — one value, tied together across
 * three files, instead of three unrelated blobs.
 */
const VECTOR_DEK = '0123456789abcdef0123456789abcdef';

write('crypto-envelope.json', ['ts', 'swift'], {
  $comment:
    'AES-256-GCM envelope, scrypt KDF, and framed object encryption. Every nonce and salt here is FIXED so the outputs are deterministic — production always uses random ones.',
  $swiftCoverage:
    'Fully run by ConformanceVectorTests.testCryptoEnvelopeVectors — a named runner that knows this file’s shape and fails loudly.',
  version: 1,

  envelopeLayout: {
    magic: 'TENV',
    magicHex: '54454e56',
    versionByte: 1,
    algByte: 1,
    algorithm: 'AES-256-GCM',
    nonceLength: 12,
    tagLength: 16,
    headerLength: 7,
    note: 'The 7-byte header is prepended to the caller AAD before being fed to GCM, so a version or algorithm downgrade cannot be forged.',
  },

  fieldAad: {
    rule: 'utf8(thing_id) || utf8(field_id) — both are fixed-length UUID strings, so no separator is needed.',
    thingId: THING_ID,
    fieldId: FIELD_ID,
    expectHex: fieldAad(THING_ID, FIELD_ID).toString('hex'),
  },

  seal: [
    {
      keyHex: KEY.toString('hex'),
      nonceHex: NONCE.toString('hex'),
      aadHex: '',
      plaintextUtf8: 'hello',
      expectHex: seal(KEY, 'hello', Buffer.alloc(0), { nonce: NONCE }).toString('hex'),
    },
    {
      keyHex: KEY.toString('hex'),
      nonceHex: NONCE.toString('hex'),
      aadHex: fieldAad(THING_ID, FIELD_ID).toString('hex'),
      plaintextUtf8: 'demo-value-not-a-real-secret',
      expectHex: seal(KEY, 'demo-value-not-a-real-secret', fieldAad(THING_ID, FIELD_ID), {
        nonce: NONCE,
      }).toString('hex'),
    },
    {
      keyHex: KEY.toString('hex'),
      nonceHex: NONCE.toString('hex'),
      aadHex: '',
      plaintextUtf8: '',
      expectHex: seal(KEY, '', Buffer.alloc(0), { nonce: NONCE }).toString('hex'),
    },
    // One per context string from spec/crypto.md §2.2. The AAD here is the exact
    // UTF-8 of the context, and the plaintext is a stand-in 32-byte DEK, so each
    // case is a wrapped key in the form both cores actually write.
    ...CONTEXTS.map(({ name, context }) => ({
      wraps: name,
      contextUtf8: context,
      keyHex: KEY.toString('hex'),
      nonceHex: NONCE.toString('hex'),
      aadHex: Buffer.from(context, 'utf8').toString('hex'),
      plaintextUtf8: VECTOR_DEK,
      expectHex: seal(KEY, VECTOR_DEK, Buffer.from(context, 'utf8'), { nonce: NONCE }).toString('hex'),
    })),
  ],

  openMustFail: [
    {
      why: 'AAD is bound to thing_id ‖ field_id — a ciphertext moved to another field must not open',
      envelopeHex: seal(KEY, 'secret', fieldAad(THING_ID, FIELD_ID), { nonce: NONCE }).toString('hex'),
      keyHex: KEY.toString('hex'),
      aadHex: fieldAad(THING_ID, OTHER_FIELD_ID).toString('hex'),
    },
    {
      why: 'wrong key',
      envelopeHex: seal(KEY, 'secret', Buffer.alloc(0), { nonce: NONCE }).toString('hex'),
      keyHex: Buffer.alloc(32, 0xff).toString('hex'),
      aadHex: '',
    },
  ],

  kdf: {
    algorithm: 'scrypt',
    production: { N: 65536, r: 8, p: 2, dkLen: 32 },
    note: 'The test parameters below are intentionally weak so a conformance run stays fast. Production parameters are asserted separately.',
    cases: [
      {
        params: { N: 1024, r: 8, p: 1, dkLen: 32 },
        passwordUtf8: '123456',
        saltHex: '000102030405060708090a0b0c0d0e0f',
        expectHex: deriveKekSync('123456', Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex'), {
          algorithm: 'scrypt',
          N: 1024,
          r: 8,
          p: 1,
          dkLen: 32,
        }).toString('hex'),
      },
    ],
  },

  deviceKek: {
    rule: "HKDF-SHA256(ikm = device secret, salt = kdf salt, info = 'things:kek2:v1', length = 32)",
    deviceSecretHex: Buffer.alloc(32, 0x09).toString('hex'),
    saltHex: Buffer.alloc(16, 0x01).toString('hex'),
    expectHex: deriveDeviceKek(Buffer.alloc(32, 0x09), Buffer.alloc(16, 0x01)).toString('hex'),
  },

  objectFrames: {
    layout: {
      magic: 'TOBJ',
      versionByte: 1,
      algByte: 1,
      frameSizeOffset: 6,
      noncePrefixOffset: 10,
      headerLength: 18,
      frameSize: 1048576,
      frame: '4-byte big-endian ciphertext length, then ciphertext || 16-byte tag',
      nonce: 'noncePrefix (8 bytes) || frameIndex (4 bytes big-endian)',
      aad: 'frameIndex (4 bytes big-endian) || isLastFrame (1 byte)',
    },
    cases: [
      {
        keyHex: OBJECT_KEY.toString('hex'),
        noncePrefixHex: OBJECT_NONCE_PREFIX.toString('hex'),
        plaintextUtf8: OBJECT_PLAINTEXT.toString('utf8'),
        expectHex: encryptObject(OBJECT_KEY, OBJECT_PLAINTEXT, OBJECT_NONCE_PREFIX).toString('hex'),
      },
      {
        keyHex: OBJECT_KEY.toString('hex'),
        noncePrefixHex: OBJECT_NONCE_PREFIX.toString('hex'),
        plaintextUtf8: '',
        expectHex: encryptObject(OBJECT_KEY, Buffer.alloc(0), OBJECT_NONCE_PREFIX).toString('hex'),
      },
    ],
  },

  objectPathFanout: {
    rule: 'objects/<hash[0:2]>/<hash[2:4]>/<hash>, hash = lowercase hex sha256 of the PLAINTEXT bytes',
    examples: ['hello objects', ''].map((plaintextUtf8) => {
      const hash = sha256Hex(Buffer.from(plaintextUtf8, 'utf8'));
      return {
        plaintextUtf8,
        hash,
        path: `objects/${hash.slice(0, 2)}/${hash.slice(2, 4)}/${hash}`,
      };
    }),
  },
});

// ── key-derivation context strings, and dek_check ───────────────────────────
//
// Every case here carries `bytesUtf8` + `sha256`, which is the shape
// core-swift's checkSHA256 runner recognises — so the file is *executed* by
// both cores rather than reported as unmatched. Be honest about what that buys:
// on the Swift side it proves the digest of a literal, not that
// KeyHierarchy.Context holds these exact strings. The strings are pinned as
// USED by the four new `seal` cases in crypto-envelope.json, which core-swift
// runs byte-exactly through SecretBox. This file is the human-readable index of
// them, and the only home dek_check has.

write('crypto-context.json', ['ts', 'swift'], {
  $comment:
    'The fixed context strings from spec/crypto.md §2.2 and §1.2, plus dek_check. These strings are wire format: they are the caller AAD of each wrapped key (and the HKDF info of KEK₂), and they are what stops one kind of wrapped key being presented as another. Colons, not dots — an earlier draft used dotted names and the two cores could not open each other’s wrapped DEK.',
  $swiftCoverage:
    'Every case is executed by core-swift’s checkSHA256 (bytesUtf8 → sha256). That verifies the byte string, not the constant in KeyHierarchy.Context; the constants themselves are pinned as-used by crypto-envelope.json’s seal cases, which core-swift runs byte-exactly. core-ts additionally asserts each string equals the constant its own code uses.',
  version: 1,
  cases: [
    ...[
      ...CONTEXTS.map(({ name, context }) => ({
        name,
        role: 'GCM caller AAD of the TENV envelope holding this key',
        contextUtf8: context,
      })),
      {
        name: 'kek2 HKDF info',
        role: 'HKDF-SHA256 `info` for the device KEK — spec/crypto.md §1.2',
        contextUtf8: 'things:kek2:v1',
      },
    ].map((c) => ({
      ...c,
      bytesUtf8: c.contextUtf8,
      utf8Hex: Buffer.from(c.contextUtf8, 'utf8').toString('hex'),
      sha256: createHash('sha256').update(Buffer.from(c.contextUtf8, 'utf8')).digest('hex'),
    })),
    {
      name: 'dek_check',
      role:
        'base64(sha256(DEK)) truncated to 22 characters, stored in vault.json. NOT redundant with AES-GCM: GCM authenticates each wrapper in isolation and cannot prove that dek_wrap_pin and dek_wrap_device contain the SAME DEK. A stale device wrapper unwraps perfectly and yields the wrong key — SQLCipher then reports "file is not a database", which points nowhere. core-swift does not yet write or verify this; per spec/crypto.md §3.2 a writer MAY omit it but a reader that finds it MUST check it, so the Swift side needs the read half.',
      bytesUtf8: VECTOR_DEK,
      utf8Hex: Buffer.from(VECTOR_DEK, 'utf8').toString('hex'),
      sha256: createHash('sha256').update(Buffer.from(VECTOR_DEK, 'utf8')).digest('hex'),
      dekCheck: dekCheck(Buffer.from(VECTOR_DEK, 'utf8')),
    },
  ],
});

// ── vault.json ──────────────────────────────────────────────────────────────

const VAULT_SALT = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
const VAULT_DEK = Buffer.from(VECTOR_DEK, 'utf8');
const VAULT_DEVICE_SECRET = Buffer.alloc(32, 0x09);
const VAULT_PIN_NONCE = Buffer.from('0b0a090807060504030201ff', 'hex');
const VAULT_DEVICE_NONCE = Buffer.from('ff0102030405060708090a0b', 'hex');
const VAULT_KDF_PARAMS = { algorithm: 'scrypt' as const, N: 1024, r: 8, p: 1, dkLen: 32 };

const VAULT_PIN_WRAP = seal(
  deriveKekSync('123456', VAULT_SALT, VAULT_KDF_PARAMS),
  VAULT_DEK,
  Buffer.from('things:dek-wrap:pin:v1', 'utf8'),
  { nonce: VAULT_PIN_NONCE },
).toString('base64');

const VAULT_DEVICE_WRAP = seal(
  deriveDeviceKek(VAULT_DEVICE_SECRET, VAULT_SALT),
  VAULT_DEK,
  Buffer.from('things:dek-wrap:device:v1', 'utf8'),
  { nonce: VAULT_DEVICE_NONCE },
).toString('base64');

const VAULT_FULL: Record<string, string> = {
  dek_check: dekCheck(VAULT_DEK),
  dek_wrap_device: VAULT_DEVICE_WRAP,
  dek_wrap_pin: VAULT_PIN_WRAP,
  device_id: '01890000-0000-7000-8000-0000000000aa',
  failed_pin_attempts: '0',
  kdf_params: canonicalJson(VAULT_KDF_PARAMS),
  kdf_salt: VAULT_SALT.toString('base64'),
};

const { dek_wrap_device: _dropped, ...VAULT_NO_DEVICE } = VAULT_FULL;

write('vault-sidecar.json', ['ts', 'swift'], {
  $comment:
    'vault.json — the UNENCRYPTED sidecar beside things.sqlite that holds the KDF salt, the KDF parameters and the wrapped DEKs (spec/crypto.md §3). It cannot live in the meta table: reading meta needs the database open, opening the database needs the DEK, and getting the DEK needs meta. Each case is a whole file: the object on the left, the exact bytes on disk on the right. Flat, string keys to string values only, sorted, no whitespace, NO trailing newline.',
  $swiftCoverage:
    'Every case is executed by core-swift’s checkCanonicalJSON (value + canonicalJson). That is the real thing being tested: FileVaultStorage writes exactly `JSONValue.object(members).canonicalJSON`, so these strings are literally the bytes core-swift produces. core-ts writes the same bytes through FileVault.',
  version: 1,
  layout: {
    filename: 'vault.json',
    location: 'beside things.sqlite in the library root',
    valueType: 'string',
    trailingNewline: false,
    unknownKeys: 'PRESERVED on write — read-modify-write the whole object, never rebuild it from a struct. Two cores and two app versions share this file.',
    required: ['kdf_salt', 'kdf_params', 'dek_wrap_pin'],
    optional: ['dek_wrap_device', 'dek_check', 'device_id', 'failed_pin_attempts'],
  },
  inputs: {
    note: 'How the wrapped values above were produced. Weak KDF parameters keep a conformance run fast.',
    pin: '123456',
    dekUtf8: VECTOR_DEK,
    kdfSaltHex: VAULT_SALT.toString('hex'),
    kdfParams: VAULT_KDF_PARAMS,
    deviceSecretHex: VAULT_DEVICE_SECRET.toString('hex'),
    pinWrapNonceHex: VAULT_PIN_NONCE.toString('hex'),
    deviceWrapNonceHex: VAULT_DEVICE_NONCE.toString('hex'),
  },
  cases: [
    {
      name: 'a fully populated vault',
      value: VAULT_FULL,
      canonicalJson: canonicalJson(VAULT_FULL),
    },
    {
      name: 'no device wrapper — a normal state, spelled by omission and not by an empty string',
      value: VAULT_NO_DEVICE,
      canonicalJson: canonicalJson(VAULT_NO_DEVICE),
    },
    {
      name: 'unknown keys written by another core or a newer version survive a rewrite',
      value: { ...VAULT_FULL, zz_future_key: 'kept', aa_future_key: 'also kept' },
      canonicalJson: canonicalJson({ ...VAULT_FULL, zz_future_key: 'kept', aa_future_key: 'also kept' }),
    },
    {
      name: 'an unprovisioned library',
      value: {},
      canonicalJson: canonicalJson({}),
    },
  ],
});

// ── oplog attribute encoding ────────────────────────────────────────────────

const B64_ENVELOPE = seal(KEY, 'demo-value-not-a-real-secret', fieldAad(THING_ID, FIELD_ID), {
  nonce: NONCE,
}).toString('base64');

const ATTR_CASES: { name: string; value: Record<string, unknown> }[] = [
  {
    name: 'keys are sorted, not written in insertion order',
    value: { title: 'Second', updated_at: '2026-08-09T12:00:00.000Z', version_vector: '{"a":2}', id: 'x' },
  },
  {
    name: 'a BLOB is the {"$b64": …} wrapper, never a bare base64 string',
    value: { value_cipher: { $b64: B64_ENVELOPE }, is_secret: 1 },
  },
  {
    name: 'null is a value and is preserved — absent means "did not change", null means "set to NULL"',
    value: { section_id: null, value_text: null, label: 'Password' },
  },
  {
    name: 'booleans are INTEGER 0/1, never true/false',
    value: { is_pinned: 1, is_locked: 0 },
  },
  {
    name: 'REAL uses the shortest round-tripping form; an integral value is written as an integer',
    value: { sort_order: 2.5, other_order: 3.0, big: 9007199254740991 },
  },
  {
    name: 'minimal string escaping — \\n \\r \\t \\" \\\\ and \\u00XX for every other control character',
    value: { label: 'line\nbreak\ttab "quoted" back\\slash bell\u0007 backspace\b formfeed\f' },
  },
  {
    name: 'non-ASCII is emitted as literal UTF-8, never \\u-escaped',
    value: { title: 'Café — Ω 😀' },
  },
  {
    name: 'an empty attribute map (a delete carries none)',
    value: {},
  },
  {
    name: 'prev_json is the same encoding — the prior values of the same columns',
    value: { value_cipher: null, value_text: 'was plain text', updated_at: '2026-08-08T00:00:00.000Z' },
  },
];

write('oplog-attrs.json', ['ts', 'swift'], {
  $comment:
    'attrs_json and prev_json — spec/oplog.md §2 and §3. A change row crosses the wire verbatim, so these bytes ARE wire format. One serialisation, not two: keys sorted, no whitespace, minimal escaping, integers without exponents, null preserved. BLOBs use the {"$b64": …} wrapper because a bare base64 string is indistinguishable from a TEXT value — a reader expecting text would write the base64 AS text into a BLOB column, and a reader expecting the wrapper would write NULL. Either way the secret is destroyed on sync, in silence.',
  $swiftCoverage:
    'Every case is executed by core-swift’s checkCanonicalJSON (value + canonicalJson) against JSONValue.canonicalJSON — the same function Oplog.append uses to build attrs_json. This is a real cross-core byte comparison, not a shape check.',
  $note:
    'core-ts previously wrote JSON.stringify(attrs), i.e. insertion order, and JSON.stringify also emits \\b and \\f where spec/oplog.md §2 rule 3 requires \\u0008 and \\u000c. Both differences are pinned by the cases below.',
  version: 1,
  blobRule: '{"$b64": "<base64>"} for a BLOB column; null for a NULL BLOB',
  cases: ATTR_CASES.map((c) => ({ ...c, canonicalJson: canonicalJson(c.value) })),
});

// ── HLC drift clamping ──────────────────────────────────────────────────────

const DRIFT_WALL = '2026-08-09T12:00:00.000Z';
const DRIFT_WALL_MS = Date.parse(DRIFT_WALL);

function driftCase(name: string, last: string | null, wallIso: string, remote: string) {
  const clock = new Hlc(DEV_A, { last, clock: () => Date.parse(wallIso) });
  const produced = clock.receive(remote);
  const parts = parseHlc(produced);
  return {
    name,
    lastHlc: last,
    wallClockIso: wallIso,
    remoteHlc: remote,
    // The expected stamp, and its decomposition. core-swift's checkHLC reads the
    // decomposition; core-ts drives an actual receive() and compares `hlc`.
    hlc: produced,
    millis: Date.parse(parts.physical),
    counter: parts.counter,
    deviceId: parts.device,
  };
}

write('hlc-drift.json', ['ts', 'swift'], {
  $comment:
    'HLC receive-side drift clamping. spec/oplog.md §1.1 defines the receive rule but is SILENT on how far ahead a peer may drag the clock, and §5.3 records the two cores disagreeing. This pins core-swift’s bound — HLCGenerator.maximumDriftMilliseconds, one hour — as the contract, and core-ts has been changed to match. Without a bound, one peer whose clock says 2099 permanently poisons the ordering of the whole library: every later stamp on every device has to exceed it, and the log is append-only, so it cannot be undone.',
  $swiftCoverage:
    'Executed by core-swift’s checkHLC, which reads millis + counter + deviceId + hlc and asserts the expected stamp formats and re-parses. HONEST LIMIT: that verifies the expected output, not the clamping that produced it. core-swift has no generic runner that can drive HLCGenerator.receive with an injected wall clock, and adding one is the single highest-value thing to do on the Swift side of this file. core-ts drives the real receive() for every case.',
  version: 1,
  rule: 'remotePhysical = min(remote.physical, wallClock + maxDriftMs), then the ordinary receive rule',
  maxDriftMs: 60 * 60 * 1000,
  localDeviceId: DEV_A,
  cases: [
    driftCase(
      'a peer inside the window is folded in unchanged',
      `2026-08-09T11:59:59.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `2026-08-09T12:00:30.000Z-0004-${DEV_B}`,
    ),
    driftCase(
      'a peer behind the local wall clock cannot move it backwards',
      `2026-08-09T11:00:00.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `2026-08-01T00:00:00.000Z-0009-${DEV_B}`,
    ),
    driftCase(
      'the same physical on both sides takes the higher counter, plus one',
      `${DRIFT_WALL}-0003-${DEV_A}`,
      DRIFT_WALL,
      `${DRIFT_WALL}-0007-${DEV_B}`,
    ),
    driftCase(
      'exactly at the bound is NOT clamped',
      `2026-08-09T11:00:00.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `${new Date(DRIFT_WALL_MS + 60 * 60 * 1000).toISOString()}-0002-${DEV_B}`,
    ),
    driftCase(
      'one millisecond past the bound IS clamped',
      `2026-08-09T11:00:00.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `${new Date(DRIFT_WALL_MS + 60 * 60 * 1000 + 1).toISOString()}-0002-${DEV_B}`,
    ),
    driftCase(
      'a peer whose clock says 2099 is pinned to now + 1h and cannot poison the ordering',
      `2026-08-09T11:00:00.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `2099-01-01T00:00:00.000Z-0001-${DEV_B}`,
    ),
    driftCase(
      'clamping still advances causally: the counter comes from the remote stamp',
      `2026-08-09T11:00:00.000Z-0000-${DEV_A}`,
      DRIFT_WALL,
      `2099-01-01T00:00:00.000Z-00ff-${DEV_B}`,
    ),
  ],
});

console.log('done');
