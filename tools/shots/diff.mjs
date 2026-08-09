#!/usr/bin/env node
/**
 * Screenshot Tour — Tier 1 review.
 *
 * Compares this run's screenshots against the committed baselines and reports only what
 * CHANGED. That filter is the entire point: a Screenshot Tour produces ~88 images per run, and
 * a human (or an agent) reviewing 88 images per push will stop reviewing within a week.
 * Reviewing the 3 that moved is sustainable forever.
 *
 * This only works if screenshots are deterministic — fixed seed data, injected clock, animations
 * disabled, pinned locale/timezone/device. If a run reports 40 changes, the determinism harness
 * is broken; fix that rather than raising the threshold, because a noisy diff gets ignored and
 * an ignored diff is worse than no diff.
 *
 *   node tools/shots/diff.mjs
 *   node tools/shots/diff.mjs --accept        promote current run to baseline
 *
 * Exits 0 when nothing changed, 1 when something did. CI treats 1 as "a human should look",
 * not as a build failure.
 */

import { readdirSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, copyFileSync }
  from 'node:fs';
import { join, basename } from 'node:path';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';

const args = new Set(process.argv.slice(2));
const ACCEPT = args.has('--accept');

const CURRENT  = process.env.SHOTS_CURRENT  ?? 'artifacts/screenshots';
const BASELINE = process.env.SHOTS_BASELINE ?? 'screenshots/baseline';
const OUT      = process.env.SHOTS_OUT      ?? 'screenshots/diff';

/** Per-pixel colour distance below which a pixel counts as unchanged. */
const PIXEL_THRESHOLD = 0.1;
/** Fraction of differing pixels below which an image counts as unchanged.
 *  Not zero: GPU text rasterisation varies by a hair between runner instances, and demanding
 *  bit-identical output produces false positives that train you to ignore the report. */
const IMAGE_THRESHOLD = 0.001; // 0.1% of pixels

const pngs = (dir) =>
  existsSync(dir) ? readdirSync(dir).filter((f) => f.toLowerCase().endsWith('.png')).sort() : [];

const load = (p) => PNG.sync.read(readFileSync(p));

function main() {
  const current = pngs(CURRENT);

  if (current.length === 0) {
    console.error(`No screenshots in ${CURRENT}.`);
    console.error('The usual cause is a missing `attachment.lifetime = .keepAlways` —');
    console.error('the default lifetime DISCARDS attachments when a test passes, which fails');
    console.error('silently as a green build with an empty artifact.');
    process.exit(2);
  }

  if (ACCEPT) {
    mkdirSync(BASELINE, { recursive: true });
    for (const f of pngs(BASELINE)) rmSync(join(BASELINE, f));
    for (const f of current) copyFileSync(join(CURRENT, f), join(BASELINE, f));
    console.log(`Baseline updated: ${current.length} screenshots.`);
    console.log('Commit this on its own, never inside a feature change — a baseline update');
    console.log('bundled into a feature PR is how a visual regression gets approved by accident.');
    return;
  }

  const baseline = pngs(BASELINE);
  if (baseline.length === 0) {
    console.log(`No baseline yet (${BASELINE} is empty).`);
    console.log(`Review all ${current.length} screenshots by hand, then run with --accept.`);
    process.exit(1);
  }

  rmSync(OUT, { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });

  const baseSet = new Set(baseline);
  const curSet  = new Set(current);

  const added   = current.filter((f) => !baseSet.has(f));
  const removed = baseline.filter((f) => !curSet.has(f));
  const common  = current.filter((f) => baseSet.has(f));

  const changed = [];
  const resized = [];

  for (const name of common) {
    const a = load(join(BASELINE, name));
    const b = load(join(CURRENT, name));

    if (a.width !== b.width || a.height !== b.height) {
      resized.push({ name, from: `${a.width}x${a.height}`, to: `${b.width}x${b.height}` });
      copyFileSync(join(CURRENT, name), join(OUT, name));
      continue;
    }

    const diff = new PNG({ width: a.width, height: a.height });
    const differing = pixelmatch(a.data, b.data, diff.data, a.width, a.height, {
      threshold: PIXEL_THRESHOLD,
      includeAA: false,
      alpha: 0.25,
      diffColor: [255, 0, 128],
    });

    const ratio = differing / (a.width * a.height);
    if (ratio > IMAGE_THRESHOLD) {
      changed.push({ name, ratio, pixels: differing });
      writeFileSync(join(OUT, `diff-${name}`), PNG.sync.write(diff));
      copyFileSync(join(CURRENT, name), join(OUT, name));
    }
  }

  changed.sort((x, y) => y.ratio - x.ratio);

  const report = {
    current: current.length,
    baseline: baseline.length,
    unchanged: common.length - changed.length - resized.length,
    changed, added, removed, resized,
  };
  writeFileSync(join(OUT, 'report.json'), JSON.stringify(report, null, 2));

  // ── Human/agent-readable summary ────────────────────────────────────────
  const pct = (r) => `${(r * 100).toFixed(2)}%`;
  const lines = [];
  lines.push('## Screenshot review');
  lines.push('');
  lines.push(`${report.unchanged} unchanged · ${changed.length} changed · ` +
             `${added.length} new · ${removed.length} removed · ${resized.length} resized`);
  lines.push('');

  if (changed.length) {
    lines.push('### Changed — review these');
    lines.push('');
    lines.push('| Screen | Pixels differing |');
    lines.push('|---|---|');
    for (const c of changed) lines.push(`| \`${c.name}\` | ${pct(c.ratio)} (${c.pixels}) |`);
    lines.push('');
  }
  if (resized.length) {
    lines.push('### Resized — a layout dimension moved');
    lines.push('');
    for (const r of resized) lines.push(`- \`${r.name}\`: ${r.from} → ${r.to}`);
    lines.push('');
  }
  if (added.length) {
    lines.push('### New screens');
    lines.push('');
    for (const a of added) lines.push(`- \`${a}\``);
    lines.push('');
  }
  if (removed.length) {
    lines.push('### Screens that disappeared');
    lines.push('');
    lines.push('A screen vanishing is usually a broken navigation path, not an intentional removal.');
    lines.push('');
    for (const r of removed) lines.push(`- \`${r}\``);
    lines.push('');
  }

  if (!changed.length && !added.length && !removed.length && !resized.length) {
    lines.push('Nothing moved. No visual review needed.');
  } else {
    lines.push('---');
    lines.push('');
    lines.push('Check each changed screen for: text truncation · Dynamic Type overflow ·');
    lines.push('contrast on glass · glass applied to content · glass on glass · inconsistent');
    lines.push('corner radii · wrong safe-area or keyboard insets · broken empty states.');
    lines.push('');
    lines.push('If the change is correct, run `node tools/shots/diff.mjs --accept` and commit');
    lines.push('the baseline **on its own**.');
  }

  const summary = lines.join('\n');
  writeFileSync(join(OUT, 'summary.md'), summary);
  console.log(summary);

  const moved = changed.length + added.length + removed.length + resized.length;
  process.exit(moved > 0 ? 1 : 0);
}

main();
