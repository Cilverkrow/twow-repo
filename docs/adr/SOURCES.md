# Reconstruction sources

Captured on 2026-08-31. This catalog records the decision-bearing source set used for the ADR reconstruction; it does not copy chat histories or secret-bearing runtime data.

## Current local Codex tasks

| Workstream | Task title | Thread ID | Coverage |
|---|---|---|---|
| WS-00 | `Projektsteuerung und Workspace` | `01a03ed1-7515-7bf1-bd6a-2d64acc8bb87` | project structure, hub, repository import |
| WS-10 | `SSC – Analyse und Entwicklung` | `01a04409-feb9-7813-ad82-46a022178ee3` | LLM bridge, source baseline, persistent roster |
| WS-20 | `Datenbank und Migrationen` | `01a03ee7-6aa3-7b90-ab47-a84feaef32b3` | migrations, donation points, professions, riding |
| WS-30 | `Serverkonfiguration` | `01a0539f-99ed-76a2-9c95-0066e98b47cb` | sanitized configuration ownership |
| WS-40 | `Deployment und Skripte` | `01a04405-40d1-7010-86b2-e067cfde30ff` | deployment helpers, shutdown, matrix discovery |
| WS-50 | `Build und Serverbetrieb` | `01a04406-8a78-7f62-98fe-0a35d91e5d8e` | build/runtime tests and trainer diagnostics |
| WS-60 | `Referenzserver und Backups` | `01a04407-4b7e-7d61-979f-aa906965de0a` | reference and backup ownership |
| WS-70 | `Bot-Persönlichkeiten` | `01a0539f-ddb6-7492-883a-56de64df918b` | personality ownership and hub compliance |
| WS-80 | `Dokumentation und Entscheidungen` | `01a053a0-1824-7e31-b646-37c54de2fd9f` | ADR and documentation ownership |

Archived local governance test consulted: `01a0541c-aaa7-73d3-9aad-bb210e4a5096`, title `Prüfe lokale Hub-Compliance`.

## Current online project chats

Project: `TWoW - Server` (`g-p-6a8ea2bb41948191ae804ba9469e3274`).

| Role | Chat title | Conversation ID |
|---|---|---|
| WS-00 | `Projektsteuerung und Workspace` | `6a8eda12-f028-83eb-8dc3-1b064a991b32` |
| WS-10 | `SSC – Analyse und Entwicklung` | `6a8edbc8-01d8-83eb-b5f6-7598dc0d75f4` |
| WS-20 | `Datenbank und Migrationen` | `6a8eddc0-7540-83eb-b38a-9508c4901257` |
| WS-30 | `Serverkonfiguration` | `6a8edc24-ff8c-83ed-ad15-fe940117a348` |
| WS-40 | `Deployment und Skripte` | `6a8edd8b-ff30-83ed-ad5f-fddff6b145af` |
| WS-50 | `Build und Serverbetrieb` | `6a94667a-6510-83eb-b82d-0330e4cb2205` |
| WS-60 | `Referenzserver und Backups` | `6a9466a8-6cfc-83eb-886f-eff12551ecce` |
| WS-70 | `Bot-Persönlichkeiten` | `6a8ff027-2fc4-83eb-8964-771e295ba863` |
| WS-80 | `Dokumentation und Entscheidungen` | `6a8ede01-1408-83eb-8891-1436269e5a68` |
| Legacy reference | `Bot Anzahl einschätzen` | `6a8cafc2-e448-83eb-b4a5-10ea136a8e21` |
| Legacy reference | `Serverdateien gemeinsam nutzen` | `6a8ea2d9-d850-83eb-900d-68457d5bf0c7` |

The current task histories and locally available Codex rollout sessions were inspected. Chat claims were accepted only when corroborated by checked-in evidence or a completed materialization record.

## Repository evidence

Primary sources:

- `AGENTS.md`
- `runbooks/workstreams/canonical-workstream-registry-v1.json`
- `runbooks/workstreams/README.md` and all nine Workstream READMEs
- `runbooks/project-structure-alignment-20260830T163408Z/`
- `runbooks/project-collab-hub-01-20260830T174433Z/`
- `runbooks/ssc-source-baseline-*`
- `runbooks/ssc-llm-bridge-*`
- `runbooks/ssc-llm-production-bridge-*`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-*`
- `runbooks/bot-personality-discovery-20260828-224032/`
- `docs/contracts/personality-context-contract-v1.md`
- `runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/`
- `runbooks/db-profession-riding-discovery-01-20260830-010856/`
- `runbooks/donation-point-*` and `runbooks/donation-runtime-test-01-20260829-184426/`
- `runbooks/shutdown-helper-console-lab/` and `runbooks/world-shutdown-smoke-evidence-*`
- existing repository boundary, provenance, security, and modularization documents
- Git history through the ADR parent commit

## Reconstruction limitation

The ADRs describe durable decisions, not every conversational suggestion. Proposals, failed gates, superseded values, and unexecuted plans remain marked as such in the decision register. Runtime, Git, hash, database, and manifest evidence outrank remembered or compacted chat content.

## 2026-08-31 TODO and restructuring consolidation

The online ChatGPT project `TWoW - Server` was reachable during this update. Its nine canonical chats and two legacy references were enumerated, and the currently relevant project-control, SSC, deployment, build, documentation, bot-count, and server-file discussions were consulted. Histories were not copied; actionable conclusions were reconciled against current repository and runbook evidence.

New primary evidence imported as sanitized text:

- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-recovery-20260831T220000Z/`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-repository-integration-closure-20260831T205652Z/`

The recovery evidence supersedes the earlier generic “MSBuild stalled” explanation with the reproducible blocker `RC2135 file not found: mangosd.ico`. The later repository-integration closure records the successful external-input recovery, clean build, candidate hashes, unchanged 28-path patch, and local `main` integration. Neither later package rewrites the earlier point-in-time evidence.

## 2026-09-01 configuration-as-code decision

ADR-0038 was imported from the verified local collaboration hub after explicit
acceptance. Its source identity was 3,257 bytes with SHA-256
`807FBDA1D13544255049625A507209D563AC9CE2941A35682833008A8805F30D`.
The repository implementation and formal drift-recovery closure are recorded in
`runbooks/ops-009-config-as-code-20260901/`; neither source copies nor approves
the active runtime configuration.

The semantic-baseline reconciliation for GitHub issue 31 is recorded separately
in `runbooks/ops-009-r1-semantic-baseline-reconciliation-20260901/`. It preserves
the first package as point-in-time evidence while superseding its configuration-
completeness claim with a classified 115-row repository contract.
