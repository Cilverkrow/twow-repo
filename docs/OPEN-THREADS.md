# Open project threads

Snapshot date: 2026-08-31. Primary owner: WS-80 for this index; each row names its operational owner.

An entry here is not authorization to start it. Before work, use `AGENTS.md`, resolve the owning workstream, verify its current evidence, and obtain any required mutation approval. Update this file when a thread is closed, split, superseded, or materially changed.

## P0 — blocks the intended bot/LLM architecture

| ID | Owner | Open thread | Confirmed current state | Required next gate |
|---|---|---|---|---|
| OT-001 | WS-10, WS-20, WS-30 | Integrate persistent-roster source into the real source tree | Phase B-R2 passed in an isolated worktree. The validated `PersistentActiveRoster*` files and migration are present only as runbook source copies; they are not in the repository's main `src/` tree. | Review the B-R2 source-copy set against current `main`, integrate it as a normal source commit, repeat adapter tests and clean build, and keep production untouched. |
| OT-002 | WS-10, WS-20, WS-30, WS-40, WS-50, WS-60 | Persistent-roster live Phase C | C0 produced a verified ordered 50-GUID snapshot and an unapplied canonical `INITIALIZE` request. No migration, active config change, candidate installation, apply, or restart test occurred. | Explicitly approve the final request and a live deployment task containing backup, migration, config, install, local-console apply, two-restart verification, and rollback. |
| OT-003 | WS-10 | Integrate the production LLM adapter into the real source tree | LLM Phase B-R1 passed isolated tests and a clean build. `ExternalLLMBridgeService.*` remains under runbook source copies, not the main `src/` tree. The root source contains the earlier local debug bridge instead. | Rebase the approved Phase B-R1 delta onto current `main`, review exactly the intended files, rerun the 683-case suite and clean build, and do not deploy. |
| OT-004 | WS-10, WS-30, WS-40, WS-50, WS-70 | LLM live Phase C | Paused behind stable roster identity. No production package installation, active config enablement, live child, Ollama inference, or game-chat delivery was authorized by the completed phases. | Finish OT-001/OT-002, define the deployment package and pins, then authorize a bounded live test separately. |
| OT-005 | WS-00, WS-40, WS-50, WS-60 | Repository-to-live deployment contract | The Git repository and live workspace are intentionally independent. There is no canonical manifest-driven synchronization or deployment pipeline between them. | Design a dry-run-first deployment manifest with explicit source/config/migration/script payloads, destination checks, backups, rollback, and no implicit live-tree overwrite. |

Primary evidence: [roster B-R2 report](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938/REPORT.md), [roster C0 report](../runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/REPORT.md), [LLM Phase B-R1 report](../runbooks/ssc-llm-production-bridge-01-phase-b-r1-20260830-194919/REPORT.md), and [ADR-0010](adr/ADR-0010-persistent-rndbot-roster.md).

## P1 — gameplay and production correctness

| ID | Owner | Open thread | Confirmed current state | Required next gate |
|---|---|---|---|---|
| OT-006 | WS-10, WS-50 | PlayerBot database deadlock | A MariaDB error 1213 occurred against `ai_playerbot_random_bots` during the donation runtime window. It was unrelated to donation progress but caused the strict overall test to fail. | Reproduce or instrument under a dedicated read-only/diagnostic task, locate transaction ordering, then approve any fix separately. |
| OT-007 | WS-10, WS-30 | Final class/race allocation | The effective RandomBot set has 52 combinations; exact equal distribution cannot total 50. Weighted matrices for 50/100/500/1000 exist but are not active config. | Approve a concrete allocation and generation policy before producing active config. |
| OT-008 | WS-10 | Seven factory-rejected combinations | The world schema permits 59 combinations, while the current factory permits 52. Seven combinations cannot be enabled safely through config alone. | Decide whether to retain the 52-pair boundary or implement and test a source extension for the seven pairs. |
| OT-009 | WS-10, WS-20, WS-30 | Player six-profession / RNDBOT two-profession split | Target policy is accepted; no coordinated source/config rollout is recorded. | Implement the RNDBOT cap across all acquisition paths first, build it, then change `MaxPrimaryTradeSkill` and test player/bot paths. |
| OT-010 | WS-10, WS-20, WS-30 | Early riding implementation | Level 5 / 5 silver and level 30 / 1 gold are accepted targets, but trainer rows, PlayerBot constants, and item requirements are not changed. | Complete source change, new forward migration, active-config review, build, controlled validation, and rollback package. |
| OT-011 | WS-20 | Complete mount coverage manifest | A broad level-40/60 item update is rejected. No approved complete spell/skill-derived mount manifest or migration exists. | Classify every mount spell/item, special case, source, and false positive; unresolved candidates block migration generation. |
| OT-012 | WS-20, WS-30 | Donation-points hardening and award policy | The progress table migration and feature-specific persistence path passed. Award amount policy, input bounds, eligibility, atomic grant/progress handling, shutdown flush, and World-thread query behavior remain unresolved. | Approve a hardening design and the desired amount/eligibility policy; do not infer these from the schema migration. |
| OT-013 | WS-20, WS-50 | Trainer purchase money-loss report | The original event had insufficient evidence. A controlled security-level-0 purchase persisted the spell and exact money delta and survived the immediate checks. | No repair now. Reopen only with a reproducible normal-account failure, bounded logs, and fresh before/after evidence. |

Primary evidence: [PlayerBot matrix report](../runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md), [profession/riding report](../runbooks/db-profession-riding-discovery-01-20260830-010856/report.md), [donation runtime report](../runbooks/donation-runtime-test-01-20260829-184426/final-report.md), and [ADR-0017](adr/ADR-0017-profession-and-riding-targets.md).

## P2 — provenance, maintainability, and operations

| ID | Owner | Open thread | Confirmed current state | Required next gate |
|---|---|---|---|---|
| OT-014 | WS-10, WS-50 | Stable build provenance | Commit `42b8a7f...` is the preferred captured source line, but the original production EXE is not bound to a complete clean-tree/toolchain manifest. | Produce a clean isolated build manifest or controlled reproducible build; never treat the embedded short revision as sufficient proof. |
| OT-015 | WS-20 | Historical migration content provenance | World migration tracker names/order match, but stored hashes are literal `manual`, not file digests. | Preserve the limitation; use fresh content hashes for new migrations and do not retroactively claim byte identity. |
| OT-016 | WS-10, WS-40, WS-70 | Incremental modularization | LLM transport, personality data, PowerShell lifecycle functions, and deployment payloads are not yet separated behind stable module contracts. | Extract one seam per reviewed change with tests and rollback; do not reorganize the live tree wholesale. |
| OT-017 | WS-60 | Reference-server and restore proof | Backups exist in historical evidence, but the repository cannot prove that a current off-host backup is complete or restorable. | Inventory the current backup location read-only, define retention, and run a disposable restore verification under explicit authorization. |
| OT-018 | WS-50, WS-60 | Client-side reproducibility | The repository contains only a small patch area, not the TWoW client, AddOns, MPQs, cache, extracted maps/DBC/vmaps/mmaps, or a canonical client manifest. | Create a sanitized client/add-on/patch manifest with hashes and acquisition/extraction instructions; keep large game files out of Git. |
| OT-019 | WS-00, WS-80 | Hub/index linkage for new repository docs | The collaboration hub is immutable without a dedicated hub-update task and does not yet index these new `docs/` status pages. | If desired, authorize a hub metadata-only update and regenerate its manifest without moving historical runbooks. |
| OT-020 | WS-00, WS-80 | Ongoing live-to-repository evidence sync | The current runbook import is a point-in-time copy. New live runbooks and decisions do not automatically enter Git. | Define a repeatable sanitized text-only import and review process with secret/binary gates. |
| OT-021 | WS-40, WS-50 | Automated repository validation | No project CI currently builds the fork or checks ADR links, text-only boundaries, manifests, or secrets on every push. | Add scoped CI after the build/dependency contract is stable; avoid uploading private runtime artifacts. |
| OT-022 | WS-80 | Project-specific root README cleanup | The root README is largely inherited and contains historical claims such as a permanently online ~1000-bot realm that are not current operational truth. | Rewrite or split the project-facing README while retaining upstream attribution and license context. |

## Deliberately separate decisions

- `MASTER_LOGOUT_GROUP_PERSISTENCE` remains outside the minimal persistent-roster implementation and needs its own analysis, implementation, and test task.
- Bot personality persistence and memory schema remain an integration task after stable roster identity; the personality contract does not itself authorize database tables.
- Legacy chats and compacted histories stay in place. They are referenced, not copied into the repository.
