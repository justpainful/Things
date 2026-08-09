# Things — Master Plan

> **Things — a completely local personal information system.**
> Everything, in one place.

Not a notes app. Not a file manager. Not a password manager. Not a bookmark manager.
It is the one place where a *single item* can be all four at once.

---

## 0. The one rule

> **The user does not adapt to the database. The database adapts to the thing the user wants to keep.**

Every schema decision in this project is judged against that sentence. If a design forces the
user to answer "is this an Account or a Note or a File?", the design is wrong.

---

## 1. Hard constraints (these shape everything)

| # | Constraint | Consequence |
|---|---|---|
| C1 | **The developer machine is Windows.** No Mac, ever. | No local iOS build, no Xcode, no SwiftUI Previews, no local simulator. Every iOS iteration is a **CI round-trip**. |
| C2 | **No paid Apple Developer Program.** | No App Store, no TestFlight, no push, limited entitlements, 7-day app expiry, sideload-only delivery. |
| C3 | **Zero cloud.** No AWS/Firebase/Supabase/analytics/telemetry. | Sync is LAN-only, peer-to-peer. No account server exists. External network calls are opt-in per action. |
| C4 | **iPhone on Wi-Fi, PC on Ethernet.** | Same router, possibly different interfaces. mDNS *usually* works; a manual `host:port` fallback is **mandatory**, not optional. |
| C5 | **Web client is localhost-only,** `http://localhost:6767`. | The web UI is never exposed to the LAN. Sync is a *separate* listener on a *separate* port with its own auth. |
| C6 | **The repo is public** (`justpainful/Things`). | Code public = fine. Real data must never be committed. Strict `.gitignore` + a CI secret-scan gate. |
| C7 | Both devices are **equal peers**. | The phone must be fully usable with the PC powered off. Neither side is "the server" for data ownership. |

### C1 is the expensive one

On a normal iOS project you change a line and see it in 2 seconds. Here you change a line, push,
and wait for a macOS runner. **The entire development strategy below exists to work around C1**:

- Push as much logic as possible *out of Swift* into a language-neutral spec + a TypeScript core
  that runs and tests instantly on Windows.
- Make the two implementations agree by **shared conformance test vectors**, not shared code.
- Make each CI run pay for itself by capturing **many screens at once** (the Screenshot Tour),
  not one screen per run.

---

## 1b. Decisions locked

| Decision | Choice | Consequence |
|---|---|---|
| **Unlock** | 6-digit **PIN**, on both clients | Fast. But a PIN alone is only a million guesses, so the key is bound to the device (Windows Credential Manager / Secure Enclave) — copying the data folder yields nothing. See [`02-SECURITY.md`](02-SECURITY.md). |
| **Language** | **English UI now**, structured for Arabic later | All strings live in catalogues from day one; layout uses leading/trailing, never left/right. Adding Arabic + RTL later is a translation pass, not a rewrite. Screenshot Tour stays single-direction for now, halving visual-review cost. |
| **Sideloading** | AltStore / SideStore, **already working** | M0's delivery risk drops sharply. CI targets the ipa shape those tools accept. Re-signing cadence still applies. |
| **Web glass fidelity** | Settled empirically **before** any web UI is written | `tools/glass-lab/` compares five techniques side by side over hostile backdrops. Winner is frozen as a primitive. A frosted-blur panel is an explicit failure condition, not a fallback. |
| **Xcode project** | Generated from `project.yml` (XcodeGen) | No hand-edited `.pbxproj`; reviewable and editable from Windows. |
| **iOS persistence** | **`sqlcipher/GRDB.swift` v7.11.1**, not SwiftData | SwiftData has no encryption-at-rest story, no FTS5 story, and no custom-sync hook — it fights all three of our requirements. Zetetic maintains a managed GRDB fork with SQLCipher pre-wired that tracks upstream tag-for-tag; upstream's README still says "you must fork GRDB" but that advice is out of date as of Feb 2026. |
| **Sync mechanism** | Our own oplog + version vectors, **not SQLite changesets** | The session/changeset extension is almost certainly absent from a SQLCipher build. Our design never depended on it — this is now a verified reason, not a preference. |
| **App extensions** | **None in v1. Single-process app.** | Whether a free account can use App Groups is genuinely contested — Apple's own capability table lists App Groups as free-tier, while community consensus says Personal Teams can't. Neither side has a reproducible test. But the *sideload pipeline* is the real blocker: re-signing tools don't reliably carry custom entitlements through (one gates it behind a paid tier, another has it as an open request). Add to that 10 App IDs per 7 days — one per extension — and only 3 active sideloaded apps. Import happens in-app. |
| **Deployment target** | **iOS 26.0** | Every Liquid Glass symbol is iOS 26.0+; there is nothing below it. 79% adoption as of June 2026, and this is a personal sideloaded app — targeting lower would cost the entire API surface for nothing. |

## 2. Architecture

```
┌──────────────────────────────┐          ┌──────────────────────────────┐
│           iPhone             │          │        Windows PC            │
│                              │          │                              │
│  Things.app (SwiftUI)        │          │  things-server (Node)        │
│  ├ ThingsCore (Swift)        │  paired  │  ├ @things/core (TS)         │
│  ├ SQLite+SQLCipher          │◄────────►│  ├ SQLite+SQLCipher          │
│  ├ objects/ (encrypted)      │   LAN    │  ├ objects/ (encrypted)      │
│  └ Keychain + Face ID        │   :6768  │  └ key in OS credential store│
│                              │          │            │                 │
└──────────────────────────────┘          │            ▼                 │
                                          │  Web UI  127.0.0.1:6767      │
                                          └──────────────────────────────┘
```

### Four layers

| Layer | Path | Owns |
|---|---|---|
| **Spec** | `spec/` | The normative, language-neutral truth: schema, field-kind registry, crypto envelope format, oplog format, sync protocol, search grammar, **and the conformance vectors both implementations must pass.** |
| **Core** | `packages/core-ts/`, `packages/core-swift/` | Two independent implementations of the spec. Data model, encryption, oplog, versions, search, sync client. |
| **iPhone** | `apps/ios/` | SwiftUI + Liquid Glass + Face ID + native system integration. |
| **Desktop** | `apps/server/`, `apps/web/` | The local service on :6767 and the Finder/Notes-like web client. |

**Why two implementations instead of one shared core?** A shared core would mean either Swift on
Windows (poor tooling) or a WebView on iOS (explicitly rejected). The cost of writing the core
twice is real but bounded — it is ~4k lines of pure logic. The cost of getting it *wrong* twice is
what conformance vectors eliminate: one JSON file of inputs and expected outputs, run by both test
suites in CI. If the two cores ever disagree, a test goes red before a user ever sees it.

### Repo layout

```
Things/
├─ docs/                     # plans, decisions, the operating loop
├─ spec/                     # NORMATIVE — changes here are contract changes
│  ├─ schema.sql             # canonical DDL
│  ├─ field-kinds.json       # base kinds + variant registry (data, not code)
│  ├─ crypto.md              # envelope formats, KDF params, AAD rules
│  ├─ oplog.md               # change records, HLC, version vectors
│  ├─ sync.md                # pairing, discovery, transfer, conflicts
│  ├─ search.md              # query grammar + operator semantics
│  └─ vectors/*.json         # conformance test vectors
├─ packages/
│  ├─ core-ts/               # TypeScript core  (runs on Windows — fast loop)
│  └─ core-swift/            # SPM package      (runs on CI only)
├─ apps/
│  ├─ ios/
│  │  ├─ project.yml         # XcodeGen — the ONLY source of project structure
│  │  ├─ Things/             # app sources
│  │  └─ ThingsUITests/      # the Screenshot Tour
│  ├─ server/                # Node service, :6767 web + :6768 sync
│  └─ web/                   # Vite + TypeScript client
├─ tools/
│  ├─ seed/                  # deterministic demo dataset (screenshot stability)
│  └─ shots/                 # xcresult → png extraction + baseline diffing
├─ screenshots/baseline/     # committed reference images
└─ .github/workflows/
```

### Decision: the Xcode project is generated, never committed as truth

`apps/ios/project.yml` (XcodeGen) is the source of truth; `Things.xcodeproj` is a build artifact
generated in CI and git-ignored. Rationale: nobody on this project can open Xcode to fix a
corrupted `.pbxproj`, and `.pbxproj` merge conflicts are unresolvable by hand at speed. A YAML file
is reviewable, diffable, and editable from Windows.

---

## 3. The data model in one paragraph

A **Thing** has **Sections**; Sections have **Fields**. A Field has a small closed **base kind**
(how it is stored and rendered) plus an open **variant** string (what it means). `youtube`,
`github`, and `discord` are not three types — they are one `url` kind with three variants, so
adding "Threads" tomorrow is a data change, not a migration. Files live in a content-addressed,
encrypted **object store** keyed by SHA-256, so the same logo in four Things is stored once.
**Collections** are many-to-many (Cloudflare lives in both `Development` and `1980` without
duplication). **Relations** are just Fields whose value is another Thing's id, which is why they
inherit sections, ordering, and drag-and-drop for free. Every mutation appends to an **oplog** with
a hybrid logical clock and a per-entity version vector — that single mechanism delivers History,
Restore, Undo, and correct field-level sync conflict detection simultaneously.

Full detail: [`docs/01-DATA-MODEL.md`](01-DATA-MODEL.md).

---

## 4. Milestones

Ordered by **risk retired per unit of time**, not by feature appeal.

### M0 — Prove the pipe (nothing else matters until this is green)

The single highest-risk assumption in this project is "a Windows user with no Apple account can
ship a Liquid Glass app to their own iPhone." Test that with a hello-world app before writing a
line of real code.

- [ ] Empty SwiftUI app, one screen, one `.glassEffect()`, generated by XcodeGen in CI.
- [ ] CI: build for simulator → boot → 1 UI test → 1 PNG artifact I can actually look at.
- [ ] CI: produce an **unsigned `.ipa`** as a release artifact.
- [ ] **Human step:** sideload that ipa onto the real iPhone and open it.
- [ ] Confirm Liquid Glass actually *renders in the simulator screenshot* (if it does not, the
      whole visual-review loop needs rethinking — better to know on day one).

**Exit:** a screenshot of glass, taken by a robot, from a Windows machine, plus an app icon on the
home screen. If M0 fails, the project's shape changes and we replan.

### M1 — Spec + vectors (+ one blocking spike)

Schema DDL, field-kind registry, crypto envelope, oplog format, search grammar, and the first
conformance vectors. No UI. This is the contract every later agent codes against.

**Blocking spike, first:** link `sqlcipher/GRDB.swift` in a throwaway target and run
`PRAGMA compile_options` on device *and* simulator to confirm **FTS5 is compiled into the SQLCipher
binary**. Search is a load-bearing feature here — five of the six access paths depend on it — so
discovering this after the schema is written would be expensive. If FTS5 is missing, choose the
fallback before writing a line of search code.

### M2 — Desktop vertical slice
`core-ts` + server + web UI: create/read/edit a Thing with Fields and Sections, real search,
Collections. Runs on Windows with a sub-second loop. **The data model gets validated here**, where
iteration is free, before it is ever written in Swift.

### M3 — iPhone read-only
`core-swift` (passing the same vectors) + the SwiftUI shell: Home, Thing detail, Search, real
Liquid Glass. Read-only against a seeded database. First real Screenshot Tour.

### M4 — Editing + history
Writes on both clients, oplog, Thing History, Restore, Trash with retention.

### M5 — Objects
Attachments vs References, SHA-256 dedupe, thumbnails, Photos-like gallery, Quick Look,
device-aware paths, Missing Files.

### M6 — Security
Passphrase + KDF, Face ID unlock, per-secret reveal gate, Auto-Lock, Privacy Mode, Locked Things
(excluded from search previews and the app-switcher snapshot).

### M7 — Sync
Bonjour discovery + manual fallback, QR pairing, encrypted transfer, version-vector conflict
detection, the "2 Versions" resolution UI, selective object sync for the phone.

### M8 — Depth
Templates, import (drag 50 files → 50 Things or 1 Thing), batch operations, saved searches,
duplicate detection, clipboard suggestions, encrypted backup/restore, Command Palette polish.

---

## 5. The operating loop

This is the project's heartbeat, exactly as specified: *everything goes through CI, screenshots get
reviewed, then an IPA — and the loop revolves around catching defects in the screenshots.*

```
  1. dispatch          a scoped slice to an implementation agent (on a branch)
  2. push              → CI: core tests (Ubuntu, fast) + iOS build (macOS)
  3. Screenshot Tour   → every screen × {light,dark} × {default,XXL type} × devices
  4. auto-diff         → pixel-compare against screenshots/baseline/, flag changed screens
  5. visual review     → I open the changed PNGs and write a defect list
  6. dispatch fixes    → narrow agents, one defect each
  7. green + clean     → merge → unsigned IPA artifact → sideload
```

Steps 2–4 run **in the background**. I never sit and wait on a macOS runner; the notification
arrives and I pick the review back up. That is the entire point of the async setup.

### Screenshot determinism (non-negotiable)

Pixel-diffing is worthless if screenshots are noisy. Every Screenshot Tour run must fix:
fixed seed dataset, injected fake clock, animations disabled, fixed locale + timezone, fixed
device + OS version. Without this, step 4 flags 40 false positives per run and gets ignored —
which quietly kills the entire quality loop.

### What "visual review" actually looks for

Text truncation and clipping · Dynamic Type overflow · contrast failures on glass · glass applied
to scrolling content or stacked glass-on-glass · misaligned baselines and inconsistent corner radii
· wrong safe-area/keyboard insets · empty-state and long-string breakage · RTL mirroring defects
· anything that reads as "an app" instead of "the system".

---

## 6. Subagent topology (cost discipline)

Four rules:

1. **Research once, write it down, never research again.** Verified facts land in `docs/` or
   `spec/` immediately. A fact re-derived is money burned twice.
2. **Partition by directory.** Agents own disjoint paths so they never collide and never need to
   read each other's context.
3. **Tier the model to the task.** Mechanical work does not need a frontier model.
4. **Background anything with wall-clock cost.** CI waits, builds, and long test runs never block
   the main thread.

| Role | Owns | Tier | Mode |
|---|---|---|---|
| Architect (me) | `docs/`, `spec/` | high | foreground — this is the contract, not delegable |
| Core-TS | `packages/core-ts/` | mid | background |
| Core-Swift | `packages/core-swift/` | mid | background |
| iOS UI | `apps/ios/` | mid–high | background |
| Web UI | `apps/web/` | mid | background |
| Server | `apps/server/` | mid | background |
| CI/Tooling | `.github/`, `tools/` | mid | background |
| Screenshot reviewer | reads artifacts only | high (vision) | foreground bursts |
| Fix agents | one defect, narrow scope | low–mid | parallel batch |

Spec changes are serialized through the architect. Everything else fans out.

---

## 7. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Free-provisioning app expires after ~7 days | Medium, permanent | AltStore/SideStore auto-refresh is already working on this iPhone; documented re-sign ritual. Apple's limits: 10 App IDs and 3 devices, each expiring in 7 days; sideloaders additionally cap 3 active apps. |
| **SideStore auto-renewal is reported broken on iOS 26.6** — the current shipping OS | Medium | Open issue filed 2026-08-04. Verify in M0 which tool actually refreshes on this phone; fall back to a tethered refresher (AltServer / Sideloadly / Impactor) that runs while the PC is awake on the same Wi-Fi. |
| A sideloader rewriting the bundle ID empties the vault | High if it happens | Keychain access group is `<TeamID>.<bundleID>`. Bundle IDs stay stable across CI builds; verified in M0. The PIN wrapper and encrypted backup are the recovery path. |
| **Web Liquid Glass looks like cheap frosted blur** | **High — this is the stated make-or-break** | Settled empirically in `tools/glass-lab/` before any web UI exists. Rejected outright if it reads as "just blur". |
| A needed entitlement requires a paid account | High | Enumerated *before* M1 (research in flight). Any blocked capability gets a documented fallback, e.g. no Share Extension → in-app import + clipboard suggestions. |
| iOS iteration latency (C1) | High, permanent | Validate the data model on the web client first; batch UI changes; many screens per CI run. |
| Screenshot diff noise drowns real defects | High | Determinism harness is part of M0/M3, not an afterthought. |
| mDNS fails across Wi-Fi/Ethernet or Windows Firewall blocks the listener | Medium | Manual `host:port` pairing is a first-class path, plus a firewall-rule setup script. |
| **FTS5 may not be compiled into Zetetic's prebuilt SQLCipher binary** | **High — would break all search** | GRDB's `SQLITE_ENABLE_FTS5` flag only exposes the *Swift API*; the FTS5 module must also exist in the linked SQLCipher binary, and no source confirms it does. **Spiked in M1 with `PRAGMA compile_options` before any search code is written.** Fallbacks: build SQLCipher from source with `--enable-fts5`, or drop SQLCipher and rely on iOS Data Protection + our own field-level encryption. |
| SQLCipher parity between iOS and Node builds | Medium | Pinned versions on both sides + a cross-open conformance test (Node writes a DB, Swift opens it) in CI. |
| A prebuilt binary dependency in a secrets app | Low–Medium | `SQLCipher.swift` is a checksum-pinned `.binaryTarget`. Reproducible for CI, but it is a binary we did not build. Accepted consciously; revisit if we ever build SQLCipher from source for FTS5 anyway. |
| Public repo leaks personal data | Medium | `.gitignore` for all data dirs, CI secret scan, seed data is obviously fake. **Repo stays public** — macOS runner minutes are free on public repos and billed at $0.062/min otherwise. |
| **Keychain loss wipes the library** (Apple ID change → new team prefix → items unreachable) | **High** | The PIN wrapper is always an independent way in, and encrypted backup is promoted from M8 nicety to safety requirement. See [`02-SECURITY.md`](02-SECURITY.md). |
| Simulator has no Secure Enclave, and *all* development happens on the simulator | High | A `#if targetEnvironment(simulator)` software-key fallback is mandatory from day one, or the app cannot be run at all in CI. |
| Biometric keychain may not work under a free Personal Team | Medium | Unverified by any Apple source. Tested on-device in M0. Fallback: PIN-only, drop Face ID. |
| Large objects sync to a phone with 128 GB | Medium | Metadata + thumbnails always; full objects on-demand or by size rule. |
| Scope. This spec is enormous. | High | M0–M4 is a genuinely useful product. M5–M8 is depth. Ship the slice. |

---

## 8. Naming discipline

The app never says **Vault**, **Database**, **Knowledge Base**, **Workspace**, **Entry**, **Record**,
or **Item**. It says: Things · Collections · Fields · Files · Notes · Recently Added · Pinned ·
Locked · Search. If a label sounds like it belongs to a developer tool, it is wrong.

---

## 9. Companion documents

| Doc | Contents |
|---|---|
| [`01-DATA-MODEL.md`](01-DATA-MODEL.md) | Thing/Section/Field, kinds + variants, objects, oplog, conflicts, search |
| [`02-SECURITY.md`](02-SECURITY.md) | Threat model, PIN + device-bound key hierarchy, lock behavior, network posture |
| [`03-DESIGN.md`](03-DESIGN.md) | Liquid Glass rules, web↔iPhone parity, screen inventory, anti-patterns |
| [`04-CI-AND-LOOP.md`](04-CI-AND-LOOP.md) | The macOS CI pipeline, Screenshot Tour, IPA build, review loop |
| [`05-OPEN-QUESTIONS.md`](05-OPEN-QUESTIONS.md) | Decisions still open. None block M0. |
