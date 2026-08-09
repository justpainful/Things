# Things — Runbook

How to actually run, develop, and ship this. Written for a Windows machine with no Mac.

---

## First run

```bash
npm install
npm run dev
```

Open **http://localhost:6767**. You will be asked to choose a PIN.

Two things to know before you type it:

- **There is no recovery.** No cloud, no account, no reset link. A forgotten PIN means a lost
  library. Write it somewhere outside Things.
- The PIN alone is not what protects you — it is combined with a machine-bound secret, so copying
  the data folder to another computer yields nothing. See [`02-SECURITY.md`](02-SECURITY.md) §3.

For LAN sync, once:

```bash
powershell -ExecutionPolicy Bypass -File tools\setup-windows.ps1
```

It opens TCP 6768 on **private networks only** and prints the address to type into the iPhone if
Bonjour discovery fails. Port 6767 is deliberately not opened — the web client binds to loopback
and must never be reachable from the LAN.

---

## Where your data lives

```
ThingsData/
├─ things.sqlite        SQLCipher-encrypted; metadata, fields, oplog, search index
├─ vault.json           UNENCRYPTED by necessity: KDF salt + the wrapped DEK.
│                       Publishing these leaks nothing — both are useless without
│                       the PIN or this machine's secret. It cannot live inside the
│                       database, because it is what unlocks the database.
├─ objects/             encrypted file bytes, content-addressed by SHA-256
└─ thumbnails/          encrypted previews
```

`ThingsData/` is git-ignored and must never be committed. The repo is public.

**Back it up.** *Export Encrypted Backup* is a safety requirement, not a convenience: several
failure modes (changing Apple ID, a sideloader rewriting the bundle ID) make the device-bound
wrapper unreachable, and the backup is the recovery path.

---

## The daily loop

### Web and core — fast, local, free

```bash
npm run dev                              # server + web, hot reload
npm test                                 # core + server suites
npm test --workspace @things/core        # just the core
npm run vectors                          # regenerate spec/vectors/*.json
```

Sub-second iteration. **This is where the data model gets validated**, before it is ever written in
Swift, because here a mistake costs seconds instead of a CI round trip.

### iOS — slow, remote, the only way

There is no Mac, so there is no local iOS build. The loop is:

```
edit apps/ios or packages/core-swift
  → push
  → GitHub Actions (macos-26)  ~6-13 min
  → download the screenshots artifact
  → look at them
  → fix
```

Batch your changes. One CI run captures **every screen in four appearance modes** — roughly 88
images from a single simulator boot — so a run that reviews twenty screens costs the same as a run
that reviews one.

Run it manually from the Actions tab (`workflow_dispatch`) or by pushing to `apps/ios/**`.

---

## Getting a build onto the iPhone

1. Actions → **IPA** → *Run workflow*
2. Download the `Things-unsigned-ipa` artifact
3. Install with AltStore / SideStore, which re-signs it with your free Apple ID

### Facts about free provisioning you have to live with

| | |
|---|---|
| Profile lifetime | **7 days**, then the app stops launching until refreshed |
| App IDs | 10 at a time, each expiring after 7 days |
| Devices | 3 per platform |
| Active sideloaded apps | 3 (a sideloader limit, not Apple's) |

**Never let the bundle identifier change.** The keychain access group is `<TeamID>.<bundleID>`, so
a changed bundle ID makes every stored key unreachable and the vault opens empty. `ipa.yml` asserts
this on every build. If your sideloader offers to rewrite the bundle ID to save an App ID slot,
decline.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| **CI is green but the screenshots artifact is empty** | An attachment is missing `.keepAlways`. The default lifetime *discards* attachments when the test passes — the most confusing failure in this pipeline, because nothing is red. |
| **iOS job suddenly takes 25+ minutes** | It is downloading a simulator runtime. Target an SDK whose runtime ships on the image (26.5) — never call `-downloadPlatform`. |
| **Everything compiles against iOS 18 and Liquid Glass vanishes** | The job landed on `macos-15`, whose default Xcode is 16.4. Pin `macos-26`. |
| **`-resultBundlePath` errors immediately** | The path already exists. `rm -rf` it first; xcodebuild refuses to overwrite. |
| **Phone sees the PC but sync times out** | Firewall, or the network is profiled Public. Run `setup-windows.ps1`. |
| **Phone cannot see the PC at all** | mDNS across a Wi-Fi/Ethernet boundary. Use *Connect manually* with the address the setup script printed. This is expected, not a bug. |
| **A Swift conformance test fails on `spec/vectors/*.json`** | The two cores have diverged on a wire format. That is the safety net working — fix Swift to match the vectors, never the reverse, since the TypeScript side is already verified against them. |
| **Vault opens empty after a weekly re-sign** | The bundle ID or Apple ID changed. Restore from an encrypted backup. |
| **Search returns nothing for a path you know exists** | Check the FTS5 diagnostic at startup — if SQLCipher shipped without FTS5, the core is on the `LIKE` fallback, which has no ranking and is reported in Settings. |

---

## Repo conventions

- **`.xcodeproj` is generated, never committed.** `apps/ios/project.yml` is the truth; CI runs
  `xcodegen generate`. Nobody here can open Xcode to repair a corrupt `.pbxproj`.
- **`spec/` is normative.** Changing a wire format requires new vectors in the same commit.
- **Line endings are LF** for anything a runner's shell touches — see `.gitattributes`. A CRLF
  shell script fails on macOS with an error that names the wrong cause.
- **Never commit real data.** CI runs a secret scan and rejects database, key, and backup files.
  Screenshots are generated only from the fictional seed dataset — a screenshot of your real
  library attached to a public CI run is a public disclosure.
