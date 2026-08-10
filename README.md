<div align="center">

# Things

A local system for keeping accounts, files, links, notes and structured personal data in one place.

</div>

## Overview

Things is built around one flexible item type called a `Thing`. A Thing can hold text, credentials, files, paths, links, images and custom fields without forcing the user into separate apps or rigid categories.

The system has two clients:

- Native SwiftUI app for iPhone
- Local web interface for desktop

Both use the same data model and sync directly over the local network.

## Platform

| Area | Implementation |
|---|---|
| iPhone | SwiftUI, iOS 26, Liquid Glass |
| Desktop | Local web client |
| Local service | TypeScript |
| iOS core | Swift |
| Storage | Local database and object storage |
| Sync | Direct LAN sync |
| Cloud | None |
| Accounts | None |

## Running the desktop client

```bash
npm install
npm run dev
```

The local interface is available at:

```text
http://localhost:6767
```

Full setup instructions are in [`docs/06-RUNBOOK.md`](docs/06-RUNBOOK.md).

## Design

A Thing is composed from sections and fields rather than a fixed record type. This lets the same model represent a login, a note, a saved file, a payment card, a link collection or a mixed record containing several of them.

The TypeScript and Swift cores are implemented separately and checked against shared conformance vectors. A change that produces different results between platforms fails validation before release.

## Documentation

| Document | Purpose |
|---|---|
| [`00-PLAN`](docs/00-PLAN.md) | Project scope and milestones |
| [`01-DATA-MODEL`](docs/01-DATA-MODEL.md) | Thing, Section and Field model |
| [`02-SECURITY`](docs/02-SECURITY.md) | Threat model and key handling |
| [`03-DESIGN`](docs/03-DESIGN.md) | UI rules and platform parity |
| [`04-CI-AND-LOOP`](docs/04-CI-AND-LOOP.md) | CI and screenshot workflow |
| [`05-OPEN-QUESTIONS`](docs/05-OPEN-QUESTIONS.md) | Decisions still open |
| [`06-RUNBOOK`](docs/06-RUNBOOK.md) | Development and release workflow |

The canonical technical specifications live under `spec/`.

## Privacy

Things is designed to operate without a cloud service. Real user databases, keys, PINs and backups are not stored in the repository. CI screenshots use generated test data only.