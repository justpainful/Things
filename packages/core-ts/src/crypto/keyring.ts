import { hkdfSync, randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import { DEFAULT_KDF_PARAMS, deriveKek, parseKdfParams } from './kdf.ts';
import type { KdfParams } from './kdf.ts';
import { open, seal, DecryptError } from './envelope.ts';
import { DeviceSecretStore } from './deviceSecret.ts';
import type { DeviceSecretStrength } from './deviceSecret.ts';

/**
 * The key hierarchy — docs/02-SECURITY.md §3.
 *
 *   PIN ──scrypt──► KEK₁ ─┐
 *                          ├─► unwrap ─► DEK (random 256-bit)
 *   device secret ─HKDF──► KEK₂ ─┘
 *
 * The DEK is never derived from the PIN; it is *wrapped* by keys that are.
 * Changing the PIN re-wraps 32 bytes instead of re-encrypting the library.
 *
 * The two wrappers are independent and either alone opens the DEK. The PIN
 * wrapper must ALWAYS work — it is the recovery route for all three of the
 * failure modes in §3 that would otherwise destroy the library.
 */

/**
 * Domain separators — `spec/crypto.md` §2.2. These exact bytes are wire format:
 * they are the caller AAD of each wrapped key, and they are what stops a
 * PIN-wrapped DEK being presented as a device-wrapped one. Colons, not dots.
 * Pinned by `spec/vectors/crypto-context.json` and, as used, by the `seal`
 * cases in `spec/vectors/crypto-envelope.json`.
 */
export const DEK_WRAP_AAD_PIN = Buffer.from('things:dek-wrap:pin:v1', 'utf8');
export const DEK_WRAP_AAD_DEVICE = Buffer.from('things:dek-wrap:device:v1', 'utf8');
/** HKDF `info` for KEK₂ — `spec/crypto.md` §1.2. */
export const KEK2_HKDF_INFO = Buffer.from('things:kek2:v1', 'utf8');
/** AAD of the encrypted backup container. Reserved; no TS writer yet. */
export const BACKUP_AAD = Buffer.from('things:backup:v1', 'utf8');

export interface KeyringState {
  kdf_salt: string; // base64
  kdf_params: string; // JSON
  dek_wrap_pin: string; // base64 envelope
  dek_wrap_device: string | null; // base64 envelope
  /** sha256 of the DEK, truncated — lets us verify an unwrap without the DEK leaving memory. */
  dek_check: string;
}

/**
 * Where the wrappers live. In production this is `vault.json` beside the
 * database (`spec/crypto.md` §3) — never the `meta` table, which lives inside
 * the very database these rows are needed to unlock.
 *
 * `set(key, null)` deletes the key. An absent `dek_wrap_device` is a normal
 * state, not an error, and the sidecar spells it by omission.
 */
export interface KeyringStore {
  get(key: string): string | null;
  set(key: string, value: string | null): void;
}

/** KEK₂ = HKDF-SHA256(device secret). */
export function deriveDeviceKek(deviceSecret: Uint8Array, salt: Uint8Array): Buffer {
  const out = hkdfSync('sha256', Buffer.from(deviceSecret), Buffer.from(salt), KEK2_HKDF_INFO, 32);
  return Buffer.from(out);
}

/**
 * `dek_check` — `spec/crypto.md` §3.2: base64(sha256(DEK)) truncated to 22
 * characters.
 *
 * **This is kept deliberately, and it is not redundant with AES-GCM.** GCM
 * authenticates each wrapper *in isolation*: it proves `dek_wrap_pin` was
 * sealed by whoever held KEK₁, and separately that `dek_wrap_device` was sealed
 * by whoever held KEK₂. It structurally cannot prove the two envelopes contain
 * the *same* DEK, because neither envelope knows the other exists.
 *
 * That is exactly the failure `spec/crypto.md` §1.2 warns about: a
 * `dek_wrap_device` left behind from an earlier provisioning, or a `vault.json`
 * half-restored from a backup, unwraps perfectly and yields the WRONG key. With
 * SQLCipher keyed by the DEK the symptom is "file is not a database", and with
 * object keys it is a pile of blobs that fail to open — neither of which points
 * at the actual cause. `dek_check` is the one cross-wrapper consistency check
 * available, it costs 22 characters, and it turns a mystery into a diagnosis.
 *
 * Reader contract: a reader that FINDS it must check it; a writer may omit it.
 */
export function dekCheck(dek: Uint8Array): string {
  return createHash('sha256').update(Buffer.from(dek)).digest('base64').slice(0, 22);
}

export class Keyring {
  private store: KeyringStore;
  private deviceStore: DeviceSecretStore;
  private dek: Buffer | null = null;

  constructor(store: KeyringStore, deviceStore: DeviceSecretStore) {
    this.store = store;
    this.deviceStore = deviceStore;
  }

  get isProvisioned(): boolean {
    return this.store.get('dek_wrap_pin') !== null;
  }

  get isUnlocked(): boolean {
    return this.dek !== null;
  }

  /** The Data Encryption Key. Throws when locked — callers must never cache it. */
  requireDek(): Buffer {
    if (!this.dek) throw new Error('locked');
    return this.dek;
  }

  lock(): void {
    if (this.dek) this.dek.fill(0);
    this.dek = null;
  }

  deviceWrapperStrength(): DeviceSecretStrength | 'none' {
    if (!this.store.get('dek_wrap_device')) return 'none';
    return this.deviceStore.available();
  }

  /**
   * Consecutive failed PIN attempts, persisted in `vault.json` so the escalating
   * delay survives a restart. Advisory and local; never synced, and Things never
   * wipes (`spec/crypto.md` §6.2).
   */
  get failedPinAttempts(): number {
    const raw = this.store.get('failed_pin_attempts');
    const n = raw === null ? 0 : parseInt(raw, 10);
    return Number.isFinite(n) && n > 0 ? n : 0;
  }

  /** First run: mint a random DEK and wrap it under both wrappers. */
  async provision(pin: string, params: KdfParams = DEFAULT_KDF_PARAMS): Promise<void> {
    if (this.isProvisioned) throw new Error('already provisioned');
    const dek = randomBytes(32);
    const salt = randomBytes(16);

    const kek1 = await deriveKek(pin, salt, params);
    this.store.set('kdf_salt', salt.toString('base64'));
    this.store.set('kdf_params', JSON.stringify(params));
    this.store.set('dek_wrap_pin', seal(kek1, dek, DEK_WRAP_AAD_PIN).toString('base64'));
    this.store.set('dek_check', dekCheck(dek));
    this.store.set('failed_pin_attempts', '0');
    kek1.fill(0);

    this.wrapForDevice(dek, salt);
    this.dek = dek;
  }

  /** Unlock with the PIN. Always available — this is the recovery route. */
  async unlockWithPin(pin: string): Promise<boolean> {
    const wrap = this.store.get('dek_wrap_pin');
    const saltB64 = this.store.get('kdf_salt');
    if (!wrap || !saltB64) return false;
    const salt = Buffer.from(saltB64, 'base64');
    const params = parseKdfParams(this.store.get('kdf_params'));
    const kek1 = await deriveKek(pin, salt, params);
    try {
      const dek = open(kek1, Buffer.from(wrap, 'base64'), DEK_WRAP_AAD_PIN);
      if (!this.verify(dek)) {
        this.recordFailedAttempt();
        return false;
      }
      this.dek = dek;
      this.store.set('failed_pin_attempts', '0');
      // Opportunistically (re-)create the device wrapper: it may have been lost
      // to a profile restore, and the PIN path is exactly how it gets rebuilt.
      if (!this.store.get('dek_wrap_device')) this.wrapForDevice(dek, salt);
      return true;
    } catch (e) {
      if (e instanceof DecryptError) {
        this.recordFailedAttempt();
        return false;
      }
      throw e;
    } finally {
      kek1.fill(0);
    }
  }

  /** Unlock with the device wrapper. Convenience only; may legitimately fail. */
  unlockWithDevice(): boolean {
    const wrap = this.store.get('dek_wrap_device');
    const saltB64 = this.store.get('kdf_salt');
    if (!wrap || !saltB64) return false;
    const ds = this.deviceStore.load();
    if (!ds) return false;
    const kek2 = deriveDeviceKek(ds.secret, Buffer.from(saltB64, 'base64'));
    try {
      const dek = open(kek2, Buffer.from(wrap, 'base64'), DEK_WRAP_AAD_DEVICE);
      if (!this.verify(dek)) return false;
      this.dek = dek;
      return true;
    } catch {
      return false;
    } finally {
      kek2.fill(0);
      ds.secret.fill(0);
    }
  }

  /** Re-wrap the DEK under a new PIN. Cheap: 32 bytes, not the library. */
  async changePin(currentPin: string, newPin: string): Promise<boolean> {
    const wasUnlocked = this.isUnlocked;
    if (!(await this.unlockWithPin(currentPin))) return false;
    const dek = this.requireDek();
    const salt = randomBytes(16);
    const params = parseKdfParams(this.store.get('kdf_params'));
    const kek1 = await deriveKek(newPin, salt, params);
    this.store.set('kdf_salt', salt.toString('base64'));
    this.store.set('dek_wrap_pin', seal(kek1, dek, DEK_WRAP_AAD_PIN).toString('base64'));
    kek1.fill(0);
    this.wrapForDevice(dek, salt);
    if (!wasUnlocked) this.lock();
    return true;
  }

  private wrapForDevice(dek: Buffer, salt: Buffer): void {
    try {
      const ds = this.deviceStore.exists() ? this.deviceStore.load() : this.deviceStore.create();
      if (!ds) {
        this.store.set('dek_wrap_device', null);
        return;
      }
      const kek2 = deriveDeviceKek(ds.secret, salt);
      this.store.set('dek_wrap_device', seal(kek2, dek, DEK_WRAP_AAD_DEVICE).toString('base64'));
      kek2.fill(0);
      ds.secret.fill(0);
    } catch {
      // A missing device wrapper is a degraded convenience, never a failure —
      // but a wrapper left behind under a stale salt would never open again,
      // so it is REMOVED rather than left in place (spec/crypto.md §1.2).
      this.store.set('dek_wrap_device', null);
    }
  }

  private recordFailedAttempt(): void {
    this.store.set('failed_pin_attempts', String(this.failedPinAttempts + 1));
  }

  /**
   * `dek_check` — MUST be checked when present (`spec/crypto.md` §3.2). Absent
   * is legal: the key is optional and an older or other-core writer may omit it.
   */
  private verify(dek: Buffer): boolean {
    const expected = this.store.get('dek_check');
    if (!expected) return true;
    const a = Buffer.from(dekCheck(dek));
    const b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  }
}
