# Things — Sync Protocol

NORMATIVE. Both cores implement this. Changes here require new conformance vectors in the same
commit.

Sync is **peer-to-peer over the local network only**. There is no server, no relay, no account, and
no cloud. Neither device is authoritative: the iPhone must be fully usable with the PC powered off,
and vice versa.

---

## 0. Design constraints that shape everything

| Constraint | Consequence |
|---|---|
| iPhone on Wi-Fi, PC on Ethernet | Same router, different interfaces. mDNS usually works. **A manual `host:port` path is mandatory**, not a fallback nicety. |
| No paid Apple account | No push, no background remote wake. Sync runs while the app is foreground, or on a manual trigger. |
| Both devices hold the same DEK | Sync moves **ciphertext untouched**. The transport never sees plaintext and never re-encrypts. |
| The PC's web UI is loopback-only | Sync is a **separate listener on a separate port** with its own auth. Reusing :6767 would expose the whole web UI to the LAN. |
| A phone cannot hold a 20 GB library | Object transfer is **selective and resumable**, decoupled from metadata sync. |

---

## 1. Ports and discovery

| Purpose | Bind | Port |
|---|---|---|
| Web UI + local API | `127.0.0.1` only | 6767 |
| Sync listener | LAN interfaces | 6768 |

### Bonjour

Service type `_things._tcp`, TXT record:

```
v=1                     protocol version
did=<device-uuid>       advertising device id
name=RAEID-PC           human name
fp=<sha256-hex-32>      first 32 hex chars of the TLS cert fingerprint
```

`fp` lets a paired peer confirm it is talking to the right machine **before** the TLS handshake,
so a rogue device answering the same service name is rejected early rather than after key exchange.

iOS requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` containing `_things._tcp`.
Both are Info.plist keys; neither needs an entitlement a free account lacks.

### Manual fallback — a first-class path

Discovery fails routinely: subnet isolation, AP client isolation, VPNs, and Windows Firewall all
break mDNS while leaving TCP perfectly healthy. The UI therefore always offers **"Connect
manually"** with a `host:port` field, and pairing works identically through it. **A build where
manual entry is missing or hidden behind a diagnostic screen is a broken build.**

Windows Firewall must be opened for 6768 explicitly; the installer script does this and the app
detects the failure and says so plainly rather than hanging on connect.

---

## 2. Pairing

Being on the same Wi-Fi grants a device **nothing**. Trust is established once, out of band.

```
PC                                            iPhone
──                                            ──────
generate self-signed cert (P-256, 10y)
generate pairing secret S (32 random bytes)
display QR:
  { v, did, name, host, port, fp, s }   ──────►  scan
                                                 store peer {did, name, fp}
                                                 TLS connect, PIN the cert against fp
         ◄──── proof: HMAC(S, "things-pair-v1" ‖ did_phone ‖ did_pc) ────
  verify HMAC
         ──── DEK wrapped to the session key + device record ────►
                                                 unwrap, store, mark paired
  store peer {did, name, fp}
```

- The QR is displayed for **120 seconds** and the pairing secret is single-use. An expired or
  reused secret is refused.
- **The DEK is transferred exactly once, at pairing, and never again.** Every later session carries
  only ciphertext.
- Unpairing deletes the peer record and its certificate pin. It does **not** delete data — the
  peer keeps its own full replica, which is the point of the architecture.

### Transport

TLS 1.3, self-signed certificate, **pinned at pairing time**. No CA, no `NSAllowsArbitraryLoads`
blanket exception — the pin *is* the trust. A certificate that does not match the stored
fingerprint aborts the connection, and the UI says the peer's identity changed rather than
offering an "accept anyway" button.

---

## 3. The sync cycle

Four phases. Metadata always completes before objects begin, so the library is browsable even if a
large transfer is interrupted.

```
1  HELLO      exchange {did, protocol version, schema version, clock}
2  DELTA      exchange version vectors → request changes since
3  APPLY      fold incoming oplog, detect conflicts, materialise
4  OBJECTS    reconcile object inventory, transfer by policy
```

### Phase 1 — HELLO

```json
{ "v": 1, "deviceId": "…", "schemaVersion": 7, "hlc": "2026-08-09T21:14:03.412Z-0007-<did>" }
```

Refuse with a clear message if `schemaVersion` differs — a newer peer must not write records an
older peer cannot represent. The user is told which device needs updating, by name.

### Phase 2 — DELTA

Each side sends its per-device high-water mark:

```json
{ "have": { "<deviceA>": "<hlc>", "<deviceB>": "<hlc>" } }
```

The peer replies with every `change` row whose originating device/HLC exceeds the mark, ordered by
HLC ascending, in pages of 500.

### Phase 3 — APPLY

Changes are applied in HLC order inside **one transaction per page**, so an interrupted sync never
leaves a half-applied entity.

For each incoming change, compare version vectors on the target entity:

| Comparison | Action |
|---|---|
| incoming dominates local | apply |
| local dominates incoming | skip (we already saw it) |
| equal | skip (idempotent — replays are safe) |
| **neither dominates** | **conflict** |

On conflict: write a `conflict` row holding both versions, and materialise the **higher-HLC** value
provisionally so the app stays usable while the choice is pending. The UI surfaces **2 Versions**.

Because version vectors live on **fields**, not Things, the common case resolves silently and
correctly: the phone edits `Notes` while the PC edits `Password` → two different entities → both
apply, no conflict. Only a genuine same-field collision ever reaches the user.

Applying a change **must not** re-append it to the local oplog as a new change, or two devices will
ping-pong forever. Incoming changes are recorded with their **original** `device_id` and `hlc`.

### Phase 4 — OBJECTS

Metadata references objects by SHA-256. The receiving side computes what it is missing, then
filters by policy:

| Policy | Behaviour |
|---|---|
| `all` | fetch everything |
| `smart` *(default on iPhone)* | thumbnails always; full objects under `maxAutoBytes` (default 10 MB); larger on demand |
| `manual` | thumbnails only; everything else on tap |

Transfer is chunked at **1 MiB**, matching the object encryption framing, so a resumed transfer
restarts at a frame boundary and never re-downloads a completed frame. `Range` requests are
supported. The receiver verifies the SHA-256 of the assembled plaintext before inserting the row;
a mismatch discards the object and re-queues it.

Objects are **already encrypted at rest and are transferred as-is** — no decrypt/re-encrypt cycle,
which matters on a phone moving hundreds of megabytes.

---

## 4. Deletion

Deletion is a soft delete (`deleted_at`) and syncs as an ordinary field change, so it converges
like anything else. **Purging** — the permanent removal after the Trash retention window — is
strictly local: each device purges its own Trash on its own schedule. A device that was offline
past the retention window and comes back does not resurrect a purged Thing, because the delete
change itself is still in the oplog.

Object reference counts are recomputed locally after applying deletions; a peer never sends a
refcount.

---

## 5. Security properties

- **No unpaired peer can do anything.** Discovery reveals only a name and a fingerprint.
- **The transport never sees plaintext.** Secret fields and objects cross the wire as the same
  ciphertext they have at rest.
- A compromised LAN yields metadata sizes and timing, not content. Titles and non-secret field
  values are inside the TLS session but are *not* separately encrypted — an attacker who defeats
  TLS *and* the certificate pin would see them. Passwords, keys, and file bytes would remain
  ciphertext even then.
- Replays are idempotent by version vector, so a recorded session cannot mutate state.
- There is **no outbound connection to anything but a paired peer**, ever.

---

## 6. Failure modes and what the user is told

| Failure | Behaviour |
|---|---|
| Peer not found via mDNS | Offer **Connect manually** immediately, not after a long timeout |
| Firewall blocking 6768 | Detect the refusal and name the cause, with the fix command |
| Certificate fingerprint changed | Refuse. Say the peer's identity changed. No "accept anyway". |
| Schema version mismatch | Refuse, name which device needs updating |
| Interrupted mid-object | Resume at the last complete frame |
| Interrupted mid-page | Transaction rolls back; the page replays cleanly |
| Clock skew on one device | HLC is monotonic; a skewed clock cannot silently win an ordering argument |
| Disk full on receiver | Metadata still syncs; objects queue and report |

---

## 7. Conformance vectors

`spec/vectors/sync-*.json` must cover: version-vector comparison across all four outcomes, HLC
ordering under a backwards clock, idempotent replay of an already-applied change, conflict
detection on the same field, and non-conflict on different fields of the same Thing.

---

## 8. Not in v1

Multi-peer (>2 devices) is representable — version vectors and the oplog are already
device-keyed — but is untested and unshipped. Device-to-device sharing of a *subset* of the
library, and any form of relay through a third machine, are explicitly out of scope.
