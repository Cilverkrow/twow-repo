# ADR-0010: Persistent ordered GUID roster with no automatic replacement

- Status: Accepted, deployment pending
- Date: 2026-08-31
- Primary: WS-10

## Context

The legacy RandomBot system rotates active characters through expiring `add` leases. Repeated server sessions therefore expose different characters and can remove established group members, undermining persistent progression and relationships.

## Decision

Replace identity rotation with a versioned, ordered roster of `character_guid` values:

- initial target is exactly 50 explicitly selected RNDBOT GUIDs;
- the same GUIDs return after restart and timer expiry;
- membership is independent of login order, query order, `validIn`, online flags, and random selection;
- later growth is append-only: 50 to 100 preserves all existing GUIDs and order;
- unavailable, deleted, locked, banned, or failing members produce `DEGRADED` with exact diagnosis;
- there is no automatic trimming, filling, substitution, or replacement;
- removal or replacement requires an explicit audited administrative operation;
- grouped roster bots cannot be logged out or removed by rotation, lease, or population policy;
- normal AI, progression, travel, revive, and session behavior remains active; only identity rotation is suppressed.

Persistent-roster work takes priority over live LLM rollout because stable bot identity is a prerequisite for durable personality and relationship continuity. LLM work remains paused until separately resumed.

## Consequences

- Character progression stays attached to recognizable bots.
- Capacity loss is visible rather than hidden by replacement.
- A concrete 50-GUID shortlist was generated and verified, but the request remains unapplied and Phase C needs separate approval.
- Master-logout group persistence is intentionally outside the minimal scope.

## Evidence

- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/IMPLEMENTATION-CONTRACT-ADDENDUM.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938/REPORT.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/REPORT.md`
