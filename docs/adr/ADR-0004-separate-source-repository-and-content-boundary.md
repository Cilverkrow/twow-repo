# ADR-0004: Separate source repository and strict content boundary

- Status: Accepted
- Date: 2026-08-31
- Primary: WS-00 / WS-80

## Context

Project changes were spread in-place across the live server workspace while other agents were active. Turning that workspace into a publishing repository would couple development, runtime state, deployment, and Git operations.

## Decision

Maintain an independent repository copy for source control. The live workspace remains the runtime and agent-working tree; the repository is not an implicit deployment target.

The repository may contain:

- platform code: `modules/` (our own modules), `services/`, `deploy/`, `ops/`, `test/`,
  `config/`, and SQL this project authors;
- the `core/` submodule reference - a pinned SHA, not a copy;
- sanitized configuration examples under `config/examples`;
- text-only runbooks and documentation;
- root `AGENTS.md`.

It must **not** contain a copy of the server source. That belongs to `twow-core` and is
consumed through the `core/` submodule; duplicating it is what left `virtual ~Spell`
fixed in one repository and broken in the other. Nor may it contain compiled binaries, symbols, archives, database files, live logs, caches, large MPQ/client game data, live credentials, secret-bearing configuration, or runtime state. Historical absolute paths are evidence only; new portable material uses repository-relative paths.

## Consequences

- Git operations cannot disturb agents working in the live tree.
- Deployment remains an explicit later operation.
- Config examples require placeholders and secret scanning.
- Client work is limited to intentional text/config/add-on/patch assets; large game data stays out.

## Evidence

- `docs/REPOSITORY-BOUNDARIES.md`
- `docs/SECURITY.md`
- `docs/PROVENANCE.md`
- Git commits preceding this ADR reconstruction
