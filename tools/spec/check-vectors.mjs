#!/usr/bin/env node
/**
 * Guards the conformance vectors against the failure mode that actually happened.
 *
 * The two cores are held in agreement only by `spec/vectors/*.json`. That safety net failed
 * once, in the worst possible way: a runner matched vector files by looking for a top-level
 * `cases` array, two files did not have one, and those files were **silently skipped**. The
 * suite reported green while the cores were byte-incompatible. A test that can quietly decline
 * to run is worse than no test, because it also manufactures confidence.
 *
 * So: every vector file must declare, in itself, which cores must execute it and how many cases
 * it contains. CI fails if a file is unreadable, undeclared, empty, or if a runner reports having
 * executed fewer cases than the file declares.
 *
 *   node tools/spec/check-vectors.mjs                 structural check
 *   node tools/spec/check-vectors.mjs --report r.json cross-check a runner's report
 *
 * A runner report is `{ "<file>.json": <casesExecuted>, ... }`.
 */

import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const DIR = 'spec/vectors';
const KNOWN_CORES = ['ts', 'swift'];

const argv = process.argv.slice(2);
const reportPath = argv.includes('--report') ? argv[argv.indexOf('--report') + 1] : null;

const fail = [];
const warn = [];
const declared = new Map(); // file -> { cores, count }

if (!existsSync(DIR)) {
  console.error(`${DIR} does not exist. The two cores have nothing holding them in agreement.`);
  process.exit(1);
}

const files = readdirSync(DIR).filter((f) => f.endsWith('.json') && f !== 'MANIFEST.json').sort();

if (files.length === 0) {
  console.error(`${DIR} is empty.`);
  process.exit(1);
}

for (const file of files) {
  const path = join(DIR, file);
  let doc;
  try {
    doc = JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    fail.push(`${file}: not valid JSON — ${e.message}`);
    continue;
  }

  // `mustRun` is what makes skipping loud instead of silent. Without it a runner is free to
  // decide a file is "not for me" and say nothing.
  const cores = doc.mustRun;
  if (!Array.isArray(cores) || cores.length === 0) {
    fail.push(
      `${file}: missing "mustRun". Add e.g. "mustRun": ["ts","swift"] so a runner that ` +
      `does not recognise this file fails loudly instead of skipping it.`,
    );
  } else {
    const unknown = cores.filter((c) => !KNOWN_CORES.includes(c));
    if (unknown.length) fail.push(`${file}: unknown core(s) in mustRun: ${unknown.join(', ')}`);
    if (cores.length === 1) {
      warn.push(`${file}: only "${cores[0]}" runs this. A single-core vector proves nothing about agreement.`);
    }
  }

  // Count cases under whichever shape this file uses, then require the file to state it.
  const counted = countCases(doc);
  if (counted === 0) {
    fail.push(`${file}: contains no recognisable cases.`);
  }

  const stated = doc.caseCount;
  if (typeof stated !== 'number') {
    fail.push(`${file}: missing "caseCount". A runner must be able to prove it ran everything.`);
  } else if (stated !== counted) {
    fail.push(`${file}: declares caseCount ${stated} but ${counted} cases are present.`);
  }

  declared.set(file, { cores: cores ?? [], count: counted });
}

/** Cases may live under `cases`, or under named groups of arrays. Count both shapes. */
function countCases(doc) {
  if (Array.isArray(doc.cases)) return doc.cases.length;
  let n = 0;
  for (const [key, value] of Object.entries(doc)) {
    if (key.startsWith('$') || key === 'mustRun' || key === 'caseCount' || key === 'version') continue;
    if (Array.isArray(value)) n += value.length;
  }
  return n;
}

// ── Cross-check a runner's self-report ─────────────────────────────────────
if (reportPath) {
  if (!existsSync(reportPath)) {
    fail.push(`Runner report ${reportPath} not found. The runner must emit what it executed.`);
  } else {
    const report = JSON.parse(readFileSync(reportPath, 'utf8'));
    const core = report.$core ?? 'unknown';
    for (const [file, meta] of declared) {
      if (!meta.cores.includes(core)) continue;
      const ran = report[file];
      if (ran === undefined) {
        fail.push(`${core}: never ran ${file}, which declares mustRun including "${core}". ` +
                  `This is the silent-skip bug; fail here rather than shipping.`);
      } else if (ran < meta.count) {
        fail.push(`${core}: ran ${ran}/${meta.count} cases in ${file}.`);
      }
    }
  }
}

// ── Output ────────────────────────────────────────────────────────────────
for (const w of warn) console.log(`warning: ${w}`);

if (fail.length) {
  console.error('');
  for (const f of fail) console.error(`error: ${f}`);
  console.error('');
  console.error(`${fail.length} problem(s). The cores are not provably in agreement.`);
  process.exit(1);
}

const total = [...declared.values()].reduce((n, m) => n + m.count, 0);
console.log(`${declared.size} vector files, ${total} cases, all declared and accounted for.`);
