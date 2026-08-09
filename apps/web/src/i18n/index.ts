import en from './en.json';

/**
 * A tiny i18n module.
 *
 * The UI is English now, but every user-facing string goes through `t()` from
 * day one (docs/00-PLAN.md §1b). Together with logical CSS properties, that
 * makes Arabic + RTL a translation pass rather than a rewrite: add a catalogue,
 * flip `dir`, done.
 */

export type Catalogue = Record<string, string>;

const catalogues: Record<string, Catalogue> = { en: en as Catalogue };

let current = 'en';

export function setLocale(locale: string): void {
  if (!catalogues[locale]) return;
  current = locale;
  document.documentElement.lang = locale;
  document.documentElement.dir = RTL_LOCALES.has(locale) ? 'rtl' : 'ltr';
}

export function registerCatalogue(locale: string, catalogue: Catalogue): void {
  catalogues[locale] = catalogue;
}

export function locale(): string {
  return current;
}

const RTL_LOCALES = new Set(['ar', 'he', 'fa', 'ur']);

/**
 * `t('list.count', { count: 4 })`.
 * A missing key returns the key itself — loud, and never a blank UI.
 */
export function t(key: string, vars?: Record<string, string | number>): string {
  const raw = catalogues[current]?.[key] ?? catalogues.en[key] ?? key;
  if (!vars) return raw;
  return raw.replace(/\{(\w+)\}/g, (_, name: string) =>
    name in vars ? String(vars[name]) : `{${name}}`,
  );
}

/** Plural helper for the handful of counted strings. */
export function tCount(baseKey: string, count: number, vars: Record<string, string | number> = {}): string {
  const oneKey = `${baseKey}One`;
  if (count === 1 && (catalogues[current]?.[oneKey] || catalogues.en[oneKey])) {
    return t(oneKey, { count, ...vars });
  }
  return t(baseKey, { count, ...vars });
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  return new Intl.DateTimeFormat(current,
    sameDay
      ? { hour: 'numeric', minute: '2-digit' }
      : { year: 'numeric', month: 'short', day: 'numeric' },
  ).format(d);
}

export function formatTime(iso: string): string {
  return new Intl.DateTimeFormat(current, { hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
}

export function formatDay(isoDate: string): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  const today = new Date();
  const yesterday = new Date(Date.now() - 86_400_000);
  if (isoDate === today.toISOString().slice(0, 10)) return 'Today';
  if (isoDate === yesterday.toISOString().slice(0, 10)) return 'Yesterday';
  return new Intl.DateTimeFormat(current, { weekday: 'long', month: 'long', day: 'numeric' }).format(d);
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = n / 1024;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[i]}`;
}
