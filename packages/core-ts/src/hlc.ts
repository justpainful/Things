/**
 * Hybrid Logical Clock.
 *
 * Wire format — NORMATIVE, mirrored by `spec/vectors/hlc.json`:
 *
 *     2026-08-09T21:14:03.412Z-0007-<deviceId>
 *     └────────── physical ──────┘ └cnt┘ └ tiebreak ┘
 *
 * Three properties, all load-bearing:
 *
 *  1. **Lexicographically sortable.** ISO-8601 UTC with a fixed number of
 *     digits sorts identically to chronological order; the counter is 4 fixed
 *     hex digits; the device id is a fixed-length UUID. So `a < b` as strings
 *     is exactly `a` happened-before-or-concurrent-earlier than `b`.
 *  2. **Physical time stays readable**, because the History UI renders it.
 *  3. **Monotonic.** A device whose wall clock is wrong cannot silently win an
 *     argument: `send()` never emits a value <= the last one it emitted, and
 *     `receive()` folds a remote timestamp in without going backwards.
 */

const COUNTER_MAX = 0xffff;

/**
 * How far ahead of local wall-clock time a peer's physical timestamp is allowed
 * to drag our clock — one hour.
 *
 * `spec/oplog.md` §1.1 defines the receive rule but is SILENT on the bound, and
 * §5.3 records the two cores disagreeing about it: `core-swift`'s
 * `HLCGenerator.maximumDriftMilliseconds` clamps at one hour, `core-ts` did not
 * clamp at all. This value is `core-swift`'s, adopted verbatim, because that
 * side was written against the spec most recently and because *some* bound is
 * required: without one, a single peer whose clock is set to 2099 permanently
 * poisons the ordering of the whole library. Every later stamp on every device
 * has to exceed it, so History is stuck in the future and nothing sorts
 * sensibly again — and it is unfixable after the fact, because the log is
 * append-only.
 *
 * The clamp costs nothing when clocks are sane: a peer inside the window is
 * folded in exactly as before. Beyond it, the remote physical is pinned to
 * `now + 1h` and the counter still advances, so causality is preserved (our
 * stamp is still strictly greater than the one we received) without the
 * physical component being dragged along.
 */
export const MAX_DRIFT_MS = 60 * 60 * 1000;

export interface HlcParts {
  physical: string;
  counter: number;
  device: string;
}

export function formatHlc(parts: HlcParts): string {
  if (parts.counter < 0 || parts.counter > COUNTER_MAX) {
    throw new RangeError(`HLC counter out of range: ${parts.counter}`);
  }
  return `${parts.physical}-${parts.counter.toString(16).padStart(4, '0')}-${parts.device}`;
}

export function parseHlc(hlc: string): HlcParts {
  // physical is exactly 24 chars: 2026-08-09T21:14:03.412Z
  const physical = hlc.slice(0, 24);
  if (hlc[24] !== '-' || hlc[29] !== '-') {
    throw new SyntaxError(`malformed HLC: ${hlc}`);
  }
  const counter = parseInt(hlc.slice(25, 29), 16);
  const device = hlc.slice(30);
  if (Number.isNaN(counter) || !device) throw new SyntaxError(`malformed HLC: ${hlc}`);
  return { physical, counter, device };
}

/** String comparison IS the causal-ish ordering. -1 / 0 / 1. */
export function compareHlc(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function maxHlc(a: string | null | undefined, b: string | null | undefined): string {
  if (!a) return b ?? '';
  if (!b) return a;
  return compareHlc(a, b) >= 0 ? a : b;
}

export class Hlc {
  readonly deviceId: string;
  private lastPhysical: string;
  private lastCounter: number;
  private clock: () => number;

  constructor(deviceId: string, opts?: { last?: string | null; clock?: () => number }) {
    this.deviceId = deviceId;
    this.clock = opts?.clock ?? Date.now;
    if (opts?.last) {
      const p = parseHlc(opts.last);
      this.lastPhysical = p.physical;
      this.lastCounter = p.counter;
    } else {
      this.lastPhysical = new Date(0).toISOString();
      this.lastCounter = 0;
    }
  }

  /** Current state as a timestamp string, without advancing. */
  peek(): string {
    return formatHlc({ physical: this.lastPhysical, counter: this.lastCounter, device: this.deviceId });
  }

  /** Stamp a local event. */
  now(): string {
    const wall = new Date(this.clock()).toISOString();
    if (wall > this.lastPhysical) {
      this.lastPhysical = wall;
      this.lastCounter = 0;
    } else {
      // Wall clock stalled or went backwards — advance logically instead.
      this.lastCounter += 1;
      if (this.lastCounter > COUNTER_MAX) {
        this.lastPhysical = bumpMillis(this.lastPhysical);
        this.lastCounter = 0;
      }
    }
    return this.peek();
  }

  /**
   * Fold in a timestamp received from a peer, then stamp the receive event.
   *
   * The remote physical is clamped to `now + MAX_DRIFT_MS` first, so a peer with
   * a wildly wrong clock cannot drag this device's clock into the future.
   */
  receive(remote: string): string {
    const r = parseHlc(remote);
    const wallMs = this.clock();
    const wall = new Date(wallMs).toISOString();
    const remotePhysical = clampDrift(r.physical, wallMs);
    const maxPhysical = [wall, this.lastPhysical, remotePhysical].sort()[2];

    if (maxPhysical === this.lastPhysical && maxPhysical === remotePhysical) {
      this.lastCounter = Math.max(this.lastCounter, r.counter) + 1;
    } else if (maxPhysical === this.lastPhysical) {
      this.lastCounter += 1;
    } else if (maxPhysical === remotePhysical) {
      this.lastCounter = r.counter + 1;
    } else {
      this.lastCounter = 0;
    }
    this.lastPhysical = maxPhysical;

    if (this.lastCounter > COUNTER_MAX) {
      this.lastPhysical = bumpMillis(this.lastPhysical);
      this.lastCounter = 0;
    }
    return this.peek();
  }
}

function bumpMillis(iso: string): string {
  return new Date(Date.parse(iso) + 1).toISOString();
}

/**
 * `min(remotePhysical, now + MAX_DRIFT_MS)`, as an ISO string.
 * Mirrors `core-swift`'s `HLCGenerator.receive`.
 */
export function clampDrift(remotePhysical: string, wallMs: number): string {
  const remoteMs = Date.parse(remotePhysical);
  if (Number.isNaN(remoteMs)) throw new SyntaxError(`malformed HLC physical: ${remotePhysical}`);
  const ceiling = wallMs + MAX_DRIFT_MS;
  return remoteMs <= ceiling ? remotePhysical : new Date(ceiling).toISOString();
}
