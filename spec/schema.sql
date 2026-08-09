-- Things — canonical schema, v1
-- NORMATIVE. Both cores (Swift/GRDB and TypeScript/node:sqlite) must produce a byte-identical
-- schema from this file. A cross-open conformance test in CI proves it: Node writes a database,
-- Swift opens it, and vice versa.
--
-- Conventions:
--   ids        TEXT, UUIDv7 (time-sortable — creation order needs no extra index)
--   timestamps TEXT, ISO-8601 UTC with milliseconds: 2026-08-09T21:14:03.412Z
--   booleans   INTEGER 0/1
--   ordering   REAL, fractional insertion (see docs/01-DATA-MODEL.md §4)
--   vectors    TEXT, JSON object {deviceId: counter}

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ─────────────────────────────────────────────────────────────────────────────
-- Devices
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE device (
  id           TEXT    PRIMARY KEY,
  name         TEXT    NOT NULL,              -- 'RAEID-PC', 'iPhone'
  platform     TEXT    NOT NULL CHECK (platform IN ('ios','windows')),
  public_key   BLOB,
  paired_at    TEXT,
  last_seen_at TEXT,
  is_self      INTEGER NOT NULL DEFAULT 0 CHECK (is_self IN (0,1))
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Things
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE thing (
  id             TEXT    PRIMARY KEY,
  title          TEXT    NOT NULL,
  icon_json      TEXT,                        -- {type:'symbol'|'emoji'|'object'|'auto', value, tint}
  cover_object   TEXT    REFERENCES object(hash) ON DELETE SET NULL,

  is_pinned      INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned   IN (0,1)),
  is_locked      INTEGER NOT NULL DEFAULT 0 CHECK (is_locked   IN (0,1)),
  is_archived    INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0,1)),
  is_template    INTEGER NOT NULL DEFAULT 0 CHECK (is_template IN (0,1)),

  created_at     TEXT    NOT NULL,
  updated_at     TEXT    NOT NULL,
  viewed_at      TEXT,                        -- drives Recents
  deleted_at     TEXT,                        -- soft delete → Recently Deleted

  version_vector TEXT    NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_thing_updated  ON thing(updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_thing_viewed   ON thing(viewed_at  DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_thing_pinned   ON thing(is_pinned)       WHERE is_pinned = 1 AND deleted_at IS NULL;
CREATE INDEX idx_thing_deleted  ON thing(deleted_at)      WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_thing_template ON thing(is_template)     WHERE is_template = 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- Sections
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE section (
  id             TEXT    PRIMARY KEY,
  thing_id       TEXT    NOT NULL REFERENCES thing(id) ON DELETE CASCADE,
  title          TEXT,                        -- NULL = the unnamed default section
  sort_order     REAL    NOT NULL,
  created_at     TEXT    NOT NULL,
  updated_at     TEXT    NOT NULL,
  version_vector TEXT    NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_section_thing ON section(thing_id, sort_order);

-- ─────────────────────────────────────────────────────────────────────────────
-- Fields — the heart of the model
--
-- kind    = HOW it is stored and rendered (closed set; changing it is a contract change)
-- variant = WHAT it means               (open registry, see field-kinds.json)
--
-- Exactly one value column is non-NULL. Enforced below and by conformance vectors.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE field (
  id             TEXT    PRIMARY KEY,
  thing_id       TEXT    NOT NULL REFERENCES thing(id)   ON DELETE CASCADE,
  section_id     TEXT             REFERENCES section(id) ON DELETE SET NULL,
  sort_order     REAL    NOT NULL,

  kind           TEXT    NOT NULL CHECK (kind IN (
                   'text','longText','richText','number','boolean','date','url','path',
                   'secret','attachment','color','code','geo','money','relation','tagList')),
  variant        TEXT,
  label          TEXT    NOT NULL,            -- user-authored: "Main account password"

  value_text     TEXT,
  value_json     TEXT,
  value_cipher   BLOB,                        -- AES-256-GCM envelope; secrets only
  object_hash    TEXT             REFERENCES object(hash)   ON DELETE RESTRICT,
  file_ref_id    TEXT             REFERENCES file_ref(id)   ON DELETE SET NULL,

  is_secret      INTEGER NOT NULL DEFAULT 0 CHECK (is_secret IN (0,1)),
  created_at     TEXT    NOT NULL,
  updated_at     TEXT    NOT NULL,
  version_vector TEXT    NOT NULL DEFAULT '{}',

  -- Exactly one value carrier (or none, for a freshly-added empty field).
  CHECK (
    (CASE WHEN value_text   IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN value_json   IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN value_cipher IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN object_hash  IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN file_ref_id  IS NOT NULL THEN 1 ELSE 0 END)
    <= 1
  ),
  -- A secret is never stored in the clear.
  CHECK (is_secret = 0 OR (value_text IS NULL AND value_json IS NULL))
);

CREATE INDEX idx_field_thing    ON field(thing_id, sort_order);
CREATE INDEX idx_field_section  ON field(section_id, sort_order);
CREATE INDEX idx_field_kind     ON field(kind);
CREATE INDEX idx_field_object   ON field(object_hash) WHERE object_hash IS NOT NULL;
-- Backlinks: "Referenced by" is this index, not a second row.
CREATE INDEX idx_field_relation ON field(value_text) WHERE kind = 'relation';
-- Duplicate-URL detection: "This link already exists in GitHub Project."
CREATE INDEX idx_field_url      ON field(value_text) WHERE kind = 'url';

-- ─────────────────────────────────────────────────────────────────────────────
-- Objects — content-addressed, encrypted, deduplicated
--
-- hash is of the PLAINTEXT bytes, so dedupe survives per-object random keys.
-- On disk: objects/<hash[0:2]>/<hash[2:4]>/<hash>
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE object (
  hash         TEXT    PRIMARY KEY,           -- sha256, lowercase hex
  byte_size    INTEGER NOT NULL,
  mime_type    TEXT,
  width        INTEGER,
  height       INTEGER,
  duration_ms  INTEGER,
  enc_key_wrap BLOB    NOT NULL,              -- per-object key, wrapped by the DEK
  enc_nonce    BLOB    NOT NULL,
  ref_count    INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT    NOT NULL
);

CREATE INDEX idx_object_size    ON object(byte_size DESC);
CREATE INDEX idx_object_orphan  ON object(ref_count) WHERE ref_count = 0;

CREATE TABLE thumbnail (
  object_hash TEXT    NOT NULL REFERENCES object(hash) ON DELETE CASCADE,
  size        INTEGER NOT NULL,               -- longest edge in points
  byte_size   INTEGER NOT NULL,
  enc_nonce   BLOB    NOT NULL,
  created_at  TEXT    NOT NULL,
  PRIMARY KEY (object_hash, size)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- File references — device-aware paths
-- Serves BOTH the "File Path" field kind and the "Reference original file"
-- attachment mode. They are the same idea.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE file_ref (
  id            TEXT    PRIMARY KEY,
  device_id     TEXT    NOT NULL REFERENCES device(id) ON DELETE CASCADE,
  path          TEXT    NOT NULL,             -- 'D:\Servers\BeamNG\Server1'
  is_directory  INTEGER NOT NULL DEFAULT 0 CHECK (is_directory IN (0,1)),
  size_at_link  INTEGER,
  mtime_at_link TEXT,
  content_hash  TEXT,                         -- lazy; lets us say "moved" not "missing"
  last_seen_at  TEXT,
  status        TEXT    NOT NULL DEFAULT 'unknown'
                        CHECK (status IN ('present','missing','unknown')),
  created_at    TEXT    NOT NULL
);

CREATE INDEX idx_file_ref_device ON file_ref(device_id);
CREATE INDEX idx_file_ref_status ON file_ref(status) WHERE status = 'missing';

-- ─────────────────────────────────────────────────────────────────────────────
-- Collections, tags
-- A Saved Search is not a separate concept: it is a collection with is_smart=1.
-- Smart Views ship as seeded smart collections, so the user can edit them.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE collection (
  id             TEXT    PRIMARY KEY,
  name           TEXT    NOT NULL,
  icon_json      TEXT,
  sort_order     REAL    NOT NULL,
  parent_id      TEXT             REFERENCES collection(id) ON DELETE SET NULL,
  is_smart       INTEGER NOT NULL DEFAULT 0 CHECK (is_smart IN (0,1)),
  is_system      INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0,1)),
  smart_query    TEXT,                        -- a search-DSL string
  created_at     TEXT    NOT NULL,
  updated_at     TEXT    NOT NULL,
  version_vector TEXT    NOT NULL DEFAULT '{}',
  CHECK (is_smart = 0 OR smart_query IS NOT NULL)
);

CREATE INDEX idx_collection_parent ON collection(parent_id, sort_order);

CREATE TABLE collection_member (
  collection_id TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
  thing_id      TEXT NOT NULL REFERENCES thing(id)      ON DELETE CASCADE,
  sort_order    REAL NOT NULL,
  added_at      TEXT NOT NULL,
  PRIMARY KEY (collection_id, thing_id)
);

CREATE INDEX idx_member_thing ON collection_member(thing_id);

CREATE TABLE tag (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
  color      TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE thing_tag (
  thing_id TEXT NOT NULL REFERENCES thing(id) ON DELETE CASCADE,
  tag_id   TEXT NOT NULL REFERENCES tag(id)   ON DELETE CASCADE,
  PRIMARY KEY (thing_id, tag_id)
);

CREATE INDEX idx_thing_tag_tag ON thing_tag(tag_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Oplog — one mechanism for History, Undo, Restore, and sync
--
-- hlc is a hybrid logical clock: physical time stays readable for the History UI
-- while remaining monotonic, so a phone with a skewed clock cannot silently win.
-- Secrets inside attrs_json/prev_json are ciphertext envelopes — otherwise History
-- would become a plaintext log of every password ever changed.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE change (
  id          TEXT NOT NULL PRIMARY KEY,      -- uuidv7
  device_id   TEXT NOT NULL,
  hlc         TEXT NOT NULL,                  -- lexicographically sortable
  entity_type TEXT NOT NULL CHECK (entity_type IN (
                'thing','section','field','collection','member','tag','thing_tag','file_ref')),
  entity_id   TEXT NOT NULL,
  op          TEXT NOT NULL CHECK (op IN ('create','update','delete')),
  attrs_json  TEXT NOT NULL,                  -- changed attributes ONLY
  prev_json   TEXT,                           -- prior values → cheap undo/restore
  applied_at  TEXT NOT NULL
);

CREATE INDEX idx_change_entity ON change(entity_id, hlc);
CREATE INDEX idx_change_sync   ON change(device_id, hlc);
CREATE INDEX idx_change_hlc    ON change(hlc);

CREATE TABLE conflict (
  id             TEXT PRIMARY KEY,
  entity_type    TEXT NOT NULL,
  entity_id      TEXT NOT NULL,
  version_a_json TEXT NOT NULL,
  version_b_json TEXT NOT NULL,
  detected_at    TEXT NOT NULL,
  resolved_at    TEXT,
  resolution     TEXT CHECK (resolution IS NULL OR resolution IN ('a','b','both','manual'))
);

CREATE INDEX idx_conflict_open ON conflict(resolved_at) WHERE resolved_at IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- Search
--
-- Secret VALUES are never inserted. A secret field contributes its LABEL only,
-- plus a has:password marker. That is a security property, not a UI preference.
-- Locked Things contribute nothing while locked.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE VIRTUAL TABLE thing_fts USING fts5(
  thing_id UNINDEXED,
  title,
  labels,
  values,      -- ⚠️ RESERVED WORD in SQLite. Must be quoted ("values") in every
               -- INSERT/UPDATE/SELECT against this table, in BOTH cores.
  notes,
  tags,
  urls,
  paths,
  filenames,
  collections,
  markers,                                    -- 'has:password has:file type:image ...'
  tokenize = "unicode61 remove_diacritics 2"
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Local, non-syncing state
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Seeded rows: schema_version, device_id, hlc_last, trash_retention_days, seed_marker.
--
-- ⚠️ KEY MATERIAL MUST NOT LIVE HERE.
-- This table is inside the SQLCipher database, which is keyed by the DEK. Storing the
-- wrapped DEK or the KDF salt here would be circular: you would need the key in order to
-- read the material required to derive the key.
--
-- Therefore the unlock material lives in an UNENCRYPTED sidecar, `vault.json`, beside the
-- database file:
--     { version, kdf: {algo:"scrypt", N, r, p, salt}, dekWrapPin, dekWrapDevice, deviceId }
-- This leaks nothing: the salt is public by design, and both wrapped DEKs are AES-256-GCM
-- ciphertext that is useless without the PIN or the device secret.
-- After a successful open, non-secret values are mirrored into `meta` for convenience.
-- Normative layout: spec/crypto.md.

CREATE TABLE sync_state (
  peer_device_id TEXT PRIMARY KEY REFERENCES device(id) ON DELETE CASCADE,
  last_hlc_sent  TEXT,
  last_hlc_recv  TEXT,
  last_sync_at   TEXT
);
