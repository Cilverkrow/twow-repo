# Repository boundaries

This repository is the source-controlled project view of the private TWoW server. It is deliberately separated from the live workspace at `C:\TW\ComTW`.

The live workspace remains the runtime and agent-working tree. This repository must never become an implicit deployment target, database directory, log sink, build output directory, or secret store.

## Layout

- `src/`, `modules/`, `sql/`, `cmake/`, `dep/`, and `tools/`: server source inherited from the Tortoise-WoW source baseline. Compiled dependencies and other binary assets are intentionally absent.
- `ops/windows/`: project-owned build, transfer, deployment, start, stop, and diagnostic helper scripts copied from the live workspace.
- `config/canonical/`: authoritative complete-template plus reviewed non-secret
  overlay contract for generated shared server configuration.
- `config/examples/`: sanitized historical configuration snapshots. Every
  credential-bearing value is replaced by a placeholder; these files are not
  deployment input.
- `runbooks/`: text-only project history, evidence, decisions, scripts, and handoffs. Packaged deliverables, executables, symbols, database files, runtime logs, and other binaries are excluded.
- `docs/`: repository provenance, boundaries, and the modularization roadmap.

## Source of truth

Observed runtime state remains authoritative for what is currently running.
Under ADR-0038, the repository is authoritative for intended shared
configuration, while a runtime `.conf` is a generated deployment artifact.
Neither the presence of canonical configuration nor a merged change authorizes
deployment, database mutation, process control, or rollback.

Historical runbooks can contain absolute paths from the original workstation. Those paths are evidence, not portable instructions. New repository documentation and automation should use paths relative to the repository root.
