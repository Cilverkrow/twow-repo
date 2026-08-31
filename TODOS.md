# TWoW project TODOs

Snapshot: 2026-08-31. This is the repository-root entry point for unfinished work. Detailed evidence, ownership, and gates are maintained in [Open project threads](docs/OPEN-THREADS.md). An unchecked item is not authorization to execute it.

## Current handover state

- Repository `main` was clean at `f1f2e01026e54cd5c119c1e8e95fc107a01f4e2b` before this documentation handover began.
- The persistent-roster change is secured as an exact 28-path local feature commit on `work/ot-001-r1-persistent-roster-integration`; this handover operation will rebase and fast-forward it into `main` after the documentation commit.
- Unit tests, two real disposable-MariaDB adapter runs, and a clean Windows Release build passed. The required icon and compiled libraries were verified external inputs, removed from the feature worktree after the build, and were not staged.
- The 50-GUID initial roster and canonical request are verified but unapplied. Phase C, deployment, active configuration changes, production database changes, bot login, and LLM live work remain unauthorized.
- The live workspace and this repository are separate. Never treat a commit as deployment.

Primary current evidence: [OT-001 integration](runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/REPORT.md), [build recovery](runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-recovery-20260831T220000Z/REPORT.md), [roster C0](runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/REPORT.md), and [Claude Code handover](docs/HANDOVER-CLAUDE-CODE.md).

## P0 — architecture and release blockers

- [ ] **OT-025 — Claude Code repository restructuring (WS-00/WS-10/WS-40/WS-50/WS-80).** Start from the documented handover, preserve the current feature worktree and upstream history, propose module boundaries before moves, and perform restructuring in isolated reviewed commits. Do not refactor the live tree.
- [ ] **OT-002 — Persistent-roster Phase C (WS-10/WS-20/WS-30/WS-40/WS-50/WS-60).** Only after an integrated clean build: approve backup, migration, config, candidate installation, local-console `INITIALIZE`, exact 50-GUID verification, two restarts, and rollback as a separate live task.
- [ ] **OT-003 — Integrate the production LLM adapter (WS-10).** Rebase the validated Phase B-R1 adapter onto current source, review the bounded delta, repeat its deterministic suite and clean build, then commit without deploying.
- [ ] **OT-004 — LLM live Phase C (WS-10/WS-30/WS-40/WS-50/WS-70).** Keep paused until stable roster identity and the deployment/package contract exist; require a separately approved bounded live-inference test.
- [ ] **OT-005 — Repository-to-live deployment contract (WS-00/WS-40/WS-50/WS-60).** Design a manifest-driven, dry-run-first deployment with destination pins, backups, rollback, process ownership, and no implicit synchronization.

## Completed in the current handover

- [x] **OT-023 — Windows resource provenance gate (WS-10/WS-50).** ADR-0019 keeps the verified icon and compiled libraries as pinned external build prerequisites. Temporary materialization and cleanup are documented in `docs/BUILD-RESOURCES.md`.
- [x] **OT-001 — Persistent-roster source integration (WS-10/WS-50).** Exactly 28 approved source paths passed scope/security gates, two fresh unit runs, two previously verified disposable-database adapter runs, and a clean Release build. A source commit exists and is being integrated into `main` by this handover; no build output is tracked or deployed.

## P1 — correctness and scale

- [ ] **OT-024 — Roster expansion and capacity proof (WS-10/WS-20/WS-50).** Extend isolated tests from the proven 50→100 path through 100→250 and 250→500. Verify full-version persistence, ordering, hashes, restart recovery, retained older versions, failure rollback, and separately measure startup/login/CPU/RAM capacity. Changing `MinRandomBots` or `MaxRandomBots` is not a persistent expansion.
- [ ] **OT-006 — PlayerBot database deadlock (WS-10/WS-50).** Reproduce or instrument MariaDB error 1213 around `ai_playerbot_random_bots`; approve a fix only after transaction ordering is proven.
- [ ] **OT-007 — Final class/race allocation (WS-10/WS-30).** Choose an explicit weighted allocation for 50/100/500/1000; 50 cannot evenly cover the effective 52 combinations.
- [ ] **OT-008 — Seven factory-rejected combinations (WS-10).** Retain the 52-pair boundary or implement and test support for the seven schema-valid rejected pairs.
- [ ] **OT-009 — Six player professions / two RNDBOT professions (WS-10/WS-20/WS-30).** Implement and verify the bot-specific cap across every acquisition path before raising the player limit.
- [ ] **OT-010 — Early riding rollout (WS-10/WS-20/WS-30).** Coordinate source thresholds, forward migration, trainer prices, approved mount-item manifest, build, validation, and rollback.
- [ ] **OT-011 — Complete mount coverage manifest (WS-20).** Classify every relevant mount spell/item and special case; unresolved entries block migration generation.
- [ ] **OT-012 — Donation-point hardening (WS-20/WS-30).** Decide award bounds and eligibility, then address atomic grant/progress behavior, failure handling, shutdown flush, and World-thread query cost.
- [ ] **OT-013 — Trainer money-loss report (WS-20/WS-50).** Keep closed to repair unless a normal-account failure becomes reproducible with fresh before/after evidence.

## P2 — maintainability, operations, and provenance

- [ ] **OT-014 — Stable build provenance (WS-10/WS-50).** Establish a clean-tree/toolchain/resource manifest that binds source, dependencies, required non-source assets, EXE, and PDB.
- [ ] **OT-015 — Historical migration provenance (WS-20).** Preserve the limitation of tracker value `manual`; use cryptographic content hashes for all new migrations.
- [ ] **OT-016 — Incremental modularization (WS-10/WS-40/WS-70).** Extract stable seams for roster policy, LLM transport, personality data, shared PowerShell lifecycle functions, and manifest-driven deployment. Avoid a single unreviewable move.
- [ ] **OT-017 — Reference-server and restore proof (WS-60).** Inventory current backups read-only, define retention, and prove restore in a disposable target.
- [ ] **OT-018 — Client reproducibility manifest (WS-50/WS-60).** Record sanitized client/AddOn/patch identities and data-extraction instructions without committing MPQs, cache, or the game installation.
- [ ] **OT-019 — Hub/index linkage (WS-00/WS-80).** Update immutable hub metadata only through a dedicated authorized task; do not casually edit its registry or manifest.
- [ ] **OT-020 — Repeatable live-to-repository evidence sync (WS-00/WS-80).** Define an allowlisted text-only import process with secret, binary, size, link, and manifest checks. The two latest OT-001 packages are now imported, but synchronization is still manual.
- [ ] **OT-021 — Repository CI (WS-40/WS-50).** After the build contract stabilizes, add checks for links, manifests, secrets, binaries, formatting, tests, and an appropriately provisioned build.
- [ ] **OT-022 — Project-facing root README (WS-80).** Separate current project truth from inherited upstream/historical claims while retaining attribution and license context.
- [ ] **OT-026 — Later runbook-repository decision (WS-00/WS-80).** Keep sanitized text-only runbooks here for the present restructuring. Evaluate a separate evidence repository later only with stable IDs, immutable history, link migration, retention, access, and secret policy.

## Non-negotiable guardrails

- No binaries, archives, live configurations, database dumps, credentials, runtime logs, client game data, or secret-bearing evidence in Git.
- No Phase C, deployment, migration, process control, or live inference is authorized by this checklist.
- Preserve upstream history and the tested OT-001 feature commit until its `main` integration and remote push are verified.
- Historical chat content remains in place. Record decisions and actionable conclusions, not transcript copies.
- See [Footguns](docs/FOOTGUNS.md), [External requirements](docs/EXTERNAL-REQUIREMENTS.md), and the [ADR index](docs/adr/README.md) before restructuring.
