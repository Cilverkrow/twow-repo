# ADR-0003: Historical chats are retained by cross-reference only

- Status: Accepted
- Date: 2026-08-30
- Primary: WS-00

## Context

The aligned online structure contains two non-canonical historical chats, while older discussions also contain misrouted subject matter. Copying complete histories would duplicate stale statements and obscure provenance.

## Decision

Apply this binding policy:

```text
HISTORICAL_CONTENT_POLICY=CROSS_REFERENCES_ONLY
COPY_OLD_CHAT_CONTENT=NO
REWRITE_OLD_CHAT_CONTENT=NO
DELETE_LEGACY_CHATS=NO
```

The online legacy chats `Bot Anzahl einschätzen` and `Serverdateien gemeinsam nutzen` remain unchanged. Future work is routed to the canonical workstream and may reference the historical chat. Histories are not merged physically or copied into new chats.

ADRs summarize durable decisions and cite evidence; they do not reproduce full chat transcripts.

## Consequences

- Historical context remains auditable.
- Canonical chats stay focused and do not inherit duplicated stale content.
- Legacy material cannot itself overrule current runtime or file evidence.

## Evidence

- `runbooks/project-structure-alignment-20260830T163408Z/project-structure-alignment-report-v1.md`
- `runbooks/project-structure-alignment-20260830T163408Z/proposed-ui-action-plan-v1.md`
