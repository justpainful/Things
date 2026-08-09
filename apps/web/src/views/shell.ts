import { api } from '../api.ts';
import type { ThingSummary } from '../api.ts';
import { clear, glassBox, h } from '../dom.ts';
import { makeGlass, resetGlass } from '../glass.ts';
import { icon, iconMarkup } from '../icons.ts';
import { formatDate, t, tCount } from '../i18n/index.ts';
import {
  loadList,
  navigate,
  notify,
  openThing,
  refreshBootstrap,
  state,
  subscribe,
} from '../store.ts';
import type { Route } from '../store.ts';
import { chooseDialog, confirmDialog, openMenu, promptDialog, toast } from '../ui.ts';
import { renderDetail } from './detail.ts';
import { openPalette } from './palette.ts';

/**
 * The three-pane shell — sidebar · list · detail.
 *
 * Glass lives on the toolbar, the sidebar chrome, and the floating + button.
 * The list and the detail pane are opaque content surfaces: docs/03-DESIGN.md
 * §1 puts glass on the navigation layer and nowhere else, and a glass header
 * over a scrolling list is also the single most reliable way to tank frame
 * rate (NOTES.md §4).
 */

let searchInput: HTMLInputElement;
let listScroll: HTMLElement;
let detailPane: HTMLElement;
let anchorIndex = 0;

export function renderShell(root: HTMLElement): void {
  resetGlass();
  clear(root);
  root.removeAttribute('aria-busy');

  const app = h('div', { class: 'app-shell', style: { display: 'contents' } });

  const toolbar = buildToolbar();
  const sidebar = h('aside', { class: 'pane sidebar' });
  const list = h('section', { class: 'pane list', 'aria-label': t('nav.library') });
  detailPane = h('section', { class: 'pane detail', 'aria-label': t('detail.empty.title') });

  const body = h('div', { class: 'body' }, sidebar, list, detailPane);
  app.append(toolbar, body);
  root.appendChild(app);
  root.appendChild(buildFab());

  makeGlass(toolbar);

  buildSidebar(sidebar);
  buildList(list);

  subscribe(() => {
    buildSidebar(sidebar);
    paintList();
    paintToolbar(toolbar);
    renderDetail(detailPane);
  });

  attachKeyboard();
  renderDetail(detailPane);
}

// ── toolbar ─────────────────────────────────────────────────────────────────

function buildToolbar(): HTMLElement {
  searchInput = h('input', {
    type: 'search',
    placeholder: t('toolbar.searchPlaceholder'),
    'aria-label': t('toolbar.search'),
    autocomplete: 'off',
    spellcheck: 'false',
  });

  let debounce = 0;
  searchInput.addEventListener('input', () => {
    clearTimeout(debounce);
    debounce = window.setTimeout(() => {
      void navigate({ kind: 'query', query: searchInput.value, title: searchInput.value ? t('toolbar.search') : t('nav.all') });
    }, 160);
  });
  searchInput.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      searchInput.value = '';
      void navigate({ kind: 'query', query: '', title: t('nav.all') });
      searchInput.blur();
    }
  });

  const search = h(
    'div',
    { class: 'toolbar__search' },
    icon('magnifyingglass'),
    searchInput,
    h('span', { class: 'kbd', text: 'Ctrl K' }),
  );

  const bar = glassBox(
    'toolbar',
    h('div', { class: 'toolbar__brand' }, h('span', { text: t('app.name') })),
    h('div', { class: 'toolbar__spacer' }),
    search,
    iconButton('arrow.uturn.backward', t('toolbar.undo'), () => void runUndo('undo'), 'undo'),
    iconButton('arrow.uturn.forward', t('toolbar.redo'), () => void runUndo('redo'), 'redo'),
    iconButton('eye.slash', t('toolbar.privacyOn'), () => void togglePrivacy(), 'privacy'),
    iconButton('sparkles', t('toolbar.commands'), () => openPalette()),
    iconButton('gear', t('toolbar.settings'), () => void navigate({ kind: 'settings' })),
    iconButton('lock', t('toolbar.lock'), () => void doLock()),
  );
  bar.setAttribute('role', 'toolbar');
  return bar;
}

function paintToolbar(bar: HTMLElement): void {
  const undo = bar.querySelector<HTMLButtonElement>('[data-key="undo"]');
  const redo = bar.querySelector<HTMLButtonElement>('[data-key="redo"]');
  if (undo) undo.disabled = !state.undo.canUndo;
  if (redo) redo.disabled = !state.undo.canRedo;

  const privacy = bar.querySelector<HTMLButtonElement>('[data-key="privacy"]');
  if (privacy) {
    const on = !!state.session?.privacyMode;
    privacy.setAttribute('aria-pressed', String(on));
    privacy.title = on ? t('toolbar.privacyOff') : t('toolbar.privacyOn');
    privacy.innerHTML = iconMarkup(on ? 'eye' : 'eye.slash');
  }
}

function iconButton(symbol: string, label: string, run: () => void, key?: string): HTMLButtonElement {
  const b = h('button', {
    type: 'button',
    class: 'icon-button',
    title: label,
    'aria-label': label,
    dataset: key ? { key } : undefined,
    on: { click: run },
  });
  b.appendChild(icon(symbol));
  return b;
}

async function togglePrivacy(): Promise<void> {
  const next = !state.session?.privacyMode;
  state.session = await api.post('/api/session/privacy', { enabled: next });
  document.documentElement.dataset.privacy = next ? 'on' : 'off';
  // Revealing a secret and then turning on Privacy Mode should re-hide it.
  if (next) state.revealed.clear();
  window.dispatchEvent(new CustomEvent('things:changed'));
}

async function runUndo(which: 'undo' | 'redo'): Promise<void> {
  const res = await api.post<{ applied: boolean; canUndo: boolean; canRedo: boolean }>(`/api/${which}`);
  state.undo = { canUndo: res.canUndo, canRedo: res.canRedo };
  await Promise.all([loadList(), refreshBootstrap()]);
  state.undo = { canUndo: res.canUndo, canRedo: res.canRedo };
  if (state.currentId) await openThing(state.currentId).catch(() => openThing(null));
  notify();
}

async function doLock(): Promise<void> {
  window.dispatchEvent(new CustomEvent('things:lock'));
}

// ── sidebar ─────────────────────────────────────────────────────────────────

function buildSidebar(root: HTMLElement): void {
  clear(root);

  const chrome = glassBox(
    'sidebar__chrome',
    h('span', { style: { flex: '1', fontSize: 'var(--text-sm)', fontWeight: 'var(--weight-semibold)' }, text: state.session?.deviceName ?? t('app.name') }),
    iconButton('plus', t('collection.new'), () => void newCollection()),
  );

  const scroll = h('nav', { class: 'sidebar__scroll', 'aria-label': t('nav.library') });
  root.append(chrome, scroll);
  makeGlass(chrome);

  const counts = state.bootstrap?.counts;

  scroll.appendChild(
    sidebarSection(t('nav.library'), [
      navRow('square.stack', t('nav.all'), counts?.all, isRoute({ kind: 'query', query: '', title: '' }), () =>
        navigate({ kind: 'query', query: '', title: t('nav.all') }),
      ),
      navRow('pin', t('nav.pinned'), counts?.pinned, isQuery('is:pinned'), () =>
        navigate({ kind: 'query', query: 'is:pinned', title: t('nav.pinned') }),
      ),
      navRow('clock', t('nav.recents'), undefined, isQuery('sort:modified'), () =>
        navigate({ kind: 'query', query: 'sort:modified', title: t('nav.recents') }),
      ),
      navRow('photo.on.rectangle', t('nav.gallery'), undefined, state.route.kind === 'gallery', () =>
        navigate({ kind: 'gallery' }),
      ),
      navRow('trash', t('nav.trash'), counts?.trash, state.route.kind === 'trash', () => navigate({ kind: 'trash' })),
      counts && counts.conflicts > 0
        ? navRow('exclamationmark.triangle', t('nav.conflicts'), counts.conflicts, state.route.kind === 'conflicts', () =>
            navigate({ kind: 'conflicts' }),
          )
        : null,
    ]),
  );

  const smart = (state.bootstrap?.collections ?? []).filter((c) => c.isSmart);
  const manual = (state.bootstrap?.collections ?? []).filter((c) => !c.isSmart);

  if (manual.length) {
    scroll.appendChild(
      sidebarSection(
        t('nav.collections'),
        manual.map((c) =>
          navRow(
            c.icon?.value ?? 'folder',
            c.name,
            c.count,
            state.route.kind === 'collection' && state.route.id === c.id,
            () => navigate({ kind: 'collection', id: c.id, title: c.name, smartQuery: c.smartQuery }),
            (x, y) => collectionMenu(x, y, c.id, c.name, c.isSystem),
          ),
        ),
      ),
    );
  }

  if (smart.length) {
    scroll.appendChild(
      sidebarSection(
        t('nav.smartViews'),
        smart.map((c) =>
          navRow(
            c.icon?.value ?? 'sparkles',
            c.name,
            c.count,
            state.route.kind === 'collection' && state.route.id === c.id,
            () => navigate({ kind: 'collection', id: c.id, title: c.name, smartQuery: c.smartQuery }),
            (x, y) => collectionMenu(x, y, c.id, c.name, c.isSystem),
          ),
        ),
      ),
    );
  }

  const tags = state.bootstrap?.tags ?? [];
  if (tags.length) {
    scroll.appendChild(
      sidebarSection(
        t('nav.tags'),
        tags.map((tag) => {
          const row = navRow('tag', tag.name, tag.count, isQuery(`tag:${tag.name.toLowerCase()}`), () =>
            navigate({ kind: 'query', query: `tag:${tag.name}`, title: tag.name }),
          );
          if (tag.color) {
            const dot = h('span', { class: 'tag-dot', style: { background: tag.color } });
            row.replaceChild(dot, row.firstChild as Node);
          }
          return row;
        }),
      ),
    );
  }
}

function sidebarSection(title: string, rows: (HTMLElement | null)[]): HTMLElement {
  return h(
    'div',
    { class: 'sidebar__section' },
    h('div', { class: 'sidebar__heading' }, h('span', { text: title })),
    ...rows.filter(Boolean),
  );
}

function navRow(
  symbol: string,
  label: string,
  count: number | undefined,
  active: boolean,
  run: () => void,
  menu?: (x: number, y: number) => void,
): HTMLElement {
  const row = h(
    'button',
    {
      type: 'button',
      class: 'nav-row',
      'aria-current': String(active),
      on: {
        click: run,
        contextmenu: (e: Event) => {
          if (!menu) return;
          e.preventDefault();
          const me = e as MouseEvent;
          menu(me.clientX, me.clientY);
        },
      },
    },
    icon(symbol),
    h('span', { class: 'nav-row__label', text: label }),
    count !== undefined ? h('span', { class: 'nav-row__count', text: String(count) }) : null,
  );
  return row;
}

function isRoute(r: Route): boolean {
  return state.route.kind === r.kind && (r.kind !== 'query' || (state.route as { query: string }).query === r.query);
}

function isQuery(q: string): boolean {
  return state.route.kind === 'query' && state.route.query === q;
}

async function newCollection(): Promise<void> {
  const name = await promptDialog({
    title: t('collection.new'),
    placeholder: t('collection.namePlaceholder'),
    confirmLabel: t('common.create'),
  });
  if (!name) return;
  await api.post('/api/collections', { name });
  await refreshBootstrap();
}

function collectionMenu(x: number, y: number, id: string, name: string, isSystem: boolean): void {
  openMenu(x, y, [
    {
      label: t('common.rename'),
      symbol: 'pencil',
      run: async () => {
        const next = await promptDialog({ title: t('common.rename'), value: name });
        if (next) {
          await api.patch(`/api/collections/${id}`, { name: next });
          await refreshBootstrap();
        }
      },
    },
    { separator: true },
    {
      label: t('collection.remove'),
      symbol: 'trash',
      danger: true,
      run: async () => {
        if (isSystem && !(await confirmDialog({ title: t('collection.remove'), body: t('collection.removeHint'), danger: true, confirmLabel: t('common.delete') }))) return;
        if (!isSystem && !(await confirmDialog({ title: t('collection.remove'), body: t('collection.removeHint'), danger: true, confirmLabel: t('common.delete') }))) return;
        await api.del(`/api/collections/${id}`);
        await refreshBootstrap();
        if (state.route.kind === 'collection' && state.route.id === id) {
          await navigate({ kind: 'query', query: '', title: t('nav.all') });
        }
      },
    },
  ]);
}

// ── list ────────────────────────────────────────────────────────────────────

function buildList(root: HTMLElement): void {
  clear(root);
  const head = h('header', { class: 'list__head' });
  listScroll = h('div', { class: 'list__scroll', role: 'listbox', tabindex: '0', 'aria-label': t('nav.all') });
  root.append(head, buildFilterChips(), listScroll);
  paintList();
}

function buildFilterChips(): HTMLElement {
  const chips: { label: string; query: string }[] = [
    { label: t('search.chip.pinned'), query: 'is:pinned' },
    { label: t('search.chip.images'), query: 'type:image' },
    { label: t('search.chip.files'), query: 'has:file' },
    { label: t('search.chip.passwords'), query: 'has:password' },
    { label: t('search.chip.links'), query: 'has:url' },
    { label: t('search.chip.untagged'), query: '-has:tag' },
    { label: t('search.chip.thisWeek'), query: 'modified:this-week' },
    { label: t('search.chip.locked'), query: 'is:locked' },
  ];

  const row = h('div', { class: 'filters', role: 'group', 'aria-label': t('search.filters') });
  for (const chip of chips) {
    row.appendChild(
      h('button', {
        type: 'button',
        class: 'filter-chip',
        text: chip.label,
        dataset: { query: chip.query },
        on: { click: () => toggleChip(chip.query) },
      }),
    );
  }
  return row;
}

/** Chips compose into the same DSL a power user would type. */
function toggleChip(fragment: string): void {
  const current = searchInput.value.trim();
  const parts = current.split(/\s+/).filter(Boolean);
  const i = parts.indexOf(fragment);
  if (i >= 0) parts.splice(i, 1);
  else parts.push(fragment);
  searchInput.value = parts.join(' ');
  void navigate({ kind: 'query', query: searchInput.value, title: searchInput.value || t('nav.all') });
}

function paintList(): void {
  const root = listScroll?.parentElement;
  if (!root || !listScroll) return;

  const head = root.querySelector<HTMLElement>('.list__head');
  if (head) {
    clear(head);
    const title = state.route.kind === 'query' && state.route.query
      ? state.route.query
      : 'title' in state.route
        ? (state.route as { title: string }).title
        : t(`nav.${state.route.kind}`);
    head.append(
      h('h2', { class: 'list__title', text: title }),
      h('span', { class: 'list__meta', text: tCount('list.count', state.list.length) }),
    );
    if (state.route.kind === 'trash' && state.list.length) {
      head.appendChild(
        h('button', {
          type: 'button',
          class: 'button button--danger',
          text: t('trash.empty'),
          on: {
            click: async () => {
              if (!(await confirmDialog({ title: t('trash.empty'), body: t('trash.retention', { days: 30 }), danger: true, confirmLabel: t('common.delete') }))) return;
              await api.post('/api/trash/empty');
              await Promise.all([loadList(), refreshBootstrap()]);
            },
          },
        }),
      );
    }
  }

  const filters = root.querySelector('.filters');
  if (filters) {
    const q = state.route.kind === 'query' ? state.route.query : '';
    for (const chip of filters.querySelectorAll<HTMLButtonElement>('.filter-chip')) {
      chip.setAttribute('aria-pressed', String(q.split(/\s+/).includes(chip.dataset.query ?? '')));
    }
  }

  clear(listScroll);

  if (state.route.kind === 'gallery' || state.route.kind === 'settings' || state.route.kind === 'conflicts' || state.route.kind === 'history') {
    listScroll.appendChild(emptyState('square.stack', t('detail.empty.title'), ''));
    return;
  }

  if (state.list.length === 0) {
    const isSearch = state.route.kind === 'query' && !!state.route.query;
    const isTrash = state.route.kind === 'trash';
    listScroll.appendChild(
      emptyState(
        isTrash ? 'trash' : isSearch ? 'magnifyingglass' : 'square.stack',
        isTrash ? t('list.emptyTrash.title') : isSearch ? t('list.emptySearch.title') : t('list.empty.title'),
        isTrash ? t('list.emptyTrash.body', { days: 30 }) : isSearch ? t('list.emptySearch.body') : t('list.empty.body'),
      ),
    );
    return;
  }

  state.list.forEach((thing, i) => listScroll.appendChild(rowFor(thing, i)));
  renderSelectionBar();
}

function rowFor(thing: ThingSummary, index: number): HTMLElement {
  const selected = state.selection.has(thing.id) || state.currentId === thing.id;

  const iconBox = h('div', { class: 'row__icon' });
  if (thing.coverObject) {
    iconBox.appendChild(h('img', { src: `/api/objects/${thing.coverObject}/thumbnail`, alt: '' }));
  } else if (thing.icon?.type === 'emoji' && thing.icon.value) {
    iconBox.appendChild(h('span', { text: thing.icon.value, style: { fontSize: '1.125rem' } }));
  } else {
    iconBox.appendChild(icon(thing.isLocked ? 'lock' : thing.icon?.value ?? 'square.stack'));
  }

  const aside = h('div', { class: 'row__aside' });
  if (thing.isPinned) aside.appendChild(icon('pin'));
  if (thing.markers.includes('has:password')) aside.appendChild(icon('key'));
  if (thing.markers.includes('has:file') || thing.markers.includes('type:image')) aside.appendChild(icon('paperclip'));
  aside.appendChild(h('span', { text: formatDate(thing.updatedAt) }));

  const row = h(
    'button',
    {
      type: 'button',
      class: 'row',
      role: 'option',
      'aria-selected': String(selected),
      dataset: { id: thing.id, index: String(index) },
      on: {
        click: (e: Event) => onRowClick(e as MouseEvent, thing, index),
        contextmenu: (e: Event) => {
          e.preventDefault();
          const me = e as MouseEvent;
          if (!state.selection.has(thing.id)) {
            state.selection.clear();
            state.selection.add(thing.id);
            paintList();
          }
          rowMenu(me.clientX, me.clientY);
        },
      },
    },
    iconBox,
    h(
      'div',
      { class: 'row__body' },
      h(
        'div',
        { class: 'row__title' },
        h('span', { text: thing.title || t('detail.untitled') }),
        thing.isLocked ? h('span', { class: 'badge', text: t('thing.locked') }) : null,
      ),
      h('div', { class: 'row__subtitle', text: thing.isLocked ? t('thing.lockedBody') : thing.subtitle }),
    ),
    aside,
  );
  return row;
}

function onRowClick(e: MouseEvent, thing: ThingSummary, index: number): void {
  if (e.shiftKey) {
    const [from, to] = anchorIndex <= index ? [anchorIndex, index] : [index, anchorIndex];
    state.selection.clear();
    for (let i = from; i <= to; i++) {
      const item = state.list[i];
      if (item) state.selection.add(item.id);
    }
    paintList();
    return;
  }
  if (e.ctrlKey || e.metaKey) {
    if (state.selection.has(thing.id)) state.selection.delete(thing.id);
    else state.selection.add(thing.id);
    anchorIndex = index;
    paintList();
    return;
  }
  state.selection.clear();
  anchorIndex = index;
  void openThing(thing.id);
}

function rowMenu(x: number, y: number): void {
  const ids = [...state.selection];
  const single = ids.length === 1 ? ids[0] : null;
  const inTrash = state.route.kind === 'trash';

  openMenu(x, y, [
    single
      ? { label: t('common.openInNewTab'), symbol: 'chevron.right', run: () => void openThing(single) }
      : { label: t('batch.selected', { count: ids.length }), symbol: 'square.stack', run: () => undefined },
    { separator: true },
    inTrash
      ? { label: t('trash.restore'), symbol: 'arrow.uturn.backward', run: () => void batch('restore', ids) }
      : { label: t('common.pin'), symbol: 'pin', run: () => void batch('pin', ids) },
    !inTrash ? { label: t('common.unpin'), symbol: 'pin', run: () => void batch('unpin', ids) } : { separator: true },
    !inTrash
      ? {
          label: t('batch.tag'),
          symbol: 'tag',
          run: async () => {
            const name = await promptDialog({ title: t('batch.tag'), placeholder: t('common.name') });
            if (name) await batch('tag', ids, name);
          },
        }
      : { separator: true },
    !inTrash
      ? {
          label: t('batch.collect'),
          symbol: 'folder',
          run: async () => {
            const options = (state.bootstrap?.collections ?? [])
              .filter((c) => !c.isSmart)
              .map((c) => ({ id: c.id, label: c.name, symbol: c.icon?.value ?? 'folder' }));
            if (options.length === 0) {
              toast(t('collection.new'));
              return;
            }
            const chosen = await chooseDialog(t('batch.collect'), options);
            if (chosen) await batch('collect', ids, chosen);
          },
        }
      : { separator: true },
    single && !inTrash
      ? {
          label: t('common.duplicate'),
          symbol: 'doc.on.doc',
          run: async () => {
            await api.post(`/api/things/${single}/duplicate`, {});
            await loadList();
          },
        }
      : { separator: true },
    single && !inTrash
      ? {
          label: t('common.saveAsTemplate'),
          symbol: 'square.dashed',
          run: async () => {
            await api.post(`/api/things/${single}/template`, {});
            await refreshBootstrap();
            toast(t('common.done'));
          },
        }
      : { separator: true },
    { separator: true },
    inTrash
      ? {
          label: t('trash.deleteNow'),
          symbol: 'trash',
          danger: true,
          run: async () => {
            for (const id of ids) await api.del(`/api/things/${id}/purge`);
            await Promise.all([loadList(), refreshBootstrap()]);
          },
        }
      : { label: t('common.delete'), symbol: 'trash', danger: true, run: () => void batch('trash', ids) },
  ]);
}

async function batch(op: string, ids: string[], value?: string): Promise<void> {
  if (ids.length === 0) return;
  await api.post('/api/batch', { ids, op, value });
  state.selection.clear();
  await Promise.all([loadList(), refreshBootstrap()]);
  if (state.currentId && ids.includes(state.currentId)) {
    if (op === 'trash') await openThing(null);
    else await openThing(state.currentId);
  }
  if (op === 'trash') {
    toast(t('common.delete'), {
      label: t('common.undo'),
      run: async () => {
        await api.post('/api/batch', { ids, op: 'restore' });
        await Promise.all([loadList(), refreshBootstrap()]);
      },
    });
  }
}

function renderSelectionBar(): void {
  document.querySelector('.selection-bar')?.remove();
  if (state.selection.size < 2) return;

  const bar = glassBox(
    'selection-bar',
    h('span', { class: 'selection-bar__count', text: t('batch.selected', { count: state.selection.size }) }),
    smallButton(t('batch.pin'), () => void batch('pin', [...state.selection])),
    smallButton(t('batch.tag'), async () => {
      const name = await promptDialog({ title: t('batch.tag'), placeholder: t('common.name') });
      if (name) await batch('tag', [...state.selection], name);
    }),
    smallButton(t('batch.trash'), () => void batch('trash', [...state.selection])),
    smallButton(t('batch.clear'), () => {
      state.selection.clear();
      paintList();
    }),
  );
  document.body.appendChild(bar);
  makeGlass(bar, { radius: 999 });
}

function smallButton(label: string, run: () => void): HTMLButtonElement {
  return h('button', { type: 'button', class: 'button', text: label, on: { click: run } });
}

function emptyState(symbol: string, title: string, body: string): HTMLElement {
  return h(
    'div',
    { class: 'empty' },
    icon(symbol),
    h('div', { class: 'empty__title', text: title }),
    body ? h('p', { class: 'empty__body', text: body }) : null,
  );
}

// ── floating action button ──────────────────────────────────────────────────

function buildFab(): HTMLElement {
  const fab = glassBox('fab', icon('plus'));
  fab.setAttribute('role', 'button');
  fab.setAttribute('tabindex', '0');
  fab.setAttribute('aria-label', t('toolbar.newThing'));
  const open = (e: Event) => {
    const rect = fab.getBoundingClientRect();
    void newThingMenu(rect.left, rect.top - 8);
    e.preventDefault();
  };
  fab.addEventListener('click', open);
  fab.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') open(e);
  });
  queueMicrotask(() => makeGlass(fab, { radius: 999 }));
  return fab;
}

async function newThingMenu(x: number, y: number): Promise<void> {
  const templates = state.bootstrap?.templates ?? [];
  openMenu(x, y, [
    { label: t('palette.cmd.newThing'), symbol: 'plus', run: () => void createThing() },
    { separator: true },
    ...templates.map((tpl) => ({
      label: tpl.name,
      symbol: tpl.symbol,
      run: () => void createThing(tpl.id),
    })),
  ]);
}

export async function createThing(templateId?: string): Promise<void> {
  const title = await promptDialog({
    title: t('toolbar.newThing'),
    placeholder: t('detail.untitled'),
    confirmLabel: t('common.create'),
  });
  if (title === null) return;
  const created = await api.post<{ id: string }>('/api/things', { title: title || 'Untitled', templateId });
  await Promise.all([loadList(), refreshBootstrap()]);
  await openThing(created.id);
}

// ── keyboard ────────────────────────────────────────────────────────────────

function attachKeyboard(): void {
  window.addEventListener('keydown', (e) => {
    const target = e.target as HTMLElement;
    const typing = /^(INPUT|TEXTAREA)$/.test(target.tagName) || target.isContentEditable;

    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      openPalette();
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') {
      e.preventDefault();
      searchInput.focus();
      searchInput.select();
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z' && !typing) {
      e.preventDefault();
      void runUndo(e.shiftKey ? 'redo' : 'undo');
      return;
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'y' && !typing) {
      e.preventDefault();
      void runUndo('redo');
      return;
    }
    if (typing) return;

    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      moveSelection(e.key === 'ArrowDown' ? 1 : -1);
      return;
    }
    if (e.key === 'Enter' && state.list.length) {
      const item = state.list[anchorIndex];
      if (item) void openThing(item.id);
      return;
    }
    if ((e.key === 'Delete' || e.key === 'Backspace') && state.selection.size) {
      e.preventDefault();
      void batch('trash', [...state.selection]);
      return;
    }
    if (e.key === 'Escape') {
      if (state.selection.size) {
        state.selection.clear();
        paintList();
      }
    }
  });
}

function moveSelection(delta: number): void {
  if (state.list.length === 0) return;
  anchorIndex = Math.max(0, Math.min(state.list.length - 1, anchorIndex + delta));
  const item = state.list[anchorIndex];
  if (!item) return;
  void openThing(item.id);
  const row = listScroll.querySelector<HTMLElement>(`[data-index="${anchorIndex}"]`);
  row?.scrollIntoView({ block: 'nearest' });
}

export function focusSearch(query?: string): void {
  if (query !== undefined) {
    searchInput.value = query;
    void navigate({ kind: 'query', query, title: query || t('nav.all') });
  }
  searchInput.focus();
}
