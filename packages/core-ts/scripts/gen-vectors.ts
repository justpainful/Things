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

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { specDir } from '../src/paths.ts';
import { parseQuery } from '../src/search/parse.ts';
import { runQuery } from '../src/search/evaluate.ts';
import { resolveDateRange } from '../src/search/dates.ts';
import { compareHlc, formatHlc, parseHlc } from '../src/hlc.ts';
import { compareVectors, mergeVectors, stringifyVector } from '../src/versionVector.ts';
import { orderBetween, orderForIndex, listNeedsRebalance, rebalance, MIN_GAP } from '../src/sortOrder.ts';
import { fieldAad, seal } from '../src/crypto/envelope.ts';
import { deriveKekSync } from '../src/crypto/kdf.ts';
import { encryptObject } from '../src/crypto/frames.ts';
import { deriveDeviceKek } from '../src/crypto/keyring.ts';
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

write('search-parser.json', {
  $comment:
    'Search DSL parser conformance. Input string → AST. The AST is clock-free: relative dates stay symbolic and are resolved by the evaluator against an injected `now`.',
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

write('search-eval.json', {
  $comment:
    'Search evaluator conformance. Fixed documents + fixed `now` → the exact list of matching ids, in result order. Note d4: a locked Thing contributes nothing to content search but stays reachable via is:locked and tag:.',
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

write('hlc.json', {
  $comment:
    'Hybrid logical clock. Format: <ISO-8601 UTC ms>-<counter, 4 lowercase hex digits>-<deviceId>. Plain string comparison IS the ordering.',
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

write('version-vector.json', {
  $comment:
    'Version vector comparison. A missing device counts as zero. `dominates` means A saw B; `concurrent` is the only case that produces a conflict.',
  version: 1,
  comparisons: VV_PAIRS.map(([a, b]) => ({ a, b, expect: compareVectors(a, b) })),
  merges: VV_PAIRS.map(([a, b]) => ({ a, b, expect: mergeVectors(a, b) })),
  canonicalJson: [
    { vector: { b: 1, a: 2 }, expect: stringifyVector({ b: 1, a: 2 }) },
    { vector: {}, expect: stringifyVector({}) },
  ],
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

write('sort-order.json', {
  $comment:
    'Fractional sort_order. A reorder must be a single-row write; rebalancing is explicit and only happens when the gap degrades below minGap.',
  version: 1,
  minGap: MIN_GAP,
  defaultStep: 1,
  between: BETWEEN.map(([prev, next]) => ({ prev, next, expect: orderBetween(prev, next) })),
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

write('crypto-envelope.json', {
  $comment:
    'AES-256-GCM envelope, scrypt KDF, and framed object encryption. Every nonce and salt here is FIXED so the outputs are deterministic — production always uses random ones.',
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

console.log('done');
