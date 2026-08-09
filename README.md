# Things

**Everything, in one place.**

A completely local personal information system. Accounts, passwords, files, photos, links, notes,
paths, and cards — all as one flexible kind of item called a **Thing**.

Not a notes app. Not a file manager. Not a password manager. Not a bookmark manager.
It is the place where one item can be all four at once.

> The user does not adapt to the database. The database adapts to the thing the user wants to keep.

---

## Run it

```bash
npm install
npm run dev          # http://localhost:6767
```

Full instructions, including LAN sync setup and troubleshooting:
[`docs/06-RUNBOOK.md`](docs/06-RUNBOOK.md).

## Status

Both cores, the local service, the web client, and the iOS app are implemented.
The iOS half has **never been compiled** — there is no Mac on this project, so its first build
happens on a GitHub Actions macOS runner.

| Document | Contents |
|---|---|
| [00-PLAN](docs/00-PLAN.md) | Constraints, architecture, milestones, the operating loop, risks |
| [01-DATA-MODEL](docs/01-DATA-MODEL.md) | Thing / Section / Field, kinds + variants, objects, oplog, conflicts |
| [02-SECURITY](docs/02-SECURITY.md) | Threat model, PIN + device-bound keys, lock behaviour, network posture |
| [03-DESIGN](docs/03-DESIGN.md) | Palette, Liquid Glass rules, web↔iPhone parity, screen inventory |
| [04-CI-AND-LOOP](docs/04-CI-AND-LOOP.md) | macOS CI, Screenshot Tour, IPA build, review loop |
| [05-OPEN-QUESTIONS](docs/05-OPEN-QUESTIONS.md) | Decisions still open |
| [06-RUNBOOK](docs/06-RUNBOOK.md) | How to run, develop, ship, and debug it |

| Spec (normative) | Contents |
|---|---|
| [schema.sql](spec/schema.sql) | Canonical DDL |
| [field-kinds.json](spec/field-kinds.json) | Field kinds, variants, templates, smart views |
| [crypto.md](spec/crypto.md) | Key hierarchy, envelope formats, framed objects |
| [oplog.md](spec/oplog.md) | HLC wire format, canonical JSON, attribute encoding |
| [search.md](spec/search.md) | Query grammar and evaluation |
| [sync.md](spec/sync.md) | Discovery, pairing, transfer, conflicts |
| [vectors/](spec/vectors) | Conformance vectors both cores must pass |

The two cores are written independently in TypeScript and Swift and held in agreement by those
vectors rather than by shared code — if they ever disagree, a test goes red before a user notices.

## Shape

- **iPhone** — SwiftUI, native, Liquid Glass, Face ID. No React Native, no Flutter, no WebView.
- **Desktop** — a local service on the PC; the client is a web UI at `http://localhost:6767`.
- **Sync** — direct over the local network between the two. Nothing else.
- **Cloud** — none. No accounts, no telemetry, no analytics, no external API is required to use it.

## A note on privacy

This repository contains **code and documentation only**. It never contains a database, a key, a
PIN, a backup, or a screenshot taken from real data. Screenshots in CI are generated exclusively
from a fictional seed dataset.
