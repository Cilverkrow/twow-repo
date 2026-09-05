# ADR-0001: Nine canonical workstreams and stable IDs

- Status: Accepted; amended 2026-09-05 (hub gate retired)
- Date: 2026-08-30
- Primary: WS-00

## Context

Local Codex tasks, online project chats, runbooks, source, configuration, operations, and documentation had overlapping names and ownership. Work could be routed differently depending on which chat was active.

## Decision

Use exactly nine canonical workstreams with stable technical IDs:

| ID | Title |
|---|---|
| WS-00 | Projektsteuerung und Workspace |
| WS-10 | SSC – Analyse und Entwicklung |
| WS-20 | Datenbank und Migrationen |
| WS-30 | Serverkonfiguration |
| WS-40 | Deployment und Skripte |
| WS-50 | Build und Serverbetrieb |
| WS-60 | Referenzserver und Backups |
| WS-70 | Bot-Persönlichkeiten |
| WS-80 | Dokumentation und Entscheidungen |

The ID is the stable identity; a later title refinement must not create a new workstream.
Tasks may name one primary owner and dependent workstreams when that helps coordination,
but these labels do not authorize work or act as a preflight gate.

The collaboration hub under `runbooks/workstreams` preserves the original routing map as
immutable historical evidence. It is not a current prerequisite, authority, or input.
Current work starts from `AGENTS.md`, the current tree and explicit authorization; GitHub
issues are the operational tracker. WS-00 remains a coordination label and WS-80 a
project-documentation label.

## Consequences

- Local and online work use matching titles.
- Each existing runbook object has one owner; overlap is expressed by references.
- Agents read root `AGENTS.md`; no hub preflight is required.
- Ownership labels guide communication but never override repository boundaries or the
  authorized mutation scope.

## Evidence

- `runbooks/project-structure-alignment-20260830T163408Z/project-structure-alignment-report-v1.md`
- `runbooks/project-collab-hub-01-20260830T174433Z/project-collab-hub-report-v1.md`
- `runbooks/workstreams/canonical-workstream-registry-v1.json`
- `AGENTS.md`
