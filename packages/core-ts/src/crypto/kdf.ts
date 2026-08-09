import { randomBytes, scrypt as scryptCb, scryptSync } from 'node:crypto';
import { promisify } from 'node:util';

/**
 * scrypt — docs/02-SECURITY.md §3.
 *
 * OWASP parameters: N=2^16, r=8, p=2. Memory-hard, which is precisely the
 * property that blunts GPU parallelism — the reason scrypt was chosen over
 * PBKDF2. Node has it natively and swift-crypto's CryptoExtras ships
 * `KDF.Insecure.Scrypt` with the same parameters, so both cores agree without
 * a third-party dependency on either side.
 *
 * Parameters are stored beside the salt in `meta.kdf_params` so they can be
 * raised later without breaking existing databases.
 */

const scryptAsync = promisify(scryptCb) as (
  password: string | Buffer,
  salt: Buffer,
  keylen: number,
  opts: { N: number; r: number; p: number; maxmem: number },
) => Promise<Buffer>;

export interface KdfParams {
  algorithm: 'scrypt';
  N: number;
  r: number;
  p: number;
  dkLen: number;
}

export const DEFAULT_KDF_PARAMS: KdfParams = {
  algorithm: 'scrypt',
  N: 1 << 16, // 65536
  r: 8,
  p: 2,
  dkLen: 32,
};

/** scrypt needs 128 * N * r * p bytes, plus slack for the mixing buffer. */
function maxmemFor(p: KdfParams): number {
  return 128 * p.N * p.r * p.p + 64 * 1024 * 1024;
}

export function newSalt(bytes = 16): Buffer {
  return randomBytes(bytes);
}

export async function deriveKek(
  pin: string,
  salt: Uint8Array,
  params: KdfParams = DEFAULT_KDF_PARAMS,
): Promise<Buffer> {
  assertParams(params);
  return scryptAsync(Buffer.from(pin, 'utf8'), Buffer.from(salt), params.dkLen, {
    N: params.N,
    r: params.r,
    p: params.p,
    maxmem: maxmemFor(params),
  });
}

/** Synchronous variant — used only by conformance-vector generation and tests. */
export function deriveKekSync(
  pin: string,
  salt: Uint8Array,
  params: KdfParams = DEFAULT_KDF_PARAMS,
): Buffer {
  assertParams(params);
  return scryptSync(Buffer.from(pin, 'utf8'), Buffer.from(salt), params.dkLen, {
    N: params.N,
    r: params.r,
    p: params.p,
    maxmem: maxmemFor(params),
  });
}

function assertParams(p: KdfParams): void {
  if (p.algorithm !== 'scrypt') throw new Error(`unsupported KDF: ${p.algorithm}`);
  if ((p.N & (p.N - 1)) !== 0 || p.N < 2) throw new RangeError('scrypt N must be a power of two >= 2');
  if (p.r < 1 || p.p < 1) throw new RangeError('scrypt r and p must be >= 1');
  if (p.dkLen !== 32) throw new RangeError('Things derives 32-byte keys only');
}

export function parseKdfParams(json: string | null | undefined): KdfParams {
  if (!json) return DEFAULT_KDF_PARAMS;
  try {
    const v = JSON.parse(json) as Partial<KdfParams>;
    const p: KdfParams = { ...DEFAULT_KDF_PARAMS, ...v, algorithm: 'scrypt' };
    assertParams(p);
    return p;
  } catch {
    return DEFAULT_KDF_PARAMS;
  }
}

/**
 * Escalating delay after a failed PIN attempt — docs/02-SECURITY.md §4.
 * Things deliberately never wipes: with no cloud copy, an auto-wipe converts a
 * forgotten PIN into permanent data loss.
 */
export function failedAttemptDelayMs(consecutiveFailures: number): number {
  const ladder = [0, 1_000, 5_000, 30_000, 60_000, 300_000];
  if (consecutiveFailures <= 0) return 0;
  return ladder[Math.min(consecutiveFailures, ladder.length - 1)];
}
