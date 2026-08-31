# Claude Code handover: repository restructuring

This handover prepares a future, explicitly authorized refactoring of the independent repository. It is not authorization to mutate the live server, deploy, run Phase C, or discard the current feature worktree.

## Read first

1. Root [AGENTS.md](../AGENTS.md)
2. Root [TODOs](../TODOS.md)
3. [Open threads](OPEN-THREADS.md)
4. [Footguns](FOOTGUNS.md)
5. [External requirements](EXTERNAL-REQUIREMENTS.md)
6. [ADR index](adr/README.md), especially ADR-0002, ADR-0004, ADR-0005, ADR-0008, ADR-0010 through ADR-0015, ADR-0018, and ADR-0019
7. [Repository boundaries](REPOSITORY-BOUNDARIES.md), [provenance](PROVENANCE.md), and [modularization roadmap](MODULARIZATION-ROADMAP.md)

## Verified starting state

- The independent Git repository is `C:\TW\GitHub\twow-repo`; the live/agent workspace is `C:\TW\ComTW`. They are deliberately not synchronized automatically.
- Pre-documentation `main` and `origin/main` were `f1f2e01026e54cd5c119c1e8e95fc107a01f4e2b`.
- The exact 28-path persistent-roster delta is integrated on local `main` as commit `3c2b93102d2106cc7c4f9170598b56de060b41d3`, parent `f28d9abf415f91174114b20e11f21e9c659faaa0`, with stable patch ID `acd6fb63b7ede8882c20422f9b903161f2cd33b6`.
- Two fresh unit runs, two real disposable-MariaDB adapter runs, and a clean Windows Release build passed. Candidate EXE/PDB files remain local and untracked.
- ADR-0019 resolves the Windows resource boundary: the icon and compiled libraries are pinned external prerequisites. Their temporary copies/junctions were removed after the successful build.
- The 50-GUID roster request is validated but unapplied. Production code, executable, configs, database, and processes were not changed by OT-001.

Evidence: [integration report](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/REPORT.md), [recovery report](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-recovery-20260831T220000Z/REPORT.md), [repository integration closure](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-repository-integration-closure-20260831T205652Z/REPORT.md), and [C0 report](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/REPORT.md).

## Refactoring objectives

Propose the target architecture before moving files. The desired separations are:

- upstream-compatible Core versus project-owned extensions;
- persistent roster policy/storage/admin contract versus legacy random-bot rotation;
- PlayerBot integration points versus the external LLM transport adapter;
- versioned personality/prompt/memory data versus C++ transport code;
- reusable PowerShell lifecycle/process/path helpers versus individual deployment scripts;
- append-only migrations versus backups and live database state;
- source/config templates versus manifest-driven deployment payloads;
- concise durable documentation versus immutable historical evidence.

Prefer narrow interfaces and dependency direction over directory movement alone. Preserve behavioral tests around every extracted seam.

## Required approach

1. Inventory current source ownership, CMake targets, configuration keys, migrations, operations scripts, runbooks, and tests.
2. Verify the active branch/worktree topology and protect the 28-path OT-001 delta. Do not reset, clean, rebase, or overwrite it without a separate approved integration plan.
3. Preserve ADR-0019's external-input boundary. Do not claim the source-only checkout is a self-contained Windows build.
4. Produce a proposed target tree, dependency diagram, migration map, and commit sequence. Identify compatibility shims and rollback for every step.
5. Refactor only in a new branch/worktree from the explicitly selected base. Keep each extraction buildable and reviewable.
6. Preserve upstream comparison. Avoid wholesale formatting, line-ending normalization, or unrelated cleanup.
7. Keep active configs, credentials, runtime binaries, game data, databases, build trees, and raw logs outside Git.
8. Treat checked-in runbooks as text evidence, not deployment input. Do not rewrite historical evidence; add corrections or cross-references.
9. Re-run scope, secret, binary, oversized-file, link, manifest, unit, adapter, and clean-build gates after relevant steps.
10. Stop before deployment, database mutation, active config changes, process control, bot login, or live LLM inference.

## Proposed refactoring sequence

1. **Baseline closure:** verify the final pushed `main`, OT-001 commit, clean-build identity, and external-input contract before creating the refactoring worktree.
2. **Module contracts:** define roster, LLM transport, and personality interfaces without changing runtime behavior.
3. **Operations library:** extract shared Windows lifecycle, process identity, dry-run, and logging functions.
4. **Deployment contract:** introduce a declarative manifest and verifier; keep execution disabled by default.
5. **Documentation/evidence boundary:** retain current text runbooks, add stable evidence identifiers, and design—without executing—a possible later repository split.
6. **CI:** add portable checks first; add provisioned Windows builds only after external dependency/resource contracts are explicit.

## Questions that must remain explicit

- How will future build agents provision and verify ADR-0019's external resource and compiled-library inputs without distributing them through this repository?
- Which custom Core changes should become independent modules, and which must remain integration hooks in upstream files?
- What is the versioned schema for personality, memory, and verified game context?
- How are deployment manifests generated, reviewed, signed/hashed, applied, and rolled back?
- How will old repository-relative runbook links survive any later evidence-repository split?
- Which tests are mandatory at 50, 100, 250, and 500 persistent bots, and which measurements define acceptable capacity?

## Completion criteria for the refactoring proposal

A proposal is ready for approval only when it includes the target tree, interface boundaries, dependency direction, per-step commits, test matrix, migration/link plan, rollback strategy, unresolved decisions, excluded scope, and proof that the live workspace and current feature worktree remain untouched.
