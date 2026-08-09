import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Core } from '../src/core.ts';
import type { KdfParams } from '../src/crypto/kdf.ts';

/**
 * Test scrypt parameters. Production is N=2^16 r=8 p=2 (docs/02-SECURITY.md);
 * a suite that ran that 40 times would take half a minute for no extra
 * coverage — the parameters themselves are asserted once in crypto.test.ts.
 */
export const TEST_KDF: KdfParams = { algorithm: 'scrypt', N: 1024, r: 8, p: 1, dkLen: 32 };

export const TEST_PIN = '000000';

const dirs: string[] = [];

export function tempDir(): string {
  const d = mkdtempSync(join(tmpdir(), 'things-test-'));
  dirs.push(d);
  return d;
}

export async function makeCore(): Promise<Core> {
  const core = Core.open({ dataDir: tempDir(), deviceName: 'TEST-PC', forceFallbackDeviceSecret: true });
  await core.keyring.provision(TEST_PIN, TEST_KDF);
  return core;
}

export function cleanup(): void {
  for (const d of dirs.splice(0)) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      /* Windows sometimes holds the sqlite handle a moment longer */
    }
  }
}
