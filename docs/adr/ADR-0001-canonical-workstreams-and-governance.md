# ADR-0001: Nine canonical workstreams and stable IDs

- Status: Accepted
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

The ID is the stable identity; a later title refinement must not create a new workstream. Every task has one primary owner and may name dependent workstreams. Unknown IDs and unresolved multi-owner conflicts block work.

The collaboration hub under `runbooks/workstreams` is the canonical routing map. WS-00 owns coordination and handoffs. WS-80 owns project-wide ADRs and indexes; detailed evidence stays with the owning workstream.

## Consequences

- Local and online work use matching titles.
- Each existing runbook object has one owner; overlap is expressed by references.
- Agents run the root `AGENTS.md` and hub preflight before acting.
- Routing errors are corrected through handoffs, not silent cross-workstream mutation.

## Evidence

- `runbooks/project-structure-alignment-20260830T163408Z/project-structure-alignment-report-v1.md`
- `runbooks/project-collab-hub-01-20260830T174433Z/project-collab-hub-report-v1.md`
- `runbooks/workstreams/canonical-workstream-registry-v1.json`
- `AGENTS.md`
