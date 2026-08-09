# Things — Open Questions

Decisions not yet made. **None of these block M0**, which is deliberate — M0 exists to retire
delivery risk, not design risk. Each entry names who decides and when it becomes urgent.

---

### Q1 — Pinned vs Favorites: one concept or two?

The vision lists both as separate access paths. Notes has Pinned; Photos has Favorites. Having both
in one app usually means the user pauses to think "which one was this?" — and a beat of hesitation
on the most-used surface is expensive.

**Recommendation:** ship **Pinned** only. It is the stronger metaphor for an app whose home screen
is a launchpad. Add Favorites later if the absence is actually felt.
**Decide by:** M2 (Home screen layout). **Owner:** you.

---

### Q2 — How much of the object store lives on the iPhone?

Full sync of a library containing 20 GB videos will fill a phone. Three options:

| Policy | Behavior |
|---|---|
| **Everything** | Simple, predictable, eventually painful |
| **Smart (recommended)** | Metadata + thumbnails always; full objects under a size threshold (default 10 MB); anything larger on demand with a tap |
| **Manual** | Per-Thing "Keep on iPhone" toggle |

**Recommendation:** Smart, with Manual as an override — mirroring how Photos handles Optimize
Storage, which is the mental model you already have.
**Decide by:** M7 (Sync). **Owner:** you.

---

### Q3 — Does the repo stay public? — **DECIDED: yes, public**

Verified against GitHub's docs on 2026-08-09: *"Use of the standard GitHub-hosted runners is free
and unlimited on public repositories"* — macOS included. Going private meters every macOS minute at
**$0.062** (~10× Linux). For a project whose entire iOS loop is macOS-only, that is the difference
between a free pipeline and a recurring bill.

Two guardrails come with it: never use a `-large`/`-xlarge` runner label (billed even on public
repos), and enforce the hygiene rules in [`02-SECURITY.md` §8](02-SECURITY.md) in CI rather than by
memory — a screenshot generated from a real database and attached to a public run is a permanent
public disclosure.

---

### Q4 — What happens when a Thing is opened on a device that lacks its files?

A Thing referencing `D:\Servers\1980` opened on the iPhone shows `RAEID-PC` + **Copy Path**. But
what about an *attached* object the phone chose not to download (Q2)? Placeholder with a download
button, or hidden entirely?

**Recommendation:** always show it, greyed, with size and a tap-to-download affordance. Hiding
content because of a storage policy makes the app feel like it lost your data.
**Decide by:** M5. **Owner:** me, unless you object.

---

### Q5 — Rich text: how far?

The vision asks for headings, bold, italic, lists, checklists, quote, code, links, tables — while
insisting the UI stay Notes-like rather than Notion-like. Tables in particular are a large amount of
work on both platforms for relatively rare use.

**Recommendation:** everything except tables in v1; tables deferred to M8 and reconsidered based on
whether you actually miss them.
**Decide by:** M4. **Owner:** you.

---

### Q6 — Does the PC service run as a background service or a manual launch?

A Windows service that autostarts is convenient but means Things is always running and always
unlocked-adjacent. A manual launch is safer and more honest about a local-first tool.

**Recommendation:** manual launch (a shortcut / tray app) for v1, with autostart as an opt-in
setting once the security model has been lived with.
**Decide by:** M2. **Owner:** you.

---

### Q7 — Clipboard suggestions: how are they triggered?

The vision correctly notes this must not feel like clipboard surveillance. On iOS, reading the
clipboard shows a system banner, so silent monitoring is impossible anyway — which is helpful here.

**Recommendation:** clipboard is read **only** when you tap **+**, never in the background, and the
suggestion appears as one dismissible row. Never a notification.
**Decide by:** M8. **Owner:** me, unless you object.

---

### Q8 — Arabic + RTL: when?

Locked for now as English-first with i18n-ready structure. The open part is *when* Arabic arrives,
because it roughly doubles visual-review cost (every screen captured in both directions).

**Recommendation:** after M6, once the screen inventory has stopped churning. Adding RTL to a
still-moving UI means reviewing the same screens twice, repeatedly.
**Decide by:** after M6. **Owner:** you.
