# Repository boundaries

There are two repositories, and the split is the point. Putting something in the wrong one is
how `virtual ~Spell` ended up fixed in one copy of the server and broken in the other.

## Which repository owns what

| | |
|---|---|
| **`twow-core`** — the server | Upstream's code and our delta to it: `src/game`, `src/shared`, `sql/base`, `sql/database_updates`, `dep/`, `tools/`, the vendored bot modules, the migration machinery. It merges from `Shyalya/tortoise-wow` and is the **terminus** — nothing is sent upstream of it (ADR-0020, ADR-0026). |
| **`twow-repo`** — this repository, the platform | Everything upstream will never have: our own modules under `modules/`, plus `services/`, `deploy/`, `ops/`, `docs/`, `test/`, `config/`, and SQL this project authors. |

`core/` here is a **submodule pinned by SHA**, not a copy. `UPSTREAM.lock` records the pin and
the fork point, `.gitmodules` records the URL, and clones need `--recursive`.

**The invariant: this repository contains no copy of anything core owns.** To change the
server, change it in `twow-core` and bump the pin. A fix applied here to a file core owns is a
fix that will be silently lost.

## Layout

- `modules/`: our own modules (`mod-*`), each with its own `src/`, `conf/`, `data/sql/`, `t/`.
- `services/`: out-of-process services, e.g. the Go `bot-brain`.
- `deploy/`: compose and Helm — how the stack is built and run.
- `ops/`: helper scripts, audits and the issue tooling.
- `test/`: cross-cutting integration and smoke suites; per-module unit tests stay in `t/`.
- `config/canonical/`: authoritative complete-template plus the reviewed non-secret overlay
  contract for generated shared server configuration.
- `config/examples/`: sanitized historical snapshots. Every credential-bearing value is a
  placeholder; these are not deployment input.
- `docs/`: ADRs, footguns, provenance, issue manifests.
- `runbooks/`: frozen historical evidence, described below.

## What must never be here

Compiled binaries, symbols, archives, database files, live logs, caches, MPQ or other client
game data, live credentials, secret-bearing configuration, runtime state — **and a second copy
of the server source.**

This repository is public. Credential-bearing values are placeholders or are marked
`MACHINE_SECRET` in `config/canonical/compose/semantic-baseline.tsv` and injected at deploy
time (ADR-0038).

## `runbooks/`

Frozen historical evidence from before the core split, kept so decisions can be traced. It is
**never an input to current work** — do not read it to start a task, and do not gate a task on
it. Historical runbooks contain absolute paths from the original Windows workstation; those
are evidence, not portable instructions. New documentation and automation use repository-relative
paths.

## Source of truth

Observed runtime state is authoritative for what is currently running. Under ADR-0038 the
repository is authoritative for *intended* shared configuration, while a runtime `.conf` is a
generated deployment artifact. Neither canonical configuration nor a merged change authorizes
deployment, database mutation, process control, or rollback.

When documentation and the tree disagree, **the tree wins** and the documentation is wrong.
Say so and fix it rather than working around it.
