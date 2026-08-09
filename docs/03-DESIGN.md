# Things — Design System

**North star:** on the home screen between Photos, Notes, and Files, Things should not look like a
third-party app that admires Apple. It should look like one of them.

That standard is unforgiving, and it is mostly won or lost on restraint.

---

## 0. Palette — LOCKED

**The reference is Messages in dark mode.** Not "a dark theme" — that specific look:

| | Value | Why exactly this |
|---|---|---|
| Canvas | **`#000000`** | True black, not `#0d0d0f`. Messages, Photos, and Music use pure black. A "soft black" is the tell of an app imitating the look instead of adopting it. |
| Elevated | `#1c1c1e` / `#2c2c2e` | Apple systemGray6 / systemGray5 dark |
| Primary text | `#ffffff` | |
| Secondary text | `rgba(235,235,245,0.60)` | **The alpha matters more than the hue.** 0.60 reads as iOS; 0.62 does not. |
| Tertiary text | `rgba(235,235,245,0.30)` | |
| Separators | `rgba(84,84,88,0.65)` | iOS separators are grey-*blue* with alpha, never pure white |
| Fills | `rgba(120,120,128,0.36 → 0.18)` | translucent grey, so chips sit correctly on glass too |
| Accent | `#0a84ff` systemBlue dark | **used sparingly** — links, focus ring, destructive confirm |
| Destructive | `#ff453a` systemRed dark | |

**Dark is the default, light is the override.** Not the other way round. Both `tokens.css` and
`glass.css` must agree on this — if one defaults to light, a browser with no colour preference
renders a black canvas with light-mode glass on top of it.

### Glass is WHITE, never tinted

Buttons and chrome are **white liquid glass**: `rgba(255,255,255,…)` fill, white specular arc,
white hairline rim. No blue glass, no accent-tinted glass, no coloured chrome.

Two consequences that are easy to get wrong:

1. **Selection is neutral, not accent-tinted.** `rgba(255,255,255,0.13)`, not a blue wash. A
   blue-tinted selected row is the single most common way a dark app stops looking like a system
   app.
2. **On a `#000` canvas there is nothing behind the glass to refract**, so the white fill is what
   carries the glass reading. `--glass-tint` runs higher in dark (0.14) than the light-mode value
   would suggest — the material has to look like a lit white lozenge while staying translucent.

### Anti-palette — automatic rejection

Blue-grey backgrounds (`#101116`, `#17191f`) · a generic blue accent used as a surface colour ·
accent-tinted selection · coloured glass · gradients on chrome · pure-white separators · any colour
value that is not an actual Apple system value.

## 1. The single most important rule about Liquid Glass

> **Glass is the navigation layer. Content is never glass.**

Apple's own apps use Liquid Glass on the floating controls that sit *above* content — tab bars,
toolbars, search fields, sheets, popovers, floating buttons. The content itself — list rows, text,
photos, form fields — stays on a normal, opaque surface.

The reliable tell of a third-party app trying too hard is glass everywhere: glass cards on a glass
background inside a glass sheet. It looks cheap, it destroys legibility, and it is exactly what
"just blur" means as an insult.

### Where glass goes in Things

| Surface | Glass | Notes |
|---|---|---|
| Tab bar (Things · Collections · Search) | ✅ system | never hand-rolled |
| Navigation / toolbar | ✅ system | |
| Floating **+** button | ✅ interactive | morphs open into the New Thing menu |
| Search field | ✅ system | |
| Command Palette (web ⌘K / Ctrl K) | ✅ prominent | the one deliberately dramatic surface |
| Context-menu previews, popovers, sheets | ✅ system | |
| Quick actions on long-press | ✅ system | |
| Field-value copy confirmation toast | ✅ small | |
| **List rows / Thing cards** | ❌ | opaque, standard |
| **Thing detail body, field cells** | ❌ | this is content |
| **Note editor** | ❌ | never put glass behind text you type |
| **Photo / gallery grid** | ❌ | media is the subject; glass steals from it |
| **Any glass on top of other glass** | ❌ | absolute prohibition |

### `.regular` everywhere. Never `.clear`.

`Glass` has three variants: `.regular`, `.clear`, `.identity`. Apple's HIG: *only* use clear glass
over visually rich backgrounds like photos and video, and **never mix `.regular` and `.clear` in
the same app**. Things is text-dense — field labels, values, notes — so `.regular` is correct on
every surface and `.clear` is banned outright. That also removes the need for the 35%-opacity
dimming layer clear glass requires over bright content.

### Implementation rules

- Prefer **system components** over `.glassEffect()`. A standard `TabView` and `.toolbar` get glass
  for free, correctly, and stay correct across OS updates. Custom glass is a last resort.
- **Remove custom backgrounds** from `NavigationStack`, `NavigationSplitView`, `.toolbar`, sheets,
  and popovers. Apple is explicit that these interfere with system glass and the scroll edge
  effect. If a screen has a custom background today, deleting it is usually the fix.
- Use **`ConcentricRectangle`** (iOS 26) for nested rounded shapes instead of hand-computing
  radii — it is the API built for the concentric rule below.
- Batch effects into one `GlassEffectContainer`. Apple: too many containers, or too many effects
  applied outside one, degrades performance.
- Register any custom bar with `safeAreaBar(edge:)` so content scrolling beneath it gets the
  system's legibility treatment.

### API corrections worth having in writing

- The modifier is **`glassEffect(_:in:)`** — there is **no `isEnabled:` parameter**. Guides carrying
  that signature were written during the 2025 beta cycle.
- `scrollEdgeEffectStyle(_:for:)` — the `for edges:` argument is required.
- `sharedBackgroundVisibility(_:)` is on **`ToolbarContent`**, not `View`.
- `tabBarMinimizeBehavior` keeps its name in iOS 27; **`toolbarMinimizeBehavior` is renamed to
  `toolbarMinimizationBehavior(_:for:)`**. Isolate it so the eventual rename is one edit.
- **Section headers are now title-case, not all-caps**, regardless of the string passed. Write the
  strings that way.
- When multiple glass elements coexist, wrap them in **`GlassEffectContainer`** so they blend and
  morph as one material rather than fighting each other.
- Apply `.glassEffect()` **after** layout and appearance modifiers.
- `.interactive()` only on things that actually respond to touch. Interactive glass on a static
  label is a lie the user can feel.
- Use `.glassEffectID` with a `@Namespace` for morphing when the hierarchy changes (the **+**
  button expanding is the flagship moment).
- Tint sparingly. Tint signals prominence; if everything is tinted, nothing is prominent.
- Gate with `#available` and provide a `.ultraThinMaterial` fallback that still looks deliberate.

### Concentric geometry

Nested rounded shapes share a centre: `innerRadius = outerRadius − padding`. Apple is rigorous
about this and the eye notices when it's wrong, even if the viewer can't name why. It applies to
both platforms.

---

## 2. Accessibility — the system does most of it for us

**Correction worth knowing: Liquid Glass adapts to accessibility settings automatically.** We do not
implement these for system glass:

| Setting | What the system does to glass, unprompted |
|---|---|
| **Reduce Transparency** | Glass becomes frostier and obscures more of what's behind it |
| **Increase Contrast** | Elements go predominantly black or white with a contrasting border |
| **Reduce Motion** | Effect intensity drops; the material's elastic properties are disabled |

We only query these for **our own** custom animations and colours — most importantly to gate
`.glassEffectTransition(.materialize)`, since Apple's own guidance is to avoid animating into and
out of blurs under Reduce Motion.

```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
@Environment(\.accessibilityReduceMotion)       var reduceMotion
@Environment(\.colorSchemeContrast)             var contrast   // .standard / .increased
```

⚠️ **UIKit naming trap:** "Increase Contrast" is `UIAccessibility.isDarkerSystemColorsEnabled` —
nothing in the name says contrast. In SwiftUI it surfaces as `colorSchemeContrast == .increased`.

**Dynamic Type** is the one we own entirely: every screen must survive the largest accessibility
size, verified in the Screenshot Tour rather than by hope.

The web client has no system to lean on, so it implements all four itself via
`prefers-reduced-transparency`, `prefers-contrast`, `prefers-reduced-motion`, and relative type
units.

---

## 3. Web ↔ iPhone parity

The web client must read as *the same app on a bigger screen*, not a companion dashboard.

Web layout is **Finder / Notes / Photos**, never an admin dashboard:

```
┌──────────────────────────────────────────────────────────┐
│  Things                                  Search      +   │  ← glass toolbar
├──────────────┬───────────────────────────────────────────┤
│ Library      │  Recent                                   │
│  Pinned      │  ┌───────────────────────────────────┐    │
│  Recents     │  │ GitHub                            │    │
│              │  │ 1980 Logo                         │    │
│ Collections  │  │ Steam                             │    │
│  1980        │  └───────────────────────────────────┘    │
│  Development │                                           │
│  Gaming      │                                           │
└──────────────┴───────────────────────────────────────────┘
```

Shared across both clients: type scale and hierarchy, spacing rhythm, corner radii, the same SF
Symbol set, the same colour semantics, the same motion curves, the same words.

Differences are only what the input device demands — hover, right-click menus, keyboard navigation,
multi-select, drag-and-drop, and ⌘K on the web; long-press, swipe, haptics, and Face ID on the
phone.

### The web glass problem

Getting Liquid Glass *right* in CSS is the hardest visual task in this project and the one most
likely to disappoint. A `backdrop-filter: blur()` frosted panel is **not** Liquid Glass and will be
rejected. The material needs, at minimum:

1. Moderate blur — heavy blur is the amateur tell
2. Saturation/vibrancy lift, so colours behind become *more* alive, not milky
3. **Edge refraction** — the rim bends and magnifies what's behind it. This is the property that
   makes it read as a physical object. Without it, it's a blurred rectangle.
4. A specular highlight arc on the top edge, dimmer on the bottom
5. Depth: hairline bright border, inner shadow, outer float shadow
6. Adaptive contrast — darkens over light backdrops, lightens over dark
7. Response to the pointer: highlight tracks, refraction intensifies, slight scale

This is being settled empirically **before** any web UI is written, via a side-by-side fidelity lab
(`tools/glass-lab/`) with five candidate techniques judged over hostile backdrops. The winner
becomes `apps/web/src/styles/glass.css` and is frozen as a primitive. It is not re-litigated per
component.

---

## 3b. The iPhone shell — decided

Deployment target **iOS 26.0** (79% adoption as of June 2026, and this is a personal sideloaded
app — targeting lower costs the entire Liquid Glass surface for nothing).

```swift
TabView {
    Tab("Things", systemImage: "square.stack") { … }
    Tab("Collections", systemImage: "folder") { … }
    Tab(role: .search) { SearchView() }        // system pins it trailing, separates it visually
}
.tabBarMinimizeBehavior(.onScrollDown)
.tabViewBottomAccessory { … }                   // reserved for a future mini-player-style slot
```

`Tab(role: .search)` in its **standard-tab** style, not button style: the HIG recommends the
dedicated-landing-page style when you want to show suggestions before the user types — which is
exactly what Home's Pinned/Recents/Suggestions surface is. `.searchToolbarBehavior(.minimize)`
where search shares a toolbar with other controls, as Notes and Mail do.

Toolbar grouping follows Apple's Landmarks sample: `ToolbarSpacer(.fixed)` splits the shared glass
background, `ToolbarItemGroup` merges neighbours into one. Never group a symbol with text in a
single shared background — it reads as one button.

Other confirmed choices: `.navigationTransition(.zoom(sourceID:in:))` + `matchedTransitionSource`
for card→detail (iOS 18+), `sensoryFeedback(_:trigger:)` for haptics (the current API —
`UIImpactFeedbackGenerator` is legacy), `presentationDetents` for sheets **without**
`presentationBackground` (custom sheet backgrounds fight system glass), `listSectionMargins`
(iOS 26) for list rhythm, and `quickLookPreview` for single files with `QLPreviewController`
bridged for multi-item galleries.

⚠️ **iOS 27 watch-item:** a `TabView` will crash if its selection is set to a hidden or unavailable
tab. Our tab set is static, so this is low risk — but worth remembering if tabs ever become
conditional.

## 4. Screen inventory

This doubles as the **Screenshot Tour manifest** — CI captures every screen below in
{light, dark} × {default, XXL Dynamic Type}.

### iPhone
`Home` · `All Things` · `Thing Detail — fields` · `Thing Detail — sections` ·
`Thing Detail — media gallery` · `Photo viewer` · `Add Field sheet` · `New Thing / templates` ·
`Search idle` · `Search results + filter chips` · `Collections` · `Collection detail` ·
`Long-press quick actions` · `Field quick actions` · `Lock screen` · `Privacy Mode on` ·
`History` · `Conflict — 2 Versions` · `Trash` · `Settings` · `Sync pairing` · `Empty states`

### Web
`Home three-pane` · `Thing detail` · `Command Palette` · `Search results` · `Gallery` ·
`Drag-and-drop import` · `Batch selection` · `Collection` · `Settings` · `PIN unlock` ·
`Empty states`

Each screen also gets a **long-content** variant — 60-character titles, 40 fields, a 20 000-word
note. Layout breaks live in the long tail, and the seed dataset is designed to force those breaks
rather than flatter the design.

---

## 5. Motion

Motion is how a system app signals it was made by people who cared. Standard iOS springs, not
custom easing curves. Navigation uses the zoom transition where a card expands into its detail.
Glass morphs rather than cross-fades when the hierarchy changes. Nothing bounces for decoration.
Everything respects Reduce Motion.

---

## 6. Words

The app says: **Things · Collections · Fields · Files · Notes · Recently Added · Pinned · Locked ·
Search**.

It never says: Vault · Database · Knowledge Base · Workspace · Entry · Record · Item · Dashboard ·
Sync Engine · Encryption Layer. If a label sounds like it was written by a developer describing
their implementation, it is wrong.

Empty states use plain language and never scold. Errors say what happened and what to do.

---

## 7. Anti-patterns — automatic rejection in visual review

Glass on content · glass on glass · a custom blur where a system component exists · everything
tinted · heavy blur · a floating pill nav bar that isn't the system tab bar · purple/blue SaaS
gradients · a settings screen that looks like a web form · inconsistent corner radii · text that
truncates at default Dynamic Type · a "Dashboard" with stat cards · icons from a generic web icon
set instead of SF Symbols · animation that ignores Reduce Motion.
