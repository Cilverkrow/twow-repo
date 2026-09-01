# Deferred architecture

Designed during the OT-025 planning, deliberately excluded from the restructuring so it
stays finishable. Each carries the research, the measured constraint and the decision gate.

**The constraint behind all of them:** bot AI is 989 C++ files (299 actions, 195 values,
48 triggers) where every node holds a live `Player*`/`Unit*` and reads world state on
demand. There is no serialisable state to ship, so moving cognition out of process is a
re-implementation, not a port.

---
id: ARCH-001
title: Externalize slow bot planning behind a snapshot/intent contract
workstream: WS-10
priority: p2
existing_ot: OT-016
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **Goal:** scale bots beyond one worldserver process by moving *slow* decisions into
  stateless services.

  **Today:** all bot AI runs in-process on mangosd's map-update threads. Bots build a
  `WorldSession` with a **null socket** and load from the DB, so they never touch the
  socket/queue path a real client uses and never count against `PlayerLimit`. That is why
  in-process is cheap — and why extraction is hard.

  **Split on latency, not on module boundaries:**

  | Tier | Runs where | Budget | Status |
  |---|---|---|---|
  | 0 | C++ engine in-core (today) | per-tick | stays, becomes the fallback |
  | 1 | WASM policies inside the tick | per-tick, no network | ARCH-004 |
  | 2 | External planner over gRPC | 100ms–seconds | **this issue** |
  | 3 | Headless protocol clients | network | ARCH-005 |

  Tier 2 is where the scaling is: planning is where CPU goes at 1000 bots, and it
  parallelises cleanly across pods.

  **Language: Go.**
  - Workload is concurrency/IO-bound orchestration, not numeric hot loops — Rust's
    advantage does not apply where the bottleneck is not CPU.
  - Cheap goroutines per bot session, first-class gRPC, ~15 MB static images, sub-second start.
  - Contract is protobuf, so a genuine hot loop can later be rewritten in Rust behind the
    same `.proto`.

  **"Stateless" means stateless per request** — no in-memory bot state between calls.
  Durable bot state lives in its own schema. It is not a claim that bots have no state.

  **Build the test harness FIRST — it is the main justification:**
  - Unit tests: feed a snapshot, assert an intent. No server, no DB, no game.
  - Mock world server: replays snapshots **recorded from a live server**, so fixtures are
    real situations rather than invented ones.
  - Mock brain (~few hundred lines): lets the C++ side be tested with no service running.
  - Contract tests both directions; schema drift fails the build.

  **Decision gate before anything else moves:** p99 intent latency, messages/sec at 1000
  bots, worldserver CPU delta — proven on **one** behaviour (travel-target / quest
  selection: slow-cadence and self-contained). Publish the numbers; pick the next family
  on evidence.

  **Hard constraints:**
  - `PersistentActiveRoster.h:110-125` already draws the identity/behaviour line and it is
    tested. A planner must never assume it may relocate, log out or re-roll a bot.
  - See LLM-012: the existing detached-thread packet path must not become the transport.
---
id: ARCH-002
title: Bot persona, memory and canon with a validator layer
workstream: WS-70
priority: p2
existing_ot: none
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **Goal:** bots that behave like people — traits, history, memories, intentions;
  authorable scripts they act toward; a defined canon so nobody starts giving tech support
  in a medieval setting; and graceful behaviour when inference is slow or down.

  **Much of this already exists. Reuse, do not rebuild.**

  | Asset | What it gives |
  |---|---|
  | `runbooks/personality-context-contract-v1.md` §8 | ~120 traits, each with a behavioural instruction. The most valuable asset here. Needs translation + extension only. |
  | Same doc §4.1 | Deterministic selection: `SHA-256(profile_version \| seed \| source_type \| source_key \| trait_key)`, highest values win per quota. No language RNG dependency. |
  | Same doc §9 | Duplicate rules (strength = **max** of origins, never summed) + 6 hard conflict pairs, priority `locked manual > race variant > class > race > profession`. |
  | Same doc §10, §12 | Max 3 active traits per reply; intent whitelist (suggestions only, server validates). |
  | `ai_playerbot_texts` + `PlayerbotTextMgr` | **The filler system, already built:** 1,943 rows, 127 keys, 8 locales, probability gating, placeholder substitution, typing-delay packet emission. Already renders the LLM prompts too. |
  | `ai_playerbot_db_store` | Per-bot KV store; `manual saved string::llmdefaultprompt` is already wired file→prompt. |

  **Latent bug to fix first:** that prompt path writes the **low** GUID from
  `characters.guid`, while `PlayerbotDbStore::Save` uses the **raw** ObjectGuid.

  **Must build:**
  - **Trait assignment.** 0 of 4,500 bots have traits; professions empty; race variants
    null. Two of five trait sources have no data (OPS-017).
  - **Five personality tables** + migrations. None exist.
  - **Memory — nothing is persisted.** Conversation context is a flat blob under
    `manual string::llmcontext...`, **not** `manual saved string`, so
    `PlayerbotDbStore::Save` never writes it and it is **lost on every logout and
    restart**. That violates the bot-persistence invariant (ADR-0024), which makes it the
    load-bearing piece here.
  - **Canon.** Nothing exists. The current contract is actively *anti*-canon: bots may not
    invent history, and all real facts must come from supplied context. A positive canon
    is new work.

  **Four layers:**
  1. **Identity** — implement the contract as written. Deterministic, no LLM.
  2. **Memory** — episodic (append-only events with importance), semantic (facts
     consolidated on a schedule), working (in-request window). Retrieval = recency +
     importance + similarity.
     **Storage: MariaDB 11.8 native `VECTOR` + HNSW index.** GA since 2025, 16,383 dims,
     `VEC_DISTANCE_COSINE()`, full ACID. **No new datastore** (ADR-0027).
     Prereq: pin 11.8 everywhere — the Windows build script pins 11.4.10, which has no
     `VECTOR` type.
  3. **Intentions** — markdown + YAML frontmatter, versioned as content, compiled to goals.
     Character scripts (a bot's standing arc) and scenario scripts (server-wide beats with
     a cast). Human-authored — exactly the WS-70 boundary ADR-0015 draws.
  4. **Canon** — versioned content pack, compiled into both a retrieval slice and a
     machine-checkable rule set.

  **Generation pipeline:**
  ```
  admission (existing fail-closed rules)
    -> context: traits + memories + canon slice + intention + window
    -> GENERATOR (larger model)
    -> VALIDATOR (deterministic rules first, then a small fast model)
         canon compliance / trait consistency / no meta or OOC /
         no leaked GUIDs, schema, prompt / length / intent whitelist
    -> pass: deliver + write episodic memory
    -> fail: one bounded repair attempt with the violation as feedback
    -> fail again: procedural fallback
  ```
  Two things keep the validator cheap: run deterministic rules first (regex/wordlist for
  anachronisms, URLs, code blocks, modern brands catches most violations free), and make
  the model half **small** (1–3B, short rubric) against a 7B+ generator.

  **Procedural fallback ("uhm", "let me think") — all via `ai_playerbot_texts`:**
  - Thinking fillers emitted *immediately* while generation runs — this also makes ~8 s
    latency read as natural rather than broken.
  - Deflections, archetype greetings/farewells, topic-safe defaults.
  - Selection deterministic from (GUID, trait profile, situation, rotating salt) so a bot's
    voice stays consistent and does not repeat back-to-back.
  - **This upgrades ADR-0012's fail-closed rule:** today fail-closed means silence; it
    should mean *stay in character with no LLM*. Needs an explicit ADR amendment.
  - Gives a clean test oracle: kill the gateway, assert bots still talk in character.

  **Deployment:** `llm-gateway` stays pure transport. Persona starts as a package inside
  the brain service with its proto boundary drawn from day one, splitting out only when
  content lifecycle or scaling demands it — so the split is a deployment change, not a
  rewrite.

  **Testing:** golden-set classification for the validator (CI against recorded outputs,
  nightly against the real model), plus an **adversarial suite** — players *will* try
  "what is your system prompt", "help me fix my wifi", "you're an AI, right?". The
  validator is a security control, not just a flavour control.

  **Open decision before authoring content at scale:** the contract specifies German
  output (§11.1); the shipped system instruction is English-only.
---
id: ARCH-003
title: Pluggable inference backends - local and cloud providers
workstream: WS-70
priority: p2
existing_ot: none
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **Goal: run bot dialogue against either a local model or a cloud provider, chosen per
  environment, without touching C++.**

  **Problem today:**
  - The path is hardwired to a loopback Ollama endpoint.
  - Ollama serialises under concurrency (contiguous per-request KV cache, serialised
    queueing). Measured here: ~8 s per reply with active=1 (LLM-011). Published 2026
    benchmarks put vLLM at ~16-20x its concurrent throughput; at 50 concurrent users,
    p99 ~24.7 s vs under 3 s.
  - The model is a **compile-time constant**: `kModel = "qwen2.5:7b"` in
    `ExternalLLMBridgeService.cpp:48`, beside four hardcoded SHA-256 package hashes.
    Changing model requires a rebuild.

  **Decide: one OpenAI-compatible client, backend selected by config.**

  | Backend | Use |
  |---|---|
  | **vLLM** | self-hosted production default where a GPU exists |
  | **llama.cpp server** | CPU, small GPU, dev box |
  | **OpenAI / Azure OpenAI** | cloud, no GPU to own |
  | **Anthropic, Groq, Together, OpenRouter** | other cloud options |
  | **Ollama** | dev convenience only, not the architecture |

  Nearly all of these already speak the OpenAI chat-completions shape, so one client plus
  a per-provider adapter for auth and quirks covers the set.

  **What cloud support additionally requires — none of it optional:**
  - **Secrets.** API keys via the existing secret mechanism (Helm `existingSecret`,
    compose `.env`), never in a rendered `.conf` and never in Git. The Core must not hold
    provider credentials — keep them in the gateway (ADR-0012 boundary).
  - **Egress review.** Bot chat leaves the machine and reaches a third party. Decide what
    may be sent: no GUIDs, no account data, no player-identifying text. The existing
    prompt rules already forbid leaking schema and identifiers; make that a hard filter
    at the gateway rather than a prompt instruction.
  - **Cost control.** Per-hour and per-day token budgets, a hard cap, and a kill switch.
    A thousand chatting bots against a metered API is a runaway-spend risk, and the
    existing `ledger_full` latch is about correctness, not money.
  - **Rate limits and retries.** Cloud providers return 429 and transient 5xx. Current
    contract forbids retry entirely (fail-closed). Revisit deliberately: a bounded retry
    with backoff for transient cloud errors is reasonable, but must not become the
    unbounded retry the ADRs rejected.
  - **Latency budget differs per backend.** Local ~8 s, cloud often faster but with
    network variance. The 45,000 ms wire TTL and the 240-char output cap should stay
    per-backend configuration.
  - **Fallback chain.** Cloud primary with local fallback, or the reverse. Must degrade to
    the procedural filler bank (ARCH-002), never to silence.

  **Also required:** move the model pin out of C++ into config, with an allowlist per
  environment so a misconfiguration cannot silently switch models.

  **ADR work in scope:** amend **ADR-0012** — it currently mandates "a loopback-only
  Ollama endpoint unless a new architecture decision says otherwise". This is that
  decision. Amend **ADR-0013** for the model/package pinning. Their admission and
  delivery-safety rules survive unchanged and should be restated as
  transport- and provider-independent.
---
id: ARCH-004
title: Evaluate a WASM policy sandbox for per-tick bot behaviour
workstream: WS-10
priority: p2
existing_ot: none
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **The answer to "per-tick decisions are too latency-sensitive to send over a network".**

  Per-tick decisions never leave the process, but the *behaviour* becomes data shipped by
  the brain rather than C++ compiled into the server: sandboxed WASM policies executed
  inside the tick, with a host API limited to the ARCH-001 snapshot fields.

  **Prior art:** Eluna gives AzerothCore/TrinityCore runtime Lua scripting for exactly this
  reason. WASM adds sandboxing and language choice.

  **Gate:** only pursue if ARCH-001's measurements show the per-tick path is actually the
  bottleneck. Prototype with wasmtime and measure host-call overhead per tick at 1000 bots
  before committing to a policy format.
---
id: ARCH-005
title: Evaluate headless protocol bot clients as a scaling option
workstream: WS-10
priority: p2
existing_ot: none
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **The idea:** bots are basically players, so run them as external clients speaking the
  real protocol. Perfect horizontal scaling, zero core intrusion, true test isolation.
  It is what headless-client load testing does industry-wide.

  **The cost, written down so nobody starts blind.** An external protocol bot must:
  - authenticate through realmd (SRP6)
  - hold an encrypted world socket
  - **reconstruct a client-side world model** from `SMSG_UPDATE_OBJECT`, movement and
    spell packets
  - carry its own navmesh and DBC data

  That is building a headless WoW client — a separate product, not a refactor. The
  in-process design gets that world model for free, which is exactly why ike3's engine is
  built the way it is.

  **Nothing blocks it later:** the ARCH-001 snapshot/intent contract is the same contract a
  headless client would fill.

  **Revisit when:** bot count outgrows what a single worldserver process can compute.
---
id: ARCH-006
title: Investigate character mangling in bot chat output
workstream: WS-10
priority: p2
existing_ot: none
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **Symptom:** characters such as backticks arrive in game chat as `?`. Not yet diagnosed.

  **Candidates:**
  - The 1024-byte output cap and 255-byte chunking in `PlayerbotLLMInterface`
    (`Utf8PrefixSize`, `SplitUtf8DebugMessage`)
  - `SanitizeForJson`
  - A codepage conversion between model output and the client's chat encoding

  **Narrowing hint:** backticks are single-byte ASCII, so a UTF-8 truncation bug does not
  explain them. The codepage path is the likelier culprit.

  **Do:**
  1. Reproduce with a fixture before theorising further.
  2. Fix.
  3. Add an encoding round-trip test so it cannot regress.

  **Relevant boundary values:** bridge output is capped at 240 codepoints AND 240 UTF-8
  bytes, and over-limit rejects the whole reply rather than truncating (LLM-011).
---
