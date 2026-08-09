import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { parseQuery, parseSize, stringifyQuery, tokenize } from '../src/search/parse.ts';
import { resolveDateRange } from '../src/search/dates.ts';
import { matchDoc, normalize, queryTouchesContent, runQuery } from '../src/search/evaluate.ts';
import type { ThingDoc } from '../src/types.ts';

const NOW = '2026-08-09T12:00:00.000Z';

function doc(over: Partial<ThingDoc> = {}): ThingDoc {
  return {
    id: '00000000-0000-7000-8000-000000000001',
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

describe('tokenizer', () => {
  test('splits on whitespace', () => {
    assert.deepEqual(tokenize('a b  c').map((t) => t.text), ['a', 'b', 'c']);
  });

  test('keeps quoted runs together and flags them', () => {
    const t = tokenize('"hello world" bare');
    assert.deepEqual(t[0], { text: 'hello world', quoted: true });
    assert.deepEqual(t[1], { text: 'bare', quoted: false });
  });

  test('handles a quoted filter value', () => {
    assert.deepEqual(tokenize('collection:"Home Lab"').map((t) => t.text), ['collection:Home Lab']);
  });

  test('backslash escapes', () => {
    assert.deepEqual(tokenize('a\\ b').map((t) => t.text), ['a b']);
    assert.deepEqual(tokenize('say\\"hi').map((t) => t.text), ['say"hi']);
  });

  test('an empty input yields no tokens', () => {
    assert.deepEqual(tokenize('   '), []);
  });
});

describe('parser', () => {
  test('bare text', () => {
    assert.deepEqual(parseQuery('cloudflare'), {
      terms: [{ kind: 'text', value: 'cloudflare', phrase: false, negated: false }],
      sort: null,
    });
  });

  test('every documented operator', () => {
    const q = parseQuery(
      'tag:1980 type:image has:password collection:1980 device:RAEID-PC modified:this-week created:2026-08 is:locked',
    );
    assert.deepEqual(
      q.terms.map((t) => (t.kind === 'filter' ? `${t.key}=${t.value}` : t.value)),
      [
        'tag=1980',
        'type=image',
        'has=password',
        'collection=1980',
        'device=raeid-pc',
        'modified=this-week',
        'created=2026-08',
        'is=locked',
      ],
    );
  });

  test('negation', () => {
    const q = parseQuery('-has:tag -draft');
    assert.equal(q.terms.length, 2);
    assert.ok(q.terms.every((t) => t.negated));
    assert.equal(q.terms[0].kind, 'filter');
    assert.equal(q.terms[1].kind, 'text');
  });

  test('quoted phrase', () => {
    const q = parseQuery('"exact phrase" loose');
    assert.deepEqual(q.terms[0], { kind: 'text', value: 'exact phrase', phrase: true, negated: false });
    assert.equal(q.terms[1].kind === 'text' && q.terms[1].phrase, false);
  });

  test('size with comparison and units', () => {
    assert.deepEqual(parseQuery('size:>50mb').terms[0], {
      kind: 'filter',
      key: 'size',
      op: 'gt',
      value: String(50 * 1024 * 1024),
      negated: false,
    });
    assert.equal(parseQuery('size:<=1kb').terms[0].value, '1024');
    assert.equal(parseQuery('size:100').terms[0].value, '100');
  });

  test('a malformed size degrades to free text rather than vanishing', () => {
    const t = parseQuery('size:huge').terms[0];
    assert.equal(t.kind, 'text');
    assert.equal(t.value, 'size:huge');
  });

  test('sort is a directive, not a term', () => {
    assert.deepEqual(parseQuery('sort:created').sort, { field: 'created', direction: 'desc' });
    assert.deepEqual(parseQuery('sort:title').sort, { field: 'title', direction: 'asc' });
    assert.deepEqual(parseQuery('sort:title.desc').sort, { field: 'title', direction: 'desc' });
    assert.equal(parseQuery('sort:created').terms.length, 0);
    assert.equal(parseQuery('sort:nonsense').terms.length, 1, 'an unknown sort field falls back to text');
  });

  test('an unknown key is free text', () => {
    const t = parseQuery('colour:red').terms[0];
    assert.equal(t.kind, 'text');
    assert.equal(t.value, 'colour:red');
  });

  test('filter values are lowercased, size values normalised', () => {
    assert.equal(parseQuery('TAG:Infrastructure').terms[0].value, 'infrastructure');
  });

  test('round-trips through stringifyQuery', () => {
    for (const input of [
      'tag:1980 -has:tag "exact phrase" cloudflare sort:created',
      'size:>52428800',
      'is:pinned is:locked',
    ]) {
      const q = parseQuery(input);
      assert.deepEqual(parseQuery(stringifyQuery(q)), q, `round trip failed for: ${input}`);
    }
  });

  test('parseSize units are 1024-based', () => {
    assert.equal(parseSize('1kb'), 1024);
    assert.equal(parseSize('1.5mb'), Math.round(1.5 * 1024 * 1024));
    assert.equal(parseSize('nope'), null);
  });
});

describe('date resolution', () => {
  test('symbolic ranges are half-open', () => {
    assert.deepEqual(resolveDateRange('today', NOW), {
      from: '2026-08-09T00:00:00.000Z',
      to: '2026-08-10T00:00:00.000Z',
    });
    // 2026-08-09 is a Sunday; the ISO week starts Monday 2026-08-03.
    assert.deepEqual(resolveDateRange('this-week', NOW), {
      from: '2026-08-03T00:00:00.000Z',
      to: '2026-08-10T00:00:00.000Z',
    });
    assert.deepEqual(resolveDateRange('this-month', NOW), {
      from: '2026-08-01T00:00:00.000Z',
      to: '2026-09-01T00:00:00.000Z',
    });
  });

  test('literal dates at three precisions', () => {
    assert.equal(resolveDateRange('2026', NOW)?.from, '2026-01-01T00:00:00.000Z');
    assert.equal(resolveDateRange('2026-08', NOW)?.to, '2026-09-01T00:00:00.000Z');
    assert.equal(resolveDateRange('2026-08-09', NOW)?.to, '2026-08-10T00:00:00.000Z');
  });

  test('unparseable values return null', () => {
    assert.equal(resolveDateRange('someday', NOW), null);
  });
});

describe('evaluator', () => {
  const opts = { now: NOW };

  test('bare terms are prefix matches, case- and diacritic-insensitive', () => {
    const d = doc({ title: 'Café Registrar' });
    assert.ok(matchDoc(parseQuery('cafe'), d, opts));
    assert.ok(matchDoc(parseQuery('regis'), d, opts));
    assert.ok(!matchDoc(parseQuery('egistrar'), d, opts), 'prefix, not substring');
  });

  test('quoted phrases are contiguous within one field', () => {
    const d = doc({ title: 'Example Registrar', text: ['Main account password'] });
    assert.ok(matchDoc(parseQuery('"account password"'), d, opts));
    assert.ok(!matchDoc(parseQuery('"registrar main"'), d, opts));
  });

  test('terms are ANDed and negation excludes', () => {
    const d = doc({ title: 'Demo Server', tags: ['infrastructure'] });
    assert.ok(matchDoc(parseQuery('demo tag:infrastructure'), d, opts));
    assert.ok(!matchDoc(parseQuery('demo tag:people'), d, opts));
    assert.ok(matchDoc(parseQuery('demo -tag:people'), d, opts));
    assert.ok(!matchDoc(parseQuery('demo -tag:infrastructure'), d, opts));
  });

  test('markers drive has: and type:', () => {
    const d = doc({ markers: ['has:password', 'type:image'] });
    assert.ok(matchDoc(parseQuery('has:password'), d, opts));
    assert.ok(matchDoc(parseQuery('type:image'), d, opts));
    assert.ok(!matchDoc(parseQuery('has:key'), d, opts));
  });

  test('has:tag and -has:tag implement Untagged', () => {
    assert.ok(matchDoc(parseQuery('has:tag'), doc({ tags: ['x'] }), opts));
    assert.ok(matchDoc(parseQuery('-has:tag'), doc({ tags: [] }), opts));
    assert.ok(!matchDoc(parseQuery('-has:tag'), doc({ tags: ['x'] }), opts));
  });

  test('size comparisons', () => {
    const big = doc({ max_object_size: 60 * 1024 * 1024 });
    assert.ok(matchDoc(parseQuery('size:>50mb'), big, opts));
    assert.ok(!matchDoc(parseQuery('size:<50mb'), big, opts));
  });

  test('date filters', () => {
    const d = doc({ created_at: '2026-08-05T10:00:00.000Z', updated_at: '2026-08-09T09:00:00.000Z' });
    assert.ok(matchDoc(parseQuery('modified:today'), d, opts));
    assert.ok(matchDoc(parseQuery('created:2026-08'), d, opts));
    assert.ok(!matchDoc(parseQuery('created:today'), d, opts));
    assert.ok(matchDoc(parseQuery('created:>2026-07'), d, opts));
    assert.ok(matchDoc(parseQuery('created:<2026-09'), d, opts));
  });

  test('trash, templates and archive do not bleed into ordinary results', () => {
    assert.ok(!matchDoc(parseQuery(''), doc({ is_trashed: true }), opts));
    assert.ok(matchDoc(parseQuery('is:trashed'), doc({ is_trashed: true }), opts));
    assert.ok(!matchDoc(parseQuery(''), doc({ is_template: true }), opts));
    assert.ok(matchDoc(parseQuery('is:template'), doc({ is_template: true }), opts));
    assert.ok(!matchDoc(parseQuery(''), doc({ is_archived: true }), opts));
    assert.ok(matchDoc(parseQuery(''), doc({ is_archived: true }), { ...opts, includeArchived: true }));
  });

  test('a locked Thing contributes nothing to content search', () => {
    const locked = doc({ title: 'Private Records', is_locked: true, markers: ['has:secret'], tags: ['personal'] });
    assert.ok(!matchDoc(parseQuery('private'), locked, opts), 'free text must not reach a locked Thing');
    assert.ok(!matchDoc(parseQuery('has:secret'), locked, opts), 'nor a content marker');
    assert.ok(matchDoc(parseQuery('is:locked'), locked, opts), 'but the Locked view still lists it');
    assert.ok(matchDoc(parseQuery('tag:personal'), locked, opts), 'and so does its tag');
  });

  test('queryTouchesContent identifies the queries that must exclude locked Things', () => {
    assert.equal(queryTouchesContent(parseQuery('is:pinned')), false);
    assert.equal(queryTouchesContent(parseQuery('hello')), true);
    assert.equal(queryTouchesContent(parseQuery('has:password')), true);
    assert.equal(queryTouchesContent(parseQuery('type:image')), true);
  });

  test('sorting', () => {
    const docs = [
      doc({ id: 'a', title: 'Beta', created_at: '2026-01-01T00:00:00.000Z' }),
      doc({ id: 'b', title: 'alpha', created_at: '2026-02-01T00:00:00.000Z' }),
    ];
    assert.deepEqual(runQuery(parseQuery('sort:title'), docs, opts).map((d) => d.id), ['b', 'a']);
    assert.deepEqual(runQuery(parseQuery('sort:created'), docs, opts).map((d) => d.id), ['b', 'a']);
    assert.deepEqual(runQuery(parseQuery('sort:created.asc'), docs, opts).map((d) => d.id), ['a', 'b']);
  });

  test('normalize folds diacritics and case', () => {
    assert.equal(normalize('Café'), 'cafe');
    assert.equal(normalize('ÅNGSTRÖM'), 'angstrom');
  });
});
