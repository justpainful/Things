/**
 * The entire "framework": a hyperscript helper and a few DOM utilities.
 *
 * No React, no virtual DOM, no component library — docs/03-DESIGN.md §7 lists
 * a framework-flavoured dashboard as an automatic rejection, and the app is
 * small enough that direct DOM is clearer than a re-render cycle.
 */

type Child = Node | string | number | null | undefined | false;

export interface Attrs {
  class?: string;
  id?: string;
  text?: string;
  html?: string;
  dataset?: Record<string, string>;
  style?: Partial<CSSStyleDeclaration> | Record<string, string>;
  on?: Record<string, EventListenerOrEventListenerObject>;
  [key: string]: unknown;
}

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') el.className = String(value);
    else if (key === 'text') el.textContent = String(value);
    else if (key === 'html') el.innerHTML = String(value);
    else if (key === 'dataset') Object.assign(el.dataset, value);
    else if (key === 'style') Object.assign(el.style, value);
    else if (key === 'on') {
      for (const [type, fn] of Object.entries(value as Record<string, EventListener>)) {
        el.addEventListener(type, fn);
      }
    } else if (key === 'value' && 'value' in el) {
      (el as unknown as { value: string }).value = String(value);
    } else if (value === true) el.setAttribute(key, '');
    else el.setAttribute(key, String(value));
  }
  append(el, children);
  return el;
}

export function append(parent: Node, children: Child[]): void {
  for (const child of children.flat(3) as Child[]) {
    if (child === null || child === undefined || child === false) continue;
    parent.appendChild(typeof child === 'object' ? child : document.createTextNode(String(child)));
  }
}

export function clear(el: Element): void {
  while (el.firstChild) el.removeChild(el.firstChild);
}

export function frag(...children: Child[]): DocumentFragment {
  const f = document.createDocumentFragment();
  append(f, children);
  return f;
}

/** Wrap content in the glass layer stack. `makeGlass` inserts the effect layers. */
export function glassBox(className: string, ...children: Child[]): HTMLDivElement {
  const content = h('div', { class: 'tg-content' }, ...children);
  return h('div', { class: className }, content);
}

export function on<T extends Event>(
  el: EventTarget,
  type: string,
  handler: (e: T) => void,
  opts?: AddEventListenerOptions,
): () => void {
  const fn = handler as EventListener;
  el.addEventListener(type, fn, opts);
  return () => el.removeEventListener(type, fn, opts);
}

export function copyText(text: string): Promise<void> {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  // http://localhost is a secure context in every current browser, but a
  // fallback costs three lines and removes a whole class of bug report.
  return new Promise((resolve) => {
    const ta = h('textarea', { style: { position: 'fixed', opacity: '0' } });
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand('copy');
    } finally {
      ta.remove();
      resolve();
    }
  });
}

/** Trap Tab inside a dialog, and restore focus when it closes. */
export function trapFocus(container: HTMLElement): () => void {
  const previous = document.activeElement as HTMLElement | null;
  const selector =
    'a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select, [tabindex]:not([tabindex="-1"])';

  const handler = (e: KeyboardEvent) => {
    if (e.key !== 'Tab') return;
    const focusable = [...container.querySelectorAll<HTMLElement>(selector)].filter(
      (el) => el.offsetParent !== null,
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  container.addEventListener('keydown', handler);
  return () => {
    container.removeEventListener('keydown', handler);
    previous?.focus?.();
  };
}
