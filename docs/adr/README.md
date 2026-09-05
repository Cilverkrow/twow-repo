# Architecture Decision Records

This directory is the canonical repository index for reconstructed project decisions. The records were created and updated on 2026-08-31 from the current local and online project tasks, the archived local governance test, the collaboration hub, checked-in runbooks, and Git history.

The records distinguish three things:

- **Accepted**: a binding project decision.
- **Accepted, deployment pending**: the design is binding, but production mutation still needs a separate approval.
- **Constraint accepted, allocation pending**: the verified technical boundary is binding while a concrete rollout choice remains open.

Chat text is provenance, not runtime truth. When evidence conflicts, use the precedence in [ADR-0002](ADR-0002-evidence-authority-and-change-gates.md). See [SOURCES.md](SOURCES.md) for the reconstructed source set and [DECISION-REGISTER.md](DECISION-REGISTER.md) for accepted and open decisions.

| ADR | Decision | Status | Primary workstream |
|---|---|---|---|
| [0001](ADR-0001-canonical-workstreams-and-governance.md) | Nine canonical workstreams and stable IDs | Accepted | WS-00 |
| [0002](ADR-0002-evidence-authority-and-change-gates.md) | Evidence precedence and explicit mutation gates | Accepted | WS-00 |
| [0003](ADR-0003-historical-chat-cross-references.md) | Historical chats are retained by cross-reference only | Accepted | WS-00 |
| [0004](ADR-0004-separate-source-repository-and-content-boundary.md) | Separate source repository with no binaries or secrets | Accepted | WS-00 / WS-80 |
| [0005](ADR-0005-preserve-upstream-history-and-modularize-incrementally.md) | Preserve upstream history; modularize incrementally | Superseded 2026-09-02 by ADR-0020 | WS-10 / WS-40 |
| [0006](ADR-0006-server-operations-ownership-and-graceful-shutdown.md) | Separate operations ownership and use graceful shutdown | Accepted | WS-40 / WS-50 |
| [0007](ADR-0007-database-migrations-backups-and-rollback.md) | Forward migrations with verified backup and rollback | Accepted | WS-20 / WS-60 |
| [0008](ADR-0008-source-baseline-and-build-provenance.md) | Baselines require clean source and build provenance | Accepted | WS-10 / WS-50 |
| [0009](ADR-0009-playerbot-race-class-matrix.md) | Use the 52-combination effective PlayerBot matrix | Constraint accepted, allocation pending | WS-10 / WS-30 |
| [0010](ADR-0010-persistent-rndbot-roster.md) | Persistent ordered GUID roster; no automatic replacement | Accepted, deployment pending | WS-10 |
| [0011](ADR-0011-roster-transaction-and-admin-contract.md) | Versioned transactional roster administration | Accepted, deployment pending | WS-10 / WS-20 |
| [0012](ADR-0012-external-llm-process-and-fail-closed-admission.md) | External LLM child process with fail-closed admission | Accepted; amended 2026-09-02 | WS-10 |
| [0013](ADR-0013-llm-wire-package-and-lifecycle-contract.md) | Strict wire, package, and child-lifecycle contract | Transport half superseded 2026-09-02 | WS-10 / WS-40 |
| [0014](ADR-0014-deterministic-bot-personalities.md) | Deterministic, persisted, fact-bounded personalities | Accepted, integration pending | WS-70 |
| [0015](ADR-0015-personality-and-technical-bridge-boundary.md) | Separate personality policy from the technical bridge | Accepted | WS-10 / WS-70 |
| [0016](ADR-0016-donation-progress-persistence.md) | Persist donation-point partial progress in `tw_logon` | Accepted and migrated | WS-20 / WS-30 |
| [0017](ADR-0017-profession-and-riding-targets.md) | Player/bot profession split and early-riding target | Accepted, implementation pending | WS-10 / WS-20 / WS-30 |
| [0018](ADR-0018-runbook-evidence-retention-before-restructuring.md) | Keep sanitized runbook evidence in the main repository for now | Accepted | WS-00 / WS-80 |
| [0019](ADR-0019-external-windows-build-inputs.md) | Keep binary Windows build inputs external and pinned | Superseded 2026-09-03 | WS-10 / WS-50 |
| [0020](ADR-0020-two-repo-upstream-split.md) | Split upstream and project code across two repositories | Proposed | WS-00 / WS-10 / WS-50 |
| [0021](ADR-0021-module-boundaries-and-schema-ownership.md) | One module system with exclusive schema ownership | Proposed | WS-10 / WS-20 |
| [0022](ADR-0022-test-strategy.md) | Unit-first testing with characterization before extraction | Proposed | WS-40 / WS-50 |
| [0023](ADR-0023-containerization-and-one-command-contract.md) | Containers and a one-command build/run contract | Proposed | WS-40 / WS-50 |
| [0024](ADR-0024-project-invariants.md) | Project invariants, bot persistence first among them | Proposed | WS-00 |
| [0025](ADR-0025-repository-and-project-structure.md) | Repository layout as a binding, enforced rule | Accepted for the `core/` split | WS-00 / WS-80 |
| [0026](ADR-0026-project-lineage-and-provenance.md) | Record the project's upstream lineage | Accepted | WS-80 / WS-50 |
| [0027](ADR-0027-database-platform.md) | MariaDB 11.8 as the single database platform | Proposed | WS-20 / WS-30 |
| [0028](ADR-0028-platform-and-ci-strategy.md) | Linux and Docker deploy; Windows compile-only | Accepted (amended 2026-09-02) | WS-40 / WS-50 |
| [0029](ADR-0029-work-tracking.md) | Issues generated from manifests in Git | Proposed | WS-00 / WS-80 |
| [0030](ADR-0030-local-mariadb-loopback-transport.md) | Explicit plaintext profile for the legacy local MariaDB endpoint | Accepted | WS-30 / WS-20 |
| [0038](ADR-0038-configuration-as-code-and-provenance.md) | Version shared server configuration and deploy it with provenance | Accepted | WS-30 / WS-40 / WS-50 / WS-60 / WS-80 |
| [0039](ADR-0039-bot-brain-identity-and-memory.md) | Out-of-process bot planning, with a stable identity and durable memory | Accepted | WS-10 / WS-20 |

ADRs 0020 to 0029 record the OT-025 restructuring. ADR-0028 is accepted because its
Linux/Docker platform contract is both binding in `AGENTS.md` and implemented in the
landed repository structure; the other entries retain the status shown in the table.
ADR-0020 supersedes the "keep one tree" half of ADR-0005, and ADR-0028 removes the CI
half of ADR-0019's provisioning problem without changing that decision for local
Windows builds.

ADR-0030 is a later accepted operations decision. It permits an explicit plaintext
client profile only for the verified legacy `127.0.0.1:3307` endpoint and does not
authorize queries, process control or deployment.

ADR-0038 was accepted separately on 2026-09-01. Its repository-only Compose
implementation and formal OPS-009 drift closure are documented in
[`CONFIGURATION-AS-CODE.md`](../CONFIGURATION-AS-CODE.md); deployment remains a
separate authorization gate.

## Creating later ADRs

Use the next number. Record context, the decision, consequences, implementation state, open gates, and repository-relative evidence. Never convert a proposal into an accepted decision without explicit user approval or stronger current evidence.
