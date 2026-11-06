# ADR-0041: Bot behaviour target architecture, replaced module by module

- Status: Accepted (owner, 2026-11-04); implementation pending, each step under its own order
- Date: 2026-11-04 (amended 2026-11-06)
- Primary: WS-10
- Related: ADR-0022 (characterization before extraction), ADR-0024 (invariants), ADR-0031 (project goal),
  ADR-0039 (out-of-process planning), ADR-0040 (module ownership)

## Context

Nobody could say in detail how our bots decide what to do. A read-only inventory, A3, now does. It
covers questing from level 1 to 60 and dungeons, and every statement is backed by `file:line` at
twow-core `7d51ef64` and, where possible, by action logs. The inventory is in
`Y:\tw\evidence\ws-00\projekt-durchleuchtung\A3-BOT-LOGIK.md`, and the movement part is in
`ws-10\cli-pathfinding\movement-a3\MOVEMENT-PATH-A3.md`.

What it found:

- **There is no planner.** Each tick, triggers push actions with fixed relevance numbers. The engine
  runs the highest one that succeeds, and the first success ends the tick (confirmed: 0 of 203,241
  successful ticks had a second success). The order of behaviour comes from about 90 numbers in the
  travel, rpg and quest strategies alone. A tie is decided by push order: `check values` beats
  `move to travel target` 24,549 times at relevance 1.0.
- **One concept has many owners.** About 20 places outside the engine reset the travel target. Five
  separate stuck detectors exist, and there are three definitions of quest progress. The level
  windows differ: quests are accepted up to +5, but targets are only chosen up to +1 for quests
  and +4 for mobs. The exclusion list has 8 slots and lives in memory only.
- **The fixes form layers of patches on the same ladder.** Of the switches with a legacy path, 152
  were adopted without the old path ever being removed (`A2-ALTPFAD.tsv`). Several are dead: the
  "has nearby quest taker" trigger is never registered, and the TravelActionMultiplier exceptions never
  match. (Correction 2026-11-04: an earlier version also listed `+bot brain` in the profile here. That
  was wrong. The strategy exists in `modules/mod-bot-brain` (ADR-0039), and the profile line keeps it
  active.)
- **Outcomes are measured.**
  - Quest-first bots are idle 23–25 % and stuck 6–7 % of the time, and grind 0 %.
  - 7.4 % of far-move arrivals end in death.
  - 40–57 % of rescued bots far-move straight back to the stuck point.
  - After any rpg action, every rpg action, including the turn-in, drops to ×0.1 relevance.
  - Follow crosses map boundaries.
  - Ad-hoc leave has no effect, and `m_GroupMap` is written without a lock (#628/#677).
- **There is no dungeon loop.** `DungeonRunBridge::StartRun` has no caller. No bot decides to run a
  dungeon, forms a group by role, travels to the instance, or handles attunement, keys or lockouts.
- **The activity throttle is off.** `DisableActivityPriorities = 1` is set on live and test, so every
  bot ticks at full rate. That is how it works now, but nothing was designed for it.

The owner approved the target picture and the replacement order on 2026-11-04: "ja", "jetzt kommen wir
der sache näher … das ist der weg" (OB-00 chat 2026-11-04; target picture and order as in A3 v2.2 part 4).

## Decision

**Bot behaviour gets an explicit owner per concern. The existing playerbot engine stays as the
executor.** The target architecture is:

| Component | Owns | Replaces |
|---|---|---|
| **Supervisor** (per bot) | the mode — QUEST · GRIND · REST · GROUP/DUNGEON · RESCUE — and the single owner of the travel target and its status; also the tick cadence per mode | the ~20 scattered target resets; refresh/reset triggers |
| **Activity planner** | "what next", scored (XP/min, distance, danger, turn-in first); grind as a real mode | the relevance ladder of travel requests; QuestFirstOrder/GrindMode/fallback layers |
| **Quest book** | one level window (accept = target = turn-in), one progress definition, one "can turn in" predicate, one "zone fits" rule, persistent exclusion list | the divergent windows, 8-slot in-memory park list, drop layers |
| **Route and movement** | pathing, far moves with a per-target repeat guard, arrival safety, danger memory per place | the 3D far-move gate without memory; separate death/camp memories |
| **Combat rule** | target choice with neighbours, rest before pulls, flee to a safe point, guards against failure loops | NeighbourAware/SafePull split; select-new-target and unlearned-spell loops |
| **Rescue ladder** | one stuck owner and one death policy (corpse run before spirit healer; repop only for the dead) | five stuck detectors; repop as a stuck remedy for living bots |
| **Group and dungeon manager** (world thread) | ad-hoc and quest groups, roles, meeting points; later the dungeon loop and attunements | ad-hoc/S7 duplication, map-thread group writes, missing dungeon loop |

Rules for getting there:

1. **Strangler per module.** Each module ships behind its own switch, default 0. It goes through an
   A/B on the normal behaviour test plan, then adoption under the owner default-1 rule, then the
   **legacy path is deleted** in the same or the next pair. No module counts as adopted while its
   legacy path is still reachable.
2. **Order:** 0 measurement base and mechanism confirmation → 1 immediate hygiene → 2 quest book →
   3 planner + supervisor core → 4 rescue ladder + danger memory → 5 combat rule → 6 group manager →
   7 dungeon loop → 8 legacy deletion (continuous). Cost work runs in parallel. Each step has the
   acceptance metric listed in A3 part 4.1. Professions, PvP, guilds and trade come after step 7.
3. **One lever per run.** Two modules are never A/B-tested in the same run, because death-rate
   overdispersion (phi 2–4) already makes a single lever marginal.
4. **No new layers on the old ladder.** While a module is being replaced, no new vetoes, relevance
   shifts or hotfix switches go onto the legacy path it replaces. The exception is HARM or crashes.
5. **Characterization first.** ADR-0022 applies: before a legacy path is replaced, action-log
   evaluation (pass1/pass2) and the target KPIs record its behaviour. That record is the baseline
   for the A/B.
6. **Where the code lives.** `mod-playerbots` and `mod-dungeon-clear` are core per ADR-0040, so the
   new modules go into twow-core as small topic branches with twin PRs as usual. No core engine change
   is part of this decision.

## Relation to ADR-0039 and ADR-0031

- **ADR-0039 and the bot brain.** The planner here is **in-process and deterministic**. ADR-0039's
  out-of-process bot brain may later become **one input** to the activity planner, for example a
  preference or an intent. It never bypasses the supervisor and never owns the travel target.
  ADR-0039's fail-closed rules are unchanged: when the planning path is unavailable, normal bot AI
  continues, and that normal AI is this architecture.
- **ADR-0031 and the activity throttle.** The goal clause "bots that level … like people" rules out
  a blanket throttle that stops unobserved bots from questing. The owner said on 2026-11-04 that the
  saving mode "gehört schlecht rein oder neu gedacht" (doesn't belong, or must be rethought).
  - The **direction** is a tick cadence by mode, owned by the supervisor. Questing, travelling,
    combat, group play and rescue run at the full rate; rest and idle run slower, with wake-up
    triggers. Cheaper ticks come first.
  - **Not decided here:** the live value of `DisableActivityPriorities` and the cadence numbers. They
    follow the A3 trace result (`A3-PREREG-TRACE.md`).

## Consequences

- Each step is its own order, its own measurement and its own adoption. This ADR approves the
  direction and the order, not any code.
- The switch count goes down over time. Every adoption removes its legacy switches and the
  corresponding profile lines (A2-ALTPFAD.tsv), and the contracts stay green.
- Acceptance metrics are standard output of every behaviour kit: idle, stuck, turn-ins, XP and deaths
  per bot-hour, failcensus, plus the action-log evaluation. A step without its metric is not adopted.
- **Risk:** steps 3 (planner) and 7 (dungeon loop) change core behaviour. They run as cohort
  crossovers, one level band at a time, with deaths per bot-hour as a guard.
- ADR-0024 invariant 1 (a bot is never lost) applies to every step. The quest book's persistent
  exclusion list writes only to project-owned tables (invariant 2).

## Amendment 2026-11-06

The status is unchanged: Accepted. This amendment records the owner's decisions of 2026-11-06 and
the OB-00 sequencing decisions that follow from them.

1. **Re-steering to the new bot logic.**
   - Owner: "freigabe zum umsteuern zur neuen botlogik und drzahung der abläufe" (OB-00 chat,
     2026-11-06).
   - What this changes in practice: rule 4 now covers tests as well as code. No A/B test runs on a
     knob of the legacy ladder. Only these three kinds of run are allowed:
     - HARM or crash fixes;
     - base and characterisation runs with the full action log (rule 5). In these runs every
       log-only switch is on and every behaviour switch keeps its default;
     - A/B tests of new A3 modules.
   - Queue entries that test old-ladder knobs are marked `#DROP` or `#HOLD` in the test queue. They
     are not deleted.
2. **Crafting moves forward.**
   - Owner: "wie empfehlung" (2026-11-06) on the M2 professions draft.
   - This changes rule 2. The **crafting module** (using a profession: crafting from materials
     in the bags) may start with step 3. It follows the same strangler rules: its own switch,
     default 0, then A/B.
   - Travel to crafting stations comes after step 3. PvP, guilds, trade and the rest of the
     professions stay after step 7.
   - Related decision: the goal for the item cheat is OFF. It is only switched off after an
     analysis and an A/B with the cheat off in one arm. The auction house stays off for now.
3. **The step 3 scaffold runs parallel to step 2.**
   - What the scaffold is: the supervisor and planner code skeleton. It sits behind its own switch,
     default 0, has counters only and changes no behaviour.
   - It may be built and merged while the quest book (step 2) is still in progress. Behaviour
     adoption keeps the order from rule 2.
   - Design basis: `Y:\tw\evidence\ws-00\projekt-durchleuchtung\A3-S3-ENTWURF.md`.
4. **Lever order for group work and steps 3–7** (OB-00, 2026-11-06). Rule 3 still applies: one
   lever per run, and an adopted module is part of the base in both arms. The order is:
   1. BOT-12 (running);
   2. group manager write path, as ops without directives;
   3. supervisor and planner, on top of that write path;
   4. group manager ADHOC and QUEST with directives;
   5. meeting point;
   6. dungeon G-1..G-3 (step 7).

   Group membership changes only through a manager op. A directive only carries what the bot
   must do: mode, target and meeting point. The bot confirms each directive back to the manager.
5. **Coupling between the core and the bot logic.** Rule 6 is confirmed:
   - New behaviour uses the existing PlayerScript hooks plus emits and edge checks inside the
     module. Events go to the bot through a module-wide mailbox keyed by guid; no pointers cross
     threads.
   - If a needed signal turns out to be impossible without a core engine change, work stops and
     the case goes to OB-00 and the owner.
   - The bot brain (ADR-0039) only supplies slow preferences to the planner, with a TTL. The
     per-tick work it does today is removed in its own twow-repo pair after the planner lands.

## Evidence

- `Y:\tw\evidence\ws-00\projekt-durchleuchtung\A3-BOT-LOGIK.md` (v2.2): parts 1–5, verification log,
  and the appendix `A3-anhang\` (strategy tables, action-log evaluation, failure catalogue,
  evaluation scripts).
- `Y:\tw\evidence\ws-10\cli-pathfinding\movement-a3\MOVEMENT-PATH-A3.md` (movement, far-move loops,
  rescue undo).
- `Y:\tw\evidence\ws-00\projekt-durchleuchtung\A2-ALTPFAD.tsv`, `A2-SCHALTER.tsv` (switch and
  legacy-path inventory).
- `Y:\tw\evidence\ws-50\a2-hotspots\A2-HOTSPOTS-20261104.md` (cost hotspots).
- Owner approval of 2026-11-04 relayed by OB-00 (session message; provenance per ADR-0002).
