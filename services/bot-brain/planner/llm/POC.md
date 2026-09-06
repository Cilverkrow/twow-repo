# Lane A1: offline memory / prompt / strict decoder PoC

Related to ARCH-002 (#43). **Not production-ready; not a live-LLM gate.**

`NewPoC(true, Config{Enabled: true, ...}, reader).PlanOne(ctx, request)` is
an explicit library entrypoint, demonstrated in `poc_test.go`. Nothing wires
it into `cmd/bot-brain`, config, the existing Planner or its fallback. Both
opt-ins must be explicit. The deterministic path and all existing files are
unchanged. No automatic retries, redirects, fallback LLM, or model switching.

## Deliberate bounds

- One snapshot / one bot / at most one HTTP call per invocation. Batch/wire
  changes belong to Pierre, not this experiment. No per-bot retained state.
- Stored canonical UUIDv4 is the memory key, never derived from realm/GUID.
  Missing UUID means no memory lookup; planning can remain stateless.
- Reader receives a deadline and limit 8. Wrong owner, excess rows, invalid
  observation or store failure rejects the experiment before inference. Normal
  production rule planning is untouched. A reader must honor cancellation.
- Memory is a **typed observation projection**, not unrestricted conversation:
  `completed`, `rejected`, `failed` for a current destination. Stale destination
  records are omitted. Free-text memory/personality ingestion is NOT implemented.
- At most 32 current POIs. Raw POI IDs are mapped to local `p0`, `p1`, ...;
  the model sees neither UUID, GUID, realm, character name, traits, coordinates,
  nor arbitrary store strings. Existing `redact` formats a reduced copy.
- Snapshot plus typed memory is JSON in a user DATA message. System instruction
  explicitly denies authority to that data. Typed projection, not prompt prose
  alone, prevents memory strings from becoming arbitrary instructions.
- Only idle/rest/travel_to in the PoC. Other existing wire intents are not
  removed; this entrypoint deliberately exposes a smaller vocabulary. Travel
  rejects combat/death/instances/group followers and cross-map destinations.
- Exact response projection: `{"choices":[{"message":{"role":"assistant",
  "content":"<JSON proposal>"}}]}`. Proposal is one `intents` entry with required
  `bot` (integer 0), `kind`, `certainty` (0..1) and conditional `poi_id` alias.
  No free rationale, tools, expiry supplied by model, null/defaulted fields,
  unknown/case-variant/duplicate keys, extra choices, fences or trailing prose.
  Lane A2 additionally permits the optional exact `usage` accounting triple
  documented in TOKEN-BUDGET.md; it never refunds the reservation.
  This projection is intentionally NOT compatibility certification for a real
  provider's richer response envelope. Existing provider auth adapters are reused.
- Strict checks precede existing `validate`, so its normalization/clamping is
  never used to repair a PoC answer. Bot identity and real POI are mapped back
  locally. The existing Intent validator is run afterward.
- Server timestamp and TTL required (1..30000ms), snapshot freshness checked;
  remaining time is bounded with a local monotonic context deadline, also after
  retrieval and decoding. Server-clock expiry remains request time + TTL; live
  delivery must still revalidate it. Response cap: 64KiB, oversize rejected.

## MariaDB / identity decisions: no invented production contract

Reviewed at base `ebebe4f9dbd46df2a0db128726abf781f2b14022`:

- ADR-0039: stored UUIDv4, durable state in `cv_brain`, module-owned migrations;
  it explicitly leaves vector retrieval design out of scope.
- Existing `modules/mod-bot-brain/sql/cv_brain/20260905120000_bot_identity_cv_brain.sql`
  defines identity, **not a memory/embedding table**.
- ADR-0027 / ARCH-002 name MariaDB 11.8 native VECTOR/HNSW and cosine;
  no external datastore is introduced.

Before real retrieval, owners must specify the versioned memory table and
columns, embedding dimension/model/version, distance/index contract, query
embedding source, ordering/tie-break, retention, and reader grants. This PR
creates no schema, SQL, grants, embedding service or fake production table.
`MemoryReader` is the narrow substitution seam; fixtures demonstrate only
retrieval plumbing, bounds and identity isolation. **REAL_VECTOR_VERIFIED=NO.**

The legacy C++ conversation persistence defect is not fixed here: C++ and
identity integration are outside Lane A1. This is not a durable-memory claim.

## Reproduction

Use the service's Go 1.23+ toolchain, network-disabled test container:

```sh
gofmt -l planner/llm/poc*.go
go vet ./...
go test -count=1 -timeout=60s ./...
go test -count=1 -timeout=60s ./...
```

All inference is `httptest`; all retrieval is a fixture. No model or database
is contacted. Local token accounting is described in TOKEN-BUDGET.md; cost
budgets, rate-limit handling, metrics, offline eval,
full README cleanup and real provider integration are separate later packages.
