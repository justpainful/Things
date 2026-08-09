import { randomBytes } from 'node:crypto';

/**
 * UUIDv7 — RFC 9562 §5.7.
 *
 *   0                   1                   2                   3
 *   |         unix_ts_ms (48 bits)          | ver |  rand_a (12)  |
 *   |var|                    rand_b (62 bits)                     |
 *
 * `rand_a` is used as a monotonic sub-millisecond counter (the "method 1"
 * guarantee in §6.2) so ids minted in the same millisecond still sort in
 * creation order. That is the whole reason we picked v7: creation order
 * survives without a separate index, in both languages.
 */

let lastMs = -1;
let counter = 0;

export function uuidv7(nowMs: number = Date.now()): string {
  let ms = nowMs;
  if (ms === lastMs) {
    counter += 1;
    if (counter > 0xfff) {
      // Counter exhausted inside one millisecond: borrow from the next.
      ms = lastMs + 1;
      lastMs = ms;
      counter = 0;
    }
  } else if (ms < lastMs) {
    // Clock went backwards. Never emit a non-monotonic id.
    ms = lastMs;
    counter += 1;
  } else {
    lastMs = ms;
    counter = randomBytes(2).readUInt16BE(0) & 0x0ff; // leave headroom to count up
  }

  const b = new Uint8Array(16);
  // 48-bit big-endian timestamp
  b[0] = (ms / 2 ** 40) & 0xff;
  b[1] = (ms / 2 ** 32) & 0xff;
  b[2] = (ms / 2 ** 24) & 0xff;
  b[3] = (ms / 2 ** 16) & 0xff;
  b[4] = (ms / 2 ** 8) & 0xff;
  b[5] = ms & 0xff;

  // version 7 + 12 bits of counter
  b[6] = 0x70 | ((counter >> 8) & 0x0f);
  b[7] = counter & 0xff;

  const rand = randomBytes(8);
  b.set(rand, 8);
  // RFC 4122 variant (10xxxxxx)
  b[8] = (b[8] & 0x3f) | 0x80;

  return hex(b);
}

function hex(b: Uint8Array): string {
  const s = Buffer.from(b).toString('hex');
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

/** Extract the embedded millisecond timestamp. Useful for tests and History. */
export function uuidv7Time(id: string): number {
  const h = id.replace(/-/g, '');
  return parseInt(h.slice(0, 12), 16);
}

export function isUuid(v: unknown): v is string {
  return typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
}

/** ISO-8601 UTC with milliseconds — the timestamp format the schema mandates. */
export function nowIso(d: Date = new Date()): string {
  return d.toISOString();
}
