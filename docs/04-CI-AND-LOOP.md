# Things — CI and the Review Loop

Everything in this document was verified against current sources on **2026-08-09**. Facts that
could not be verified are marked. Runner images change weekly; re-verify before blaming the code.

---

## 1. Why CI is the whole development environment here

There is no Mac. There is no local simulator, no SwiftUI Preview, no Xcode. **CI is not a quality
gate bolted onto development — it *is* the development environment.** A change to an iOS view is
not "seen" until a robot in GitHub's macOS cloud renders it and hands back a PNG.

Two consequences drive every decision below:

1. **Latency is the scarce resource.** A round trip is ~6–13 minutes (estimate, §7). So each run
   must return *as much information as possible* — many screens, many appearance modes, all at
   once. One screenshot per run would make this project unshippable.
2. **Money is not the scarce resource — concurrency is.** macOS minutes are free here (§2), but
   only 5 macOS jobs can run at a time. Parallelism must be spent carefully.

---

## 2. Cost and limits — verified

| Fact | Source |
|---|---|
| *"Use of the standard GitHub-hosted runners is free and unlimited on public repositories."* | GitHub Docs — *Choose the runner for a job* |
| *"GitHub Actions usage is free … for public repositories that use standard GitHub-hosted runners."* | GitHub Docs — Billing |
| ⚠️ *"Larger runners are always charged for, even when used by public repositories."* | GitHub Docs — Billing |
| macOS rate when billed: **$0.062/min** (Linux 2-core: $0.006) | GitHub Docs — Billing |
| **Max 5 concurrent macOS jobs**, Free/Pro/Team alike; shared with larger runners | GitHub Docs — Limits |
| Max job runtime 6 h; max 256 matrix jobs | GitHub Docs — Limits |

### Two rules that follow

1. **Never use a `-large` or `-xlarge` label.** `macos-26-large`, `macos-latest-large`,
   `xcode-27-xlarge` are all billed. Use plain **`macos-26`**. *(Whether plain `xcode-27` is
   standard or larger is unverified — treat as billed until checked.)*
2. **This is the strongest argument for keeping the repo public** and settles
   [Q3](05-OPEN-QUESTIONS.md#q3--does-the-repo-stay-public). Going private converts a free pipeline
   into a metered one. The security answer is discipline (§8), not privacy of the repo.

---

## 3. The runner, pinned

Use **`macos-26`** (arm64, macOS 26.5.2, 3 vCPU M1, 7 GB RAM, 14 GB SSD).

| | Value |
|---|---|
| Default Xcode | **26.6** (17F113) at `/Applications/Xcode.app` |
| iOS SDK | **26.5** |
| Simulator runtimes **preinstalled** | iOS **26.2, 26.4, 26.5** |
| Preinstalled devices incl. | iPhone 17, **iPhone 17 Pro**, iPhone 17 Pro Max, iPhone Air, iPhone 17e, iPad family |
| Also on image | xcbeautify 3.2.1, fastlane, xcodes, CLT 26.6, Swift 6.2+ |

### The runtime trap that must be avoided

iOS **26.0 and 26.1 runtimes are NOT on the image** even though their SDKs are. Selecting Xcode
26.0.1 or 26.1.1 forces `xcodebuild -downloadPlatform iOS` — an estimated **8–20 minute**,
multi-GB download, on a runner with 14 GB of disk, and **it is not practically cacheable** (system
paths, root-owned, against a 10 GB repo-wide cache budget).

> **Rule: target iOS 26.5 with the default Xcode and never call `-downloadPlatform`.**
> Do not pin `Xcode_26.5.app` by path either — patch versions rotate weekly and a hardcoded path
> becomes a broken build on a Tuesday. Use the default and *assert* the version in a step.

Deployment target: **iOS 26.0**; build/test against the 26.5 SDK and runtime.

`macos-15` is a trap for a different reason: its default Xcode is **16.4**, so an unpinned build
there silently compiles against iOS 18 and every Liquid Glass API vanishes behind `#available`.

---

## 4. The pipelines

Four workflows, split so that cheap feedback never waits behind expensive feedback.

| Workflow | Runner | Trigger | Purpose |
|---|---|---|---|
| `core.yml` | `ubuntu-latest` | every push | core-ts tests, **spec conformance vectors**, web build, lint, secret scan. Free, fast, catches most logic bugs. |
| `ios.yml` | `macos-26` | push to `apps/ios/**`, `packages/core-swift/**`, manual | build + Swift tests + **Screenshot Tour** + artifacts |
| `ipa.yml` | `macos-26` | tag, manual | unsigned `.ipa` for sideloading |
| `parity.yml` | `ubuntu` + `macos-26` | nightly | Node writes a database, Swift opens it, and vice versa |

**Most work never touches a macOS runner.** The data model, search grammar, crypto envelopes, and
oplog semantics are all validated on Ubuntu in seconds via the shared vectors. That is the entire
point of the spec-plus-two-implementations design.

---

## 5. The Screenshot Tour

The mechanism the whole project revolves around: *catch defects in the screenshots.*

### Everything in ONE job

With only 5 concurrent macOS jobs, a `{light,dark} × {default,XXL}` matrix would burn four of them
and boot four simulators to photograph the same app. Instead: **one job, one simulator boot, four
passes**, toggling appearance and type size in-process.

```
appearance:   xcrun simctl ui <udid> appearance light|dark
dynamic type: launch arg  -UIPreferredContentSizeCategoryName
                          UICTContentSizeCategoryAccessibilityXXL
```

Roughly 22 iOS screens × 4 modes ≈ **88 PNGs per run**, from one boot. That is what makes a
13-minute round trip worth paying.

### The gotcha that silently produces empty artifacts

Apple's docs on `XCTAttachment.Lifetime.deleteOnSuccess`: *"…is the default lifetime for all new
attachments … an attachment should be discarded if its test passes successfully."*

**Passing tests throw their screenshots away by default.** This is the single most common reason a
screenshot pipeline returns an empty zip, and it fails in the most confusing direction — green
build, no evidence.

```swift
func snap(_ name: String) {
    let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    att.name = name
    att.lifetime = .keepAlways        // REQUIRED. Default discards on success.
    add(att)
}
```

### Extraction — `xcparse` is dead, do not use it

`xcparse`'s last release was 2024-10-28 and it **fails on Xcode 26+** (open issue #91:
`"does not appear to be an xcresult"`). Legacy `xcresulttool get --legacy` is deprecated. The
current supported path, per the Xcode 27b4 man page:

```bash
rm -rf TestResults.xcresult          # -resultBundlePath ERRORS if the path exists
# … xcodebuild test -resultBundlePath "$PWD/TestResults.xcresult" …

xcrun xcresulttool export attachments \
  --path TestResults.xcresult \
  --output-path artifacts/screenshots
```

*Unverified:* whether `export attachments` emits a `manifest.json` mapping filenames back to test
names. Have the first run `ls` the output directory and adapt the renaming step to what is actually
there. Also avoid `xcresulttool merge` — reported crashing on Xcode 26.1+. Emit one `.xcresult`
per job.

### Determinism — non-negotiable

Pixel-diffing is worthless against noisy screenshots. A tour that flags 40 false positives per run
gets ignored within a week, and the quality loop dies quietly. Every run fixes:

- the **seed dataset** (`tools/seed/`) — identical Things, ids, and ordering every time
- an **injected clock** — "2 hours ago" must not drift between runs
- **animations disabled** via a launch argument
- **fixed locale, timezone, device, and OS** (`iPhone 17 Pro`, iOS 26.5)
- no network, no randomness, no `UUID()` in view code

The seed dataset is designed to be *hostile*: 60-character titles, a Thing with 40 fields, a
20 000-word note, empty collections, a missing file reference, an 8 MB image. Layout breaks live in
the long tail, and a seed that flatters the design is worse than no seed at all.

### Two-tier review

**Tier 1 — automatic.** Pixel-compare `artifacts/screenshots/` against `screenshots/baseline/`.
Unchanged screens are dropped. Only changed screens survive to Tier 2. This keeps human/AI review
proportional to the size of the change rather than the size of the app.

**Tier 2 — visual.** The changed PNGs get opened and read against the checklist in
[`03-DESIGN.md`](03-DESIGN.md#7-anti-patterns--automatic-rejection-in-visual-review): truncation,
Dynamic Type overflow, contrast on glass, glass-on-glass, glass on content, radius inconsistency,
safe-area and keyboard insets, broken empty states.

Baselines are committed and updated deliberately in their own commit, never bundled into a feature
change — a baseline update inside a feature PR is how a visual regression gets approved by
accident.

---

## 6. The unsigned IPA

`xcodebuild -exportArchive` cannot produce an unsigned ipa — every documented export `method`
signs. Archive, then build the `Payload/` zip by hand:

```bash
xcodebuild archive \
  -project Things.xcodeproj -scheme Things -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/Things.xcarchive" \
  -derivedDataPath "$PWD/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" \
  | xcbeautify

mkdir -p build/Payload
cp -R build/Things.xcarchive/Products/Applications/Things.app build/Payload/
( cd build && zip -qry Things-unsigned.ipa Payload )
```

AltStore/SideStore re-signs this and injects its own entitlements, which is why
`CODE_SIGN_ENTITLEMENTS=""` is safe and avoids "entitlements file not found" failures.

**Caveats worth knowing.** `CODE_SIGNING_ALLOWED` and `CODE_SIGNING_REQUIRED` are **absent from
Apple's public Build Settings Reference** — they are real but undocumented, and could change
without a deprecation notice. I found *no evidence* of Xcode 26/27 breaking this recipe, which is
not the same as confirming it runs on 26.6; M0 exists precisely to find out. And a documented bug
(Apple forum 795881) has unsigned builds reusing stale binaries — *"when xcodebuild is run with
signing, it rebuilds the Runner binary, but without signing it does not rebuild"* — so always use a
clean `-derivedDataPath` for the archive step. This is the concrete reason **DerivedData is not
cached** (§7).

---

## 7. Caching and timing

**Cache SwiftPM only.** `actions/cache@v6`:

```yaml
path: |
  build/DerivedData/SourcePackages
  ~/Library/Caches/org.swift.swiftpm     # path unverified, harmless
key: spm-${{ runner.os }}-${{ hashFiles('**/Package.resolved') }}
```

**Do not cache DerivedData.** `actions/checkout` stamps every file with checkout time, and Xcode
tracks input mtimes at nanosecond resolution — so a naively restored DerivedData cache produces a
100% rebuild *plus* the restore cost. Solving it needs an mtime-restoring action
(`irgaly/xcode-cache`), which buys minutes for a small app while adding the stale-binary risk from
§6. Not worth it here.

Cache budget is 10 GB per repo, evicted after a week unused. Artifacts: `actions/upload-artifact@v7`
(ESM, Node 24), 90-day max retention on public repos, 500 artifacts per job. Use
`compression-level: 0` for PNGs (already compressed), `if-no-files-found: error` so an empty
screenshot run fails loudly instead of shipping silence, and `if: always()` so failures still
produce evidence.

### Wall clock, and what was cut

Wall clock **is** iteration speed here, so it gets treated as a feature. Four things were costing
minutes for nothing:

| Waste | Fix | Saved |
|---|---|---|
| `xcodebuild test` called twice → the app compiled **twice** | one `build-for-testing`, then two `test-without-building` runs | **2–4 min** |
| `brew install xcodegen` | release binary via `gh release download` | ~80 s |
| Simulator booted *after* the build | boot detached during checkout, warms up while compiling | ~30 s |
| `npm ci` over the whole workspace, on macOS, to diff PNGs | diffing moved to a parallel Ubuntu job installing two pure-JS libs | ~40 s |

Also: `ONLY_ACTIVE_ARCH=YES`, `-skipPackagePluginValidation`, `-skipMacroValidation`, and
`-parallel-testing-enabled NO` on the tour (simulator clones break screenshot determinism and cost
more than they save at this size).

**Estimate now: ≈ 4–7 min** (queue 0.5–3 min · checkout + resolve ~1 min · build 2–4 min · tests
1–2 min · extract + upload ~20 s). `timeout-minutes: 30`, `cancel-in-progress` so a superseded push
frees its macOS slot immediately.

The remaining floor is the Swift compile itself. If it ever needs to go lower, the next lever is
caching DerivedData with an mtime-restoring action — deliberately not done yet, because it
reintroduces the stale-binary bug in §6 for a couple of minutes.

---

## 8. Secret scanning and the screenshot leak path

A screenshot generated from a **real** database, attached to a public CI run, is a public
disclosure of your passwords. This is the most plausible way this project leaks something real.

- The Screenshot Tour reads **only** `tools/seed/`. There is no code path from a real database to
  an artifact, and a test asserts the seed marker is present before any screenshot is taken.
- `core.yml` runs a secret scan and fails on a hit.
- `.gitignore` covers every data directory, `*.sqlite*`, `objects/`, `*.thingsbackup`.

---

## 9. M0 — the acceptance test for all of the above

M0 exists to prove this document is true rather than plausible. A hello-world SwiftUI app, and:

- [ ] `macos-26`, default Xcode, **no runtime download** (assert `xcrun simctl list runtimes`)
- [ ] XcodeGen generates the project from `project.yml`
- [ ] One UI test with `.keepAlways`, screenshot extracted via `xcresulttool export attachments`,
      downloaded and **actually looked at**
- [ ] **Liquid Glass visibly renders in that simulator screenshot** — if it does not, the visual
      review loop needs rethinking, and it is far better to learn that on day one
- [ ] Unsigned `.ipa` produced, sideloaded via AltStore/SideStore, app opens on the iPhone
- [ ] **On the real device:** a Secure-Enclave P-256 key created with `[.privateKeyUsage,
      .biometryCurrentSet]` and read back behind Face ID, **under a free Personal Team profile**.
      No Apple documentation confirms this works; it is the riskiest assumption in
      [`02-SECURITY.md`](02-SECURITY.md). If it fails, the PIN path still works and Face ID is
      simply dropped — but we need to know before building an unlock UI around it.
- [ ] Total round-trip time measured and recorded here, replacing the estimate in §7

If any box fails, the project's shape changes and we replan before writing real code.
