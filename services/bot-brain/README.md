# bot-brain

The out-of-process bot planning service. First deliverable of **ARCH-001**
("Externalize slow bot planning behind a snapshot/intent contract").

**The deliverable is the contract, not the planner.** Everything in
[`contract/`](contract/) is meant to be depended on and argued about; everything
else is a working demonstration that the contract is implementable.

---

## Why this exists

Bot AI today is `core/modules/mod-playerbots/`, 462 C++ files of which 413 are the
decision engine under `src/playerbot/strategy/`. **Changing one of those files
costs 326 seconds of rebuild and relink.** That is the number this service
exists to remove: a policy change here is an environment variable and a
container restart.

ARCH-001 splits bot cognition by latency, not by module:

| Tier | Runs where | Budget | Status |
|---|---|---|---|
| 0 | C++ in-core, on the map-update threads | per-tick | stays, and is the fallback |
| 1 | WASM policies inside the tick | per-tick, no network | ARCH-004, not started |
| 2 | **External planner, this service** | 100 ms – seconds | this repo directory |
| 3 | Headless protocol clients | network | ARCH-005, costed and deferred |

Tier 0 keeps every per-tick decision forever. This service only ever answers
slow questions: where should this bot go, what should it work on next.

---

## What actually works today

Verified by `go test ./...` and by running the binary:

- **The contract.** Snapshot, intent, batch envelope, version negotiation,
  skew-tolerant decoding. Fully specified and tested.
- **The deterministic planner** (`planner/rule`). A priority ladder that answers
  every snapshot in a batch, with no network, no clock and no randomness.
- **The fallback wrapper** (`planner.Fallback`). Structurally guarantees that a
  slow or broken primary planner never costs a bot its plan.
- **The HTTP server.** `/healthz`, `/readyz`, `/metrics`, `/v1/contract`,
  `POST /v1/plan`. Batches of 1000 bots are exercised in tests.
- **Prometheus metrics**, hand-rolled so the module has zero dependencies.
- **Config**, entirely from environment. An unset value takes a default that
  produces a working service; a value that is *set but unreadable* fails
  startup, naming every bad variable at once rather than quietly running on a
  default nobody chose. A startup check also refuses the one *valid* combination
  that would silently defeat the whole design (an LLM timeout with no budget
  left for the fallback).

## What exists but has never run for real

- **The C++ integration** (`modules/mod-bot-brain`). The seam, the client, the
  config flag and the wire codec all exist and are unit-tested; the module
  attaches through `RegisterAiContextAugmenter` with zero delta to the bot tree.
  What has never happened is a bot taking an intent from it (#155). Until that
  does, treat this end as unproven rather than done.

  Three known gaps between the two sides, all verified in the tree:

  - The client sends **one snapshot per request**, which is the thing this
    package's own contract doc warns against; `MaxBatch = 2048` is decorative
    until that changes.
  - Only the **first** intent in a response is applied. Harmless today because
    responses carry one, and a silent dropper of N-1 intents the moment
    batching lands - so the two must change together.
  - The handshake runs **once at startup and is never retried**, so a service
    that restarts leaves the brain off for the worldserver's whole lifetime.
- **Durable identity and memory.** ADR-0039 decides both - a stored v4 UUID and
  a `cv_brain` schema - and the UUID now travels on the wire. The store itself
  is created but nothing writes to it yet.

## What is a skeleton

- **The LLM planner** (`planner/llm`). Its *plumbing* is real and tested against
  `httptest`: config surface, per-provider auth, request construction, response
  parsing, hostile-input validation, timeout, circuit breaker, egress filter.
  Its *judgment* is not: the prompt is a first draft with no evaluation behind
  it, there is no token budget, no cost cap and no rate-limit handling. ARCH-003
  requires all three before this is pointed at a metered cloud endpoint.
- **The intent vocabulary** is a starting set. It covers travel, quests, vendors
  and rest — the "slow-cadence and self-contained" family ARCH-001 names as the
  first thing to prove.

## What does not exist at all

- **gRPC/protobuf.** ARCH-001 names protobuf as the eventual transport and that
  is still right. This is HTTP/JSON so the C++ side can be developed against it
  with curl. The `contract` package is transport-agnostic; adding gRPC is
  generating a `.proto` from those structs plus a second handler.
- **The snapshot recorder and the mock world server.** ARCH-001 asks for
  fixtures recorded from a live server. The tests here use invented snapshots,
  which is exactly the weakness that document warns about.
- **Any measurement.** ARCH-001's decision gate is p99 intent latency, messages
  per second at 1000 bots, and worldserver CPU delta. **None of those numbers
  exist yet**, and nothing here should be taken as evidence about them.

---

## The contract

### Snapshot: what the server tells the brain

Per bot: identity (`realm` + character low GUID), slow character state (level,
class, race, faction, money, free bag slots, personality trait keys), position
(map-local yards), coarse vitals (percentages, plus dead/combat/resting/mounted
flags), aggregate surroundings (**counts**, not entity lists), the quest log as
ids and progress, a list of **server-resolved destination candidates**, and the
outcome of the previous intent.

The single most important shape is `PointOfInterest`. **The brain never
discovers places** — it chooses among places the server already resolved and
handed it by opaque id. A brain that could name arbitrary coordinates would be a
brain that can walk bots into geometry.

### What is deliberately NOT in the snapshot

| Excluded | Why |
|---|---|
| Auras, cooldowns, threat tables, per-target health | Tier 0 owns combat. Acting on this at tier-2 latency is how you get a planner making dangerous rotation decisions on data that is seconds old. |
| Entity lists of any kind | At 1000 bots per tick this is the payload that kills the design. Counts and one or two distances carry every decision this tier makes. |
| Full inventory and item lists | Same bandwidth argument. Aggregates (free slots, money, average durability) are what the decisions actually turn on. |
| Quest text, objective text, any localised content | The server owns the quest template. Localised prose in a payload that may reach a cloud provider is bandwidth and an egress problem at once. |
| Navmesh, paths, waypoints | The server paths. The brain names a destination and nothing more. |
| Pointers, session handles, `Player*`/`Unit*` anything | ADR-0012: no world or AI objects cross the worker boundary. Not negotiable. |
| Account ids, IPs, real player names, chat logs | ARCH-003 egress rule. Snapshots may reach a third party. |
| Cross-map destination candidates | Cross-map travel means flight paths, which is a tier-0 decision. |

### Intent: what the brain tells the server

An intent names a goal for one bot: `idle`, `travel_to`, `pick_quest`,
`turn_in_quest`, `abandon_quest`, `grind_area`, `vendor_sell`, `repair`, `rest`.
It carries a POI id (never coordinates), a confidence, an expiry in the
server's clock, and a debug rationale.

**Intents are advisory.** The worldserver revalidates every one against live
state and may reject it; rejection comes back on the next snapshot's
`last_outcome` and is a normal outcome, not an error.

### How ADR-0024 invariant 1 is enforced

A bot must never be lost. Three layers, in order of how hard they are to
subvert:

1. **Vocabulary.** There is no intent kind that creates, deletes, relocates,
   re-rolls, logs out or substitutes a bot. Adding one requires editing
   `contract/intent.go`, and `TestNoIntentKindTouchesIdentity` fails if anyone
   tries. The brain cannot express the dangerous thing.
2. **The model never names a bot.** The LLM planner sends batch *indices*, not
   GUIDs, and maps replies back to identities it already held. A hallucinated
   GUID cannot address anything.
3. **The transport drops strays.** Any intent for a bot that was not in the
   request is discarded and counted (`botbrain_dropped_intents_total`), so a
   planner bug becomes a metric rather than a misdirected bot.

---

## Versioning and skew

The C++ side and this service deploy separately and **will** skew. That is
treated as the normal case, not an exception.

Every request and response carries `contract_version` as `MAJOR.MINOR`:

- **MAJOR** changes are breaking — a field removed or repurposed, a unit
  changed, an intent kind's meaning changed. A peer on a different major is
  refused with **HTTP 409** and a body listing `supported_majors`. Refusal is
  correct: the worldserver's response is to stop calling the brain and run
  tier-0 AI, which is always available (ADR-0024 invariant 6, fail closed to
  core behaviour rather than to wrong behaviour).
- **MINOR** changes are additive — new optional fields, new intent kinds. Both
  sides ignore what they do not recognise.

Concretely:

| Peer sends | This build does |
|---|---|
| `1.0` | Serves, stamps `1.0`. |
| `1.9` (newer C++, older service — the usual rolling-deploy direction) | Serves, ignores the unknown fields, **counts them** in `stats.unknown_fields` and `botbrain_unknown_fields_total`, stamps `1.0`. |
| `1.0` from a build that is behind (older C++, newer service) | Serves, stamps down to the peer's minor so it is not told about fields its decoder predates. |
| `2.0` | **409**, `code: "version_skew"`, plus the supported majors. |
| nothing at all | **409**. A missing version is never defaulted — guessing the peer's version is how skew becomes wrong behaviour instead of an error. |

`GET /v1/contract` returns the version, supported majors, known intent kinds and
batch cap, so the C++ side can check skew **once at startup** rather than
discovering it one dropped intent at a time in production.

`botbrain_unknown_fields_total` is the number to watch during a rolling deploy.

### Two clocks, one time base

The worldserver and this service do not share a clock, and container clock skew
is real. So:

- `sent_at_ms` and `observed_at_ms` are **the server's clock**.
- `expires_at_ms` on an intent is computed as `sent_at_ms + TTL` — never from
  this process's own `time.Now`. It is enforced by the side that stamped it.

This is also the main defence against a slow brain: an intent that took eight
seconds to produce arrives already expired and is dropped, rather than sending a
bot somewhere it decided to go a long time ago.

---

## Never block on inference

`planner.Fallback` wraps a primary planner (typically the LLM) with a
deterministic secondary and a hard timeout. Whatever the primary has not
answered for — because it timed out, errored, was skipped by its circuit
breaker, returned malformed intents, or simply answered for fewer bots than it
was given — the rule planner answers for. Partial results from a slow primary
are kept.

Readiness deliberately **does not** depend on the LLM. A brain with a dead model
is still a working brain; reporting unready would remove a healthy instance from
rotation for a condition it is designed to survive.

The one misconfiguration that would defeat all of this — a model timeout as long
as the whole batch deadline, leaving the fallback no budget — is a **startup
failure**, not a warning.

---

## Running it

```bash
cd services/bot-brain
go test ./...        # no network needed, no external dependencies
go run ./cmd/bot-brain
```

```bash
docker build -t twow/bot-brain:dev services/bot-brain
docker compose -f deploy/compose/bot-brain.yml up -d --build
```

`deploy/compose/bot-brain.yml` is a **separate** compose file and is not
referenced by `docker-compose.yml`. The server stack must keep starting and
playing with this service absent (ADR-0024 invariant 4), and the simplest way to
guarantee that is for the main compose file not to mention it.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Liveness. Never consults the planner: a liveness probe that fails on a dependency gets the container killed for something a restart cannot fix. |
| GET | `/readyz` | Readiness. 503 while draining or if the deterministic planner is somehow unavailable. Ignores the LLM. |
| GET | `/metrics` | Prometheus text exposition. |
| GET | `/v1/contract` | Version, supported majors, intent kinds, batch cap. For startup skew detection. |
| POST | `/v1/plan` | The batch endpoint. |

### A batch, end to end

```bash
curl -s localhost:8085/v1/plan -H 'Content-Type: application/json' -d '{
  "contract_version": "1.0",
  "request_id": "tick-8814",
  "sent_at_ms": 1700000000000,
  "deadline_ms": 1000,
  "snapshots": [{
    "bot":   {"realm": 1, "guid": 101},
    "char":  {"name": "Ashfang", "level": 24, "class": 1, "race": 2,
              "faction": "horde", "free_bag_slots": 0},
    "pos":   {"map_id": 1, "x": 100, "y": 200, "z": 30},
    "vitals": {"health_pct": 95, "durability_pct": 80},
    "surroundings": {"group_size": 1},
    "observed_at_ms": 1699999999000,
    "pois": [{"id": "v7", "kind": "vendor",
              "pos": {"map_id": 1}, "distance_yards": 120}]
  }]
}'
```

```json
{
  "contract_version": "1.0",
  "request_id": "tick-8814",
  "intents": [{
    "bot": {"realm": 1, "guid": 101},
    "intent_id": "i-cd54dcf9c00ef43d2b96974f",
    "kind": "vendor_sell",
    "travel": {"poi_id": "v7"},
    "confidence": 0.8,
    "expires_at_ms": 1700000030000,
    "source": "rule",
    "rationale": "bags full -> vendor v7"
  }],
  "stats": {"snapshots_in": 1, "intents_out": 1, "fallback_used": 0,
            "plan_ms": 1, "unknown_fields": 0}
}
```

Note `expires_at_ms` = `sent_at_ms` + 30 s: the server's clock, not ours.

### Configuration

All from environment; see `deploy/compose/bot-brain.yml` for the annotated set.
The ones that matter:

| Variable | Default | Notes |
|---|---|---|
| `BOT_BRAIN_LISTEN` | `127.0.0.1:8085` | Loopback, not every interface. Containers override to `:8085` deliberately - there the network namespace is the boundary. |
| `BOT_BRAIN_MAX_BATCH` | `2048` | Snapshots per call. Enforced by the decoder, so it bounds work, not memory. |
| `BOT_BRAIN_MAX_BODY_BYTES` | `16777216` | Request body cap, applied before decoding. This is the limit that bounds memory. |
| `BOT_BRAIN_DEFAULT_DEADLINE` | `2s` | Used when the caller sends no `deadline_ms`. |
| `BOT_BRAIN_INTENT_TTL` | `30s` | Intent validity, in the *server's* clock. |
| `BOT_BRAIN_RULE_*` | see compose | The policy knobs. This is the 326 seconds you are buying back. |
| `BOT_BRAIN_LLM_ENABLED` | `false` | Off by default. Rules-only is a working brain. |
| `BOT_BRAIN_LLM_BASE_URL` / `_MODEL` / `_PROVIDER` / `_API_KEY` | empty | Any OpenAI-compatible endpoint. |
| `BOT_BRAIN_LLM_TIMEOUT` | `1500ms` | Must be shorter than the deadline, enforced at startup. |
| `BOT_BRAIN_LLM_ALLOWED_MODELS` | empty | Allowlist, so a typo cannot switch models silently. |

Durations accept Go syntax (`1500ms`, `2s`); a bare integer is milliseconds.

### Inference backends (ARCH-003)

One OpenAI-compatible client, backend chosen by configuration, per-provider
adapters for auth quirks only. The model is **not** a compile-time constant —
that was the ARCH-003 finding about `kModel = "qwen2.5:7b"` in
`ExternalLLMBridgeService.cpp`.

| Backend | `BASE_URL` | `PROVIDER` | Key |
|---|---|---|---|
| vLLM (production default with a GPU) | `http://vllm:8000/v1` | `openai` | none |
| llama.cpp server / Ollama (dev) | `http://host:11434/v1` | `openai` | none |
| OpenAI | `https://api.openai.com/v1` | `openai` | `sk-…` |
| Azure OpenAI | `https://<res>.openai.azure.com/openai/deployments/<dep>` | `azure` | `api-key` |
| Anthropic-compatible gateway | your gateway | `anthropic` | `x-api-key` |
| Groq / Together / OpenRouter | their `/v1` | `openai` | bearer |

An empty key sends **no** `Authorization` header at all, rather than a literal
`Bearer `, so local endpoints work unmodified.

**Egress.** `planner/llm.redact` is the single place that decides what leaves
the machine, and it is a hard filter rather than a prompt instruction. It sends
no GUID, no realm, no character name, no account data and no precise
coordinates — bots are batch indices. `TestPromptCarriesNoIdentifiers` asserts
it. This is stricter than ARCH-003 requires, because loosening a filter is a
reviewable change and tightening one after a leak is not.

### Metrics

| Metric | Watch it for |
|---|---|
| `botbrain_plan_requests_total{outcome}` | `version_skew` appearing means a deploy mismatch. |
| `botbrain_plan_intents_total{source}` | `rule` vs `llm` vs `fallback` mix. |
| `botbrain_fallback_intents_total` | Persistently near the snapshot rate means the primary planner is **not working** — a condition that otherwise looks exactly like success. |
| `botbrain_unknown_fields_total` | The rolling-deploy skew signal. |
| `botbrain_dropped_intents_total{reason}` | `unasked_bot` is never routine; it is a planner bug touching identity. |
| `botbrain_version_skew_total` | Refused peers. |
| `botbrain_plan_duration_seconds` | The latency half of ARCH-001's decision gate. |

---

## How the C++ side will eventually talk to it

Not built. This is the shape it should take, written down so it can be argued
with before anybody writes it.

1. **At startup**, `GET /v1/contract`. If no `supported_majors` entry matches
   the major the C++ side was compiled against, log loudly and leave the brain
   path **disabled**. Never half-enable it.
2. **On a slow cadence** (seconds, not ticks), off the map-update threads,
   collect snapshots for bots due for a planning decision. Building a snapshot
   is a read of live state and must happen on the world thread; the HTTP call
   must not.
3. **Batch them.** Hundreds per call. `deadline_ms` should be set from how long
   the server can actually wait — the server knows, the brain does not.
4. **Post to `/v1/plan`** from a worker, never from a map-update thread, and
   never over the existing detached-thread packet path (LLM-012 is explicit
   that this must not become the transport).
5. **Revalidate every intent** against live state on the world thread before
   acting: is the POI id still known, is the bot still out of combat, is it
   still the group leader, has `expires_at_ms` passed. Drop what fails.
6. **Report the outcome** in the next snapshot's `last_outcome` — that is how
   the loop closes without the brain keeping state.
7. **Fail closed to tier 0.** Timeout, 409, connection refused, garbage — all
   of them mean "run in-core AI this tick". A bot must never wait on this
   service.

The C++ side keeps sole authority over identity. No response from this service
may cause a bot to be created, deleted, replaced, re-rolled or logged out; a
server that receives such a request should reject it with reason
`identity_protected`, which this service treats as an alert-worthy event because
it can only mean a bug.

---

## Layout

```
contract/    the deliverable: snapshot, intent, envelope, versioning
planner/     the Planner interface and the Fallback wrapper
  rule/      deterministic priority ladder (default, always available)
  llm/       OpenAI-compatible planner (skeleton; plumbing real, judgment not)
httpapi/     HTTP transport, metrics wiring, stray-intent defence
metrics/     hand-rolled Prometheus exposition (keeps dependencies at zero)
config/      environment loading and the startup sanity checks
cmd/bot-brain/  wiring, graceful shutdown, the `healthcheck` subcommand
```

**Zero external dependencies, deliberately.** `go.mod` has no `require` block,
so the module builds and tests on a machine with no module proxy and no network.
The cost is a hand-written metrics registry with fixed histogram buckets; if
real histogram semantics are ever needed, swapping in `client_golang` is
contained behind `metrics/`.

## Next, in the order that makes sense

1. **The snapshot recorder.** ARCH-001 is explicit that fixtures should be
   recorded from a live server rather than invented. Every test here uses
   invented snapshots, and that is this deliverable's weakest point.
2. **The C++ seam** on one behaviour only — travel-target/quest selection —
   with the brain path off by default.
3. **The measurements** that ARCH-001's decision gate actually asks for: p99
   intent latency, messages/sec at 1000 bots, worldserver CPU delta. Publish
   them; pick the next behaviour family on evidence, not on enthusiasm.
4. **Then** ARCH-003's cost controls, and only then point this at a metered API.

## References

- `docs/issues/30-deferred-architecture.md` — ARCH-001 through ARCH-006
- `docs/adr/ADR-0024-project-invariants.md` — invariant 1 (persistence) and 6 (fail closed)
- `docs/adr/ADR-0012` — external LLM process, fail-closed admission, the worker boundary
- `docs/adr/ADR-0013` — wire and lifecycle contract for the existing bridge
- `docs/adr/ADR-0023` — containerization and the one-command contract
- `core/modules/mod-playerbots/src/playerbot/PersistentActiveRoster.h` — the identity/behaviour line a planner must never cross
