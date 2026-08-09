/**
 * The API client.
 *
 * Same-origin only — the server binds loopback and its CSP says
 * `connect-src 'self'`, so there is nowhere else to talk to. The bearer token
 * lives in memory and in sessionStorage, never localStorage: closing the tab
 * should end the session, which is exactly what docs/02-SECURITY.md §6 asks
 * for ("also on tab close").
 */

const TOKEN_KEY = 'things.token';

let token: string | null = sessionStorage.getItem(TOKEN_KEY);
const lockListeners = new Set<() => void>();
const mutationListeners = new Set<() => void>();

/**
 * Anything that wrote is a candidate for Undo. The toolbar listens to this
 * rather than re-fetching /api/bootstrap after every keystroke — the server is
 * the authority, but the button should light up immediately.
 */
export function onMutation(fn: () => void): void {
  mutationListeners.add(fn);
}

/**
 * POST does not always mean "wrote something the user could undo". Marking a
 * Thing as viewed and revealing a secret are both POSTs and neither belongs in
 * the undo stack — treating them as writes made Redo unreachable, because
 * opening a Thing invalidated it.
 */
const NON_MUTATING_POSTS = [/^\/api\/session/, /^\/api\/undo/, /^\/api\/redo/, /\/view$/, /\/reveal$/];

function isMutation(method: string, path: string): boolean {
  if (method === 'GET') return false;
  return !NON_MUTATING_POSTS.some((re) => re.test(path));
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function setToken(next: string | null): void {
  token = next;
  if (next) sessionStorage.setItem(TOKEN_KEY, next);
  else sessionStorage.removeItem(TOKEN_KEY);
}

export function hasToken(): boolean {
  return !!token;
}

export function onLocked(fn: () => void): void {
  lockListeners.add(fn);
}

async function request<T>(method: string, path: string, body?: unknown, isBinary = false): Promise<T> {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  let payload: BodyInit | undefined;
  if (body instanceof Blob || body instanceof ArrayBuffer || body instanceof Uint8Array) {
    payload = body as BodyInit;
  } else if (body !== undefined) {
    payload = JSON.stringify(body);
    headers['content-type'] = 'application/json';
  }

  const res = await fetch(path, { method, headers, body: payload });

  if (res.status === 423 || (res.status === 401 && token)) {
    setToken(null);
    for (const fn of lockListeners) fn();
  }

  if (isBinary) {
    if (!res.ok) throw new ApiError(res.status, res.statusText);
    if (isMutation(method, path)) for (const fn of mutationListeners) fn();
    return (await res.arrayBuffer()) as T;
  }

  const text = await res.text();
  const data = text ? (JSON.parse(text) as unknown) : null;
  if (!res.ok) {
    const message = (data as { error?: string } | null)?.error ?? res.statusText;
    throw new ApiError(res.status, message);
  }
  if (isMutation(method, path)) for (const fn of mutationListeners) fn();
  return data as T;
}

export const api = {
  get: <T>(path: string) => request<T>('GET', path),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body),
  patch: <T>(path: string, body?: unknown) => request<T>('PATCH', path, body),
  del: <T>(path: string) => request<T>('DELETE', path),
  upload: <T>(path: string, bytes: ArrayBuffer | Blob) => request<T>('POST', path, bytes),
};

// ── wire types ──────────────────────────────────────────────────────────────

export interface SessionState {
  provisioned: boolean;
  locked: boolean;
  privacyMode: boolean;
  autoLockMs: number;
  lockedInMs: number | null;
  deviceWrapper: string;
  failedAttempts: number;
  retryAfterMs: number;
  deviceName: string;
}

export interface ThingSummary {
  id: string;
  title: string;
  icon: IconSpec | null;
  isPinned: boolean;
  isLocked: boolean;
  isArchived: boolean;
  updatedAt: string;
  createdAt: string;
  deletedAt: string | null;
  subtitle: string;
  markers: string[];
  tags: string[];
  coverObject: string | null;
  fieldCount: number;
}

export interface IconSpec {
  type: 'symbol' | 'emoji' | 'object' | 'auto';
  value?: string;
  tint?: string;
}

export interface FieldView {
  id: string;
  sectionId: string | null;
  sortOrder: number;
  kind: string;
  variant: string | null;
  label: string;
  isSecret: boolean;
  hasValue: boolean;
  text: string | null;
  json: unknown;
  objectHash: string | null;
  object: { hash: string; byteSize: number; mimeType: string | null; width: number | null; height: number | null } | null;
  fileRef: {
    id: string;
    path: string;
    deviceId: string;
    deviceName: string;
    isDirectory: boolean;
    status: string;
    isThisDevice: boolean;
  } | null;
  symbol: string;
  actions: string[];
  marker: string | null;
  gallery: boolean;
  updatedAt: string;
}

export interface ThingDetail {
  id: string;
  title: string;
  icon: IconSpec | null;
  coverObject: string | null;
  isPinned: boolean;
  isLocked: boolean;
  isArchived: boolean;
  isTemplate: boolean;
  createdAt: string;
  updatedAt: string;
  tags: { id: string; name: string; color: string | null }[];
  collections: { id: string; name: string }[];
  sections: { id: string; title: string | null; sortOrder: number }[];
  fields: FieldView[];
  backlinks: { id: string; title: string }[];
  markers: string[];
}

export interface CollectionView {
  id: string;
  name: string;
  icon: IconSpec | null;
  isSmart: boolean;
  isSystem: boolean;
  smartQuery: string | null;
  count: number;
}

export interface TagView {
  id: string;
  name: string;
  color: string | null;
  count: number;
}

export interface TemplateView {
  id: string;
  name: string;
  symbol: string;
  builtin: boolean;
}

export interface Bootstrap {
  device: { id: string; name: string } | null;
  collections: CollectionView[];
  tags: TagView[];
  counts: { all: number; pinned: number; trash: number; templates: number; conflicts: number; objects: number };
  templates: TemplateView[];
  undo: { canUndo: boolean; canRedo: boolean };
}

export interface RegistryVariant {
  id: string;
  kind: string;
  label: string;
  symbol: string;
  actions: string[];
  marker?: string;
  gallery?: boolean;
  validate?: string;
  max?: number;
}

export interface RegistryData {
  version: number;
  kinds: Record<string, { storage: string; multiline?: boolean; alwaysSecret?: boolean }>;
  actions: Record<string, { label: string; gated?: boolean; deviceScoped?: boolean }>;
  variants: RegistryVariant[];
  templates: { id: string; name: string; symbol: string }[];
  smartViews: { id: string; name: string; symbol: string; query: string }[];
}

export interface HistoryDay {
  date: string;
  changes: {
    id: string;
    hlc: string;
    appliedAt: string;
    entityType: string;
    entityId: string;
    op: string;
    attrs: string[];
    summary: string;
    canRestore: boolean;
  }[];
}

export interface GalleryItem {
  fieldId: string;
  thingId: string;
  thingTitle: string;
  label: string;
  hash: string;
  byteSize: number;
  mimeType: string | null;
  width: number | null;
  height: number | null;
  updatedAt: string;
}
