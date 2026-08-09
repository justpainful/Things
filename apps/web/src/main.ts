import './styles/reset.css';
import './styles/tokens.css';
import './styles/glass.css';
import './styles/app.css';

import { hasToken, onLocked, setToken } from './api.ts';
import { installDropTarget } from './dnd.ts';
import { initGlass } from './glass.ts';
import { setLocale, t } from './i18n/index.ts';
import { loadList, loadSession, loadShell, lock, notify, state } from './store.ts';
import { renderLock } from './views/lock.ts';
import { renderShell } from './views/shell.ts';
import { closeMenu } from './ui.ts';

/**
 * Entry point.
 *
 * Two screens: locked and unlocked. There is no router in the URL — the app is
 * a single local window and a URL would only be another place a Thing's title
 * could leak (into history, into a screenshot). Navigation lives in memory.
 */

const root = document.getElementById('app');
if (!root) throw new Error('missing #app');

setLocale('en');
initGlass();
installDropTarget();

onLocked(() => {
  setToken(null);
  void showLock();
});

window.addEventListener('things:lock', () => {
  void lock().then(showLock);
});

window.addEventListener('things:changed', () => notify());

// Closing the tab ends the session: sessionStorage goes with it, and the
// server's auto-lock timer takes care of the rest.
window.addEventListener('pagehide', () => closeMenu());

async function boot(): Promise<void> {
  const session = await loadSession();
  if (session.locked || !hasToken()) {
    renderLock(root!, session, () => void start());
    return;
  }
  await start();
}

async function start(): Promise<void> {
  try {
    await loadSession();
    await loadShell();
  } catch {
    await showLock();
    return;
  }
  renderShell(root!);
  await loadList();
  document.title = t('app.name');
}

async function showLock(): Promise<void> {
  const session = await loadSession();
  state.current = null;
  state.currentId = null;
  state.list = [];
  renderLock(root!, session, () => void start());
}

void boot();
