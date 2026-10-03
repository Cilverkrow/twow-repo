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

> **This clause no longer describes how the project scales (noted 2026-09-27).** ARCH-001 is closed,
> its gate never produced numbers, and scaling is now being pursued in-core under the D1–D4 gates
> below. The sentence is left exactly as written because changing what the project is *for* is the
> owner's call; see [Open contradiction](#open-contradiction-the-second-clause-2026-09-27) for the
> facts and two candidate rewordings to choose between.

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

## Owner direction (2026-09-24)

Recorded at the owner's request as the current guiding idea. It is expected to evolve; it does not
change this ADR's status (still Proposed).

**Organic, self-earned progression is the core loop.** The upstream bot fork is built around
random bots that are summoned by command, arrive pre-geared and exist to fill a group. This project
deliberately departs from that model, and from the Turtle WoW original, because neither was designed
for what we want: persistent bots that quest, travel, learn and use professions, craft and equip
their own gear, and progress through dungeons and later raids alongside the player -- ideally as
members of the player's guild. The player gears up not only themselves but their bots.

Consequences for game rules (funserver profile only; the default profile stays upstream-like):

- **Rewards for showing up.** Content should not have to be repeated eight times. Bosses and rares
  drop a fixed number of loot units with a quality profile that favours the content's tier
  (raid: epic and better; dungeon: blue; rares: like dungeons), with diminishing repeats so a loot
  table is actually explored. Tracked in #323 and #288.
- **A world full of exciting rares.** Rares spawn reliably, respawn on a shortened, configurable
  scale, and carry special loot, including a level-banded bind-on-equip pool. They are also an
  observation point for bot behaviour. Tracked in #298 and #322.
- **Bots first play competently alone, then in small groups.** Since release train 7 the roster
  runs small ad-hoc bot-bot quest groups (#365 step 2: level window, size cap, own leave path).
  Groups that are level-coherent and that bots leave on their own remain the goal (#324); open
  bot-bot grouping beyond that stays off. Test-phase XP rates are 1x so that behavioural fixes are
  measured, not masked. (Amended 2026-10-02 per OB-00 decision 1 in #485: the live state takes
  precedence over the earlier "grouping stays off until #324" wording.)
- **Professions are part of progression**, first opportunistically from level 1 (#306), later as a
  deliberate phase in which a bot crafts its own equipment (#318).

**The long-term dream (third priority, after questing and levelling work):** a bot answers in chat
from its own GUID-bound character sheet -- class, spec, quests, professions, recipes -- and in the
voice of its personality: a human warrior proud and honourable, an undead rogue guarded and sly.
This is the "indistinguishable from a living one" clause made concrete; see ADR-0039, ARCH-002 (#43)
and #282.

## Metrics and gates (2026-09-26)

Owner decisions D1–D4 (2026-09-26). They make "a player would notice" measurable for the persistent
roster; the report template lives in `docs/measurements/7-day-scaling-gate-report-template.md` (#349).

| Metric | Source | Gate |
|---|---|---|
| **Lost bots** | roster version vs. characters/accounts | **0** (hard gate, ADR-0024 invariant 1) |
| **Tick budget (D1)** | `perf.log` (logs only map updates > 100 ms) | max ≤ 3000 ms; slow updates (> 100 ms) per day as a trend. Target p99 ≤ 1000 ms per day once a per-tick statistic exists (#351, prerequisite for scaling) |
| **Levelling progress (D2)** | `tw_char.characters` daily snapshot | median roster level rises daily (up to level 20); no bot online ≥ 24 h without XP gain |
| **Loops (D3)** | `deaths.csv`, `bot_events.csv` | none: ≥ 10 deaths/h by the same killer at the same position, or ≥ 5× "no destination" per bot and day, counts as a loop |
| **Quest turn-ins** | `character_queststatus.rewarded` | rising; reported per day and per bot-hour |
| **Profession skill** | `character_skills` (primary professions) | share of bots with a learned profession and with skill > 1 rising |
| **Equipment upgrades** | equip diagnostics / `bot_events.csv` | reported; no equip loops |
| **Evidence (D4)** | daily copy of CSV logs + DB snapshot to `evidence\ws-60\longrun-7d\<date>` | a missing day or lost data leaves the verdict OPEN |

**Base roster (owner decision 2026-09-26, overlay Ä10a, #366):** 154 active bots (77 per faction: 10 tanks,
20 healers, 47 DPS), introduced with release train 6 together with a level-1 reset of all 154. The owner
deliberately moved the base from 136 to 154 without a completed 7-day run. The 7-day measurement
window restarts with 154 at train 6 world-up. The #351 prerequisite (tick p99) is deliberately not
required for this step: the first 24 h after the train 6 deploy serve as the p99 baseline at 154.
Rollback guard: if, after the 5-minute warm-up, tick p99 > 1000 ms or max > 3000 ms persists, the roster goes
back to 136 (rollback stack of train 5), reported to the owner.

**Wave 1 (owner decision 2026-09-27, overlay Ä10b, #366):** 180 bots (per faction 10 tanks, 20 healers, 60 DPS, race-balanced, including the new race/class pairs) come with release train 7 **as soon as train 7 is ready, without waiting for the 7-day run with 154**; the 7-day window restarts at train 7 world-up. The long-term target is 360 (per faction 20/40/120, wave 2).

**Scaling gate (overlay Ä10):** more than 180 active bots (next step: wave 2 up to 360) only after a
documented run of ≥ 7 days with the 180 base that passes all gates above, plus #351 for the real tick
p99, plus an explicit owner approval.

## Open contradiction: the second clause (2026-09-27)

Recorded, not resolved. The Decision above has three load-bearing clauses; **the middle one has
stopped matching practice**, and this ADR exists precisely so that kind of drift is visible instead
of inherited.

What changed, as facts rather than judgements:

- **ARCH-001 is closed** (#42). The snapshot/intent contract shipped: it stands at version 1.6, the
  Go service is built, vetted and race-tested in CI, and `modules/mod-bot-brain` is still wired.
- **ARCH-001's decision gate never produced numbers, and now cannot.** p99 intent latency, messages
  per second at 1000 bots and worldserver CPU delta are all measurements *of out-of-process
  planning*. Nothing plans out of process in a running deployment today, so there is nothing to
  measure. The gate is not pending; it is unreachable in the current configuration.
- **Scaling is being pursued in-core instead**, and deliberately: the owner direction of 2026-09-24
  ranks the brain-side work as *third* priority, behind questing and levelling. The roster has gone
  136 → 154 → 180 with 360 as the target, gated on D1–D4 — tick budget, levelling, loops, evidence.
- **Those are a different question.** ARCH-001's gate asked *"should decisions move out of the
  world thread?"*. D1–D4 ask *"is the population alive and is the tick holding?"*. Both are worth
  asking. Only the second is being asked, and the Decision clause still advertises the first.

None of this is a process failure — every roster step is a recorded owner decision with a stated
rationale and a rollback guard, which is more discipline than the clause it contradicts ever got.
The problem is narrower and entirely fixable: **the document that exists to settle "which statement
do I believe?" now contains two answers.** A reader following the Decision would go looking for an
out-of-process scaling story; a reader following the gates would find an in-core one.

### Two candidate rewordings, for the owner to pick

**(a) Amend the clause to describe what the project does.** Replace "planned out of process so it
scales" with a clause about the scaling property actually being pursued — a persistent roster that
grows without breaking the tick budget — and demote out-of-process planning to a means held in
reserve, named in the Consequences rather than in the Decision. This is the honest option if the
in-core path is expected to carry the project to its roster target.

**(b) Keep the clause and say out loud that it is deferred.** Leave the Decision untouched, and add
one sentence stating that the means is parked behind the two higher priorities, with the condition
that would revive it — most plausibly a tick budget that in-core planning cannot hold at the roster
target. This is the honest option if out-of-process planning is still the intended endgame.

**Recommendation: (a).** Two roster increases have now been taken on in-core evidence, the contract
has had one commit in eighteen days, and ARCH-004 and ARCH-005 — both explicitly downstream of
ARCH-001's measurements — cannot be started while those measurements are unreachable. Under (b)
that backlog stays blocked on numbers nobody is in a position to produce. (a) unblocks it by
admitting the means changed; the *goal* is untouched either way, which is the part that matters.

### Two smaller notes, while this section is open

**Correction (2026-09-27, same day): the earlier version of this section was wrong about the
instrument, and the error is recorded rather than quietly edited.** It claimed the scaling gate
"cannot fire" and the rollback guard was "half-inert" because a real tick p99 could not be computed.
That is not true:

- **The per-tick statistic exists and is switched on.** `core/src/game/TickStats.h` computes
  `p50`/`p95`/`p99`/`max`/`over100`/`over200` by nearest rank, fed from the world loop by
  `PerformanceMonitor::RecordTick`, emitted as one aggregated `perf.log` line per interval, with a
  `tick_stats_test` in ctest. The code default is off (`World.cpp:1396`), **but the deployed profile
  turns it on**: `config/canonical/profiles/funserver-test/mangosd.overlay.conf:43-44` sets
  `PerformanceLog.TickStats = 1` and `TickStatsInterval = 60`, tagged `INTENTIONAL_CHANGE` /
  `issue-351-tick-stats-d1` in `semantic-profile.tsv`, and the live runtime overrides are rendered
  from that profile. So D1's own caveat — "a real p99 cannot be computed" — is itself now stale.
- **`.perfmon` was never the p99 blocker.** It is a bot-internal profiler (which triggers, values and
  actions cost what) reporting min/max/avg/total with **no percentile of any kind**. It was genuinely
  broken — `Init()` sat below three early returns in `RandomPlayerbotMgr::UpdateAIInternal`, so under
  a persistent roster `mapsData` stayed empty and every probe returned `nullptr` — and it is fixed in
  twow-core#186. But fixing it was never going to serve a p99 gate.

**What is actually missing is the report, not the instrument.** `docs/measurements/` still holds only
the template; no filled-in run exists. The base has moved 136 → 154 → 180, each step a recorded owner
decision with a rationale and a rollback stack, and each restarting the 7-day window — so the gate has
still never guarded an actual step, and the threshold has been rewritten three times to track the
base. That part of the earlier text stands. The difference is that the obstacle is a measurement
nobody has taken, not a number nobody can take, which is a much smaller problem and a much cheaper
one to close.

One thing twow-core#186 did surface that does bear on D1: `.perfmon` aggregated its **max column out
of each bucket's minimum** (`PerformanceMonitor.cpp:139-140`), so every `max` it has ever printed was
really a minimum. Anyone who read a `max` off a `.perfmon` report — as opposed to the `perf.log` tick
line — was reading the wrong number.

**This section does not change this ADR's status.** It remains Proposed — which is itself worth a
decision now, because a Proposed ADR is currently carrying the D1–D4 gates that release trains are
managed against. Either accepting it or moving the owner decisions somewhere with standing would
remove that mismatch.

## References

- `docs/adr/ADR-0024-project-invariants.md` — the six invariants, and the veto clause above
- `docs/issues/30-deferred-architecture.md` — ARCH-001 through ARCH-006, the actual roadmap
- `docs/adr/ADR-0039-bot-brain-identity-and-memory.md` — durable brain state, and the amendment of
  "stateless" to mean per-request
- `docs/adr/ADR-0040-module-ownership-and-the-core-boundary.md` — where work goes, and why
- `docs/OPEN-THREADS.md` — OT-022, the README claim
