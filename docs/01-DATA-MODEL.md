# Things — Data Model

The goal of this document is narrow and specific: **define a model that can absorb every feature in
the product vision without a rewrite.** Templates, sync, history, smart collections, dedupe, and
device-aware paths are all deliberately *consequences* of the model below rather than features
bolted onto it.

Governing rule: *the database adapts to the thing the user wants to keep.*

---

## 1. The five ideas

1. **Thing → Section → Field.** Three levels. Never more. Deep hierarchy is the failure mode we are
   explicitly avoiding.
2. **Base kind + variant.** A small closed set of storage/render primitives, plus an open string
   for meaning. `youtube` is not a type; it is `url` with `variant:"youtube"`.
3. **Content-addressed objects.** Bytes are stored once, keyed by the SHA-256 of their plaintext,
   encrypted at rest, reference-counted.
4. **Everything a Thing points at is a Field.** Relations, files, paths, tags — all Fields. This is
   what makes ordering, sections, drag-and-drop, and the "Add Field" flow uniform.
5. **The oplog is the truth of *change*.** Materialized tables are a cache of the fold. History,
   Undo, Restore, and sync conflict detection are one mechanism, not four.

---

## 2. Field kinds — the central decision

The vision lists ~50 field types. Encoding 50 types as 50 enum cases means every new type is a
schema migration in two languages. Instead:

```
kind    = HOW it is stored and rendered   (closed set, ~16, changing it is a contract change)
variant = WHAT it means                   (open string, adding one is a data change)
```

### Base kinds

| kind | storage | notes |
|---|---|---|
| `text` | `value_text` | single line |
| `longText` | `value_text` | multi-line plain |
| `richText` | `value_json` | portable rich-text tree (headings, lists, checklists, quote, code, links, tables) |
| `number` | `value_text` (decimal string) | decimal string avoids float drift across Swift/JS |
| `boolean` | `value_text` `"0"`/`"1"` | |
| `date` | `value_text` ISO-8601 | `value_json.precision` = `date`/`time`/`datetime` |
| `url` | `value_text` | |
| `path` | `file_ref_id` | device-scoped filesystem location; the row lives in `file_ref` |
| `secret` | `value_cipher` | **never** written in plaintext, never indexed by value |
| `attachment` | → `object` or `file_ref` | stored bytes or a pointer |
| `color` | `value_text` `#RRGGBB` | |
| `code` | `value_text` | `value_json.language` |
| `geo` | `value_json` `{lat,lon}` | |
| `money` | `value_json` `{amount:"12.50",currency:"SAR"}` | |
| `relation` | `value_text` = target thing id | |
| `tagList` | → `thing_tag` | |

### Variants (data, not code — `spec/field-kinds.json`)

| kind | variants |
|---|---|
| `text` | `plain` `username` `email` `phone` `address` `ip` `port` `reference` |
| `secret` | `password` `apiKey` `token` `secret` `sshKey` `recoveryCodes` `pin` |
| `url` | `website` `youtube` `github` `discord` `x` `instagram` `tiktok` `steam` `dashboard` … |
| `attachment` | `file` `image` `video` `audio` `pdf` `icon` `avatar` `logo` `qr` |
| `number` | `plain` `rating` `progress` `percent` |
| `path` | `file` `folder` |
| `code` | `code` `command` `json` `config` |

The registry entry carries display metadata: label, SF Symbol, web icon, keyboard affordances,
default `is_secret`, validation regex, and the quick actions offered on long-press. **Adding
"Threads" ships as a one-line JSON change to both clients.**

### Why this matters concretely

The vision's rule "*it's all just enhanced Fields internally*" is exactly this table. A `password`
and an `apiKey` differ only in label, icon, and copy-button wording — they must not differ in
storage, or you get two encryption paths and two bugs.

---

## 3. Schema

IDs are **UUIDv7** — random-looking but time-sortable, so creation order survives without a
separate index and ids sort meaningfully in both languages.

### Things

```sql
CREATE TABLE thing (
  id              TEXT PRIMARY KEY,        -- uuidv7
  title           TEXT NOT NULL,
  icon_json       TEXT,                    -- {type:'symbol'|'emoji'|'object'|'auto', value, tint}
  cover_object    TEXT REFERENCES object(hash),
  is_pinned       INTEGER NOT NULL DEFAULT 0,
  is_locked       INTEGER NOT NULL DEFAULT 0,   -- requires Face ID; hidden from previews
  is_archived     INTEGER NOT NULL DEFAULT 0,
  created_at      TEXT NOT NULL,           -- ISO-8601 UTC
  updated_at      TEXT NOT NULL,
  viewed_at       TEXT,                    -- drives Recents
  deleted_at      TEXT,                    -- soft delete → Recently Deleted
  version_vector  TEXT NOT NULL            -- {deviceId: counter}
);
```

`icon_json.type = 'auto'` is the "Things generates a system icon from the content" behavior:
a deterministic local function of title + dominant field kinds → SF Symbol + tint. No AI, no cloud.

### Sections and Fields

```sql
CREATE TABLE section (
  id         TEXT PRIMARY KEY,
  thing_id   TEXT NOT NULL REFERENCES thing(id) ON DELETE CASCADE,
  title      TEXT,                          -- NULL = the unnamed default section
  sort_order REAL NOT NULL,                 -- fractional ordering, see §4
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE field (
  id           TEXT PRIMARY KEY,
  thing_id     TEXT NOT NULL REFERENCES thing(id) ON DELETE CASCADE,
  section_id   TEXT REFERENCES section(id) ON DELETE SET NULL,
  sort_order   REAL NOT NULL,

  kind         TEXT NOT NULL,               -- base kind, §2
  variant      TEXT,                         -- open registry string
  label        TEXT NOT NULL,               -- user-authored: "Main account password"

  value_text   TEXT,
  value_json   TEXT,
  value_cipher BLOB,                        -- AES-256-GCM envelope, secrets only
  object_hash  TEXT REFERENCES object(hash),
  file_ref_id  TEXT REFERENCES file_ref(id),

  is_secret      INTEGER NOT NULL DEFAULT 0, -- default from registry, user-overridable
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  version_vector TEXT NOT NULL              -- per-field → field-level conflict detection
);
```

**Exactly one** of `value_text` / `value_json` / `value_cipher` / `object_hash` / `file_ref_id` is
non-NULL, enforced by a CHECK constraint and by a conformance vector.

The `version_vector` living on the *field* row rather than the Thing row is what makes the vision's
requirement work: *phone edits Notes, PC edits Password → both apply, no conflict.*

### Objects — content-addressed store

```sql
CREATE TABLE object (
  hash         TEXT PRIMARY KEY,            -- sha256 of PLAINTEXT bytes (lowercase hex)
  byte_size    INTEGER NOT NULL,
  mime_type    TEXT,
  width        INTEGER, height INTEGER, duration_ms INTEGER,
  enc_key_wrap BLOB NOT NULL,               -- per-object key, wrapped by the DEK
  enc_nonce    BLOB NOT NULL,
  ref_count    INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL
);
```

Hashing **plaintext** (not ciphertext) is deliberate: it preserves dedupe even though every object
gets a unique random key. "This file is already stored in Things" is a primary-key hit.

On disk: `objects/<first2>/<next2>/<hash>` — the fan-out the vision sketched, which also keeps
Windows directories under control at scale.

Original filenames belong to the *field*, not the object — the same PNG can be `logo.png` in one
Thing and `avatar.png` in another. That lives in `field.value_json.filename`.

### File references — device-aware paths

`D:\Servers\BeamNG\Server1` is meaningless without knowing *which machine*. One table serves both
the "File Path" field and the "Reference original file" attachment mode — they are the same idea.

```sql
CREATE TABLE file_ref (
  id           TEXT PRIMARY KEY,
  device_id    TEXT NOT NULL REFERENCES device(id),
  path         TEXT NOT NULL,
  is_directory INTEGER NOT NULL DEFAULT 0,
  size_at_link INTEGER,
  mtime_at_link TEXT,
  content_hash TEXT,                        -- lazy; enables "moved, not missing" recovery
  last_seen_at TEXT,
  status       TEXT NOT NULL DEFAULT 'unknown'  -- present | missing | unknown
);
```

Behavior falls out of this: on the owning device the action is **Open in Explorer**; elsewhere the
UI shows `RAEID-PC` + the path + **Copy Path**. `status='missing'` populates the Missing Files view.

### Collections, tags, relations

```sql
CREATE TABLE collection (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  icon_json TEXT, sort_order REAL NOT NULL,
  parent_id TEXT REFERENCES collection(id),  -- at most one level; UI enforces
  is_smart INTEGER NOT NULL DEFAULT 0,
  smart_query TEXT,                          -- a search-DSL string
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);

CREATE TABLE collection_member (
  collection_id TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
  thing_id      TEXT NOT NULL REFERENCES thing(id) ON DELETE CASCADE,
  sort_order    REAL NOT NULL,
  PRIMARY KEY (collection_id, thing_id)
);

CREATE TABLE tag (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT);
CREATE TABLE thing_tag (thing_id TEXT, tag_id TEXT, PRIMARY KEY (thing_id, tag_id));
```

Many-to-many membership is what lets **Cloudflare** appear in both `Development` and `1980` with
one copy of the data. A **Saved Search** is not a separate concept — it is
`collection(is_smart=1, smart_query='tag:1980 type:file')`. Smart Views ship as seeded smart
collections, which means the user can edit them and build their own.

**Relations are Fields** (`kind='relation'`). Backlinks are an index, never a second row:

```sql
CREATE INDEX idx_field_relation ON field(value_text) WHERE kind='relation';
```

So "1980 Website → Cloudflare" is one row, and Cloudflare's detail screen shows
*Referenced by: 1980 Website* by querying that index. No dangling pairs, no sync divergence between
the two halves of a relationship.

### Devices

```sql
CREATE TABLE device (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,     -- 'RAEID-PC'
  platform TEXT NOT NULL,                       -- ios | windows
  public_key BLOB, paired_at TEXT, last_seen_at TEXT,
  is_self INTEGER NOT NULL DEFAULT 0
);
```

---

## 4. Ordering

`sort_order REAL` with fractional insertion: to drop an item between `2.0` and `3.0`, write `2.5`.
No renumbering cascade, so a reorder is a single-row change — which matters enormously for sync,
where renumbering 40 rows would manufacture 40 phantom conflicts. Periodic rebalancing when
precision degrades.

---

## 5. The oplog — history, undo, restore, and sync as one mechanism

Every mutation appends here. Materialized tables above are the fold.

```sql
CREATE TABLE change (
  id          TEXT PRIMARY KEY,   -- uuidv7
  device_id   TEXT NOT NULL,
  hlc         TEXT NOT NULL,      -- hybrid logical clock, lexicographically sortable
  entity_type TEXT NOT NULL,      -- thing|section|field|collection|member|tag|file_ref
  entity_id   TEXT NOT NULL,
  op          TEXT NOT NULL,      -- create|update|delete
  attrs_json  TEXT NOT NULL,      -- changed attributes ONLY
  prev_json   TEXT,               -- prior values → cheap undo/restore
  applied_at  TEXT NOT NULL
);
CREATE INDEX idx_change_entity ON change(entity_id, hlc);
CREATE INDEX idx_change_sync   ON change(device_id, hlc);
```

**Wall-clock timestamps are not used for causality.** An HLC keeps physical time readable for the
History UI while remaining monotonic, so a phone with a slightly wrong clock cannot silently win an
argument with the PC.

This one table delivers:

- **History** — `WHERE entity_id IN (thing + its fields) ORDER BY hlc DESC`, grouped by day, which
  renders as *"Today · Changed password"*.
- **Restore** — append the inverse from `prev_json`. Never destructive; restoring is itself
  history.
- **Undo/Redo** — same mechanism, scoped to the session.
- **Sync** — "send me everything after HLC *x*".

Retention: the oplog is compacted on a configurable schedule (default: keep 90 days of detail, then
collapse to one snapshot per entity). Secret values inside `attrs_json`/`prev_json` are stored as
ciphertext envelopes, never plaintext — otherwise History would become a plaintext password log,
which would be a serious and easily-missed security bug.

### Conflicts, done properly

The vision rejects last-write-wins. Timestamps alone cannot distinguish "later" from "concurrent",
so each entity carries a **version vector** `{deviceId: counter}`:

| Comparison | Meaning | Action |
|---|---|---|
| A dominates B | A saw B | apply A |
| B dominates A | B saw A | keep B |
| Neither dominates | genuinely concurrent | **conflict** |

```sql
CREATE TABLE conflict (
  id TEXT PRIMARY KEY, entity_type TEXT, entity_id TEXT,
  version_a_json TEXT NOT NULL, version_b_json TEXT NOT NULL,
  detected_at TEXT NOT NULL, resolved_at TEXT, resolution TEXT
);
```

Because vectors live on **fields**, the vision's example resolves exactly as demanded: phone edits
Notes, PC edits Password → two different entities → no conflict, both apply. Only a genuine
same-field collision surfaces **2 Versions**, and the higher-HLC value is shown provisionally so
the app stays usable while the choice is pending.

---

## 6. Search

```sql
CREATE VIRTUAL TABLE thing_fts USING fts5(
  thing_id UNINDEXED,
  title, labels, values, notes, tags, urls, paths, filenames, collections,
  tokenize = "unicode61 remove_diacritics 2"
);
```

**Secret values are never inserted.** A `secret` field contributes its *label* and the token
`has:password` — implementing "show Things that contain a Password field without revealing the
password", which is a security property, not a UI preference.

Locked Things contribute nothing while locked; they are excluded from search previews, Recents
previews, and the app-switcher snapshot.

### Query grammar (`spec/search.md`)

```
tag:1980  type:image  has:password  has:file  collection:1980
device:RAEID-PC  modified:this-week  created:2026-08  is:locked  is:pinned
"exact phrase"  -excluded
```

Bare text matches everywhere. Operators are optional sugar the UI's filter chips generate — the
user never has to learn them, and the power user never has to leave the keyboard. Both cores parse
this with the **same grammar and the same test vectors**, so a saved search written on the PC
resolves identically on the phone.

---

## 7. Encryption

| Layer | Mechanism |
|---|---|
| Whole database | SQLCipher (AES-256), key = the DEK |
| Secret fields | AES-256-GCM, **AAD = `thing_id ‖ field_id`** |
| Objects | per-object random key, AES-256-GCM in 1 MiB frames (seekable video), key wrapped by the DEK |
| Key hierarchy | passphrase → KDF → KEK → unwraps DEK. iOS additionally wraps the DEK in the Keychain behind Face ID. |

Binding secret ciphertext to its `thing_id ‖ field_id` via AAD means a copied ciphertext blob
cannot be transplanted into another Thing to trick the app into decrypting it somewhere it does not
belong — cheap to implement, and the kind of thing that is painful to retrofit.

Because both devices share the DEK after pairing, **sync moves ciphertext untouched**: the
transport never sees plaintext, and re-encryption per transfer is unnecessary.

Exact KDF choice, parameters, and envelope byte layout land in `spec/crypto.md` once the platform
capability research (in flight) confirms what is available under free provisioning.

---

## 8. Templates

A Template is a Thing with `is_template=1` living outside normal listings. "New from Template"
deep-copies its sections and fields with empty values. Because a Template is just a Thing, the user
can build one from any existing Thing ("Save as Template") — no separate editor, no second schema.

Seeded: Account · Person · Server · Project · Card · Blank.

---

## 9. What this model buys us later, for free

| Feature | Falls out of |
|---|---|
| Smart Collections / Saved Searches | `collection.is_smart` + query grammar |
| Thing History, Restore, Undo | oplog + `prev_json` |
| Field-level sync merge | per-field version vectors |
| "This file is already in Things" | `object.hash` primary key |
| "This link already exists in GitHub Project" | index on `field.value_text` where `kind='url'` |
| Backlinks / Referenced by | relation index |
| Device-aware Open/Copy Path | `file_ref.device_id` |
| Selective sync to the phone | `object.byte_size` + policy |
| Batch operations | set-based writes over the same tables |
| Adding a new link type | one line in `field-kinds.json` |

Every one of those is a query or a data change — **none is a migration.** That was the objective.

---

## 10. Deliberately deferred

- Rich-text tree format → `spec/richtext.md` (M4). Portable JSON, not NSAttributedString or HTML.
- Encrypted backup container layout → `spec/backup.md` (M8).
- Thumbnail cache keying and eviction → M5.
- Full-text indexing of PDF/document *contents* → out of scope for v1.
