# ADR-0031: What this project is for

- Status: Proposed
- Date: 2026-09-08
- Primary: WS-00

## Context

The goal of this project is not written down anywhere.

That is a finding, not a complaint. Looking for it turned up four partial statements at different
altitudes, in documents that do not reference each other, and one of them is explicitly disavowed by
two others:

- `README.md:25-28` — *"Playerbots are the foundation of this fork, not a side feature. Upstream
  still lists them as planned; here they are what the server is built around, and running a thousand
  of them permanently is what shapes everything else."* Its "~1000 permanently online" claim is
  contradicted as current truth by `docs/README.md:30` and `OPEN-THREADS.md:60` (OT-022).
- **ARCH-001** (`docs/issues/30-deferred-architecture.md:20-21`) — *"scale bots beyond one
  worldserver process by moving slow decisions into stateless services."*
- **ARCH-002** (`:75-77`) — *"bots that behave like people — traits, history, memories, intentions;
  authorable scripts they act toward; a defined canon so nobody starts giving tech support in a
  medieval setting; and graceful behaviour when inference is slow or down."*
- **ADR-0024**, which functions as the north star in practice because it is the one people quote:
  six invariants, of which *"Bots are persistent. A bot must never be lost"* and *"Fail closed"* do
  most of the work.

The absence has a cost, and it is not abstract. Without a stated goal there is no test for whether a
piece of work serves it, so the honest question at each decision point becomes "is this good?"
instead of "does this get us there?" — and those have different answers. Two examples from this
repository:

- A config flag left **5,021 of 5,039 bots at level 1** with no spells, no money and no professions,
  for as long as the realm had run. Every individual component was working. Nothing was asking
  whether the population was actually playing.
- `services/bot-brain/README.md` had drifted into claiming that shipped, working capabilities did not
  exist. A reader following it would have rebuilt them.

Both are failures of *aim*, not of execution.

## Decision

**This project builds a WoW 1.12 private server whose bot population is indistinguishable from a
living one — bots that level, work, trade and talk like people — planned out of process so it scales,
and never at the cost of losing a bot or blocking the world thread.**

The three clauses are load-bearing and each one rules something out.

**"Indistinguishable from a living one"** is the product goal, and it is deliberately behavioural
rather than architectural. It is satisfied by what a player observes, not by what the code contains.
A bot with a stored personality profile that behaves identically to every other bot does not advance
it; a bot that picks a different destination because of who it is does. This is the clause that makes
"does it change behaviour?" a legitimate review question.

**"Planned out of process so it scales"** is ARCH-001, and it is a means, not an end. It is subject
to ARCH-001's own decision gate — p99 intent latency, messages/sec at 1000 bots, worldserver CPU
delta — which has produced no numbers to date. If those numbers come back badly, the right response
is to change the means, not to defend it.

**"Never at the cost of losing a bot or blocking the world thread"** is ADR-0024, restated here
because it is the clause that overrides the other two. A feature that advances the product goal and
risks invariant 1 does not ship. This is not a tiebreaker; it is a veto.

### What this is not

- **Not a general-purpose emulator.** Upstream compatibility is a means of keeping merge cost low
  (ADR-0026, ADR-0040), not a goal in itself.
- **Not an LLM showcase.** Inference is one input to bot behaviour. The rule planner is the fallback
  and must stay good enough that a deployment with inference off is still a good server — which is
  also why personality has to affect behaviour, not only prompt text.
- **Not a bot count.** "A thousand bots" is a scale constraint that shapes the architecture, not an
  achievement. Five thousand bots at level 1 is not five thousand bots.

## Consequences

**A claim about the population needs evidence from the population.** The level-1 finding was
available to anyone who ran one query, for months. Work that changes what bots *are* is not done when
it compiles; it is done when the population reflects it. This is the practical reason
`test/smoke/30-bot-persistence.sh` skipping in CI is a project-level problem rather than a testing
detail.

**Architectural work is gated on its own evidence.** ARCH-004 (WASM policies) and ARCH-005 (headless
clients) are explicitly downstream of ARCH-001's measurements. Under this ADR that ordering is not a
preference; starting them without the numbers is starting work that cannot be judged.

**"It works" is not the standard; "a player would notice" is.** For the bot-brain in particular this
means an intent kind is finished when a bot visibly does the thing, not when the intent is produced
and correctly serialised.

**The disavowed README claim should be corrected rather than re-litigated.** OT-022 already tracks
this. This ADR does not resolve it; it removes the ambiguity about which document to believe.

## Status of this ADR

Proposed, deliberately. An ADR that states what the project is *for* is the owner's to accept —
drafting it is a way of making the gap visible and offering specific words to argue with, not a way
of deciding it. The words above are assembled from statements already in the tree; if the assembly is
wrong, the disagreement is worth having explicitly, because everything downstream inherits it.

## References

- `docs/adr/ADR-0024-project-invariants.md` — the six invariants, and the veto clause above
- `docs/issues/30-deferred-architecture.md` — ARCH-001 through ARCH-006, the actual roadmap
- `docs/adr/ADR-0039-bot-brain-identity-and-memory.md` — durable brain state, and the amendment of
  "stateless" to mean per-request
- `docs/adr/ADR-0040-module-ownership-and-the-core-boundary.md` — where work goes, and why
- `docs/OPEN-THREADS.md` — OT-022, the README claim
