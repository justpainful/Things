import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';

/**
 * The device wrapper — docs/02-SECURITY.md §3, Wrapper 2.
 *
 * 32 random bytes sealed to the Windows user account with DPAPI, from which
 * KEK₂ is derived with HKDF. Copy the ThingsData folder to another machine or
 * another user and the sealed blob is inert: that is the answer to threat T1,
 * which the doc calls "the one that actually matters".
 *
 * ── How DPAPI is reached from Node ──────────────────────────────────────────
 * Node has no DPAPI binding and this project refuses native modules (the whole
 * point of node:sqlite was to avoid a build step). So `ProtectedData` is
 * reached through Windows PowerShell, which exposes it from System.Security.
 * The secret travels over stdin/stdout as base64 — never as a command-line
 * argument, which would be visible to every process on the machine.
 *
 * ── The fallback, stated honestly ───────────────────────────────────────────
 * If PowerShell is unavailable or refuses (non-Windows, locked-down host), the
 * implementation falls back to a plain file with a clearly-marked weaker
 * guarantee: it is obfuscation-at-rest, NOT device binding. `strength` on the
 * returned handle says which one you got, and the server surfaces it in
 * Settings rather than pretending.
 *
 * Either way the PIN wrapper (Wrapper 1) works independently and is the
 * recovery route. Nothing here is ever the only way in.
 */

export type DeviceSecretStrength = 'dpapi' | 'file-fallback';

export interface DeviceSecret {
  secret: Buffer;
  strength: DeviceSecretStrength;
}

const PS_ENTROPY = 'Things.DeviceSecret.v1';

function powershellExe(): string | null {
  if (process.platform !== 'win32') return null;
  for (const exe of ['powershell.exe', 'pwsh.exe']) {
    const probe = spawnSync(exe, ['-NoProfile', '-NonInteractive', '-Command', 'exit 0'], {
      stdio: 'ignore',
      windowsHide: true,
      timeout: 15_000,
    });
    if (probe.status === 0) return exe;
  }
  return null;
}

/** Run a PowerShell snippet, feeding `input` on stdin and returning stdout. */
function ps(exe: string, script: string, input: string): string | null {
  const r = spawnSync(exe, ['-NoProfile', '-NonInteractive', '-Command', '-'], {
    input: `${script}\n`,
    encoding: 'utf8',
    windowsHide: true,
    timeout: 30_000,
    env: { ...process.env, THINGS_PS_INPUT: input },
  });
  if (r.status !== 0 || !r.stdout) return null;
  const out = r.stdout.trim();
  return out.length ? out : null;
}

const PROTECT = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$bytes = [Convert]::FromBase64String($env:THINGS_PS_INPUT)
$entropy = [Text.Encoding]::UTF8.GetBytes('${PS_ENTROPY}')
$out = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, 'CurrentUser')
[Convert]::ToBase64String($out)
`;

const UNPROTECT = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$bytes = [Convert]::FromBase64String($env:THINGS_PS_INPUT)
$entropy = [Text.Encoding]::UTF8.GetBytes('${PS_ENTROPY}')
$out = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $entropy, 'CurrentUser')
[Convert]::ToBase64String($out)
`;

export interface DeviceSecretStoreOptions {
  /** Directory holding the sealed blob. Normally <dataDir>/keys. */
  dir: string;
  /** Force the file fallback — used by tests so they never touch the real DPAPI store. */
  forceFallback?: boolean;
}

export class DeviceSecretStore {
  private dir: string;
  private forceFallback: boolean;

  constructor(opts: DeviceSecretStoreOptions) {
    this.dir = opts.dir;
    this.forceFallback = opts.forceFallback ?? process.env.THINGS_DEVICE_SECRET === 'file';
  }

  private get dpapiPath(): string {
    return join(this.dir, 'device-secret.dpapi');
  }

  private get fallbackPath(): string {
    return join(this.dir, 'device-secret.fallback');
  }

  available(): DeviceSecretStrength {
    if (this.forceFallback) return 'file-fallback';
    return powershellExe() ? 'dpapi' : 'file-fallback';
  }

  exists(): boolean {
    return existsSync(this.dpapiPath) || existsSync(this.fallbackPath);
  }

  /** Create and seal a fresh 32-byte device secret. Overwrites any existing one. */
  create(): DeviceSecret {
    mkdirSync(this.dir, { recursive: true });
    const secret = randomBytes(32);
    const exe = this.forceFallback ? null : powershellExe();
    if (exe) {
      const sealed = ps(exe, PROTECT, secret.toString('base64'));
      if (sealed) {
        writeFileSync(this.dpapiPath, sealed, 'utf8');
        restrict(this.dpapiPath);
        return { secret, strength: 'dpapi' };
      }
    }
    // TODO(M6): replace with a real Windows Credential Manager binding once a
    // dependency-free path exists. Until then this file is explicitly weaker
    // than DPAPI and is reported as such in Settings.
    writeFileSync(this.fallbackPath, obfuscate(secret).toString('base64'), 'utf8');
    restrict(this.fallbackPath);
    return { secret, strength: 'file-fallback' };
  }

  /** Load the existing device secret, or null if there is none / it is unreadable. */
  load(): DeviceSecret | null {
    if (existsSync(this.dpapiPath) && !this.forceFallback) {
      const exe = powershellExe();
      if (exe) {
        const b64 = ps(exe, UNPROTECT, readFileSync(this.dpapiPath, 'utf8').trim());
        if (b64) return { secret: Buffer.from(b64, 'base64'), strength: 'dpapi' };
      }
      // Sealed blob present but unreadable: different Windows user, or a
      // restored profile. The PIN wrapper is the way in. Do not throw.
      return null;
    }
    if (existsSync(this.fallbackPath)) {
      const raw = Buffer.from(readFileSync(this.fallbackPath, 'utf8').trim(), 'base64');
      return { secret: deobfuscate(raw), strength: 'file-fallback' };
    }
    return null;
  }
}

/**
 * The fallback's at-rest transform. A machine-derived keystream — hostname,
 * user, platform — so the file is not a plaintext key sitting on disk, while
 * being completely honest that this is obfuscation and not a security boundary.
 */
function machineKey(): Buffer {
  const material = [
    process.env.COMPUTERNAME ?? process.env.HOSTNAME ?? '',
    process.env.USERNAME ?? process.env.USER ?? '',
    process.platform,
    process.arch,
    'things.device-secret.fallback.v1',
  ].join('');
  return createHash('sha256').update(material).digest();
}

function obfuscate(b: Buffer): Buffer {
  const k = machineKey();
  const out = Buffer.alloc(b.length);
  for (let i = 0; i < b.length; i++) out[i] = b[i] ^ k[i % k.length];
  return out;
}

const deobfuscate = obfuscate;

function restrict(path: string): void {
  try {
    chmodSync(path, 0o600);
  } catch {
    /* Windows ACLs do not map onto POSIX modes; the data dir is user-scoped anyway. */
  }
  void dirname(path);
}
