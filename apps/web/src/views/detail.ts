import { api } from '../api.ts';
import type { FieldView, ThingDetail } from '../api.ts';
import { clear, copyText, h } from '../dom.ts';
import { icon } from '../icons.ts';
import { formatBytes, formatDate, formatDay, formatTime, t } from '../i18n/index.ts';
import {
  loadGallery,
  loadHistory,
  loadList,
  navigate,
  openThing,
  refreshBootstrap,
  reloadCurrent,
  state,
  variant,
} from '../store.ts';
import { chooseDialog, confirmDialog, openMenu, promptDialog, toast } from '../ui.ts';
import { currentTier } from '../glass.ts';

/**
 * The detail pane.
 *
 * This is CONTENT, so nothing here is glass — not the field cells, not the
 * note editor, not the gallery grid. docs/03-DESIGN.md §1 is explicit and this
 * is the surface where third-party apps usually get it wrong.
 *
 * Fields render entirely from the registry: icon, label, actions and secret
 * masking all come from `spec/field-kinds.json`, so adding a variant needs no
 * code here.
 */

export function renderDetail(root: HTMLElement): void {
  clear(root);

  switch (state.route.kind) {
    case 'settings':
      root.appendChild(renderSettings());
      return;
    case 'conflicts':
      root.appendChild(renderConflicts());
      return;
    case 'gallery':
      root.appendChild(renderGallery());
      return;
    case 'history':
      root.appendChild(renderHistory());
      return;
  }

  if (!state.current) {
    root.appendChild(
      h(
        'div',
        { class: 'empty' },
        icon('square.stack'),
        h('div', { class: 'empty__title', text: t('detail.empty.title') }),
        h('p', { class: 'empty__body', text: t('detail.empty.body') }),
      ),
    );
    return;
  }

  root.appendChild(renderThing(state.current));
}

// ── a Thing ─────────────────────────────────────────────────────────────────

function renderThing(thing: ThingDetail): HTMLElement {
  const inner = h('div', { class: 'detail__inner' });

  const title = h('input', {
    class: 'detail__title',
    value: thing.title,
    'aria-label': t('common.name'),
    on: {
      change: async (e: Event) => {
        const next = (e.target as HTMLInputElement).value.trim();
        if (next && next !== thing.title) {
          await api.patch(`/api/things/${thing.id}`, { title: next });
          await Promise.all([reloadCurrent(), loadList()]);
        }
      },
    },
  });

  const iconBox = h('div', { class: 'detail__icon' });
  iconBox.appendChild(
    thing.icon?.type === 'emoji' && thing.icon.value
      ? h('span', { text: thing.icon.value, style: { fontSize: '1.75rem' } })
      : icon(thing.isLocked ? 'lock' : thing.icon?.value ?? 'square.stack'),
  );

  inner.appendChild(
    h(
      'header',
      { class: 'detail__header' },
      iconBox,
      h(
        'div',
        { style: { flex: '1', minInlineSize: '0' } },
        title,
        h(
          'div',
          { class: 'detail__submeta' },
          h('span', { text: t('detail.updated', { date: formatDate(thing.updatedAt) }) }),
          h('span', { text: '·' }),
          h('span', { text: t('detail.created', { date: formatDate(thing.createdAt) }) }),
        ),
      ),
      h(
        'div',
        { class: 'detail__actions' },
        actionButton(thing.isPinned ? 'pin' : 'pin', thing.isPinned ? t('common.unpin') : t('common.pin'), thing.isPinned, async () => {
          await api.patch(`/api/things/${thing.id}`, { isPinned: !thing.isPinned });
          await Promise.all([reloadCurrent(), loadList()]);
        }),
        actionButton('clock', t('detail.history'), false, () => void navigate({ kind: 'history', thingId: thing.id })),
        actionButton('ellipsis', t('detail.more'), false, (e) => {
          const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
          thingMenu(rect.left, rect.bottom + 4, thing);
        }),
      ),
    ),
  );

  // Tags and collections — chips that generate the same DSL the search bar takes.
  const chips = h('div', { class: 'chip-row' });
  for (const tag of thing.tags) {
    chips.appendChild(
      h(
        'span',
        { class: 'chip' },
        h('button', {
          type: 'button',
          style: { all: 'unset', cursor: 'pointer' },
          text: tag.name,
          on: { click: () => void navigate({ kind: 'query', query: `tag:${tag.name}`, title: tag.name }) },
        }),
        h('button', {
          type: 'button',
          'aria-label': `${t('common.delete')} ${tag.name}`,
          html: '×',
          on: {
            click: async () => {
              await api.del(`/api/things/${thing.id}/tags/${tag.id}`);
              await Promise.all([reloadCurrent(), refreshBootstrap()]);
            },
          },
        }),
      ),
    );
  }
  for (const col of thing.collections) {
    chips.appendChild(
      h('button', {
        type: 'button',
        class: 'chip',
        text: col.name,
        on: { click: () => void navigate({ kind: 'collection', id: col.id, title: col.name, smartQuery: null }) },
      }),
    );
  }
  chips.appendChild(
    h('button', {
      type: 'button',
      class: 'chip chip--add',
      text: `+ ${t('detail.addTag')}`,
      on: {
        click: async () => {
          const name = await promptDialog({ title: t('detail.addTag'), placeholder: t('common.name') });
          if (!name) return;
          await api.post(`/api/things/${thing.id}/tags`, { name });
          await Promise.all([reloadCurrent(), refreshBootstrap()]);
        },
      },
    }),
  );
  inner.appendChild(chips);

  if (thing.isLocked) {
    inner.appendChild(
      h(
        'div',
        { class: 'empty' },
        icon('lock'),
        h('div', { class: 'empty__title', text: t('thing.locked') }),
        h('p', { class: 'empty__body', text: t('thing.lockedBody') }),
        h('button', {
          type: 'button',
          class: 'button',
          text: t('common.unlock'),
          on: {
            click: async () => {
              await api.patch(`/api/things/${thing.id}`, { isLocked: false });
              await Promise.all([reloadCurrent(), loadList()]);
            },
          },
        }),
      ),
    );
    return inner;
  }

  // Unfiled fields first, then each section.
  const unfiled = thing.fields.filter((f) => !f.sectionId);
  if (unfiled.length) inner.appendChild(sectionBlock(thing, null, unfiled));
  for (const section of thing.sections) {
    inner.appendChild(sectionBlock(thing, section, thing.fields.filter((f) => f.sectionId === section.id)));
  }

  // Media gallery for this Thing — flat, opaque, media is the subject.
  const media = thing.fields.filter((f) => f.object && (f.object.mimeType ?? '').startsWith('image/'));
  if (media.length) {
    inner.appendChild(
      h(
        'div',
        { class: 'section' },
        h('div', { class: 'section__head' }, h('span', { class: 'section__title', text: t('detail.gallery') }), h('span', { class: 'section__rule' })),
        h(
          'div',
          { class: 'gallery' },
          ...media.map((f) =>
            h(
              'figure',
              { class: 'gallery__item', on: { click: () => openPreview(f) } },
              h('img', { src: `/api/objects/${f.object!.hash}/thumbnail`, alt: f.label, loading: 'lazy' }),
              h('figcaption', { text: f.label }),
            ),
          ),
        ),
      ),
    );
  }

  if (thing.backlinks.length) {
    inner.appendChild(
      h(
        'div',
        { class: 'section' },
        h('div', { class: 'section__head' }, h('span', { class: 'section__title', text: t('detail.referencedBy') }), h('span', { class: 'section__rule' })),
        ...thing.backlinks.map((b) =>
          h('button', { type: 'button', class: 'nav-row', on: { click: () => void openThing(b.id) } }, icon('link'), h('span', { class: 'nav-row__label', text: b.title })),
        ),
      ),
    );
  }

  inner.appendChild(
    h(
      'div',
      { style: { display: 'flex', gap: 'var(--sp-2)', marginBlockStart: 'var(--sp-4)' } },
      h('button', { type: 'button', class: 'button', text: `+ ${t('detail.addField')}`, on: { click: () => void addField(thing, null) } }),
      h('button', {
        type: 'button',
        class: 'button',
        text: `+ ${t('detail.addSection')}`,
        on: {
          click: async () => {
            const name = await promptDialog({ title: t('detail.addSection'), placeholder: t('common.name') });
            if (name === null) return;
            await api.post(`/api/things/${thing.id}/sections`, { title: name });
            await reloadCurrent();
          },
        },
      }),
    ),
  );

  return inner;
}

function actionButton(symbol: string, label: string, active: boolean, run: (e: Event) => void): HTMLButtonElement {
  const b = h('button', {
    type: 'button',
    class: `icon-button${active ? ' is-active' : ''}`,
    title: label,
    'aria-label': label,
    on: { click: run },
  });
  b.appendChild(icon(symbol));
  return b;
}

function sectionBlock(thing: ThingDetail, section: ThingDetail['sections'][number] | null, fields: FieldView[]): HTMLElement {
  const block = h('div', { class: 'section' });

  if (section) {
    block.appendChild(
      h(
        'div',
        { class: 'section__head' },
        h('input', {
          class: 'section__title',
          value: section.title ?? '',
          'aria-label': t('common.name'),
          on: {
            change: async (e: Event) => {
              await api.patch(`/api/sections/${section.id}`, { title: (e.target as HTMLInputElement).value });
              await reloadCurrent();
            },
          },
        }),
        h('span', { class: 'section__rule' }),
        h('button', {
          type: 'button',
          class: 'icon-button',
          title: t('detail.addField'),
          on: { click: () => void addField(thing, section.id) },
          html: '',
        }),
        h('button', {
          type: 'button',
          class: 'icon-button',
          title: t('common.delete'),
          on: {
            click: async () => {
              if (!(await confirmDialog({ title: t('common.delete'), body: section.title ?? '', danger: true, confirmLabel: t('common.delete') }))) return;
              await api.del(`/api/sections/${section.id}`);
              await reloadCurrent();
            },
          },
          html: '',
        }),
      ),
    );
    const head = block.querySelector('.section__head')!;
    head.children[2].appendChild(icon('plus'));
    head.children[3].appendChild(icon('trash'));
  }

  // Fields sit in one opaque grouped list — Contacts / Settings, not a form.
  const list = h('div', { class: 'field-list' });
  if (fields.length === 0) {
    list.appendChild(h('p', { class: 'field-empty', text: t('thing.noFields') }));
  }
  for (const [index, field] of fields.entries()) {
    list.appendChild(fieldRow(thing, field, index, fields));
  }
  block.appendChild(list);
  return block;
}

// ── one field ───────────────────────────────────────────────────────────────

function fieldRow(thing: ThingDetail, field: FieldView, index: number, siblings: FieldView[]): HTMLElement {
  const def = variant(field.variant);
  const stacked = field.kind === 'richText' || field.kind === 'longText' || field.kind === 'code';
  const row = h('div', {
    class: `field${stacked ? ' field--stacked' : ''}`,
    draggable: 'true',
    dataset: { fieldId: field.id, index: String(index) },
  });

  // Drag to reorder. One row is written server-side — fractional sort_order.
  row.addEventListener('dragstart', (e) => {
    row.classList.add('is-dragging');
    e.dataTransfer?.setData('text/things-field', field.id);
    if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
  });
  row.addEventListener('dragend', () => row.classList.remove('is-dragging'));
  row.addEventListener('dragover', (e) => {
    if (!e.dataTransfer?.types.includes('text/things-field')) return;
    e.preventDefault();
    row.classList.add('drop-before');
  });
  row.addEventListener('dragleave', () => row.classList.remove('drop-before'));
  row.addEventListener('drop', async (e) => {
    row.classList.remove('drop-before');
    const movedId = e.dataTransfer?.getData('text/things-field');
    if (!movedId || movedId === field.id) return;
    e.preventDefault();
    await api.patch(`/api/fields/${movedId}`, { sectionId: field.sectionId, index });
    await reloadCurrent();
  });

  row.appendChild(h('div', { class: 'field__grip', title: t('field.rename') }, icon('line.3.horizontal')));

  row.appendChild(
    h(
      'div',
      { class: 'field__label' },
      icon(field.symbol),
      h('input', {
        value: field.label,
        'aria-label': t('field.rename'),
        on: {
          change: async (e: Event) => {
            await api.patch(`/api/fields/${field.id}`, { label: (e.target as HTMLInputElement).value });
            await Promise.all([reloadCurrent(), loadList()]);
          },
        },
      }),
    ),
  );

  row.appendChild(valueCell(field));

  const actions = h('div', { class: 'field__actions' });
  for (const action of field.actions) actions.appendChild(actionFor(field, action));
  actions.appendChild(
    h(
      'button',
      {
        type: 'button',
        title: t('detail.more'),
        on: {
          click: (e: Event) => {
            const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
            fieldMenu(r.left, r.bottom + 4, thing, field, index, siblings.length);
          },
        },
      },
      icon('ellipsis'),
    ),
  );
  row.appendChild(actions);

  void def;
  return row;
}

function valueCell(field: FieldView): HTMLElement {
  const cell = h('div', { class: `field__value${field.kind === 'code' ? ' field__value--code' : ''}` });

  if (field.isSecret) {
    const revealed = state.revealed.has(field.id);
    const code = h('code', {
      class: `${revealed ? 'is-revealed' : ''} is-sensitive`,
      text: field.hasValue ? (revealed ? '' : '••••••••••••') : t('field.empty'),
    });
    if (revealed) code.textContent = state.revealedValues.get(field.id) ?? '';
    cell.appendChild(h('div', { class: 'field__secret' }, code));
    return cell;
  }

  if (field.fileRef) {
    cell.appendChild(
      h(
        'div',
        { class: 'file-ref' },
        h('span', { class: 'file-ref__path', text: field.fileRef.path, title: field.fileRef.path }),
        h('span', {
          class: 'file-ref__device',
          dataset: { status: field.fileRef.status },
          text:
            field.fileRef.status === 'missing'
              ? t('field.missing', { device: field.fileRef.deviceName })
              : t('field.onDevice', { device: field.fileRef.deviceName }),
        }),
      ),
    );
    return cell;
  }

  if (field.object) {
    const isImage = (field.object.mimeType ?? '').startsWith('image/');
    cell.appendChild(
      h(
        'div',
        { style: { display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', minInlineSize: '0' } },
        isImage
          ? h('img', {
              src: `/api/objects/${field.object.hash}/thumbnail`,
              alt: field.label,
              style: { inlineSize: '2.5rem', blockSize: '2.5rem', objectFit: 'cover', borderRadius: 'var(--radius-xs)' },
              loading: 'lazy',
            })
          : icon('doc'),
        h('span', { text: formatBytes(field.object.byteSize) }),
      ),
    );
    return cell;
  }

  if (field.kind === 'richText' || field.kind === 'longText' || field.kind === 'code') {
    const text =
      field.kind === 'richText' ? richToPlain(field.json) : field.text ?? '';
    const area = h('textarea', {
      rows: '4',
      placeholder: t('field.placeholder'),
      spellcheck: field.kind === 'code' ? 'false' : 'true',
      'aria-label': field.label,
    });
    area.value = text;
    area.addEventListener('change', async () => {
      const value =
        field.kind === 'richText'
          ? { json: { type: 'doc', content: area.value.split('\n').map((line) => ({ type: 'paragraph', text: line })) } }
          : { text: area.value };
      await api.patch(`/api/fields/${field.id}`, { value });
      await Promise.all([reloadCurrent(), loadList()]);
    });
    cell.appendChild(area);
    return cell;
  }

  if (field.kind === 'boolean') {
    const box = h('input', { type: 'checkbox', 'aria-label': field.label });
    box.checked = field.text === '1';
    box.addEventListener('change', async () => {
      await api.patch(`/api/fields/${field.id}`, { value: { text: box.checked ? '1' : '0' } });
      await reloadCurrent();
    });
    cell.appendChild(box);
    return cell;
  }

  const sensitive = field.variant === 'email' || field.variant === 'phone' || field.kind === 'relation';
  const input = h('input', {
    type: field.kind === 'date' ? 'date' : field.kind === 'number' ? 'text' : 'text',
    value: field.text ?? '',
    placeholder: t('field.placeholder'),
    'aria-label': field.label,
    class: sensitive ? 'is-sensitive' : '',
  });
  input.addEventListener('change', async () => {
    await api.patch(`/api/fields/${field.id}`, { value: { text: input.value } });
    await Promise.all([reloadCurrent(), loadList()]);
  });
  cell.appendChild(input);
  return cell;
}

function actionFor(field: FieldView, action: string): HTMLButtonElement {
  const map: Record<string, { symbol: string; label: string; run: () => void | Promise<void> }> = {
    copy: {
      symbol: 'doc.on.clipboard',
      label: t('field.copy'),
      run: () => copyFieldValue(field),
    },
    reveal: {
      symbol: state.revealed.has(field.id) ? 'eye.slash' : 'eye',
      label: state.revealed.has(field.id) ? t('field.hide') : t('field.reveal'),
      run: () => toggleReveal(field),
    },
    open: {
      symbol: 'arrow.up.forward',
      label: t('field.open'),
      run: () => {
        if (field.text) window.open(field.text, '_blank', 'noopener,noreferrer');
      },
    },
    copyLink: { symbol: 'link', label: t('field.copyLink'), run: () => copyFieldValue(field) },
    copyPath: { symbol: 'doc.on.clipboard', label: t('field.copyPath'), run: () => copyFieldValue(field) },
    openInExplorer: {
      symbol: 'folder',
      label: t('field.openInExplorer'),
      // Opening Explorer needs an OS call the browser cannot make. On the
      // owning device the honest affordance is Copy Path; the iOS client and a
      // future tray helper do the real thing.
      run: () => copyFieldValue(field),
    },
    sendEmail: {
      symbol: 'envelope',
      label: t('field.sendEmail'),
      run: () => {
        if (field.text) window.location.href = `mailto:${field.text}`;
      },
    },
    call: {
      symbol: 'phone',
      label: t('field.call'),
      run: () => {
        if (field.text) window.location.href = `tel:${field.text}`;
      },
    },
    quickLook: { symbol: 'eye', label: t('field.quickLook'), run: () => openPreview(field) },
    saveToFiles: {
      symbol: 'arrow.down.doc',
      label: t('field.saveToFiles'),
      run: () => {
        if (field.object) window.open(`/api/objects/${field.object.hash}`, '_blank', 'noopener');
      },
    },
    openThing: {
      symbol: 'chevron.right',
      label: t('field.openThing'),
      run: () => {
        if (field.text) void openThing(field.text);
      },
    },
  };

  const spec = map[action] ?? { symbol: 'ellipsis', label: action, run: () => undefined };
  const b = h('button', { type: 'button', title: spec.label, 'aria-label': spec.label, on: { click: () => void spec.run() } });
  b.appendChild(icon(spec.symbol));
  return b;
}

async function copyFieldValue(field: FieldView): Promise<void> {
  let value = field.text ?? '';
  if (field.isSecret) {
    const res = await api.post<{ value: string }>(`/api/fields/${field.id}/reveal`);
    value = res.value;
  } else if (field.fileRef) {
    value = field.fileRef.path;
  } else if (field.kind === 'richText') {
    value = richToPlain(field.json);
  }
  await copyText(value);
  toast(t('field.copied'));
}

async function toggleReveal(field: FieldView): Promise<void> {
  if (state.revealed.has(field.id)) {
    state.revealed.delete(field.id);
    state.revealedValues.delete(field.id);
  } else {
    const res = await api.post<{ value: string }>(`/api/fields/${field.id}/reveal`);
    state.revealed.add(field.id);
    state.revealedValues.set(field.id, res.value);
    // Re-hide after a timeout — docs/02-SECURITY.md §6.
    window.setTimeout(() => {
      state.revealed.delete(field.id);
      state.revealedValues.delete(field.id);
      void reloadCurrent();
    }, 30_000);
  }
  await reloadCurrent();
}

function fieldMenu(x: number, y: number, thing: ThingDetail, field: FieldView, index: number, count: number): void {
  openMenu(x, y, [
    {
      label: t('field.rename'),
      symbol: 'pencil',
      run: async () => {
        const label = await promptDialog({ title: t('field.rename'), value: field.label });
        if (label) {
          await api.patch(`/api/fields/${field.id}`, { label });
          await reloadCurrent();
        }
      },
    },
    {
      label: t('detail.addField'),
      symbol: 'plus',
      run: () => void addField(thing, field.sectionId),
    },
    { separator: true },
    index > 0
      ? {
          label: '↑',
          symbol: 'chevron.down',
          run: async () => {
            await api.patch(`/api/fields/${field.id}`, { index: index - 1 });
            await reloadCurrent();
          },
        }
      : { separator: true },
    index < count - 1
      ? {
          label: '↓',
          symbol: 'chevron.down',
          run: async () => {
            await api.patch(`/api/fields/${field.id}`, { index: index + 1 });
            await reloadCurrent();
          },
        }
      : { separator: true },
    { separator: true },
    {
      label: t('field.remove'),
      symbol: 'trash',
      danger: true,
      run: async () => {
        await api.del(`/api/fields/${field.id}`);
        await Promise.all([reloadCurrent(), loadList()]);
      },
    },
  ]);
}

export async function addField(thing: ThingDetail, sectionId: string | null): Promise<void> {
  const options = (state.registry?.variants ?? []).map((v) => ({
    id: v.id,
    label: v.label,
    symbol: v.symbol,
    hint: v.kind,
  }));
  const chosen = await chooseDialog(t('detail.addField'), options);
  if (!chosen) return;
  await api.post(`/api/things/${thing.id}/fields`, { variant: chosen, sectionId });
  await Promise.all([reloadCurrent(), loadList()]);
}

function thingMenu(x: number, y: number, thing: ThingDetail): void {
  openMenu(x, y, [
    { label: t('detail.history'), symbol: 'clock', run: () => void navigate({ kind: 'history', thingId: thing.id }) },
    {
      label: t('common.duplicate'),
      symbol: 'doc.on.doc',
      run: async () => {
        const copy = await api.post<{ id: string }>(`/api/things/${thing.id}/duplicate`, {});
        await loadList();
        await openThing(copy.id);
      },
    },
    {
      label: t('common.saveAsTemplate'),
      symbol: 'square.dashed',
      run: async () => {
        await api.post(`/api/things/${thing.id}/template`, {});
        await refreshBootstrap();
        toast(t('common.done'));
      },
    },
    {
      label: thing.isLocked ? t('common.unlock') : t('common.lock'),
      symbol: thing.isLocked ? 'lock.open' : 'lock',
      run: async () => {
        await api.patch(`/api/things/${thing.id}`, { isLocked: !thing.isLocked });
        await Promise.all([reloadCurrent(), loadList()]);
      },
    },
    { separator: true },
    {
      label: t('common.delete'),
      symbol: 'trash',
      danger: true,
      run: async () => {
        await api.del(`/api/things/${thing.id}`);
        await Promise.all([loadList(), refreshBootstrap()]);
        await openThing(null);
        toast(t('common.delete'), {
          label: t('common.undo'),
          run: async () => {
            await api.post(`/api/things/${thing.id}/restore`);
            await loadList();
            await openThing(thing.id);
          },
        });
      },
    },
  ]);
}

// ── previews ────────────────────────────────────────────────────────────────

function openPreview(field: FieldView): void {
  if (!field.object) return;
  const backdrop = h('div', {
    class: 'dialog-backdrop',
    on: {
      click: (e: Event) => {
        if (e.target === backdrop) backdrop.remove();
      },
    },
  });
  const isImage = (field.object.mimeType ?? '').startsWith('image/');
  const isVideo = (field.object.mimeType ?? '').startsWith('video/');
  backdrop.appendChild(
    h(
      'figure',
      { style: { maxInlineSize: '90vw', maxBlockSize: '86vh', display: 'grid', gap: 'var(--sp-2)', justifyItems: 'center' } },
      isImage
        ? h('img', { src: `/api/objects/${field.object.hash}`, alt: field.label, style: { maxBlockSize: '78vh', borderRadius: 'var(--radius-lg)' } })
        : isVideo
          ? h('video', { src: `/api/objects/${field.object.hash}`, controls: true, style: { maxBlockSize: '78vh', borderRadius: 'var(--radius-lg)' } })
          : h('div', { class: 'empty' }, icon('doc'), h('div', { class: 'empty__title', text: field.label })),
      h('figcaption', { class: 'preview__caption', text: `${field.label} · ${formatBytes(field.object.byteSize)}` }),
    ),
  );
  document.body.appendChild(backdrop);
  window.addEventListener('keydown', function esc(e) {
    if (e.key === 'Escape') {
      backdrop.remove();
      window.removeEventListener('keydown', esc);
    }
  });
}

// ── panels ──────────────────────────────────────────────────────────────────

function renderGallery(): HTMLElement {
  const inner = h('div', { class: 'detail__inner' });
  inner.appendChild(h('h1', { class: 'detail__title', style: { marginBlockEnd: 'var(--sp-4)' }, text: t('nav.gallery') }));

  if (state.gallery.length === 0) {
    inner.appendChild(h('div', { class: 'empty' }, icon('photo'), h('div', { class: 'empty__title', text: t('list.empty.title') }), h('p', { class: 'empty__body', text: t('list.empty.body') })));
    return inner;
  }

  const grid = h('div', { class: 'gallery' });
  for (const item of state.gallery) {
    grid.appendChild(
      h(
        'figure',
        {
          class: 'gallery__item',
          title: `${item.thingTitle} · ${item.label}`,
          on: { click: () => void openThing(item.thingId) },
        },
        h('img', { src: `/api/objects/${item.hash}/thumbnail`, alt: item.label, loading: 'lazy' }),
        h('figcaption', { text: `${item.thingTitle} · ${formatBytes(item.byteSize)}` }),
      ),
    );
  }
  inner.appendChild(grid);
  void loadGallery;
  return inner;
}

function renderHistory(): HTMLElement {
  const inner = h('div', { class: 'detail__inner' });
  inner.appendChild(
    h(
      'header',
      { class: 'detail__header' },
      h('div', { class: 'detail__icon' }, icon('clock')),
      h('div', { style: { flex: '1' } }, h('h1', { class: 'detail__title', text: t('history.title') })),
      h('button', {
        type: 'button',
        class: 'button',
        text: t('common.close'),
        on: {
          click: () => {
            const id = state.route.kind === 'history' ? state.route.thingId : null;
            void navigate({ kind: 'query', query: '', title: t('nav.all') }).then(() => (id ? openThing(id) : undefined));
          },
        },
      }),
    ),
  );

  if (state.history.length === 0) {
    inner.appendChild(h('p', { class: 'empty__body', text: t('history.empty') }));
    return inner;
  }

  for (const day of state.history) {
    const block = h('div', { class: 'history__day' }, h('div', { class: 'history__date', text: formatDay(day.date) }));
    for (const change of day.changes) {
      block.appendChild(
        h(
          'div',
          { class: 'history__entry' },
          h('span', { class: 'history__time', text: formatTime(change.appliedAt) }),
          h('span', { class: 'history__summary', text: change.summary }),
          change.canRestore
            ? h('button', {
                type: 'button',
                text: t('history.restore'),
                on: {
                  click: async () => {
                    await api.post(`/api/history/${change.id}/restore`, { mode: 'before' });
                    const id = state.route.kind === 'history' ? state.route.thingId : null;
                    if (id) await loadHistory(id);
                    await loadList();
                    toast(t('history.restored'));
                  },
                },
              })
            : null,
        ),
      );
    }
    inner.appendChild(block);
  }
  return inner;
}

function renderConflicts(): HTMLElement {
  const inner = h('div', { class: 'detail__inner' });
  inner.appendChild(h('h1', { class: 'detail__title', style: { marginBlockEnd: 'var(--sp-2)' }, text: t('conflicts.title') }));
  inner.appendChild(h('p', { class: 'settings__hint', text: t('conflicts.body') }));

  const host = h('div', { style: { marginBlockStart: 'var(--sp-4)' } });
  inner.appendChild(host);

  void api.get<{ id: string; entityType: string; entityId: string }[]>('/api/conflicts').then((list) => {
    clear(host);
    if (list.length === 0) {
      host.appendChild(h('p', { class: 'empty__body', text: t('conflicts.none') }));
      return;
    }
    const grouped = h('div', { class: 'settings__list' });
    host.appendChild(grouped);
    for (const c of list) {
      grouped.appendChild(
        h(
          'div',
          { class: 'settings__row' },
          h('div', {}, h('div', { class: 'settings__label', text: `${c.entityType} · ${c.entityId.slice(0, 8)}` })),
          h(
            'div',
            { style: { display: 'flex', gap: 'var(--sp-2)' } },
            h('button', {
              type: 'button',
              class: 'button',
              text: t('conflicts.keepLocal'),
              on: { click: () => void resolve(c.id, 'a') },
            }),
            h('button', {
              type: 'button',
              class: 'button button--primary',
              text: t('conflicts.keepRemote'),
              on: { click: () => void resolve(c.id, 'b') },
            }),
          ),
        ),
      );
    }
  });

  async function resolve(id: string, resolution: 'a' | 'b'): Promise<void> {
    await api.post(`/api/conflicts/${id}/resolve`, { resolution });
    await Promise.all([refreshBootstrap(), loadList()]);
    await navigate({ kind: 'conflicts' });
  }

  return inner;
}

function renderSettings(): HTMLElement {
  const inner = h('div', { class: 'detail__inner' });
  inner.appendChild(h('h1', { class: 'detail__title', style: { marginBlockEnd: 'var(--sp-6)' }, text: t('settings.title') }));

  const wrapper = state.session?.deviceWrapper ?? 'none';
  const wrapperText =
    wrapper === 'dpapi'
      ? t('settings.deviceWrapper.dpapi')
      : wrapper === 'file-fallback'
        ? t('settings.deviceWrapper.fallback')
        : t('settings.deviceWrapper.none');

  inner.appendChild(
    group(t('settings.security'), [
      row(t('settings.deviceWrapper'), wrapperText, null),
      row(
        t('settings.autoLock'),
        t('settings.autoLockHint'),
        (() => {
          const select = h('select', { class: 'text-input', style: { inlineSize: 'auto' } });
          const options: [string, number][] = [
            [t('settings.autoLock.never'), 0],
            [t('settings.autoLock.1'), 60_000],
            [t('settings.autoLock.5'), 300_000],
            [t('settings.autoLock.15'), 900_000],
          ];
          for (const [label, ms] of options) {
            const opt = h('option', { value: String(ms), text: label });
            if (state.session?.autoLockMs === ms) opt.selected = true;
            select.appendChild(opt);
          }
          select.addEventListener('change', async () => {
            state.session = await api.post('/api/session/autolock', { ms: Number(select.value) });
          });
          return select;
        })(),
      ),
      row(
        t('settings.changePin'),
        '',
        h('button', {
          type: 'button',
          class: 'button',
          text: t('settings.changePin'),
          on: {
            click: async () => {
              const currentPin = await promptDialog({ title: t('settings.currentPin'), placeholder: '······' });
              if (!currentPin) return;
              const newPin = await promptDialog({ title: t('settings.newPin'), placeholder: '······' });
              if (!newPin) return;
              try {
                await api.post('/api/session/pin', { currentPin, newPin });
                toast(t('common.done'));
              } catch (e) {
                toast((e as Error).message);
              }
            },
          },
        }),
      ),
      row(t('settings.privacy'), t('settings.privacyHint'), null),
    ]),
  );

  inner.appendChild(
    group(t('settings.storage'), [
      row(t('settings.objects'), formatBytes(state.bootstrap?.counts.objects ?? 0), null),
      row(
        t('settings.rescan'),
        '',
        h('button', {
          type: 'button',
          class: 'button',
          text: t('settings.rescan'),
          on: {
            click: async () => {
              const res = await api.post<{ present: number; missing: number }>('/api/maintenance/rescan');
              toast(`${res.present} present · ${res.missing} missing`);
            },
          },
        }),
      ),
      row(
        t('settings.gc'),
        '',
        h('button', {
          type: 'button',
          class: 'button',
          text: t('settings.gc'),
          on: {
            click: async () => {
              const res = await api.post<{ removed: number; bytes: number }>('/api/maintenance/gc');
              toast(`${res.removed} · ${formatBytes(res.bytes)}`);
              await refreshBootstrap();
            },
          },
        }),
      ),
    ]),
  );

  inner.appendChild(
    group(t('settings.appearance'), [row(t('settings.glassTier'), t(`settings.glassTier.${currentTier()}`), null)]),
  );

  inner.appendChild(group(t('settings.sync'), [row(t('settings.sync'), t('settings.syncHint'), null)]));

  return inner;
}

function group(title: string, rows: HTMLElement[]): HTMLElement {
  return h(
    'section',
    { class: 'settings__group' },
    h('div', { class: 'section__head' }, h('span', { class: 'section__title', text: title }), h('span', { class: 'section__rule' })),
    h('div', { class: 'settings__list' }, ...rows),
  );
}

function row(label: string, hint: string, control: HTMLElement | null): HTMLElement {
  return h(
    'div',
    { class: 'settings__row' },
    h('div', {}, h('div', { class: 'settings__label', text: label }), hint ? h('p', { class: 'settings__hint', text: hint }) : null),
    control,
  );
}

function richToPlain(json: unknown): string {
  if (!json) return '';
  const walk = (n: unknown): string => {
    if (typeof n === 'string') return n;
    if (Array.isArray(n)) return n.map(walk).join('\n');
    if (n && typeof n === 'object') {
      const o = n as Record<string, unknown>;
      const own = typeof o.text === 'string' ? o.text : '';
      const kids = walk(o.content ?? o.children ?? []);
      return [own, kids].filter(Boolean).join('\n');
    }
    return '';
  };
  return walk(json).trim();
}
