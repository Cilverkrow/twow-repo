# ADR-0011: Versioned transactional roster administration

- Status: Accepted, deployment pending
- Date: 2026-08-31
- Primary: WS-10 / WS-20

## Context

A stable roster needs reproducible identity, concurrent update protection, idempotent administration, auditability, and fail-closed startup. Ad-hoc SQL lists or config ordering do not provide those properties.

## Decision

Store immutable ordered roster versions with an atomic current-version pointer. Canonical snapshots and administrative requests use versioned UTF-8-without-BOM, LF-only serialization and SHA-256 digests.

Administrative operations use canonical lowercase UUIDv4 `operation_id` values and a canonical `request_sha256`. Replaying the same operation ID and request returns the stored result without mutation; reusing the ID with different bytes fails closed. Version creation, members, pointer update, request/result audit, before/after hashes, and concurrency check are one database transaction.

Supported operation semantics are `INITIALIZE`, append-oriented expansion/add, and explicitly audited remove/replace/rollback. Non-initialize operations require the expected current version. Concurrent full operations yield one winner and a version-mismatch loser with no loser mutation.

Runtime states separate desired membership, availability, and online state: `DISABLED`, `LOADING`, `STARTING`, `HEALTHY`, `DEGRADED`, `INVALID_FAIL_CLOSED`, `SHUTTING_DOWN`, and `STOPPED`. Invalid schema, pointer, order, uniqueness, or hash cannot self-repair.

Administration is local-console-only, requires maintenance mode and an offline roster, and returns restart-required after apply. RA and game chat are not administrative channels.

## Consequences

- Exact roster state is independently reconstructible and hashable.
- Database rollback and concurrency behavior are testable.
- Apply cannot mutate a live online roster.
- Phase B-R2 validated the real C++ adapter against disposable MariaDB instances; production migration and activation remain gated.

## Evidence

- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-analysis-01-package-closure-r1-20260830-223307/IMPLEMENTATION-CONTRACT-ADDENDUM.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938/RESULT.txt`
