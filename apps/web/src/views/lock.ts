import { api, setToken } from '../api.ts';
import type { SessionState } from '../api.ts';
import { clear, glassBox, h } from '../dom.ts';
import { makeGlass, resetGlass } from '../glass.ts';
import { icon } from '../icons.ts';
import { t } from '../i18n/index.ts';

/**
 * PIN setup and unlock.
 *
 * Two things this screen must get right, both from docs/02-SECURITY.md §4:
 * escalating delays after a failed attempt, and never implying that repeated
 * failures destroy anything. There is no cloud copy, so an auto-wipe would
 * turn a forgotten PIN into permanent loss — the copy says "try again", not
 * "attempts remaining".
 */

export function renderLock(root: HTMLElement, session: SessionState, onUnlocked: () => void): void {
  resetGlass();
  clear(root);
  root.removeAttribute('aria-busy');

  const setup = !session.provisioned;
  const input = h('input', {
    class: 'lock__pin',
    type: 'password',
    inputmode: 'numeric',
    autocomplete: 'off',
    'aria-label': setup ? t('lock.setup.title') : t('lock.unlock.title'),
    placeholder: t('lock.placeholder'),
    maxlength: '32',
  });
  const error = h('div', { class: 'lock__error', role: 'alert' });
  const submit = h('button', {
    type: 'submit',
    class: 'button button--primary',
    text: setup ? t('lock.setup.action') : t('lock.unlock.action'),
    style: { inlineSize: '100%' },
  });

  const form = h(
    'form',
    {
      style: { display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', inlineSize: '100%' },
      on: { submit: (e: Event) => void onSubmit(e) },
    },
    input,
    error,
    submit,
  );

  const card = glassBox(
    'lock__card',
    h('div', { class: 'lock__glyph' }, icon(setup ? 'key' : 'lock')),
    h('h1', { class: 'lock__title', text: setup ? t('lock.setup.title') : t('lock.unlock.title') }),
    h('p', { class: 'lock__hint', text: setup ? t('lock.setup.hint') : t('lock.unlock.hint') }),
    form,
  );

  root.appendChild(h('div', { class: 'lock' }, card));
  makeGlass(card);
  input.focus();

  let busy = false;

  async function onSubmit(e: Event): Promise<void> {
    e.preventDefault();
    if (busy) return;
    const pin = input.value.trim();
    if (!/^\d{6,}$/.test(pin)) {
      error.textContent = t('lock.tooShort');
      return;
    }

    busy = true;
    submit.textContent = t('lock.working');
    error.textContent = '';

    try {
      const path = setup ? '/api/session/setup' : '/api/session/unlock';
      const res = await api.post<{ token?: string; error?: string; retryAfterMs?: number }>(path, { pin });
      if (res.token) {
        setToken(res.token);
        onUnlocked();
        return;
      }
      error.textContent = res.error ?? t('lock.wrong');
    } catch (err) {
      const e2 = err as { status?: number; message?: string };
      if (e2.status === 401) {
        // The server sends the delay; show it rather than a scary counter.
        const state = await api.get<SessionState>('/api/state').catch(() => null);
        const wait = Math.ceil((state?.retryAfterMs ?? 0) / 1000);
        error.textContent = wait > 0 ? t('lock.wait', { seconds: wait }) : t('lock.wrong');
      } else {
        error.textContent = e2.message ?? t('common.error');
      }
    } finally {
      busy = false;
      submit.textContent = setup ? t('lock.setup.action') : t('lock.unlock.action');
      input.select();
    }
  }
}
