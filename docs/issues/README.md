# Issue manifest

GitHub issues for this project are generated from the files in this directory, not
created by hand. The manifest is the reviewable source of truth; the tracker is a
projection of it.

Why: issues drift, get closed by accident, and lose the evidence path that made them
worth filing. A manifest in Git keeps the mapping reviewable, re-runnable, and
diffable, and it survives a botched import.

## Files

| File | Contents |
|---|---|
| `00-refactor-plan.md` | The approved restructuring plan (OT-025). Source for the deferred-architecture issues. |
| `10-open-threads.md` | Items already tracked in `TODOS.md` / `docs/OPEN-THREADS.md` as OT-002..OT-026. |
| `20-runbook-sweep.md` | Open items recovered from `runbooks/` by the 2026-08-31 three-way sweep. |
| `30-deferred-architecture.md` | Work deliberately out of scope for the restructuring. |

## Format

Each item is a YAML front-matter block. `id` is stable and appears in the issue
title, which is what makes the import idempotent: the importer looks for an existing
issue whose title starts with the id and skips it rather than creating a duplicate.

```yaml
---
id: WS10-001            # stable; becomes the issue title prefix
title: ...              # imperative, <= 70 chars
workstream: WS-10       # becomes label ws-10
priority: p0|p1|p2      # becomes label p0/p1/p2
existing_ot: OT-024     # cross-reference, or `none`
source: runbooks/...    # evidence path
superseded_by: none
body: |
  ...
---
```

## Importing

`ops/issues/import-issues.sh` reads every manifest file and creates what is missing.
It is safe to re-run: existing ids are skipped, never updated or duplicated. Run it
with `--dry-run` first; that is the default.
