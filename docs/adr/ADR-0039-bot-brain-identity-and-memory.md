# ADR-0039: Out-of-process bot planning, with a stable identity and durable memory

- Status: Accepted
- Date: 2026-09-05
- Primary: WS-10 / WS-20

## Context

`services/bot-brain` plans bot behaviour out of process; `modules/mod-bot-brain` attaches to the
worldserver and applies the result. Both are built and unit-tested, and no bot has yet acted on
an intent (#155).

Two prior decisions bound this work and are **not** reopened here. ADR-0012 and ADR-0013 were
amended on 2026-09-02 so that their *transport* half is superseded — Windows named pipes and an
owned child process gave way to an HTTP service — while their *discipline* half stands:

- fail-closed admission, with bounded queue, message, context, deadline and concurrency limits;
- **World/AI objects and raw pointers never cross the worker boundary**;
- unknown or extra data closes admission;
- **no automatic retry, no resubmit, no fallback LLM, no automatic restart**;
- normal bot AI continues when the planning path rejects or fails.

Two of those are already load-bearing in code rather than prose: `contract/wire.go`'s
`countUnknown` implements the third, and `BotBrainClient.h:41-44` implements the second as a type
signature — everything crossing the boundary is `std::string` or `uint32_t`, so the detached
thread cannot name a `WorldSession` (the LLM-012 use-after-free).

What this ADR adds is what the owner asked for and the current design forbids: the brain must
identify bots stably and remember things about them. `cmd/bot-brain/main.go:3-6` states the
opposite — "It holds no per-bot state between requests" — so that invariant is amended
deliberately rather than eroded by a commit.

## Decision

### 1. Bot identity is a stored UUID, not a derived one

Each bot gets a **version-4 UUID, minted once and stored** in a project-owned mapping to
`(realm, guid)`. The brain uses only the UUID as a key.

Identity is **not** derived from `realm:guid`, and the reason is
`core/tools/RealmMerge/RealmMerge.cpp:190`:

```sql
UPDATE `characters` SET `guid` = (`guid` + %u)
```

A realm merge shifts every character GUID by an offset. A UUIDv5 over `"realm:guid"` would
therefore produce a different identity for the same character, orphaning every stored fact about
it — with **no repair**, because the identity would be a pure function of a value that moved.

A stored UUID survives the same event: the identity does not change, and only the mapping's
`guid` column needs the `+ offset` the merge tool already applies to twenty other tables. That is
one additional `UPDATE` in a tool built to do exactly that.

Consequence worth stating: because the brain keys on a UUID, a raw game GUID is never a storage
key, never a metric label, and never reaches an LLM prompt. `planner/llm/llm.go:398-431` already
redacts identifiers; this makes that structural rather than careful.

### 2. Durable brain state lives in a `cv_brain` MariaDB schema

Per **ADR-0027**, which already decided this and anticipated the question: MariaDB is the single
database platform for "upstream schemas, project module schemas, **and any future service
schema**", and "vector storage for bot memory uses MariaDB's native `VECTOR` type. No separate
vector database is introduced." The stack runs `mariadb:11.8`, which has `VECTOR`, so retrieval
over bot memory grows into the same engine later with no change of infrastructure.

`cv_bots` is **not** that store, measured rather than assumed: its `data` column is
`varchar(255)` and its `value` column is `bigint`, keyed `UNIQUE (owner, bot, event)`. That is
upstream's random-bot event-marker store and it is good at that. A failure counter fits in
`value`; a persona does not fit in 255 bytes and a memory certainly does not. `cv_bots` stays the
worldserver's, untouched.

`cv_brain` is created and granted the way `cv_bots` already is in `deploy/compose/db-init.sh` —
`:115` creates it, `:130` grants a set narrower than the `GRANT ALL` the four `tw_*` schemas get.
The brain gets **its own database user** with rights to `cv_brain` and nothing else; the
worldserver's user gets no access to `cv_brain`. Its migrations run through core's `AutoUpdater`
like every other schema (ADR-0007 as amended).

### 3. The statelessness invariant is amended, not abandoned

It becomes: **the process holds no state in memory between requests; durable brain-derived state
lives in `cv_brain`; the worldserver remains authoritative for all game state.**

The property the original invariant protected is preserved — the process can be killed, scaled or
replaced at any moment without a bot noticing — because the store is external to the process
rather than inside it.

The line that does not move: **brain state is derived and advisory.** It is a record of what the
brain decided and observed. It never becomes something the game reads as truth, and it is never
a second source for data the worldserver owns.

### 4. Batching is the unit of work

One request carries many snapshots and returns many intents. `contract/wire.go:16-20` already
states why, and the client currently contradicts it by sending one snapshot per request.

## Consequences

- The brain acquires a database dependency it did not have. `/readyz` must reflect store health,
  and a store outage must degrade to stateless planning rather than to no planning — the
  fail-closed rule in ADR-0012 governs admission, not availability of memory.
- Identity requires a mapping table and a mint-on-first-sight path, which is new state in the
  worldserver's care and a new failure mode: a bot seen before the mapping exists must be
  planned for without memory rather than refused.
- `RealmMerge` gains a project-owned table it must migrate. If that line is forgotten, brain
  state silently attaches to the wrong character — the worst outcome available here, and the
  reason it is named in this ADR rather than left to the tool's author to notice.
- Adding the UUID to the wire is additive, so `VersionMinor` bumps and both declarations move
  together, enforced by `ops/ci/check-contract-version.sh`.
- Vector memory and retrieval are **not** in scope. The `VECTOR` column is available when there is
  something worth embedding; deciding the retrieval design before there is any memory to retrieve
  would be guessing.

## Evidence

- `core/tools/RealmMerge/RealmMerge.cpp:190` — the GUID shift that rules out a derived identity.
- `modules/mod-playerbots/sql/cv_bots/20260901190000_ai_playerbot_random_bots_cv_bots.sql` —
  `data varchar(255)`, `value bigint`, `UNIQUE (owner, bot, event)`.
- `deploy/compose/db-init.sh:115,126-130` — the schema-creation and narrower-grant precedent.
- `services/bot-brain/cmd/bot-brain/main.go:3-6` — the invariant this ADR amends.
- `services/bot-brain/contract/wire.go:16-20` — batching as the stated design.
- `modules/mod-bot-brain/src/BotBrainPipeline.cpp:649-657` — the client that contradicts it.
- `modules/mod-bot-brain/src/BotBrainClient.h:41-44` — the worker boundary as a type signature.
- `docs/adr/ADR-0027-database-platform.md` — MariaDB for any future service schema; native
  `VECTOR` for bot memory.
- `docs/adr/ADR-0012-external-llm-process-and-fail-closed-admission.md` and `ADR-0013-*` — the
  admission and protocol discipline that survives their transport amendment.
