# Things — Security Design

Things holds passwords, API keys, card details, and personal documents, on a machine whose repo is
public and whose OS has no Secure Enclave. The design below is sized to a **realistic** threat
model, not a theatrical one.

> **Nothing in this repository ever contains a real PIN, passphrase, key, or personal record.**
> The PIN is chosen by the user at first run and exists only in their head and in derived form on
> their own devices. CI runs a secret scan on every push.

---

## 1. Threat model

| # | Threat | In scope | Handled by |
|---|---|---|---|
| T1 | Someone copies the `ThingsData` folder (USB, backup, cloud-synced folder, stolen drive) | **Yes — primary** | Device-bound key wrapping (§3) |
| T2 | The public repo leaks something real | **Yes — primary** | No data in repo, `.gitignore`, CI secret scan |
| T3 | The iPhone is stolen while locked | **Yes** | Secure Enclave + Face ID + data protection |
| T4 | Someone looks over your shoulder while you browse | **Yes** | Privacy Mode, Locked Things, no secrets in previews |
| T5 | A device on the LAN tries to talk to the sync port | **Yes** | Pairing required, pinned cert, no unpaired peers |
| T6 | Malware running as *you* on an unlocked Windows session | **Partially** | Honest limits (§4) |
| T7 | Nation-state, hardware implants, cold-boot RAM extraction | No | Out of scope, and saying otherwise would be dishonest |

**T1 is the one that actually matters.** Files get copied. Backups get synced. Drives get sold.

---

## 2. Why a 6-digit PIN is not, by itself, enough

A 6-digit PIN is 1,000,000 possibilities. If the encryption key were derived from the PIN alone,
then anyone holding a copy of the database could try all million offline, in parallel, on a GPU.
Even with an aggressive KDF, that is hours to days — for *everything you own*.

The iPhone solves this exact problem, and Things copies its solution: **the PIN is useless without
the device.** The key is derived from the PIN *combined with a secret that never leaves the
machine's OS-protected store*. Copy the folder, get nothing. The PIN stays six digits and the
unlock stays fast.

---

## 3. Key hierarchy

The DEK is a random 256-bit key that encrypts everything. It is **never derived from the PIN** —
it is *wrapped* by keys that are. That way, changing your PIN re-wraps 32 bytes instead of
re-encrypting your entire library.

The DEK is wrapped **twice, independently**. Either wrapper alone can open it:

```
             ┌─ Wrapper 1 — PIN path (always available, the recovery route) ─┐
  PIN ──► PBKDF2-HMAC-SHA256, 600k rounds, 16-byte salt ──► KEK ──► unwrap ──┤
                                                                             │
             ┌─ Wrapper 2 — device path (convenience, biometric) ────────────┤
  Secure Enclave P-256 ──► ECDH ──► HKDF-SHA256 ──────────► KEK₂ ──► unwrap ─┤
  (iPhone)                                                                   │
  DPAPI-sealed secret ────► HKDF-SHA256 ─────────────────► KEK₂ ──► unwrap ──┤
  (Windows)                                                                  │
                                                                             ▼
                                                              DEK (random 256-bit)
                                       ┌──────────────┬──────────────┬───────────┐
                                       ▼              ▼              ▼           ▼
                                  SQLCipher    secret fields   object keys   backup key
```

### Why two wrappers, and why this is not optional

`.biometryCurrentSet` — the flag that invalidates a key when the biometric enrollment set changes —
is the *right* security choice and a **data-loss footgun**. If you add a fingerprint or re-enrol
Face ID, that key becomes permanently unusable. If it were the only way in, your entire library
would be gone. **The PIN path must always exist as the recovery route.** Biometrics are convenience
on top, never the sole door.

### Platform specifics (verified 2026-08-09)

| | iPhone | Windows |
|---|---|---|
| Device secret | Secure Enclave **P-256 key** — the SE holds *only* P-256 keys and cannot store a symmetric key at all. Pattern: `sharedSecretFromKeyAgreement` → `hkdfDerivedSymmetricKey`. | 32 random bytes sealed with DPAPI (user scope), in Windows Credential Manager |
| Access control | `SecAccessControlCreateWithFlags(…, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet])` | Bound to the Windows user account |
| Key persistence | SE key's `dataRepresentation` (an SE-encrypted blob, not the key) stored as `kSecClassGenericPassword`, **no `kSecAttrAccessGroup`** | — |

Omitting `kSecAttrAccessGroup` is deliberate: the app then lands in its default group
`$(teamID).$(bundleID)`, granted by the implicit `application-identifier` entitlement that even a
free Personal Team profile carries. Setting an explicit group would require the Keychain Sharing
capability, which a free account cannot mint.

### KDF: scrypt — memory-hard, and Apple actually ships it

Argon2id is OWASP's first recommendation and **it is not available on this platform.** CryptoKit
ships exactly one KDF — HKDF. No PBKDF2, no Argon2. Every Swift Argon2 package is either abandoned
(last commit 2023, or 2018) or has single-digit stars and no audit; depending on an unmaintained C
wrapper for the root key of a password store is the worse risk.

But swift-crypto's `CryptoExtras` — which builds on iOS, unlike the parts of that package gated to
Linux — provides **`KDF.Insecure.Scrypt`**, the only **memory-hard** KDF Apple ships, alongside
`KDF.Insecure.PBKDF2` (which is itself a typed wrapper over Apple's CommonCrypto, with a
hard-enforced 210 000-round floor citing OWASP).

**Decision: scrypt**, OWASP parameters `N=2^16, r=8, p=2` (or `N=2^17, r=8, p=1`), calibrated so
the slowest device — the iPhone — stays near 0.3–0.5 s. Node has native scrypt with identical
parameters, so both cores agree without a third-party dependency on either side. Parameters are
stored beside the salt so they can be raised later without breaking existing databases.

This matters more than a footnote: PBKDF2's weakness is GPU parallelism, and memory-hardness is
precisely the property that blunts it. Choosing scrypt over PBKDF2 costs nothing and removes the
main reason the earlier PBKDF2 plan needed apologising for. Device-binding (§3) remains the primary
defence; scrypt makes the fallback case meaningfully stronger rather than merely acceptable.

`KDF.Insecure` is Apple's namespace for *password-based* KDFs generally — the name is not a
judgement on scrypt specifically.

### The DEK is portable, the wrappers are not

Both devices need the same DEK to read the same data — that is what lets sync move ciphertext
untouched. Pairing transfers the DEK once over the pairing-authenticated channel; each device then
wraps it with its own local wrappers.

### ⚠️ Three failure modes that would destroy the library

The keychain access group is derived from `<TeamID>.<bundleID>`. **Anything that changes either
half makes every stored item unreachable, and the vault opens empty.**

1. **Changing your Apple ID changes the team prefix.** The device wrapper dies with it.
2. **Some sideloading tools rewrite the bundle identifier** on install — often deliberately, to
   work around the 10-App-IDs-per-7-days limit. If the bundle ID differs between weekly re-signs,
   the vault appears empty every refresh. **Verify what our sideloader does to the bundle ID in
   M0, and keep bundle IDs stable across CI builds** (stable IDs also reuse existing App IDs
   instead of consuming new ones from that quota).
3. **The 7-day rebuild cycle itself** is survivable *only because* the team ID and bundle ID
   normally stay constant across reinstalls.

All three are survivable for one reason: **the PIN wrapper never depends on the keychain.**

Therefore: **Export Encrypted Backup is not an M8 nicety, it is a safety requirement**, and its key
must be derived from the PIN alone. Ship a "back up now" prompt before the app holds anything the
user would miss.

### ⚠️ The simulator has no Secure Enclave

Apple's DTS is explicit: the simulator "acts like an iOS device that has no SE."
`SecureEnclave.isAvailable` is `false` and biometric-gated items generally return values without
prompting. **Every screenshot in this project is taken on a simulator**, so the app must ship a
`#if targetEnvironment(simulator)` software-key fallback or it is not developable at all. The real
security path can only be verified on the device.

**Unverified and worth testing in M0:** whether biometric-gated keychain items work under a free
Personal Team profile. No Apple statement confirms it either way. It is the single riskiest
assumption in this design — and if it fails, the PIN path still works and Face ID simply becomes
unavailable.

---

## 4. What this does and does not protect against — stated plainly

**Protected.** Copied database or backup, stolen drive, stolen locked iPhone, a curious person on
your LAN, someone reading over your shoulder, the public repo.

**Not fully protected.** Malware running as your Windows user while you are logged in can reach the
DPAPI secret, and could then brute-force a 6-digit PIN offline. scrypt at ~0.3–0.5 s per guess,
memory-hard so GPUs parallelise it poorly, makes that days rather than seconds — but it is not a
wall.

That limit is proportionate: an attacker at that level already has your browser's saved passwords
and can keylog the PIN as you type it. Pretending otherwise would be security theatre. If you ever
want to close it, the answer is a longer passphrase on the PC — which the design supports as a
setting without any schema change.

**Failed PIN attempts** use escalating delays (1s, 5s, 30s, 5min…). Things deliberately **never
wipes** on repeated failures: this is a local-only app with no cloud copy, so an auto-wipe converts
a forgotten PIN or a child mashing keys into permanent, unrecoverable data loss. That trade is
wrong here.

---

## 5. Secrets at rest and in motion

- Secret fields are encrypted with **AES-256-GCM**, AAD bound to `thing_id ‖ field_id`, so a
  ciphertext blob cannot be relocated into a different Thing.
- **The oplog stores secrets as ciphertext too.** Without this, History becomes a plaintext log of
  every password you ever changed — an easy and severe mistake.
- **The search index never contains a secret value.** It holds the field's *label* and a
  `has:password` marker, which is exactly the behavior asked for: find Things that have a password
  without revealing it.
- Locked Things contribute nothing to search, Recents previews, or the app-switcher snapshot while
  locked.
- Objects are encrypted per-file with their own key, in 1 MiB frames so video can seek without
  decrypting the whole file.

## 6. Unlock and lock behavior

| Surface | Unlock | Auto-lock |
|---|---|---|
| iPhone app | Face ID, PIN fallback | Immediately / 1 / 5 / 15 min / never |
| Web on localhost | PIN entry | Same options; also on tab close and on OS lock |
| Revealing an individual secret | Optional second gate (Face ID / PIN) | Re-hides after a timeout |
| Locked Thing | Always gated, regardless of app unlock state | — |

**Privacy Mode** is a single toggle that masks every secret, email, phone, and key on screen
without locking the app — for when someone is next to you. It is a display state, not a security
boundary, and the UI should not imply otherwise.

## 7. Network posture

- Web UI binds **127.0.0.1 only**, port 6767. It is never reachable from the LAN. This is enforced
  in code, not configuration, and covered by a test.
- Sync listens on a **separate** port and accepts **only paired devices**: TLS with a self-signed
  certificate pinned at pairing time, plus a mutual proof of the pairing secret.
- Pairing is out-of-band: the PC shows a QR code, the phone scans it. There is no discovery-based
  auto-trust — being on the same Wi-Fi grants a device nothing.
- **No outbound connections, ever**, except actions the user explicitly triggers (e.g. *Fetch
  Metadata* on a link). `External Metadata` ships **off**. No telemetry, no update check, no
  crash reporting.

## 8. Repo hygiene (T2)

- `.gitignore` covers every data directory, `*.sqlite*`, `objects/`, `*.thingsbackup`, `.env`.
- Seed data is obviously fictional — no real domains, no plausible-looking keys.
- CI runs a secret scan and fails the build on a hit.
- Screenshot artifacts are generated **only** from the seed dataset, never from a real database.
  This is a genuine leak path worth naming: a screenshot of your real Things, attached to a public
  CI run, is a public disclosure.
