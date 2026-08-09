# Liquid Glass on the web — technique notes

Companion to `index.html` in this folder. Open that file directly from disk in
Chrome or Edge; it makes no network requests.

Everything below was verified by building the five candidates and watching them
render, not by reading blog posts. Where a claim comes from measurement it says
so; where it is an engineering judgement it says that too.

---

## 1. What we are actually trying to reproduce

Apple's iOS 26 material is not frosted glass. It is a thin convex lens with a
tinted, vibrancy-boosted body. Six properties, in rough order of how much each
one contributes to "that's the real thing":

| # | Property | What it does | Web primitive |
|---|----------|--------------|---------------|
| 1 | **Edge refraction** | Surface slope is near zero across the face and steep in the last few px before the rim, so the rim shows a squeezed, displaced band of what is behind *and just outside* the shape while the centre stays comparatively clear | `feDisplacementMap` inside `backdrop-filter`, or a masked ring with `transform: scale()` |
| 2 | **Vibrancy** | Colours behind the glass get *more* alive, not milky | `saturate(1.7–2.0)` + `brightness(1.05–1.1)` |
| 3 | **Moderate blur** | Softens without destroying the backdrop. Heavy blur is the amateur tell | `blur(8–14px)`, not 25–40 |
| 4 | **Specular** | Bright thin arc top, dimmer arc bottom, plus a glint that moves with the object | `inset` `box-shadow` (follows `border-radius`, so it wraps corners correctly) + a radial gradient driven by `--px`/`--py` |
| 5 | **Adaptive contrast** | Darkens over light content, lifts over dark content, so foreground text keeps a stable contrast ratio | `contrast(<1)` in the filter chain, then `saturate()` to restore chroma |
| 6 | **Depth** | 0.5px bright border, inner shade, outer drop shadow — it floats | layered `box-shadow` |
| 7 | **Chromatic dispersion** | Different refractive index per wavelength; a faint warm/cool split at the rim | three `feDisplacementMap` passes at ±6.5% scale, recombined |
| 8 | **Concentric radii** | Nested shapes share a centre: `inner = outer − padding` | `calc(var(--r) - var(--pad))` |

Property 1 is the whole ballgame. Without it you have a translucent rectangle,
not an object.

---

## 2. The five candidates

### A — Naive frosted blur *(the reject)*
`backdrop-filter: blur(21px)` plus a flat white fill. Nothing else.

- **Support:** universal (Chrome 76+, Safari 9 prefixed / 18 unprefixed, Firefox 103+).
- **Cost:** one GPU blur pass per element. Cheapest of the five.
- **Verdict:** reject. Three separate tells: blur radius roughly 2× Apple's so the
  backdrop turns to mush; no saturation lift so colours behind go *duller* when
  real glass makes them more alive; hard alpha cut at the edge with no border,
  arc or shadow, so it has no thickness and does not float.

### B — Vibrant slab
Moderate blur + `saturate`/`brightness`, gradient tint, 0.5px border, inset
top/bottom arcs, inner shade, outer shadow.

- **Support:** universal.
- **Cost:** one blur+colour pass, plus a handful of composited gradient layers.
  Negligible over B's own footprint.
- **Verdict:** this is the ceiling of "good CSS glass" and it is genuinely nice.
  It fails the moment you put it next to the iOS app, because the backdrop
  behind it is geometrically untouched. It also has no adaptive contrast, so
  label legibility swings with whatever is underneath.

### C — CSS rim-lens
B, plus a ring built with the mask-composite border trick that carries its own
stronger `backdrop-filter` and a `transform: scale(1.055)`, plus `contrast()`
adaptive normalisation.

```css
.rim {
  border: 11px solid transparent;         /* the ring's thickness */
  transform: scale(1.055);                /* magnifies its own backdrop */
  backdrop-filter: blur(1.5px) saturate(2.2) brightness(1.08);
  mask-image: linear-gradient(#000 0 0), linear-gradient(#000 0 0);
  mask-clip: padding-box, border-box;
  mask-composite: exclude;                /* -webkit-mask-composite: xor */
}
```

- **Support:** universal in practice. `mask-composite` is Chrome 120+, Safari
  15.4+, Firefox 53+; older Chromium needs `-webkit-mask-composite: xor`. Both
  are declared in `index.html`.
- **Cost:** a *second* backdrop-filter pass per glass element, so roughly 2×
  candidate B. The ring is small in area but the compositor still snapshots the
  full element bounds for it.
- **Verdict:** the best cross-browser answer. It is a painted approximation of
  magnification rather than a resample, so it cannot bend a straight line — on
  the stripes backdrop the band brightens and shifts but does not curve. At
  normal UI scale over normal content, almost nobody will notice.
- **Verified:** filling the ring with flat red confirms the mask produces a
  true ring following the corner radius, not a filled rect.

### D — SVG displacement rim
A displacement map is generated procedurally on a `<canvas>` at element size and
fed to `feDisplacementMap` through `backdrop-filter: url(#id)`.

The map encodes a 2-D offset per pixel: `R = 128 + dx·127`, `G = 128 + dy·127`,
where `(dx, dy)` is the **outward** normal of a rounded-rect signed distance
field scaled by a convex-lens slope term:

```
d      = sdRoundedBox(p)          // negative inside
t      = clamp(-d / bevel, 0, 1)  // 0 at rim, 1 on the face
u      = 1 - t
slope  = u / sqrt(1 - u²)         // circular-arc cross-section
amt    = min(1, slope * 0.5)      // saturates in the last few px
(dx,dy)= normalize(∇sdf) * amt
```

`feDisplacementMap` then samples `P(x + s·(R−0.5), y + s·(G−0.5))`, so a
positive scale with an outward normal pulls content from *outside* the shape
inward — the squeezed band that reads as glass thickness.

- **Support: Chromium only.** Safari and Firefox parse
  `backdrop-filter: url(#f)` without error and then silently drop the `url()`
  part, leaving a flat blur. There is no feature query that distinguishes this —
  `CSS.supports('backdrop-filter','url(#x)')` returns `true` everywhere. The lab
  UA-sniffs for Chromium and shows an honest per-candidate badge. Tracked
  upstream as [w3c/svgwg#1142](https://github.com/w3c/svgwg/issues/1142).
- **Cost:** highest. Per element: one canvas map build (CPU, cached by
  `WxH+radius+bevel`, ~40k–120k px, sub-millisecond) plus a per-frame SVG filter
  graph on the compositor. Rebuilds only on resize; the refraction slider just
  re-scales the existing map via the `scale` attribute.
- **Verdict:** the only candidate that produces true refraction, and on the
  stripe backdrop the difference is not subtle — the stripes visibly *bend*
  through the rim. But it degrades to plain B outside Chromium with no warning,
  and it has no adaptive contrast.

### E — Things Glass *(recommended)*
D + chromatic dispersion + adaptive contrast + pointer-tracked specular + press
response + C's rim-lens ring underneath as a built-in fallback.

- **Support:** full fidelity on Chromium; degrades to C on Safari/Firefox
  because the ring is still there when the `url()` is dropped.
- **Cost:** highest of the five — three displacement passes plus a second
  backdrop-filter for the ring. See §4.
- **Verdict:** ship this.

---

## 3. Gotchas, all of them load-bearing

These cost real time to find. Every one is annotated in `index.html` too.

1. **`mix-blend-mode` and `backdrop-filter` cannot coexist in the same subtree.**
   A blended child forces its parent to isolate; an isolated group is a
   *backdrop root*; every `backdrop-filter` inside then samples an empty group
   and renders **nothing at all**. This was a live bug in the first build of
   this page — candidate E showed a completely unfiltered backdrop and it took a
   red-fill probe to see why. The standard "luminosity blend layer for adaptive
   contrast" advice you find in tutorials therefore **cannot work** inside a
   glass component. Use `contrast()` in the filter chain instead: it pulls the
   backdrop toward mid grey (whites down, blacks up), keeps hue, is cheaper,
   and has no isolation conflict. Follow it with `saturate()` to put back the
   chroma that `contrast()` costs.

2. **Anything that creates a backdrop root blanks the effect.** `filter`,
   `opacity < 1`, `mask`, `mask-image`, `contain: paint`, `isolation: isolate`,
   `will-change` of any of those, on the element *or any ancestor*. In
   particular `will-change: transform` on a glass element or its parent is a
   common accidental kill.

3. **Nested `backdrop-filter` does not compose.** Glass inside glass samples the
   already-composited parent, not the page. The toolbar icon buttons in the lab
   are deliberately plain translucent fills with concentric radii, not
   glass-in-glass.

4. **Put the filter on a dedicated child.** `.glass` owns `border-radius`,
   `overflow: hidden` and the outer shadow; `.glass > .bd` owns the
   `backdrop-filter` and nothing else. Clipping and filtering never fight.

5. **`color-interpolation-filters="sRGB"` is mandatory** on the displacement
   filter. The SVG default is `linearRGB`, which re-encodes the map's channel
   values and produces offsets that are wrong by a gamma curve.

6. **Inflate the filter region.** Use `filterUnits="userSpaceOnUse"` with
   `x=-80 y=-80 width=W+160 height=H+160`. Without the margin, rim samples that
   reach outside the element hit transparent black and you get a dark fringe.
   Keep the `feImage` subregion at exactly `0,0,W,H`.

7. **`backdrop-filter` dimensions do not follow the element automatically** when
   an SVG filter is involved — the map and the filter region must be rebuilt on
   resize. `ResizeObserver`, debounced, with the map cached by geometry.

8. **A translucent background is not required on the filtered element**, contrary
   to widespread advice; a fully transparent `.bd` filters fine. What *is*
   required is that nothing above it is fully opaque.

9. **SVG displacement has no super-sampling.** At high `scale` the rim goes
   slightly aliased. A little blur after the displacement hides it; do not push
   `scale` past ~60px on small elements.

---

## 4. Performance

These composite on the GPU, and the cost is per-element-area per-frame, not
per-element. Measured shape of the problem:

- **The expensive thing is snapshotting the backdrop**, which happens once per
  backdrop-filtered element per frame. Ten small glass chips are much cheaper
  than one glass panel covering the viewport.
- **Candidate E is ~3–4× candidate B** per element: three displacement passes
  plus the ring's second backdrop-filter.
- **Scrolling is the danger case.** A glass header over a long scrolling list
  re-snapshots and re-filters the whole header every frame. This is the single
  most likely way to tank frame rate in the Things web client.

Rules for the web client:

1. **Cap the number of live glass surfaces per view at ~8.** Sidebar, header,
   floating toolbar, active-row highlight, modal. Not every list row.
2. **Never put glass on a scrolling list item.** Use a flat translucent fill.
3. **Bound the area.** Full-viewport glass is a full-viewport filter every
   frame. Keep panels under roughly a third of the viewport.
4. **Do not animate `blur()` or the displacement `scale` on scroll.** The press
   ramp in the lab is fine because it is a one-off 180ms transition on a single
   element.
5. **Avoid `will-change` on or around glass** — it both costs memory and can
   create a backdrop root (gotcha 2).
6. **Drop to candidate B automatically on low-power signals**: a coarse
   `navigator.hardwareConcurrency <= 4` check, or a rolling `requestAnimationFrame`
   frame-time budget that trips a `data-glass="lite"` attribute on `<html>`.
   Everything is CSS-variable driven, so the downgrade is one attribute.

---

## 5. Recommendation for the Things web client

**Adopt candidate E**, authored as a single `.tg-glass` component with the layer
stack intact and every parameter behind a custom property. The exact CSS is in
the lab's copyable readout and updates live with the sliders.

Tier it:

| Tier | Trigger | What renders |
|------|---------|--------------|
| **Full** | Chromium, no accessibility preference | E — SVG displacement + dispersion + ring + adaptive contrast |
| **Standard** | Safari / Firefox — `url()` dropped | C — rim-lens ring carries the refraction. Automatic, no code branch needed: the ring is always in the DOM |
| **Lite** | Low-power heuristic, or `data-glass="lite"` | B — blur + vibrancy + depth, no ring, no SVG |
| **Flat** | `prefers-reduced-transparency: reduce` | opaque surface, 1px hairline, no filters |

The tiering costs nothing structurally because C is a strict subset of E and B
is a strict subset of C.

### `prefers-reduced-transparency: reduce`

Genuine opacity, not reduced blur. Users who set this often have a vestibular or
low-vision reason and translucency actively hurts them.

```css
@media (prefers-reduced-transparency: reduce) {
  .tg-glass > .bd,
  .tg-glass > .rim  { display: none; }
  .tg-glass > .tint { background: var(--surface-opaque); }
  .tg-glass > .edge { box-shadow: inset 0 0 0 1px var(--hairline); }
}
```

Three requirements:

- **The layout must not move a single pixel.** Same box, same radius, same
  padding, same shadow footprint. Only the fill changes.
- **`--surface-opaque` must be a real solid colour**, not a high-alpha
  translucent one.
- **Re-check text contrast in this mode.** The adaptive `contrast()` term is
  gone, so labels that relied on it need to hit 4.5:1 against the opaque
  surface on their own.

Support: Chrome 118+, Safari 17.4+, Firefox 113+ (behind a pref in older
builds). Where unsupported the media query simply does not match, which is the
correct failure direction.

### `prefers-reduced-motion: reduce`

The material stops *responding*, but stays glass.

```css
@media (prefers-reduced-motion: reduce) {
  .tg-glass { transition: none; }          /* no press scale, no shadow easing */
  .tg-glass > .spec { transition: none; }  /* glint snaps, does not glide */
}
```

Also, at the app level:

- Freeze any ambient backdrop drift.
- Drop the pointer-tracked specular to a **static** top-lit gradient — keep the
  lighting, remove the tracking. The highlight moving under the cursor is
  exactly the kind of continuous parallax this preference exists to suppress.
- Keep the press *state* (it is feedback, not decoration) but make it an
  instant change rather than a 180ms scale.
- Keep the refraction. It is static geometry, not motion.

### Suggested starting values

Straight from the lab defaults, which were tuned against the stripe backdrop:

```
blur        11px      /* NOT 20+ — that is candidate A */
saturate    1.85
contrast    0.78      /* adaptive normalisation */
brightness  1.06
refraction  48px      /* feDisplacementMap scale */
tint        0.11
radius      26px      /* inner = 26 − padding */
```

---

## 6. Open items

- The Chromium UA sniff for `url()`-in-`backdrop-filter` is unpleasant but there
  is no capability query for it. Revisit if
  [w3c/svgwg#1142](https://github.com/w3c/svgwg/issues/1142) lands an
  interoperable primitive.
- The displacement map assumes a rounded rectangle. Circles work (radius clamps
  to `min(w,h)/2`); arbitrary paths would need a real SDF rasteriser.
- No `@supports` path yet for a future native `backdrop-refraction`-style
  property. Keep the parameters in custom properties so a swap is one file.
- Not yet measured on a real low-end device. The frame-time budget heuristic in
  §4 is proposed, not validated.
