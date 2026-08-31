# Repository boundaries

This repository is the source-controlled project view of the private TWoW server. It is deliberately separated from the live workspace at `C:\TW\ComTW`.

The live workspace remains the runtime and agent-working tree. This repository must never become an implicit deployment target, database directory, log sink, build output directory, or secret store.

## Layout

- `src/`, `modules/`, `sql/`, `cmake/`, `dep/`, and `tools/`: server source inherited from the Tortoise-WoW source baseline. Compiled dependencies and other binary assets are intentionally absent.
- `ops/windows/`: project-owned build, transfer, deployment, start, stop, and diagnostic helper scripts copied from the live workspace.
- `config/examples/`: sanitized configuration snapshots. Every credential-bearing value is replaced by a placeholder.
- `runbooks/`: text-only project history, evidence, decisions, scripts, and handoffs. Packaged deliverables, executables, symbols, database files, runtime logs, and other binaries are excluded.
- `docs/`: repository provenance, boundaries, and the modularization roadmap.

## Source of truth

Runtime truth remains in the explicitly selected live environment. Files in this repository describe and reproduce changes, but do not authorize deployment, database mutation, process control, or rollback.

Historical runbooks can contain absolute paths from the original workstation. Those paths are evidence, not portable instructions. New repository documentation and automation should use paths relative to the repository root.
