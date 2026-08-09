import { api, onMutation, setToken } from './api.ts';
import type {
  Bootstrap,
  GalleryItem,
  HistoryDay,
  RegistryData,
  SessionState,
  ThingDetail,
  ThingSummary,
} from './api.ts';

/**
 * Application state.
 *
 * One store, one event, explicit reloads. The app is small enough that a
 * re-render on change is cheaper to reason about than fine-grained reactivity,
 * and the DOM cost is trivial next to the backdrop-filter budget.
 */

export type Route =
  | { kind: 'query'; query: string; title: string }
  | { kind: 'collection'; id: string; title: string; smartQuery: string | null }
  | { kind: 'gallery' }
  | { kind: 'trash' }
  | { kind: 'settings' }
  | { kind: 'conflicts' }
  | { kind: 'history'; thingId: string };

export interface AppState {
  session: SessionState | null;
  registry: RegistryData | null;
  bootstrap: Bootstrap | null;
  route: Route;
  list: ThingSummary[];
  loadingList: boolean;
  selection: Set<string>;
  currentId: string | null;
  current: ThingDetail | null;
  gallery: GalleryItem[];
  history: HistoryDay[];
  /** Field ids whose secret is currently on screen. */
  revealed: Set<string>;
  /** The revealed plaintext, in memory only, cleared on lock and on a timer. */
  revealedValues: Map<string, string>;
  lastFocusedFieldId: string | null;
  /** Mirrors the server's undo stack; updated optimistically on every write. */
  undo: { canUndo: boolean; canRedo: boolean };
}

type Listener = () => void;

export const state: AppState = {
  session: null,
  registry: null,
  bootstrap: null,
  route: { kind: 'query', query: '', title: 'All Things' },
  list: [],
  loadingList: false,
  selection: new Set(),
  currentId: null,
  current: null,
  gallery: [],
  history: [],
  revealed: new Set(),
  revealedValues: new Map(),
  lastFocusedFieldId: null,
  undo: { canUndo: false, canRedo: false },
};

// A write happened somewhere: Undo becomes available and Redo is invalidated,
// exactly as the oplog does server-side.
onMutation(() => {
  state.undo = { canUndo: true, canRedo: false };
  notify();
});

const listeners = new Set<Listener>();

export function subscribe(fn: Listener): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function notify(): void {
  for (const fn of listeners) fn();
}

// ── loading ─────────────────────────────────────────────────────────────────

export async function loadSession(): Promise<SessionState> {
  state.session = await api.get<SessionState>('/api/state');
  document.documentElement.dataset.privacy = state.session.privacyMode ? 'on' : 'off';
  return state.session;
}

export async function loadShell(): Promise<void> {
  const [registry, bootstrap] = await Promise.all([
    api.get<RegistryData>('/api/registry'),
    api.get<Bootstrap>('/api/bootstrap'),
  ]);
  state.registry = registry;
  state.bootstrap = bootstrap;
  state.undo = bootstrap.undo;
}

export async function refreshBootstrap(): Promise<void> {
  state.bootstrap = await api.get<Bootstrap>('/api/bootstrap');
  state.undo = state.bootstrap.undo;
  notify();
}

export function routeQuery(route: Route): string {
  switch (route.kind) {
    case 'query':
      return route.query;
    case 'collection':
      return route.smartQuery ?? '';
    case 'trash':
      return 'is:trashed';
    case 'gallery':
      return 'type:image';
    default:
      return '';
  }
}

export async function loadList(): Promise<void> {
  const route = state.route;
  if (route.kind === 'settings' || route.kind === 'conflicts' || route.kind === 'history') return;

  state.loadingList = true;
  notify();

  const params = new URLSearchParams();
  params.set('q', routeQuery(route));
  if (route.kind === 'collection' && !route.smartQuery) params.set('collection', route.id);
  if (route.kind === 'trash') params.set('trashed', '1');

  try {
    const res = await api.get<{ things: ThingSummary[] }>(`/api/things?${params}`);
    state.list = res.things;
  } finally {
    state.loadingList = false;
    notify();
  }
}

export async function openThing(id: string | null): Promise<void> {
  state.currentId = id;
  state.revealed.clear();
  state.revealedValues.clear();
  if (!id) {
    state.current = null;
    notify();
    return;
  }
  state.current = await api.get<ThingDetail>(`/api/things/${id}`);
  notify();
  void api.post(`/api/things/${id}/view`).catch(() => undefined);
}

export async function reloadCurrent(): Promise<void> {
  if (!state.currentId) return;
  state.current = await api.get<ThingDetail>(`/api/things/${state.currentId}`);
  notify();
}

export async function loadGallery(): Promise<void> {
  const res = await api.get<{ items: GalleryItem[] }>('/api/gallery');
  state.gallery = res.items;
  notify();
}

export async function loadHistory(thingId: string): Promise<void> {
  const res = await api.get<{ days: HistoryDay[] }>(`/api/things/${thingId}/history`);
  state.history = res.days;
  notify();
}

export async function navigate(route: Route): Promise<void> {
  state.route = route;
  state.selection.clear();
  notify();
  if (route.kind === 'gallery') await loadGallery();
  if (route.kind === 'history') await loadHistory(route.thingId);
  await loadList();
}

export async function lock(): Promise<void> {
  await api.post('/api/session/lock').catch(() => undefined);
  setToken(null);
  state.current = null;
  state.currentId = null;
  state.list = [];
  await loadSession();
  notify();
}

export function variant(id: string | null | undefined) {
  if (!id || !state.registry) return undefined;
  return state.registry.variants.find((v) => v.id === id);
}

export function variantsForPicker() {
  return state.registry?.variants ?? [];
}
