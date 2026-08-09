import { api } from '../api.ts';
import type { ThingSummary } from '../api.ts';
import { clear, copyText, glassBox, h, trapFocus } from '../dom.ts';
import { destroyGlass, makeGlass } from '../glass.ts';
import { icon } from '../icons.ts';
import { t } from '../i18n/index.ts';
import { loadList, navigate, openThing, refreshBootstrap, reloadCurrent, state } from '../store.ts';
import { promptDialog, toast } from '../ui.ts';

/**
 * The Command Palette — Ctrl K.
 *
 * docs/03-DESIGN.md calls this "the one deliberately dramatic surface", and
 * the main power surface of the web client. It does five things:
 * open a Thing, create a Thing, open a collection, copy a field, add a field.
 * Everything else is a bonus.
 */

interface Entry {
  group: string;
  label: string;
  symbol: string;
  hint?: string;
  run: () => void | Promise<void>;
}

let openEl: HTMLElement | null = null;

export function openPalette(initial = ''): void {
  if (openEl) {
    closePalette();
    return;
  }

  const input = h('input', {
    class: 'palette__input',
    type: 'text',
    placeholder: t('palette.placeholder'),
    value: initial,
    autocomplete: 'off',
    spellcheck: 'false',
    'aria-label': t('palette.placeholder'),
  });
  const results = h('div', { class: 'palette__results', role: 'listbox' });

  const panel = glassBox('palette', input, results);
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-modal', 'true');
  panel.setAttribute('aria-label', t('toolbar.commands'));

  const backdrop = h('div', {
    class: 'palette-backdrop',
    on: {
      pointerdown: (e: Event) => {
        if (e.target === backdrop) closePalette();
      },
    },
  });
  backdrop.appendChild(panel);
  document.body.appendChild(backdrop);
  makeGlass(panel);
  const release = trapFocus(panel);

  openEl = backdrop;
  let entries: Entry[] = [];
  let index = 0;
  let token = 0;

  const paint = () => {
    clear(results);
    if (entries.length === 0) {
      results.appendChild(h('div', { class: 'palette__empty', text: t('palette.empty') }));
      return;
    }
    let lastGroup = '';
    entries.forEach((entry, i) => {
      if (entry.group !== lastGroup) {
        lastGroup = entry.group;
        results.appendChild(h('div', { class: 'palette__group', text: entry.group }));
      }
      results.appendChild(
        h(
          'button',
          {
            type: 'button',
            class: 'palette__item',
            role: 'option',
            'aria-selected': String(i === index),
            on: {
              click: () => {
                closePalette();
                void entry.run();
              },
            },
          },
          icon(entry.symbol),
          h('span', { class: 'palette__label', text: entry.label }),
          entry.hint ? h('span', { class: 'palette__hint', text: entry.hint }) : null,
        ),
      );
    });
  };

  const refresh = async () => {
    const mine = ++token;
    const query = input.value.trim();
    const next = await buildEntries(query);
    if (mine !== token) return;
    entries = next;
    index = 0;
    paint();
  };

  input.addEventListener('input', () => void refresh());
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || (e.key === 'n' && e.ctrlKey)) {
      e.preventDefault();
      index = Math.min(index + 1, entries.length - 1);
      paint();
      results.querySelectorAll('.palette__item')[index]?.scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'ArrowUp' || (e.key === 'p' && e.ctrlKey)) {
      e.preventDefault();
      index = Math.max(index - 1, 0);
      paint();
      results.querySelectorAll('.palette__item')[index]?.scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const entry = entries[index];
      if (entry) {
        closePalette();
        void entry.run();
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      closePalette();
    }
  });

  input.focus();
  void refresh();

  function closePalette(): void {
    release();
    destroyGlass(panel);
    backdrop.remove();
    openEl = null;
  }

  // Expose for the outer close path.
  (backdrop as HTMLElement & { close?: () => void }).close = closePalette;
}

export function isPaletteOpen(): boolean {
  return !!openEl;
}

async function buildEntries(query: string): Promise<Entry[]> {
  const entries: Entry[] = [];
  const q = query.toLowerCase();
  const matches = (s: string) => !q || s.toLowerCase().includes(q);

  // 1 — open a Thing. The palette's primary job.
  if (query) {
    const res = await api
      .get<{ things: ThingSummary[] }>(`/api/search?q=${encodeURIComponent(query)}&limit=8`)
      .catch(() => ({ things: [] as ThingSummary[] }));
    for (const thing of res.things) {
      entries.push({
        group: t('palette.things'),
        label: thing.title,
        symbol: thing.isLocked ? 'lock' : thing.icon?.value ?? 'square.stack',
        hint: t('palette.hint.open'),
        run: () => void openThing(thing.id),
      });
    }
  } else {
    for (const thing of state.list.slice(0, 6)) {
      entries.push({
        group: t('palette.things'),
        label: thing.title,
        symbol: thing.icon?.value ?? 'square.stack',
        hint: t('palette.hint.open'),
        run: () => void openThing(thing.id),
      });
    }
  }

  // 2 — copy a field from the Thing that is open.
  if (state.current && !state.current.isLocked) {
    for (const field of state.current.fields) {
      if (!field.hasValue) continue;
      if (!matches(field.label)) continue;
      entries.push({
        group: t('palette.fields'),
        label: field.label,
        symbol: field.symbol,
        hint: t('palette.hint.copy'),
        run: async () => {
          let value = field.text ?? field.fileRef?.path ?? '';
          if (field.isSecret) {
            const res = await api.post<{ value: string }>(`/api/fields/${field.id}/reveal`);
            value = res.value;
          }
          await copyText(value);
          toast(t('field.copied'));
        },
      });
    }
  }

  // 3 — collections.
  for (const col of state.bootstrap?.collections ?? []) {
    if (!matches(col.name)) continue;
    entries.push({
      group: t('palette.collections'),
      label: col.name,
      symbol: col.icon?.value ?? (col.isSmart ? 'sparkles' : 'folder'),
      hint: String(col.count),
      run: () => void navigate({ kind: 'collection', id: col.id, title: col.name, smartQuery: col.smartQuery }),
    });
  }

  // 4 — create a Thing, from blank or from a template.
  const commands: Entry[] = [
    {
      group: t('palette.commands'),
      label: t('palette.cmd.newThing'),
      symbol: 'plus',
      run: async () => {
        const title = await promptDialog({ title: t('toolbar.newThing'), placeholder: t('detail.untitled'), confirmLabel: t('common.create') });
        if (title === null) return;
        const created = await api.post<{ id: string }>('/api/things', { title: title || 'Untitled' });
        await Promise.all([loadList(), refreshBootstrap()]);
        await openThing(created.id);
      },
    },
    ...(state.bootstrap?.templates ?? []).map((tpl) => ({
      group: t('palette.commands'),
      label: t('palette.cmd.newFromTemplate', { name: tpl.name }),
      symbol: tpl.symbol,
      run: async () => {
        const created = await api.post<{ id: string }>('/api/things', { title: tpl.name, templateId: tpl.id });
        await Promise.all([loadList(), refreshBootstrap()]);
        await openThing(created.id);
      },
    })),
    {
      group: t('palette.commands'),
      label: t('palette.cmd.newCollection'),
      symbol: 'folder',
      run: async () => {
        const name = await promptDialog({ title: t('collection.new'), placeholder: t('collection.namePlaceholder'), confirmLabel: t('common.create') });
        if (!name) return;
        await api.post('/api/collections', { name });
        await refreshBootstrap();
      },
    },
    { group: t('palette.commands'), label: t('palette.cmd.gallery'), symbol: 'photo.on.rectangle', run: () => void navigate({ kind: 'gallery' }) },
    { group: t('palette.commands'), label: t('palette.cmd.trash'), symbol: 'trash', run: () => void navigate({ kind: 'trash' }) },
    { group: t('palette.commands'), label: t('palette.cmd.settings'), symbol: 'gear', run: () => void navigate({ kind: 'settings' }) },
    {
      group: t('palette.commands'),
      label: t('palette.cmd.toggleTheme'),
      symbol: 'eye.slash',
      run: async () => {
        const next = !state.session?.privacyMode;
        state.session = await api.post('/api/session/privacy', { enabled: next });
        document.documentElement.dataset.privacy = next ? 'on' : 'off';
      },
    },
    { group: t('palette.commands'), label: t('palette.cmd.undo'), symbol: 'arrow.uturn.backward', run: async () => { await api.post('/api/undo'); await Promise.all([loadList(), refreshBootstrap()]); } },
    { group: t('palette.commands'), label: t('palette.cmd.redo'), symbol: 'arrow.uturn.forward', run: async () => { await api.post('/api/redo'); await Promise.all([loadList(), refreshBootstrap()]); } },
    {
      group: t('palette.commands'),
      label: t('palette.cmd.lock'),
      symbol: 'lock',
      run: () => {
        window.dispatchEvent(new CustomEvent('things:lock'));
      },
    },
  ];

  // 5 — add a field to the Thing that is open.
  if (state.current && !state.current.isLocked) {
    for (const v of state.registry?.variants ?? []) {
      const label = t('palette.cmd.addField', { name: v.label });
      if (!matches(label) && !matches(v.id)) continue;
      commands.push({
        group: t('palette.commands'),
        label,
        symbol: v.symbol,
        run: async () => {
          await api.post(`/api/things/${state.current!.id}/fields`, { variant: v.id });
          await reloadCurrent();
        },
      });
    }
  }

  entries.push(...commands.filter((c) => matches(c.label)));
  return entries.slice(0, 40);
}
