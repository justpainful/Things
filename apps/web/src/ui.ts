import { clear, glassBox, h, trapFocus } from './dom.ts';
import { makeGlass, destroyGlass } from './glass.ts';
import { icon } from './icons.ts';
import { t } from './i18n/index.ts';

/**
 * Overlay furniture: toasts, context menus, dialogs.
 *
 * All three are navigation-layer surfaces, so all three are glass — and none
 * of them ever nests inside another glass surface (NOTES.md gotcha 3).
 */

// ── toasts ──────────────────────────────────────────────────────────────────

export function toast(message: string, action?: { label: string; run: () => void }): void {
  const host = document.getElementById('toasts');
  if (!host) return;

  const el = glassBox(
    'toast',
    h('span', { text: message }),
    action && h('button', { type: 'button', text: action.label, on: { click: () => { action.run(); dismiss(); } } }),
  );
  makeGlass(el, { radius: 999 });
  host.appendChild(el);

  const timer = window.setTimeout(dismiss, action ? 6000 : 2600);

  function dismiss(): void {
    clearTimeout(timer);
    destroyGlass(el);
    el.remove();
  }
}

// ── context menu ────────────────────────────────────────────────────────────

export interface MenuItem {
  label: string;
  symbol?: string;
  danger?: boolean;
  separator?: false;
  run: () => void;
}

export type MenuEntry = MenuItem | { separator: true };

export function openMenu(x: number, y: number, entries: MenuEntry[]): void {
  closeMenu();

  const content: HTMLElement[] = [];
  for (const entry of entries) {
    if ('separator' in entry && entry.separator) {
      content.push(h('div', { class: 'menu__sep' }));
      continue;
    }
    const item = entry as MenuItem;
    content.push(
      h(
        'button',
        {
          type: 'button',
          class: `menu__item${item.danger ? ' menu__item--danger' : ''}`,
          role: 'menuitem',
          on: {
            click: () => {
              closeMenu();
              item.run();
            },
          },
        },
        item.symbol ? icon(item.symbol) : null,
        h('span', { text: item.label }),
      ),
    );
  }

  const el = glassBox('menu', ...content);
  el.setAttribute('role', 'menu');
  el.style.visibility = 'hidden';
  document.body.appendChild(el);
  makeGlass(el);

  // Keep it on screen; flip rather than clamp so the pointer never covers it.
  const rect = el.getBoundingClientRect();
  const left = x + rect.width > window.innerWidth - 8 ? Math.max(8, x - rect.width) : x;
  const top = y + rect.height > window.innerHeight - 8 ? Math.max(8, y - rect.height) : y;
  el.style.insetInlineStart = `${left}px`;
  el.style.insetBlockStart = `${top}px`;
  el.style.visibility = '';

  openMenuEl = el;
  const first = el.querySelector<HTMLElement>('.menu__item');
  first?.focus();

  setTimeout(() => {
    window.addEventListener('pointerdown', onOutside, { once: true });
    window.addEventListener('keydown', onKey);
  }, 0);
}

let openMenuEl: HTMLElement | null = null;

function onOutside(e: PointerEvent): void {
  if (openMenuEl && !openMenuEl.contains(e.target as Node)) closeMenu();
}

function onKey(e: KeyboardEvent): void {
  if (!openMenuEl) return;
  if (e.key === 'Escape') {
    e.stopPropagation();
    closeMenu();
    return;
  }
  if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
  e.preventDefault();
  const items = [...openMenuEl.querySelectorAll<HTMLElement>('.menu__item')];
  const i = items.indexOf(document.activeElement as HTMLElement);
  const next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
  items[next]?.focus();
}

export function closeMenu(): void {
  if (!openMenuEl) return;
  window.removeEventListener('keydown', onKey);
  destroyGlass(openMenuEl);
  openMenuEl.remove();
  openMenuEl = null;
}

// ── dialogs ─────────────────────────────────────────────────────────────────

export interface PromptOptions {
  title: string;
  body?: string;
  placeholder?: string;
  value?: string;
  confirmLabel?: string;
  danger?: boolean;
}

export function promptDialog(opts: PromptOptions): Promise<string | null> {
  return new Promise((resolve) => {
    const input = h('input', {
      class: 'text-input',
      type: 'text',
      value: opts.value ?? '',
      placeholder: opts.placeholder ?? '',
    });
    build(opts, resolve, [input], () => input.value.trim() || null, () => input.select());
  });
}

export function confirmDialog(opts: PromptOptions): Promise<boolean> {
  return new Promise((resolve) => {
    build(
      opts,
      (value) => resolve(value !== null),
      [],
      () => 'yes',
      () => undefined,
    );
  });
}

function build(
  opts: PromptOptions,
  resolve: (value: string | null) => void,
  extra: HTMLElement[],
  read: () => string | null,
  afterOpen: () => void,
): void {
  const backdrop = h('div', { class: 'dialog-backdrop' });
  const confirm = h('button', {
    type: 'button',
    class: `button button--primary${opts.danger ? ' button--danger' : ''}`,
    text: opts.confirmLabel ?? t('common.save'),
    on: { click: () => done(read()) },
  });
  const cancel = h('button', {
    type: 'button',
    class: 'button',
    text: t('common.cancel'),
    on: { click: () => done(null) },
  });

  const dialog = glassBox(
    'dialog',
    h('h2', { text: opts.title }),
    opts.body ? h('p', { text: opts.body }) : null,
    ...extra,
    h('div', { class: 'dialog__row' }, cancel, confirm),
  );
  dialog.setAttribute('role', 'dialog');
  dialog.setAttribute('aria-modal', 'true');
  dialog.setAttribute('aria-label', opts.title);

  backdrop.appendChild(dialog);
  document.body.appendChild(backdrop);
  makeGlass(dialog);
  const release = trapFocus(dialog);

  backdrop.addEventListener('pointerdown', (e) => {
    if (e.target === backdrop) done(null);
  });
  dialog.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') done(null);
    if (e.key === 'Enter' && (e.target as HTMLElement).tagName === 'INPUT') done(read());
  });

  (extra[0] ?? confirm).focus();
  afterOpen();

  function done(value: string | null): void {
    release();
    destroyGlass(dialog);
    backdrop.remove();
    resolve(value);
  }
}

/** A small chooser used for "pick a field type", "pick a collection", etc. */
export function chooseDialog(
  title: string,
  options: { id: string; label: string; symbol?: string; hint?: string }[],
): Promise<string | null> {
  return new Promise((resolve) => {
    const backdrop = h('div', { class: 'dialog-backdrop' });
    const search = h('input', { class: 'text-input', type: 'text', placeholder: title });
    const list = h('div', { class: 'palette__results', role: 'listbox' });

    let filtered = options;
    let index = 0;

    const render = () => {
      clear(list);
      filtered.forEach((opt, i) => {
        list.appendChild(
          h(
            'button',
            {
              type: 'button',
              class: 'palette__item',
              role: 'option',
              'aria-selected': String(i === index),
              on: { click: () => done(opt.id) },
            },
            opt.symbol ? icon(opt.symbol) : null,
            h('span', { class: 'palette__label', text: opt.label }),
            opt.hint ? h('span', { class: 'palette__hint', text: opt.hint }) : null,
          ),
        );
      });
      if (filtered.length === 0) list.appendChild(h('div', { class: 'palette__empty', text: t('palette.empty') }));
    };

    search.addEventListener('input', () => {
      const q = search.value.trim().toLowerCase();
      filtered = options.filter((o) => o.label.toLowerCase().includes(q) || o.id.includes(q));
      index = 0;
      render();
    });

    search.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        index = Math.min(index + 1, filtered.length - 1);
        render();
        list.children[index]?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        index = Math.max(index - 1, 0);
        render();
        list.children[index]?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (filtered[index]) done(filtered[index].id);
      } else if (e.key === 'Escape') {
        done(null);
      }
    });

    const dialog = glassBox('dialog', h('h2', { text: title }), search, list);
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    backdrop.appendChild(dialog);
    document.body.appendChild(backdrop);
    makeGlass(dialog);
    const release = trapFocus(dialog);
    render();
    search.focus();

    backdrop.addEventListener('pointerdown', (e) => {
      if (e.target === backdrop) done(null);
    });

    function done(value: string | null): void {
      release();
      destroyGlass(dialog);
      backdrop.remove();
      resolve(value);
    }
  });
}
