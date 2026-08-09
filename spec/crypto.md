# Things — Cryptographic Formats

NORMATIVE. Both cores implement this. Changes here require new conformance vectors in the same
commit — see §9.

This file exists because it did not. The TypeScript core and the Swift core were written
independently against `docs/02-SECURITY.md`, which describes the *design* but not the *bytes*.
They agreed on AES-256-GCM and scrypt and disagreed on almost everything a parser cares about:
magic, header length, whether the header is authenticated, nonce-prefix width, frame framing,
and the spelling of the KDF parameter keys. None of that is visible until an iPhone tries to
open something the PC wrote. **The bytes below are the contract; the vectors are the proof.**

Pinned by [`spec/vectors/crypto-envelope.json`](vectors/crypto-envelope.json).
Related: [`spec/oplog.md`](oplog.md) (HLC and canonical JSON), [`spec/sync.md`](sync.md),
[`docs/02-SECURITY.md`](../docs/02-SECURITY.md) (threat model and rationale — this file must
never contradict its §3).

---

## 1. Key hierarchy

The **DEK** is a random 256-bit key. It encrypts everything: the SQLCipher database, secret
field values, and every per-object key. It is **never derived from the PIN** — it is *wrapped*
by keys that are. Changing the PIN therefore re-wraps 32 bytes instead of re-encrypting the
library.

The DEK is wrapped **twice, independently**. Either wrapper alone opens it.

```
  PIN ──scrypt(N,r,p, kdf_salt)──► KEK₁ ──► TENV envelope ──► dek_wrap_pin ──┐
                                            AAD "things:dek-wrap:pin:v1"     │
                                                                             ├──► DEK
  device secret ──HKDF-SHA256(kdf_salt, "things:kek2:v1")──► KEK₂ ──────────┤    (random,
      Windows: 32 DPAPI-sealed bytes                                         │     256-bit)
      iPhone:  Secure Enclave P-256 ──ECDH──► shared secret ──HKDF──► KEK₂   │
                                            AAD "things:dek-wrap:device:v1"  │
                                                     dek_wrap_device ────────┘
                                                                             │
                      ┌──────────────┬───────────────┬────────────┬──────────┘
                      ▼              ▼               ▼            ▼
                 SQLCipher     secret fields    object keys   backup key
                (raw key =    (TENV, AAD =     (TENV, AAD =   (PIN-derived
                 hex of DEK)   thing‖field)   "things:object-  only — §1.3)
                                                 key:v1")
```

### 1.1 Wrapper 1 — the PIN path

`KEK₁ = scrypt(password = utf8(PIN), salt = kdf_salt, N, r, p) → 32 bytes` (§6).
The PIN is taken as raw UTF-8 with **no trimming and no normalisation**: a leading zero is part
of the PIN.

This wrapper **must always exist**. `docs/02-SECURITY.md` §3 lists three ways the device wrapper
dies (changed Apple ID, a sideloader rewriting the bundle id, re-enrolled Face ID); the PIN path
is the only reason any of them is survivable.

### 1.2 Wrapper 2 — the device path

Device-bound, convenience only, and **never portable**. The two platforms cannot produce the
same bytes — the Secure Enclave holds P-256 keys and cannot store a symmetric key at all — so
this wrapper is re-created locally on each device and never syncs.

What *is* unified, so there is one rule to reason about:

| | Value |
|---|---|
| HKDF hash | SHA-256 |
| HKDF `salt` | `kdf_salt` — the same salt as the PIN path, not a second one |
| HKDF `info` | `things:kek2:v1` |
| Output | 32 bytes |
| IKM (Windows) | the 32-byte DPAPI-sealed device secret |
| IKM (iPhone) | the ECDH shared secret from the Secure Enclave P-256 key with its own public key |

The vector `deviceKek` pins the Windows shape:
`HKDF-SHA256(ikm = device secret, salt = kdf salt, info = "things:kek2:v1", L = 32)`.

**Consequence of sharing the salt:** rotating `kdf_salt` (a PIN change) invalidates KEK₂.
Any operation that writes a new `kdf_salt` MUST re-wrap for the device in the same operation,
and MUST delete `dek_wrap_device` if it cannot. A device wrapper left behind under a stale salt
is a wrapper that fails at unlock time for no visible reason.

### 1.3 The DEK is portable, the wrappers are not

Both devices need the *same* DEK, because sync moves ciphertext untouched. Pairing transfers the
DEK once over the pairing-authenticated channel (`spec/sync.md`); each device then wraps it with
its own local wrappers. The backup key is derived from the PIN alone, precisely so a backup
survives the loss of every device wrapper.

---

## 2. Envelope — `TENV`

The one sealed-blob format. Used for secret field values (`field.value_cipher`, and the same
bytes base64'd inside `attrs_json`) **and** for every wrapped key (`dek_wrap_pin`,
`dek_wrap_device`, `object.enc_key_wrap`). One format, one parser, one set of vectors.

```
  byte   0    1    2    3    4    5    6    7                 19            len-16
       ┌────┬────┬────┬────┬────┬────┬────┬──────────────────┬─────────────┬──────────┐
       │ 'T'│ 'E'│ 'N'│ 'V'│ ver│ alg│ nl │ nonce (12 bytes) │ ciphertext  │ tag (16) │
       └────┴────┴────┴────┴────┴────┴────┴──────────────────┴─────────────┴──────────┘
       └────────── header, 7 bytes ─────────┘
       └────────── fed to GCM as AAD, then the caller's AAD ──────────┘
```

| Offset | Size | Field | Value at version 1 |
|---|---|---|---|
| 0 | 4 | magic | `TENV` = `54 45 4e 56` |
| 4 | 1 | version | `0x01` |
| 5 | 1 | algorithm | `0x01` = AES-256-GCM, 12-byte nonce, 16-byte tag |
| 6 | 1 | nonce length | `0x0c` (12) |
| 7 | 12 | nonce | random per seal; **fixed only in vectors** |
| 19 | n | ciphertext | |
| 19+n | 16 | GCM tag | |

Minimum length is 35 bytes (empty plaintext).

### 2.1 The header-into-AAD rule

> `GCM AAD = envelope[0..7] ‖ callerAAD`

The 7 header bytes are prepended to whatever AAD the caller supplies. A writer builds them; a
reader takes them **from the envelope it is parsing**, so the tag covers exactly the header that
was presented.

This prevents **version/algorithm downgrade forgery**. Without it, the header is unauthenticated
metadata: an attacker holding a captured envelope could rewrite byte 5 to name a weaker
algorithm, or byte 4 to name a version whose reader is more permissive, and the tag would still
verify against the untouched ciphertext. With it, any edit to the header — including the nonce
length, which controls how the rest of the buffer is split — breaks authentication.

A reader MUST still reject unknown values in bytes 4–6 *before* attempting decryption. The AAD
rule protects a reader that already knows the version; the explicit check is what stops it
parsing one it does not.

### 2.2 Field AAD

> `AAD = utf8(thing_id) ‖ utf8(field_id)`

Both halves are canonical 36-character UUID strings, so plain concatenation is unambiguous and
no separator is needed. Vector: `fieldAad`.

This prevents **relocation**: a ciphertext blob copied out of one Thing and pasted into another
row will not open, because `thing_id` is part of what the tag covers. Without it, anyone with
write access to the database could move a stored secret to a Thing whose "reveal" button they
are willing to press, and the app would decrypt it for them. The vector `openMustFail[0]` is
exactly this attack.

Fields are the *only* AAD that is data-derived. Everything else uses a fixed context string:

| Envelope | Caller AAD (exact bytes, UTF-8) |
|---|---|
| `dek_wrap_pin` | `things:dek-wrap:pin:v1` |
| `dek_wrap_device` | `things:dek-wrap:device:v1` |
| `object.enc_key_wrap` | `things:object-key:v1` |
| encrypted backup container | `things:backup:v1` |
| secret field value | `utf8(thing_id) ‖ utf8(field_id)` |

These strings are **wire format**. They are what stops a PIN-wrapped DEK being presented as a
device-wrapped one, or an object key being presented as a DEK.

### 2.3 Nonces

12 bytes from the platform CSPRNG per seal, never reused with the same key. A fixed nonce
appears only in the vectors, and only so the outputs are deterministic; any production code path
that accepts a caller-supplied nonce must be reachable from tests only.

---

## 3. Storage of key material

### 3.1 `vault.json` — an unencrypted sidecar, and why it must be

`spec/schema.sql` seeds `dek_wrap_pin`, `dek_wrap_device`, `kdf_salt` and `kdf_params` as rows of
the `meta` table, and `docs/01-DATA-MODEL.md` §7 says the SQLCipher key *is* the DEK. **Those two
statements cannot both hold.** Reading `meta` requires opening the database; opening the database
requires the DEK; obtaining the DEK requires reading `meta`. The wrapped DEK cannot live inside
the thing it unlocks.

So it lives beside it, unencrypted:

```
<library root>/
  things.sqlite      SQLCipher, keyed by the raw DEK
  vault.json         ← this file: salts, KDF parameters, wrapped DEKs
  objects/           TOBJ containers (§5)
```

`vault.json` is **normative**. The `meta` rows may be mirrored once the library is open — they
are useful to a backup format that wants a self-describing container — but they are never the
source of truth and are never read to unlock.

### 3.2 Exact shape

A flat JSON object, **string keys to string values only** (no nested objects, no numbers), UTF-8,
written atomically:

```json
{
  "dek_wrap_device": "VEVOVgEBDPGr…",
  "dek_wrap_pin": "VEVOVgEBDLm3…",
  "device_id": "01890000-0000-7000-8000-0000000000aa",
  "failed_pin_attempts": "0",
  "kdf_params": "{\"N\":65536,\"algorithm\":\"scrypt\",\"dkLen\":32,\"p\":2,\"r\":8}",
  "kdf_salt": "AQIDBAUGBwgJCgsMDQ4PEA=="
}
```

| Key | Required | Value |
|---|---|---|
| `kdf_salt` | yes | base64 of 16 random bytes. Salt for both KEK₁ (scrypt) and KEK₂ (HKDF). |
| `kdf_params` | yes | a JSON **string** holding the object in §6. |
| `dek_wrap_pin` | yes | base64 of a `TENV` envelope over the 32-byte DEK, AAD `things:dek-wrap:pin:v1`. |
| `dek_wrap_device` | no | same, AAD `things:dek-wrap:device:v1`. Absent means "no device wrapper on this device", which is a normal state, not an error. |
| `dek_check` | no | base64(sha256(DEK)) truncated to 22 characters. Lets an unwrap be verified without the DEK leaving memory. A reader that finds it MUST check it; a writer MAY omit it. |
| `device_id` | no | this device's UUIDv7. Kept here so it survives a database rebuild. |
| `failed_pin_attempts` | no | decimal count, for the escalating delay in `docs/02-SECURITY.md` §4. Advisory and local; never synced. |

Rules:

* **Unknown keys MUST be preserved on write.** Read-modify-write the whole object; never
  rewrite it from a struct. Two cores and two app versions share this file.
* Key order is irrelevant. Writers SHOULD sort keys (both cores do) so the file diffs cleanly.
* `vault.json` never contains plaintext key material, a PIN, or a PIN hash.

### 3.3 Why publishing the salt and the wrapped DEK leaks nothing

Assume an attacker has the whole folder — that is threat T1, the one that actually matters, and
it is the *expected* case, not a worst case. They now hold `kdf_salt`, `kdf_params`, and two
AES-GCM envelopes over the DEK.

* **The salt is not a secret and never was.** Its job is to make precomputation useless: a
  rainbow table over six-digit PINs is only valid for one salt, so it must be rebuilt per
  library. Publishing it costs nothing that was not already assumed.
* **`dek_wrap_pin` is AES-256-GCM.** Recovering the DEK from it means either breaking AES-GCM or
  guessing the PIN — and each guess costs a full scrypt evaluation at `N=65536, r=8, p=2`, which
  is 64 MiB of memory per attempt and deliberately hostile to GPU parallelism. That is the entire
  reason a memory-hard KDF was chosen. It is also why the design does not stop there: a six-digit
  PIN alone is 10⁶ guesses, which is not enough, which is why there is a second wrapper.
* **`dek_wrap_device` is the real answer to T1.** Its KEK₂ derives from a secret that is not in
  the folder and never enters it: a DPAPI blob bound to one Windows account, or a P-256 key
  inside a Secure Enclave. Copy the folder to another machine and this wrapper is inert — not
  "hard", *inert*, because the input simply is not there.
* **The tag prevents tampering, not just reading.** An attacker cannot substitute a DEK of their
  choosing to make the library decrypt into something they control; the AAD-bound tag fails.

What the folder *does* reveal: that a Things library exists, its size, and how many objects it
holds. Object *sizes* are visible on disk. Things does not claim to hide those.

---

## 4. What the DEK protects directly

| Consumer | Mechanism |
|---|---|
| `things.sqlite` | SQLCipher `PRAGMA key = "x'<64 hex chars of the DEK>'"`. The raw-key form, so SQLCipher does not run its own KDF over a key that already went through scrypt. |
| secret field values | `TENV` envelope, AAD = `thing_id ‖ field_id` (§2.2). |
| object keys | each object gets a fresh random 256-bit key; that key is wrapped in a `TENV` envelope under the DEK with AAD `things:object-key:v1` and stored in `object.enc_key_wrap`. |

The DEK never encrypts object *bytes* directly. That indirection is what lets an object be
deduplicated and reference-counted without re-keying, and keeps one key from encrypting an
unbounded number of GCM messages.

---

## 5. Framed objects — `TOBJ`

Files are encrypted in **1 MiB plaintext frames** so a video can seek without decrypting
everything before the seek point, and so a large import does not need the whole file in memory.

```
  byte  0    1    2    3    4    5    6      10                 18
      ┌────┬────┬────┬────┬────┬────┬────────┬──────────────────┬──────────────────────┐
      │ 'T'│ 'O'│ 'B'│ 'J'│ ver│ alg│ frame  │ nonce prefix     │ frames …             │
      │    │    │    │    │    │    │ size(4)│ (8 bytes)        │                      │
      └────┴────┴────┴────┴────┴────┴────────┴──────────────────┴──────────────────────┘
      └──────────────── header, 18 bytes ──────────────────────┘

  each frame:  ┌──────────────┬───────────────────────────────┬──────────┐
               │ length (4,BE)│ ciphertext                    │ tag (16) │
               └──────────────┴───────────────────────────────┴──────────┘
                 length counts ciphertext + tag, NOT itself
```

| Offset | Size | Field | Value at version 1 |
|---|---|---|---|
| 0 | 4 | magic | `TOBJ` |
| 4 | 1 | version | `0x01` |
| 5 | 1 | algorithm | `0x01` = AES-256-GCM |
| 6 | 4 | frame size, big-endian | `1048576` (1 MiB of **plaintext**) |
| 10 | 8 | nonce prefix | random per object |
| 18 | … | frames | at least one, always |

* **Per-frame nonce:** `noncePrefix (8 bytes) ‖ UInt32BE(frameIndex)` = 12 bytes. Unique because
  the prefix is random per object and the object key encrypts nothing else. The 32-bit index
  caps an object at 4 TiB, which is a limit the rest of the app hits first.
* **Per-frame AAD:** `UInt32BE(frameIndex) ‖ isLastFrame (0x00 | 0x01)` = 5 bytes.
* **A zero-byte object still gets exactly one frame** (empty, `isLast = 1`), so a reader always
  has something to authenticate rather than trusting an empty file.
* The header is **not** in the frame AAD. It does not need to be: the frame size only affects how
  a *plaintext offset* maps to a frame index, and every frame's own index and last-flag are
  authenticated, so a rewritten header cannot make a reader accept the wrong bytes — only fail.

### 5.1 Range reads

To read plaintext `[start, start+length)`:

1. Parse the header; take `frameSize`.
2. Walk the length prefixes once to build the frame index `[(offset, length)]`. This is O(frames)
   over 4-byte reads, not over the data.
3. `first = start / frameSize`, `last = (start + length - 1) / frameSize`, clamped to the last
   frame that exists.
4. Decrypt frames `first…last` — each with its own index, and `isLast` set only for the final
   frame *of the file*, never of the request.
5. Return `joined[start - first*frameSize ..< +length]`.

A 40-byte read from a 3 GB video touches at most two frames.

### 5.2 What tampering is detected, and how

| Attack | Detected by |
|---|---|
| Flip a byte anywhere in a frame | GCM tag |
| Swap two frames | frame index is in both the nonce and the AAD |
| Duplicate a frame | same |
| Drop trailing frames (truncation) | the new final frame was sealed with `isLast = 0`; a reader that knows it is final authenticates with `isLast = 1`, and the tag fails |
| Append frames after the last | the frame sealed with `isLast = 1` is no longer final, so it is opened with `isLast = 0` and fails |
| Replace the whole file with another valid container | the object key comes from `object.enc_key_wrap`, wrapped under *this* library's DEK; and a full read re-hashes the plaintext and compares it to the file name (§5.3) |
| Corrupt a length prefix | the frame boundary moves, so that frame fails authentication (or the walk runs off the end and the container is rejected) |

Note the honest limit: a **range read cannot verify the whole-file hash**, because it does not
read the whole file. It verifies the frames it touches. A full `load` verifies both.

### 5.3 Path fan-out and dedupe

```
objects/<hash[0:2]>/<hash[2:4]>/<hash>
hash = lowercase hex SHA-256 of the PLAINTEXT bytes
```

Hashing the plaintext rather than the ciphertext is what preserves dedupe even though every
object has a unique random key: "this file is already in Things" becomes a primary-key hit. The
two-level fan-out keeps directory sizes sane on Windows. Vector: `objectPathFanout`.

The cost of plaintext hashing, stated plainly: someone holding the folder can confirm whether a
*specific file they already have* is stored, by hashing their copy. They learn nothing about
files they do not already possess.

---

## 6. scrypt

| Parameter | Production value |
|---|---|
| algorithm | `scrypt` |
| `N` | 65536 (2¹⁶) |
| `r` | 8 |
| `p` | 2 |
| `dkLen` | 32 |

OWASP's recommendation, calibrated so the slowest device — the iPhone — stays near 0.3–0.5 s.
Node ships scrypt natively; swift-crypto's `_CryptoExtras` ships `KDF.Insecure.Scrypt` with the
same three numbers, so both cores agree without a third-party dependency on either side.
(`Insecure` is Apple's namespace for password-based KDFs generally, not a verdict on scrypt.)

Vectors use `N=1024, r=8, p=1` so a conformance run stays fast; the production numbers are
asserted separately, as constants, in both cores.

### 6.1 Parameters are stored beside the salt

`kdf_params` sits next to `kdf_salt` in `vault.json`, serialised as a JSON string with **these
exact key names**:

```json
{"algorithm":"scrypt","N":65536,"r":8,"p":2,"dkLen":32}
```

Key order is irrelevant (both cores sort or emit in declaration order; either parses). The names
are not: a reader that expects `n` and `dkLen` and receives `N` and `keyByteCount` falls back to
its defaults and derives the wrong key — silently, if the defaults happen to match today and
loudly, later, when someone raises the cost.

**The rule:** parameters travel with the salt so they can be raised without breaking existing
databases. Raising them is: derive KEK₁ with the *stored* parameters, unwrap the DEK, derive a
new KEK₁ with the new parameters and a fresh salt, re-wrap, write both. Nothing else in the
library is touched, because the DEK did not change. A reader MUST use the stored parameters and
MUST NOT assume its own defaults; a missing or unparseable `kdf_params` means the version-1
defaults above.

Constraints a reader enforces: `algorithm == "scrypt"`, `N` a power of two ≥ 2, `r ≥ 1`,
`p ≥ 1`, `dkLen == 32`.

### 6.2 Failed attempts

Escalating delay only — Things **never wipes**. There is no cloud copy, so an auto-wipe converts
a forgotten PIN into permanent data loss. The ladder lives in `docs/02-SECURITY.md` §4; it is a
local UX control, not a cryptographic one, and the two cores are not required to agree on its
exact seconds.

---

## 7. Conformance

`spec/vectors/crypto-envelope.json` is generated by
`node packages/core-ts/scripts/gen-vectors.ts` and consumed by both test suites:

| Section | Asserts |
|---|---|
| `envelopeLayout` | the constants in §2 |
| `fieldAad` | §2.2 |
| `seal` | byte-exact envelopes for fixed key/nonce/AAD, including empty plaintext |
| `openMustFail` | relocation and wrong-key both fail |
| `kdf` | production parameters, and a byte-exact derivation |
| `deviceKek` | §1.2 |
| `objectFrames` | byte-exact containers, including the zero-byte object |
| `objectPathFanout` | §5.3 |

Every nonce and salt in the vectors is fixed so the outputs are deterministic. **Production code
must never take a nonce from a caller outside tests.**

---

## 8. Known gaps

Recorded here rather than left to be discovered on sync day.

1. **`core-ts` stores key material in the `meta` table, not `vault.json`.** Its `Keyring` is
   constructed over `db.meta()/db.setMeta()`. This works today only because the Windows database
   is not yet SQLCipher-encrypted, which is precisely the contradiction §3.1 describes. Moving it
   to `vault.json` is required before the Windows database is keyed, and is the one remaining
   place where the two cores disagree about *where* the wrapped DEK lives.
2. **`dek_check` is written by `core-ts` and ignored by `core-swift`.** Harmless — it is optional
   and preserved on write — but the Swift side should start verifying it.
3. The lockout ladders differ in their exact seconds (§6.2). Deliberate; not wire format.

---

## 9. Changing this file

1. **A change to any byte layout, AAD string, context string, JSON key name, or KDF parameter in
   this file requires new or updated vectors in `spec/vectors/` in the same commit.** No
   exceptions, including "obviously equivalent" ones — the whole class of bug this file exists to
   prevent looked obviously equivalent to whoever wrote it.
2. Regenerate with `node packages/core-ts/scripts/gen-vectors.ts`. The generator is deterministic;
   re-running it with no behaviour change must produce no diff.
3. Both suites must run against the new vectors in the same commit: `npm test --workspace
   @things/core` and `swift test` in `packages/core-swift`. A vector file that no runner in
   either suite matches is a silent pass — every core must fail loudly on an unknown vector
   section rather than skipping it.
4. A format change that cannot be read by already-written data needs a **new version byte**, not
   an edited one, plus a reader for the old value. Version 1 has shipped to no users, so it is
   still editable; that stops being true at first release, and this line is the reminder.
5. Never weaken a rule to make an implementation pass. The vectors are the target; the code moves.
