# Things — Oplog Wire Formats

NORMATIVE. Both cores implement this. Changes here require new conformance vectors in the same
commit — see §6.

The oplog is one table seen from four angles: History, Restore, Undo/Redo, and sync. Because a
`change` row crosses the wire verbatim (`spec/sync.md`), everything *in* a row is wire format:
the timestamp string, the JSON encoding of the attributes, and the version vector.

Pinned by [`spec/vectors/hlc.json`](vectors/hlc.json) and
[`spec/vectors/version-vector.json`](vectors/version-vector.json).
Related: [`spec/crypto.md`](crypto.md) (the envelope those attributes carry),
[`docs/01-DATA-MODEL.md`](../docs/01-DATA-MODEL.md) §5.

---

## 1. Hybrid logical clock

```
2026-08-09T21:14:03.412Z-0001-11111111-1111-7111-8111-111111111111
└────────── physical, 24 chars ────────┘ └cnt┘ └───── device id ─────┘
```

> `hlc = physical ‖ "-" ‖ counter ‖ "-" ‖ deviceId`

| Part | Width | Form |
|---|---|---|
| physical | exactly 24 | ISO-8601 UTC with milliseconds, `YYYY-MM-DDTHH:MM:SS.mmmZ` — byte-identical to JavaScript's `Date#toISOString()` |
| counter | exactly 4 | lowercase hex, zero-padded, range `0000`–`ffff` |
| deviceId | 36 | canonical lowercase UUID |

**Plain string comparison IS the ordering.** Every part is fixed width and lexicographically
ordered, so `a < b` as strings is the causal-ish ordering, and `ORDER BY hlc` in SQLite needs no
custom collation. An implementation MAY compare the parsed parts instead, but it MUST produce the
same answer — both cores assert this against `hlc.json`'s `sorted` and `comparisons` sections.

Parsing is **positional**, not by splitting on `-`: the device id is a UUID and contains hyphens.
`physical = s[0..24]`, `s[24] == '-'`, `counter = s[25..29]`, `s[29] == '-'`, `device = s[30..]`.

### 1.1 Advancing

* `now()` — if the wall clock is strictly greater than the last physical, take it and reset the
  counter to 0; otherwise keep the physical and increment the counter. A device whose clock is
  wrong cannot emit a value ≤ one it already emitted.
* `receive(remote)` — take `max(wall, last, remote.physical)`; if that equals both `last` and
  `remote.physical`, the counter is `max(last.counter, remote.counter) + 1`; if it equals only
  one of them, that side's counter + 1; otherwise 0.
* On counter overflow past `0xffff`, advance the physical by 1 ms and reset the counter. A
  formatter MUST NOT emit a counter outside `0000`–`ffff`.

The two cores currently differ in how they *reject* a wildly skewed peer: the Swift generator
clamps an incoming physical to one hour ahead of local time, the TypeScript one does not clamp.
That affects liveness, not encoding, and no vector covers it — see §5.

---

## 2. Canonical JSON

`attrs_json`, `prev_json`, `version_vector`, `icon_json` and `kdf_params` are compared, hashed
and diffed across two cores. They therefore have one serialisation, not two:

1. Object keys sorted ascending by **Unicode scalar (UTF-8 byte) order**. Keys in this project
   are ASCII (column names, device UUIDs); anything else is out of contract.
2. No insignificant whitespace: `{"a":1,"b":2}`, never `{ "a": 1 }`.
3. Strings escaped minimally: `\"`, `\\`, `\n`, `\r`, `\t`, and `\u00XX` for other codepoints
   below `0x20`. Everything else is emitted as literal UTF-8 — no `\u` escaping of non-ASCII.
4. Integers with no decimal point and no exponent. Non-integers use the shortest representation
   that round-trips (JavaScript `Number#toString`); a value that is integral is written as an
   integer, so `3.0` is `3` and `2.5` stays `2.5`.
5. `null` is a value and is preserved. A key that is absent and a key whose value is `null` mean
   different things: absent means "this attribute did not change", `null` means "it was set to
   NULL".

Vector: `version-vector.json` → `canonicalJson`, e.g. `{"b":1,"a":2}` serialises to
`{"a":2,"b":1}`, and `{}` serialises to `{}`.

---

## 3. Attribute encoding

`attrs_json` holds only the attributes that changed; `prev_json` holds their prior values. Values
map to JSON by column type:

| Column type | JSON |
|---|---|
| TEXT | string, or `null` |
| INTEGER | number, or `null`. Booleans are `0`/`1`, never `true`/`false`. |
| REAL | number (per §2 rule 4), or `null` |
| BLOB | **`{"$b64": "<base64>"}`**, or `null` |

> **BLOBs use the `$b64` wrapper, not a bare base64 string.** The only BLOB an oplog row carries
> today is `field.value_cipher`, the `TENV` envelope of a secret. A bare string is indistinguishable
> from a TEXT value, so a reader expecting text writes the base64 *as text* into a BLOB column —
> and a reader expecting the wrapper writes NULL. Either way the secret is destroyed on sync, in
> silence. The wrapper is the only self-describing option available without a schema lookup on the
> receiving side.

Secret values in the oplog are **always the ciphertext envelope**, never plaintext. Otherwise
History becomes a plaintext log of every password ever changed — called out by name in
`docs/02-SECURITY.md` §5.

Unknown attribute keys are **dropped, not applied**. `attrs_json` arrives from the network, so
column names are taken from a fixed allow-list per entity type; nothing else reaches an
`UPDATE … SET`.

---

## 4. Version vectors

`{deviceId: counter}`, serialised as canonical JSON (§2). A missing device counts as zero.

| Relation | Meaning | Action |
|---|---|---|
| `equal` | same knowledge | nothing |
| `dominates` | A saw B | apply A |
| `dominated` | B saw A | keep B |
| `concurrent` | neither saw the other | **conflict** — the only case that produces one |

Vectors live on the *field* row, so "phone edits Notes, PC edits Password" is two entities and
never a conflict. Pinned by `version-vector.json` (`comparisons`, `merges`, `canonicalJson`).

---

## 5. Known gaps

Recorded rather than left to be discovered on sync day.

1. **`core-ts` does not canonicalise `attrs_json`.** It writes `JSON.stringify(attrs)`, which
   emits keys in insertion order. `core-swift` writes sorted-key canonical JSON. Both *parse* each
   other's output correctly — nothing breaks today — but the two cores produce different bytes for
   the same change, so any future byte-level use (hashing a row, signing a batch, dedupe by
   content) diverges. Swift cannot match JS insertion order (its dictionaries are unordered), so
   §2 is the only implementable common rule and `core-ts` is the side that must move. **Needs a
   canonical-JSON vector file before it is changed.**
2. **No vector file covers `attrs_json` or `prev_json` at all.** §3 is currently enforced by
   reading the code of both cores, which is exactly the situation that produced the `TENV`/`TSEC`
   split. A `spec/vectors/oplog.json` — fixed rows in, fixed JSON out, including a BLOB and a
   `null` — is the fix.
3. **HLC drift clamping differs** (§1.1). Encoding is identical and vector-covered; the receive
   policy is not.

---

## 6. Changing this file

Same protocol as `spec/crypto.md` §9:

1. Any change to the HLC string form, the canonical-JSON rules, the attribute encoding, or the
   version-vector form requires new or updated vectors in `spec/vectors/` **in the same commit**.
2. Regenerate with `node packages/core-ts/scripts/gen-vectors.ts`; the generator is deterministic.
3. Both suites run against the new vectors in the same commit (`npm test --workspace @things/core`,
   `swift test`).
4. A vector section no runner matches is a silent pass. Every core must fail loudly on a vector
   file it does not understand rather than skipping it.
