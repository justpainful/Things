# Things — Search

NORMATIVE. Both cores parse and evaluate this identically, enforced by
`spec/vectors/search-parser.json` and `spec/vectors/search-eval.json`. A saved search written on
the PC must resolve identically on the phone.

Search is the most important surface in the app. Five of the six access paths lead through it, so
it is designed to be fast and forgiving before it is designed to be powerful.

---

## 1. The security rule comes first

**Secret values are never indexed and never returned.**

A `secret` field contributes to the index:
- its **label** ("Main account password")
- its **marker** from `field-kinds.json` (`has:password`, `has:key`, `has:secret`)

and nothing else. Typing `password` therefore surfaces *the Things that have one* without ever
revealing a value — which is a security property, not a presentation choice.

**Locked Things contribute nothing while locked.** No title, no labels, no markers. They are absent
from results, from search previews, from Recents previews, and from the app-switcher snapshot.

Deleted (trashed) Things are excluded unless the query says `is:deleted`.

---

## 2. Query grammar

```
query      := term (WS term)*
term       := negation? (operator | phrase | word)
negation   := "-"
operator   := key ":" value
key        := tag | type | has | collection | device | is | modified | created | size | sort
phrase     := '"' <any except quote> '"'
word       := <non-space, non-quote run>
```

Bare words are free text, matched across every indexed column. Multiple terms are **AND**.
A quoted phrase matches as a phrase. `-` negates any term.

Parsing is **total** — it never throws. Malformed input degrades to free text, because a search
field that errors while you are mid-word is hostile. `has:` with no value is a literal `has:`
search; `tag:"two words"` is valid.

### Operators

| Operator | Values | Notes |
|---|---|---|
| `tag:` | tag name | case-insensitive |
| `type:` | `image` `video` `audio` `document` `link` `note` `file` | from the variant registry `marker` |
| `has:` | `password` `key` `secret` `file` `url` `path` `tag` `note` `attachment` | presence, never value |
| `collection:` | name or id | |
| `device:` | device name or id | for device-scoped paths |
| `is:` | `pinned` `locked` `archived` `deleted` `template` `missing` `untagged` `conflicted` | |
| `modified:` `created:` | `today` `yesterday` `this-week` `this-month` `this-year`, `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or `>`/`<` + any of those | |
| `size:` | `>10mb` `<1gb` `>500kb` | applies to attached objects |
| `sort:` | `relevance` (default) `created` `modified` `viewed` `title` `size` | at most one; last wins |

Units are case-insensitive and binary (`mb` = 1024²).

### Examples

```
1980                              free text across everything
github.com                        every Thing referencing GitHub
D:\                               every Windows path
tag:1980 type:file                saved as a Smart Collection
has:password -tag:old             accounts, excluding archived ones
device:RAEID-PC has:path          what lives on the PC
modified:this-week sort:modified  this week's work, newest first
"recovery codes"                  exact phrase
```

The average user never learns any of this. The filter chips in the UI **generate** these strings,
and the query box shows what they generated — which is how a power user discovers the syntax
without being taught it.

---

## 3. Evaluation

Two stages, because FTS5 and SQL are each good at different halves.

**Stage 1 — FTS5** handles free text and phrases against `thing_fts`, producing candidate
`thing_id`s ranked by `rank`.

**Stage 2 — SQL predicates** handle every operator. Operators are *not* pushed into the FTS query.

That split is deliberate and was found the hard way: markers like `has:password` do not survive
`unicode61` tokenisation — the tokenizer splits on `:` and drops the structure, so a marker stored
as text becomes two useless tokens. Operators are therefore resolved as SQL `EXISTS` predicates
over `field`, `thing_tag`, `collection_member`, and `file_ref`.

An empty free-text part means stage 1 is skipped entirely and the operators run alone, so
`is:pinned` is a cheap indexed query rather than a full-text scan.

### Ranking

`sort:relevance` (the default) orders by: exact title match, then title prefix match, then FTS5
`rank`, then `viewed_at` descending. Recency breaks ties because in a personal store the thing you
touched last week is almost always the thing you mean.

Any other `sort:` bypasses relevance entirely.

---

## 4. Tokenisation

```sql
tokenize = "unicode61 remove_diacritics 2"
```

`remove_diacritics 2` is the Unicode-correct setting — version 1 mishandles several scripts.

Two consequences worth stating, because both look like bugs otherwise:

- **`porter` stemming is not used.** It is English-only, and this index holds usernames, hostnames,
  file paths, and (later) Arabic. Stemming `things` → `thing` is a poor trade for corrupting
  `Cloudflare-Prod-01`.
- **Paths and URLs are additionally indexed split on separators** (`/ \ . : - _`), so `D:\Servers`
  matches a query for `Servers`, and `github.com/user/repo` matches `repo`. Without this, the most
  common real query in this app — pasting part of a path — silently returns nothing.

---

## 5. Index maintenance

The FTS row for a Thing is rebuilt on any change to: its title, its fields, its tags, or its
collection membership. Rebuild-on-write rather than triggers, because the rebuild must consult the
variant registry to decide what a field contributes — which is application logic, not SQL.

Locking or unlocking a Thing rebuilds (or clears) its row immediately.

`thing_fts` is an ordinary FTS5 table inside the SQLCipher database, so **the inverted index is
encrypted at rest along with everything else** — a search index in the clear would otherwise leak
exactly the terms the encryption exists to protect.

⚠️ The column named `values` is a **SQLite reserved word** and must be quoted in every statement,
in both cores.

⚠️ Whether FTS5 is compiled into the SQLCipher binary is verified at runtime, not assumed. The
Swift core probes `PRAGMA compile_options` plus a real `CREATE VIRTUAL TABLE` at startup and falls
back to a `LIKE`-based `SearchIndex` implementation behind the same protocol. The fallback is
slower and has no ranking; it is a safety net, not a supported mode, and the app reports it.

---

## 6. Saved searches

A saved search is not a separate concept — it is `collection(is_smart = 1, smart_query = '…')`.
Smart Views ship as seeded smart collections, which means the user can open one, see the query that
produced it, edit it, and make their own. That is the whole feature, and it costs no extra schema.
