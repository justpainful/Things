/**
 * Symbolic date values for `created:` / `modified:`.
 *
 * Resolution is a pure function of (value, now), never of the ambient clock,
 * so the conformance vectors can pin an exact `now` and stay stable.
 * Ranges are half-open: [from, to).
 */

export interface DateRange {
  from: string;
  to: string;
}

const DAY = 86_400_000;

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function startOfDayUtc(ms: number): number {
  const d = new Date(ms);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
}

/** ISO week: Monday is day 1. */
function startOfWeekUtc(ms: number): number {
  const start = startOfDayUtc(ms);
  const dow = (new Date(start).getUTCDay() + 6) % 7;
  return start - dow * DAY;
}

function startOfMonthUtc(ms: number): number {
  const d = new Date(ms);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
}

function addMonthsUtc(ms: number, n: number): number {
  const d = new Date(ms);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + n, 1);
}

/**
 * Resolve a symbolic or literal date value to a half-open range.
 * Returns null when the value is not a recognised date.
 */
export function resolveDateRange(value: string, nowIso: string): DateRange | null {
  const now = Date.parse(nowIso);
  if (Number.isNaN(now)) return null;
  const v = value.trim().toLowerCase();

  switch (v) {
    case 'today': {
      const s = startOfDayUtc(now);
      return { from: iso(s), to: iso(s + DAY) };
    }
    case 'yesterday': {
      const s = startOfDayUtc(now) - DAY;
      return { from: iso(s), to: iso(s + DAY) };
    }
    case 'this-week': {
      const s = startOfWeekUtc(now);
      return { from: iso(s), to: iso(s + 7 * DAY) };
    }
    case 'last-week': {
      const s = startOfWeekUtc(now) - 7 * DAY;
      return { from: iso(s), to: iso(s + 7 * DAY) };
    }
    case 'this-month': {
      const s = startOfMonthUtc(now);
      return { from: iso(s), to: iso(addMonthsUtc(s, 1)) };
    }
    case 'last-month': {
      const s = addMonthsUtc(startOfMonthUtc(now), -1);
      return { from: iso(s), to: iso(addMonthsUtc(s, 1)) };
    }
    case 'this-year': {
      const y = new Date(now).getUTCFullYear();
      return { from: iso(Date.UTC(y, 0, 1)), to: iso(Date.UTC(y + 1, 0, 1)) };
    }
    case 'last-year': {
      const y = new Date(now).getUTCFullYear() - 1;
      return { from: iso(Date.UTC(y, 0, 1)), to: iso(Date.UTC(y + 1, 0, 1)) };
    }
  }

  // last N days: 7d, 30d, 90d
  const rel = /^(\d+)d$/.exec(v);
  if (rel) {
    const n = parseInt(rel[1], 10);
    const s = startOfDayUtc(now) - (n - 1) * DAY;
    return { from: iso(s), to: iso(startOfDayUtc(now) + DAY) };
  }

  // 2026 · 2026-08 · 2026-08-09
  let m = /^(\d{4})$/.exec(v);
  if (m) {
    const y = parseInt(m[1], 10);
    return { from: iso(Date.UTC(y, 0, 1)), to: iso(Date.UTC(y + 1, 0, 1)) };
  }
  m = /^(\d{4})-(\d{2})$/.exec(v);
  if (m) {
    const s = Date.UTC(parseInt(m[1], 10), parseInt(m[2], 10) - 1, 1);
    return { from: iso(s), to: iso(addMonthsUtc(s, 1)) };
  }
  m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
  if (m) {
    const s = Date.UTC(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10));
    return { from: iso(s), to: iso(s + DAY) };
  }

  return null;
}
