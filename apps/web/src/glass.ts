/**
 * The glass engine — candidate E from tools/glass-lab, as ONE primitive.
 *
 * Everything visual lives in styles/glass.css. This file only does the three
 * things CSS cannot:
 *
 *   1. generate the rounded-rect SDF displacement map, per element size;
 *   2. build the three-pass chromatic-dispersion SVG filter and keep its
 *      region and map in sync on resize (NOTES.md gotchas 5, 6, 7);
 *   3. track the pointer for the specular glint and the press ramp.
 *
 * Tiering is decided once, here, and expressed as one attribute on <html>.
 */

const NS = 'http://www.w3.org/2000/svg';
const MARGIN = 80; // filter-region inflation; without it the rim gets a dark fringe
const MAX_LIVE_SURFACES = 10; // NOTES.md §4: cap live glass per view

export type GlassTier = 'full' | 'standard' | 'lite' | 'flat';

let tier: GlassTier = 'standard';
let defs: SVGDefsElement | null = null;
let uid = 0;
const mapCache = new Map<string, string>();
const surfaces: Surface[] = [];
let reducedMotion = false;

interface Surface {
  el: HTMLElement;
  bd: HTMLElement;
  id: string;
  displacements: { node: SVGElement; k: number }[];
  filter: SVGFilterElement;
  image: SVGElement;
  w: number;
  h: number;
  r: number;
  boost: number;
}

/** Chromium is the only engine that honours url(#…) inside backdrop-filter.
 *  There is no feature query for it: CSS.supports() returns true everywhere.
 *  Tracked as w3c/svgwg#1142. */
function supportsSvgBackdrop(): boolean {
  const ua = navigator.userAgent;
  return /Chrome\/|Chromium\/|Edg\//.test(ua) && !/OPT\//.test(ua);
}

function detectTier(): GlassTier {
  if (window.matchMedia('(prefers-reduced-transparency: reduce)').matches) return 'flat';
  if (!CSS.supports('backdrop-filter', 'blur(1px)') && !CSS.supports('-webkit-backdrop-filter', 'blur(1px)')) {
    return 'flat';
  }
  // Coarse low-power heuristic. Refined at runtime by the frame budget below.
  if ((navigator.hardwareConcurrency ?? 8) <= 4) return 'lite';
  return supportsSvgBackdrop() ? 'full' : 'standard';
}

export function currentTier(): GlassTier {
  return tier;
}

export function initGlass(): void {
  defs = document.querySelector('#glass-defs defs');
  reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  setTier(detectTier());

  const transparency = window.matchMedia('(prefers-reduced-transparency: reduce)');
  transparency.addEventListener('change', () => setTier(detectTier()));
  window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', (e) => {
    reducedMotion = e.matches;
  });

  if (!reducedMotion) attachPointerTracking();
  watchFrameBudget();
}

function setTier(next: GlassTier): void {
  tier = next;
  document.documentElement.dataset.glass = next;
  for (const s of surfaces) applyFilter(s);
}

/**
 * Turn an element into a glass surface. It must already contain a
 * `.tg-content` child; the five effect layers are inserted before it.
 */
export function makeGlass(el: HTMLElement, opts: { radius?: number } = {}): void {
  el.classList.add('tg-glass');
  if (opts.radius !== undefined) el.style.setProperty('--glass-r', `${opts.radius}px`);

  if (!el.querySelector(':scope > .tg-bd')) {
    const layers = document.createDocumentFragment();
    for (const cls of ['tg-bd', 'tg-rim', 'tg-tint', 'tg-spec', 'tg-edge']) {
      const d = document.createElement('div');
      d.className = `tg-l ${cls}`;
      layers.appendChild(d);
    }
    el.insertBefore(layers, el.firstChild);
  }

  if (surfaces.length >= MAX_LIVE_SURFACES) return; // budget, NOTES.md §4
  const bd = el.querySelector<HTMLElement>(':scope > .tg-bd');
  if (!bd) return;

  const id = `tg-refract-${++uid}`;
  const built = buildFilter(id);
  if (!built) return;

  const surface: Surface = { el, bd, id, ...built, w: 0, h: 0, r: 0, boost: 1 };
  surfaces.push(surface);
  measure(surface);

  const ro = new ResizeObserver(() => {
    clearTimeout(resizeTimers.get(surface));
    resizeTimers.set(
      surface,
      window.setTimeout(() => measure(surface), 90),
    );
  });
  ro.observe(el);
}

const resizeTimers = new WeakMap<Surface, number>();

export function destroyGlass(el: HTMLElement): void {
  const i = surfaces.findIndex((s) => s.el === el);
  if (i === -1) return;
  surfaces[i].filter.remove();
  surfaces.splice(i, 1);
}

/** Drop every registered surface — called when a whole screen is replaced. */
export function resetGlass(): void {
  for (const s of surfaces.splice(0)) s.filter.remove();
}

// ── the SVG filter ──────────────────────────────────────────────────────────

function svg(tag: string, attrs: Record<string, string | number>): SVGElement {
  const n = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'href') {
      n.setAttributeNS(null, 'href', String(v));
      n.setAttribute('xlink:href', String(v));
    } else n.setAttribute(k, String(v));
  }
  return n;
}

function buildFilter(id: string): Pick<Surface, 'displacements' | 'filter' | 'image'> | null {
  if (!defs) return null;

  // color-interpolation-filters="sRGB" is MANDATORY: the linearRGB default
  // re-encodes the map's channel values and the offsets come out wrong by a
  // gamma curve. NOTES.md gotcha 5.
  const filter = svg('filter', {
    id,
    filterUnits: 'userSpaceOnUse',
    primitiveUnits: 'userSpaceOnUse',
    'color-interpolation-filters': 'sRGB',
    x: -MARGIN,
    y: -MARGIN,
    width: 100 + 2 * MARGIN,
    height: 100 + 2 * MARGIN,
  }) as SVGFilterElement;

  const image = svg('feImage', {
    x: 0,
    y: 0,
    width: 100,
    height: 100,
    preserveAspectRatio: 'none',
    result: 'map',
    href: '',
  });
  filter.appendChild(image);

  // Chromatic dispersion: a different refractive index per wavelength, so the
  // rim picks up a faint warm/cool split. Subliminal on its own; removing it
  // takes the rim from "glass" to "smear".
  const channels = [
    { k: 1.065, matrix: '1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0', out: 'cR' },
    { k: 1.0, matrix: '0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0', out: 'cG' },
    { k: 0.935, matrix: '0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0', out: 'cB' },
  ];

  const displacements: { node: SVGElement; k: number }[] = [];
  channels.forEach((c, i) => {
    const dm = svg('feDisplacementMap', {
      in: 'SourceGraphic',
      in2: 'map',
      scale: 0,
      xChannelSelector: 'R',
      yChannelSelector: 'G',
      result: `d${i}`,
    });
    filter.appendChild(dm);
    displacements.push({ node: dm, k: c.k });
    filter.appendChild(svg('feColorMatrix', { in: `d${i}`, type: 'matrix', values: c.matrix, result: c.out }));
  });
  filter.appendChild(
    svg('feComposite', { in: 'cR', in2: 'cG', operator: 'arithmetic', k1: 0, k2: 1, k3: 1, k4: 0, result: 'cRG' }),
  );
  filter.appendChild(svg('feComposite', { in: 'cRG', in2: 'cB', operator: 'arithmetic', k1: 0, k2: 1, k3: 1, k4: 0 }));

  defs.appendChild(filter);
  return { displacements, filter, image };
}

/**
 * The displacement map. R and G encode a 2-D offset:
 *   byte 128 → 0.5 → zero displacement
 *   feDisplacementMap samples P(x + s·(R − 0.5), y + s·(G − 0.5))
 *
 * The vector is the OUTWARD normal of a rounded-rect signed distance field,
 * scaled by a convex-lens slope term that is ~0 across the face and saturates
 * in the last few px before the edge. Sampling outward at the rim pulls
 * content from *outside* the shape inward — the squeezed band that reads as
 * glass thickness, and the one property that makes this an object rather than
 * a translucent rectangle.
 */
function buildMap(w: number, h: number, radius: number, bevel: number): string {
  const W = Math.max(4, Math.round(w));
  const H = Math.max(4, Math.round(h));
  const R = Math.min(radius, Math.min(W, H) / 2);
  const B = Math.max(2, Math.min(bevel, Math.min(W, H) / 2.2));
  const key = `${W}x${H}r${R.toFixed(1)}b${B.toFixed(1)}`;
  const cached = mapCache.get(key);
  if (cached) return cached;

  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d');
  if (!ctx) return '';
  const img = ctx.createImageData(W, H);
  const d = img.data;

  const cx = W / 2;
  const cy = H / 2;
  const hx = W / 2;
  const hy = H / 2;

  const sdf = (x: number, y: number): number => {
    const qx = Math.abs(x - cx) - (hx - R);
    const qy = Math.abs(y - cy) - (hy - R);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - R;
  };

  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const px = x + 0.5;
      const py = y + 0.5;
      const s = sdf(px, py);
      const i = (y * W + x) * 4;
      let dx = 0;
      let dy = 0;

      if (s < 0) {
        const t = Math.min(1, -s / B); // 0 at rim, 1 past the bevel
        const u = 1 - t;
        const slope = u / Math.sqrt(Math.max(1e-3, 1 - u * u)); // circular-arc cross-section
        const amt = Math.min(1, slope * 0.5);
        if (amt > 0) {
          const gx = sdf(px + 1, py) - sdf(px - 1, py);
          const gy = sdf(px, py + 1) - sdf(px, py - 1);
          const gl = Math.hypot(gx, gy) || 1;
          dx = (gx / gl) * amt;
          dy = (gy / gl) * amt;
        }
      }

      d[i] = 128 + Math.round(Math.max(-1, Math.min(1, dx)) * 127);
      d[i + 1] = 128 + Math.round(Math.max(-1, Math.min(1, dy)) * 127);
      d[i + 2] = 128;
      d[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  const url = canvas.toDataURL();
  mapCache.set(key, url);
  return url;
}

function measure(s: Surface): void {
  const rect = s.el.getBoundingClientRect();
  const w = Math.round(rect.width);
  const h = Math.round(rect.height);
  if (!w || !h) return;
  const cs = getComputedStyle(s.el);
  const r = Math.min(parseFloat(cs.borderTopLeftRadius) || 0, Math.min(w, h) / 2);
  if (w === s.w && h === s.h && r === s.r) return;

  s.w = w;
  s.h = h;
  s.r = r;

  s.filter.setAttribute('width', String(w + 2 * MARGIN));
  s.filter.setAttribute('height', String(h + 2 * MARGIN));
  s.image.setAttribute('width', String(w));
  s.image.setAttribute('height', String(h));

  const bevel = Math.max(8, Math.min(28, Math.min(w, h) * 0.22));
  const url = buildMap(w, h, r, bevel);
  if (url) {
    s.image.setAttributeNS(null, 'href', url);
    s.image.setAttribute('xlink:href', url);
  }
  applyFilter(s);
}

function applyFilter(s: Surface): void {
  const style = getComputedStyle(document.documentElement);
  const num = (name: string, fallback: number) => parseFloat(style.getPropertyValue(name)) || fallback;

  const refract = num('--glass-refract', 48) * s.boost;
  for (const d of s.displacements) d.node.setAttribute('scale', (refract * d.k).toFixed(2));

  if (tier !== 'full') {
    // The CSS already carries the correct chain for standard / lite / flat.
    s.bd.style.removeProperty('backdrop-filter');
    s.bd.style.removeProperty('-webkit-backdrop-filter');
    return;
  }

  const chain =
    `url(#${s.id}) blur(${num('--glass-blur', 11)}px) ` +
    `contrast(${(1 - num('--glass-adapt', 0.24) * 0.9).toFixed(3)}) ` +
    `brightness(${num('--glass-bright', 1.06)}) saturate(${num('--glass-sat', 1.85)})`;
  s.bd.style.setProperty('backdrop-filter', chain);
  s.bd.style.setProperty('-webkit-backdrop-filter', chain);
}

// ── pointer response ────────────────────────────────────────────────────────

function attachPointerTracking(): void {
  const boost = (el: HTMLElement, value: number) => {
    const s = surfaces.find((x) => x.el === el);
    if (!s) return;
    s.boost = value;
    applyFilter(s);
  };

  document.addEventListener(
    'pointermove',
    (e) => {
      const el = (e.target as HTMLElement | null)?.closest<HTMLElement>('.tg-glass');
      if (!el) return;
      const r = el.getBoundingClientRect();
      el.style.setProperty('--px', `${(((e.clientX - r.left) / r.width) * 100).toFixed(1)}%`);
      el.style.setProperty('--py', `${(((e.clientY - r.top) / r.height) * 100).toFixed(1)}%`);
    },
    { passive: true },
  );

  document.addEventListener(
    'pointerover',
    (e) => {
      const el = (e.target as HTMLElement | null)?.closest<HTMLElement>('.tg-glass');
      if (el) {
        el.classList.add('is-hover');
        boost(el, 1.14);
      }
    },
    { passive: true },
  );

  document.addEventListener(
    'pointerout',
    (e) => {
      const el = (e.target as HTMLElement | null)?.closest<HTMLElement>('.tg-glass');
      if (el && !el.contains(e.relatedTarget as Node | null)) {
        el.classList.remove('is-hover', 'is-press');
        el.style.setProperty('--px', '50%');
        el.style.setProperty('--py', '0%');
        boost(el, 1);
      }
    },
    { passive: true },
  );

  document.addEventListener(
    'pointerdown',
    (e) => {
      const el = (e.target as HTMLElement | null)?.closest<HTMLElement>('.tg-glass');
      if (el) {
        el.classList.add('is-press');
        boost(el, 1.38);
      }
    },
    { passive: true },
  );

  document.addEventListener(
    'pointerup',
    () => {
      for (const el of document.querySelectorAll<HTMLElement>('.tg-glass.is-press')) {
        el.classList.remove('is-press');
        boost(el, el.classList.contains('is-hover') ? 1.14 : 1);
      }
    },
    { passive: true },
  );
}

/**
 * Rolling frame-time budget. Glass over a long scrolling list re-snapshots the
 * backdrop every frame; if that starts costing real time, drop a tier rather
 * than ship a janky window. One attribute change, because everything is
 * custom-property driven.
 */
function watchFrameBudget(): void {
  if (tier === 'flat' || tier === 'lite') return;
  let last = performance.now();
  let slow = 0;
  let samples = 0;

  const tick = (now: number) => {
    const dt = now - last;
    last = now;
    samples++;
    if (dt > 32) slow++;
    if (samples >= 180) {
      if (slow > 45) {
        setTier('lite');
        return;
      }
      samples = 0;
      slow = 0;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
