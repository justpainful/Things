import { api } from './api.ts';
import { glassBox, h } from './dom.ts';
import { destroyGlass, makeGlass } from './glass.ts';
import { icon } from './icons.ts';
import { t, tCount } from './i18n/index.ts';
import { loadList, openThing, refreshBootstrap, state } from './store.ts';
import { toast } from './ui.ts';

/**
 * Drag-and-drop import.
 *
 * The question the drop has to answer is the interesting one: 50 files could
 * mean 50 Things, or one Thing with 50 attachments. Both are legitimate, so
 * Things asks instead of guessing — once, in a glass sheet, with the third
 * option ("add to the Thing you have open") only offered when it exists.
 *
 * Bytes are uploaded first so the content-addressed store can dedupe before
 * anything is created; re-dropping the same folder costs nothing.
 */

export function installDropTarget(): void {
  let depth = 0;
  let sheet: HTMLElement | null = null;

  window.addEventListener('dragover', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
  });

  window.addEventListener('dragenter', (e) => {
    if (!hasFiles(e)) return;
    depth++;
  });

  window.addEventListener('dragleave', () => {
    depth = Math.max(0, depth - 1);
  });

  window.addEventListener('drop', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    depth = 0;
    const files = [...(e.dataTransfer?.files ?? [])];
    if (files.length === 0) return;
    if (sheet) return;
    sheet = askAndImport(files, () => {
      if (sheet) destroyGlass(sheet.querySelector('.dropzone__card') as HTMLElement);
      sheet?.remove();
      sheet = null;
    });
  });
}

function hasFiles(e: DragEvent): boolean {
  return !!e.dataTransfer && [...e.dataTransfer.types].includes('Files');
}

function askAndImport(files: File[], close: () => void): HTMLElement {
  const current = state.current;
  const card = glassBox(
    'dropzone__card',
    icon('arrow.down.doc'),
    h('h2', { style: { fontSize: 'var(--text-lg)', fontWeight: 'var(--weight-semibold)' }, text: tCount('import.title', files.length) }),
    h('p', { class: 'settings__hint', text: t('import.question') }),
    h(
      'div',
      { class: 'dropzone__choices' },
      choice(t('import.perFile', { count: files.length }), t('import.perFileHint'), () => run('perFile')),
      choice(t('import.single'), t('import.singleHint'), () => run('single')),
      current && !current.isLocked
        ? choice(t('import.toThing', { title: current.title }), t('import.toThingHint'), () => run('single', current.id))
        : null,
    ),
    h('button', { type: 'button', class: 'button', text: t('import.cancel'), on: { click: close } }),
  );

  const zone = h('div', { class: 'dropzone' }, card);
  document.body.appendChild(zone);
  makeGlass(card);

  zone.addEventListener('pointerdown', (e) => {
    if (e.target === zone) close();
  });

  async function run(mode: 'perFile' | 'single', thingId?: string): Promise<void> {
    close();
    toast(t('import.working'));
    try {
      const manifest: { hash: string; filename: string; mime: string | null }[] = [];
      for (const file of files) {
        const bytes = await file.arrayBuffer();
        const res = await api.upload<{ hash: string }>(
          `/api/objects?mime=${encodeURIComponent(file.type || 'application/octet-stream')}`,
          bytes,
        );
        manifest.push({ hash: res.hash, filename: file.name, mime: file.type || null });
      }
      const created = await api.post<{ created: string[] }>('/api/import', {
        mode,
        thingId,
        files: manifest,
      });
      await Promise.all([loadList(), refreshBootstrap()]);
      if (created.created.length === 1) await openThing(created.created[0]);
      toast(t('import.done', { count: files.length }));
    } catch (err) {
      toast((err as Error).message || t('common.error'));
    }
  }

  return zone;
}

function choice(title: string, hint: string, run: () => void): HTMLElement {
  return h(
    'button',
    { type: 'button', class: 'dropzone__choice', on: { click: run } },
    h('strong', { text: title }),
    h('span', { text: hint }),
  );
}
