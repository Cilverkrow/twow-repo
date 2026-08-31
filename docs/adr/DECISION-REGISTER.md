# Decision register

Operational follow-up is maintained in [Open project threads](../OPEN-THREADS.md). Known implementation and operating hazards are maintained in [Footguns](../FOOTGUNS.md), and non-repository prerequisites are listed in [External requirements](../EXTERNAL-REQUIREMENTS.md).

## Accepted decisions

The accepted durable decisions are recorded by ADR-0001 through ADR-0019. They cover project governance, evidence authority, chat-history policy, repository boundaries, provenance, modularization, operational ownership, database safety, PlayerBot population constraints, persistent roster semantics, the external LLM bridge, personalities, donation progress, professions, riding, current runbook-evidence retention, and external Windows build inputs.

## Implemented but not automatically deployable

- The source-only GitHub repository exists independently from the live workspace.
- The collaboration hub and nine-workstream model are materialized and verified.
- Graceful shutdown helper behavior has passed its controlled evidence run.
- The donation progress table migration was applied and the feature-specific persistence path passed; an unrelated PlayerBot deadlock kept the broad runtime test's strict overall result at `FAIL`.
- Persistent-roster Phase B-R2 and LLM-bridge Phase B-R1 passed isolated tests and clean builds. Neither result authorizes production deployment.
- The 50-GUID roster shortlist, ordered snapshot, and unapplied `INITIALIZE` request were generated and verified in Phase C0. They were not applied.
- The 28-path persistent-roster integration passed unit tests, two real disposable-database adapter runs, and a clean Windows Release build. A local feature commit exists; the current repository handover integrates it into `main` without deploying it.
- Relevant sanitized text-only runbooks remain in this repository for the upcoming restructuring; a separate evidence repository is deferred.
- Binary Windows resource and library inputs remain external, pinned prerequisites under ADR-0019.

## Explicitly open or separately gated

| Topic | Current state | Required next decision |
|---|---|---|
| Persistent roster Phase C | Not deployed | explicit deployment/migration/config/process authorization |
| LLM bridge Phase C | Paused behind roster priority | explicit deployment and live-inference authorization after roster work |
| Master logout/group persistence | Deliberately excluded from minimal roster scope | separate design and test decision |
| 50/100/500/1000 class-race allocation | Weighted models exist; exact 50 cannot evenly cover 52 combinations | approve a concrete allocation before config generation |
| Seven schema-valid but factory-rejected race/class pairs | Verified technical mismatch | decide whether to extend the factory or retain the 52-pair boundary |
| Profession/riding rollout | Target accepted, changes not applied | approve coordinated Core, Config, migration, item manifest, build, and rollback task |
| Mount coverage | No broad migration allowed | complete and approve a spell/skill-derived mount manifest |
| Donation award amount | Runtime-owned configuration policy | do not infer from the table migration; approve separately if changing |
| Trainer money-loss remediation | Initial event was insufficient evidence; controlled normal-account purchase succeeded | no code or data change without a reproducible failure and new approval |
| Historic `manual` migration hashes | Names/order can match while content provenance is absent | retain the limitation; never treat `manual` as a cryptographic file hash |
| Roster expansion to 250/500 | Generic persistence supports it; only 50→100 has named unit and real-adapter proof | add isolated 100→250 and 250→500 persistence tests plus separate capacity measurements |
| Later evidence repository | No split now | reconsider only after restructuring with stable IDs and link/access/retention/sync contracts |

## Superseded or rejected approaches

- Copying or rewriting historical chats: rejected in favor of cross-references.
- Turning the live workspace into the Git repository: rejected in favor of an independent repository copy.
- Deep modularization before the first import: deferred.
- Committing binaries, live configs, database state, large client assets, logs, or credentials: rejected.
- Selecting “the first 50” RNDBOTs by query/login order or random choice: rejected.
- Replacing unavailable roster bots automatically: rejected.
- Reusing detached-thread/raw-`WorldSession*` delayed packet code for LLM completion: rejected.
- Letting the Core parse/extract bridge ZIPs: rejected; deployment tooling owns package verification and extraction.
- Broadly changing every level-40/60 item for early riding: rejected; manifest-driven coverage is required.
- Treating an unproven trainer event as authorization for repair: rejected.
