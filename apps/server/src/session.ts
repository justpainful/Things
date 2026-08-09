import { randomBytes, timingSafeEqual } from 'node:crypto';
import type { Core } from '@things/core';
import { failedAttemptDelayMs } from '@things/core';

/**
 * Session state — docs/02-SECURITY.md §6.
 *
 *   Unlock       PIN entry
 *   Auto-lock    a timer, plus explicit lock on tab close
 *   Privacy Mode masks every secret, email, phone and key on screen without
 *                locking. It is a DISPLAY state, not a security boundary, and
 *                the API says so rather than implying otherwise.
 *
 * Failed attempts get escalating delays and Things never wipes: with no cloud
 * copy, an auto-wipe turns a forgotten PIN into permanent data loss.
 */

const OBJECT_COOKIE = 'things_objects';

export interface SessionState {
  provisioned: boolean;
  locked: boolean;
  privacyMode: boolean;
  autoLockMs: number;
  lockedInMs: number | null;
  deviceWrapper: string;
  failedAttempts: number;
  retryAfterMs: number;
}

export class Session {
  private core: Core;
  private token: string | null = null;
  private lastActivity = Date.now();
  private timer: NodeJS.Timeout | null = null;
  private failures = 0;
  private nextAttemptAt = 0;

  autoLockMs: number;
  privacyMode = false;

  constructor(core: Core, autoLockMs: number) {
    this.core = core;
    this.autoLockMs = autoLockMs;
  }

  get provisioned(): boolean {
    return this.core.keyring.isProvisioned;
  }

  get locked(): boolean {
    return !this.core.keyring.isUnlocked;
  }

  state(): SessionState {
    return {
      provisioned: this.provisioned,
      locked: this.locked,
      privacyMode: this.privacyMode,
      autoLockMs: this.autoLockMs,
      lockedInMs: this.locked || this.autoLockMs <= 0 ? null : Math.max(0, this.autoLockMs - (Date.now() - this.lastActivity)),
      deviceWrapper: this.core.keyring.deviceWrapperStrength(),
      failedAttempts: this.failures,
      retryAfterMs: Math.max(0, this.nextAttemptAt - Date.now()),
    };
  }

  async setup(pin: string): Promise<{ token: string }> {
    if (this.provisioned) throw new Error('already set up');
    validatePin(pin);
    await this.core.keyring.provision(pin);
    return { token: this.issue() };
  }

  async unlock(pin: string): Promise<{ token: string } | { retryAfterMs: number }> {
    const wait = this.nextAttemptAt - Date.now();
    if (wait > 0) return { retryAfterMs: wait };

    const ok = await this.core.keyring.unlockWithPin(pin);
    if (!ok) {
      this.failures += 1;
      this.nextAttemptAt = Date.now() + failedAttemptDelayMs(this.failures);
      return { retryAfterMs: Math.max(0, this.nextAttemptAt - Date.now()) };
    }
    this.failures = 0;
    this.nextAttemptAt = 0;
    return { token: this.issue() };
  }

  /** Convenience unlock via the device wrapper. May legitimately fail. */
  unlockWithDevice(): { token: string } | null {
    return this.core.keyring.unlockWithDevice() ? { token: this.issue() } : null;
  }

  async changePin(currentPin: string, newPin: string): Promise<boolean> {
    validatePin(newPin);
    return this.core.keyring.changePin(currentPin, newPin);
  }

  lock(): void {
    this.core.keyring.lock();
    this.core.oplog.clearUndoHistory();
    this.token = null;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  /**
   * `<img src>` and `<video src>` cannot carry an Authorization header, so
   * object reads additionally accept the same token from a cookie.
   *
   * The cookie is HttpOnly, SameSite=Strict, and scoped to `/api/objects`, and
   * the server only honours it for GET on that path — so it can fetch bytes
   * and nothing else. Combined with the loopback bind and the Host-header
   * guard, that is a narrower surface than a query-string token, which would
   * also end up in the browser's history and in any screenshot of the URL bar.
   */
  get cookieHeader(): string {
    return this.token
      ? `${OBJECT_COOKIE}=${this.token}; Path=/api/objects; HttpOnly; SameSite=Strict`
      : `${OBJECT_COOKIE}=; Path=/api/objects; HttpOnly; SameSite=Strict; Max-Age=0`;
  }

  authorizeObjectCookie(cookieHeader: string | undefined): boolean {
    if (this.locked || !this.token || !cookieHeader) return false;
    const match = new RegExp(`(?:^|;\\s*)${OBJECT_COOKIE}=([^;]+)`).exec(cookieHeader);
    if (!match) return false;
    const presented = match[1];
    if (presented.length !== this.token.length) return false;
    if (!timingSafeEqual(Buffer.from(presented), Buffer.from(this.token))) return false;
    this.touch();
    return true;
  }

  /** Constant-time bearer-token check. */
  authorize(header: string | undefined): boolean {
    if (this.locked || !this.token) return false;
    const presented = (header ?? '').replace(/^Bearer\s+/i, '');
    if (presented.length !== this.token.length) return false;
    if (!timingSafeEqual(Buffer.from(presented), Buffer.from(this.token))) return false;
    this.touch();
    return true;
  }

  private issue(): string {
    this.token = randomBytes(32).toString('base64url');
    this.touch();
    return this.token;
  }

  private touch(): void {
    this.lastActivity = Date.now();
    if (this.timer) clearTimeout(this.timer);
    if (this.autoLockMs > 0) {
      this.timer = setTimeout(() => this.lock(), this.autoLockMs);
      this.timer.unref?.();
    }
  }

  dispose(): void {
    if (this.timer) clearTimeout(this.timer);
  }
}

export function validatePin(pin: string): void {
  if (!/^\d{6,32}$/.test(pin)) {
    throw new Error('The PIN must be at least 6 digits.');
  }
}
