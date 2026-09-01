# Divergence findings

Concrete, verified items from reviewing `Shyalya/tortoise-wow`, the public fork
this project was forked from. Two read-only reviews produced these; the seven
defects that were also live in our tree have already been fixed and are not
repeated here.

> **Correction 2026-09-02.** This document previously called Shyalya's repository
> "not an upstream in the usual sense but the same project developed in parallel by
> the same people", and the phrase "the parallel line" throughout means only
> "upstream". Shyalya is an **unrelated third party**; their fork of
> `Penqle/tortoise-wow` is an ordinary upstream. Nothing here requires anyone's
> agreement to offer upstream. See ADR-0020 for the verified lineage.

Every entry names the file and, where one exists, the reference commit. Nothing
here was taken on trust: the claims that drove code changes were verified against
our own source first.

---
id: BOT-03
title: Bot logout dereferences a master who has already disconnected
workstream: WS-10
priority: p1
existing_ot: none
source: modules/mod-playerbots/src/playerbot/PlayerbotMgr.cpp
superseded_by: none
body: |
  `PlayerbotHolder::LogoutPlayerBot` sends farewell messages through the security
  check, which dereferences the cached `master` pointer. A master who disconnected
  moments earlier leaves that pointer dangling, and `if (master)` cannot detect it.

  The tick path already revalidates, via an inline block in `PlayerbotAI::UpdateAI`.
  The logout path does not.

  **Fix:** extract that block as `PlayerbotAI::RevalidateMasterPointer()` and call
  it in `LogoutPlayerBot` before anything can speak to the master.

  Four crashes were attributed to this on the parallel line, all in `IsOpposing`
  reached from the farewell message. Reference: `Shyalya/tortoise-wow@c388a7e`.
---
id: BOT-04
title: Engine::removeStrategy holds an iterator across a callback that invalidates it
workstream: WS-10
priority: p1
existing_ot: none
source: modules/mod-playerbots/src/playerbot/strategy/Engine.cpp
superseded_by: none
body: |
  It calls `OnStrategyRemoved(state)` on the strategy and *then* reads the
  iterator and erases through it. The hook may change the strategy set --
  `RpgStrategy::OnStrategyRemoved` removes another strategy -- which invalidates
  the iterator, and the following erase tears the red-black tree apart (`SIGABRT`
  in `std::_Rb_tree_rebalance_for_erase`).

  **Fix -- detach first, notify second:** cache the raw pointer, update the hash,
  erase, then call the hook. The map holds non-owning pointers, so the pointer
  survives the erase.

  Right on its own terms too: by the time a strategy hears it was removed, it
  should be. Reference: `Shyalya/tortoise-wow@0cec7f9`.
---
id: BOT-05
title: Party-member evaluation reads bot AI across map boundaries
workstream: WS-10
priority: p1
existing_ot: none
source: modules/mod-playerbots/src/playerbot/strategy/values/PartyMemberValue.cpp
superseded_by: none
body: |
  The member loop calls `ai->IsTank(player)` and predicates going through
  `Engine::ContainsStrategy` -- reads only safe while that bot is being updated on
  the current map thread. A member who has left the instance is updated by a
  different thread, so the read races that bot's own strategy change.

  **Fix:** as the first check inside the loop, skip any member whose map differs
  from the bot's, or who has no map.

  Correct on domain grounds as well -- there is no healing or assisting across a
  map boundary -- so this is defence in depth, not a workaround. Reference:
  `Shyalya/tortoise-wow@c388a7e`.
---
id: BOT-06
title: Heap-use-after-free in the bot path-debug logger
workstream: WS-10
priority: p2
existing_ot: none
source: modules/mod-playerbots/src/playerbot/strategy/actions/MovementActions.cpp
superseded_by: none
body: |
  Around line 1317 the path diagnostic indexes the result of `getPointPath()`,
  which returns **by value**. Binding a reference to `operator[]` on that temporary
  does not extend the vector's lifetime, so it dangles at the end of the statement
  and the next line reads freed memory. Found by AddressSanitizer on the parallel
  line. It also rebuilds the whole vector every iteration.

  **Fix:** hoist the vector into a local and index that. Reference:
  `Shyalya/tortoise-wow@6ed7c78`.
---
id: BOT-07
title: Remove the stale Eluna OnGiveXP block from XpGainAction
workstream: WS-10
priority: p2
existing_ot: none
source: modules/mod-playerbots/src/playerbot/strategy/actions/XpGainAction.cpp
superseded_by: none
body: |
  The file contains an `ENABLE_ELUNA`-guarded call to `sEluna->OnGiveXP` plus an
  include of `luaEngine.h`. Nothing defines `ENABLE_ELUNA` here, so it has never
  compiled -- and it *cannot* compile if Eluna is ever enabled: `sEluna` is a
  global from an older Eluna, the current one keeps per-map states behind a
  manager, and there is no lower-case `luaEngine.h`.

  Delete the block and the include. If the hook is wanted it belongs with the other
  Eluna hooks. Latent today, a hard build break the day someone turns Eluna on.
  Reference: `Shyalya/tortoise-wow@05adb74`.
---
id: BOT-08
title: Audit the persistent-roster logout guards for call sites passing the default
workstream: WS-10
priority: p2
existing_ot: none
source: modules/mod-playerbots/src/playerbot/PlayerbotMgr.cpp
superseded_by: none
body: |
  `LogoutPlayerBot` and `DisablePlayerBot` take a trailing bool defaulting to
  `false`, and reject the call with an error when the target is a persistent-roster
  member. That is the mechanism enforcing project invariant 1 (ADR-0024).

  At least four call sites still pass the default: `PlayerbotAI.cpp:1280`,
  `PlayerbotAI.cpp:1284`, `PlayerbotLoginMgr.cpp:347`, `PlayerbotMgr.cpp:417`.
  `RandomPlayerbotMgr.cpp:2584` -- the invalid-bot logout inside `ProcessBot` -- is
  the one to check first: if it is reachable for a roster bot it logs an error
  **every tick**.

  Classify each site. A legitimate shutdown or cleanup path passes `true`, as
  `LogoutAllBots` at `PlayerbotMgr.cpp:455` already does; an ordinary rotation
  request leaves `false` and needs its rejection quiet enough not to flood the log.
  Add a regression test per classification.
---
id: CORE-01
title: Group::UpdatePlayerOutOfRange reads another map thread's visible list
workstream: WS-10
priority: p1
existing_ot: none
source: src/game/Group/Group.cpp
superseded_by: none
body: |
  `Group.cpp:1462` still carries the core's own comment `// Possible unsafe call
  (cross maps groups)`. It calls `IsInVisibleList` on a player who may be on
  another map, being updated by another thread.

  **Fix:** skip the `IsInVisibleList` call and send the packet unconditionally when
  the two players are on different maps. **Behaviour is provably unchanged** -- a
  player on another map cannot have this one in his visible list, so the call would
  have returned false and the packet gone out anyway. The call is not replaced,
  only skipped exactly where its answer is already known.

  Pairs with the `m_visibleGUIDs` locking fix already landed: same crash signature
  (`_Hashtable::find`), the other side of the race. Reference:
  `Shyalya/tortoise-wow@22f634b`.
---
id: CORE-02
title: Four script hooks are declared but never dispatched
workstream: WS-10
priority: p1
existing_ot: none
source: src/game/ScriptObjects.h
superseded_by: none
body: |
  `ScriptObjects.h` declares `OnAllCreatureUpdate`, `OnGameObjectAddWorld`,
  `OnGameObjectRemoveWorld` and `OnGameObjectUpdate`, and **none has a call site**.
  A module registering any of them compiles, links, registers, and never runs.

  `Creature.cpp:278` fires only `OnCreatureAddWorld`, with a comment noting that
  hook had itself been dead. Same bug, fixed once and not swept.

  **Fix:** add the dispatches in `Creature::Update` and `GameObject::AddToWorld`,
  `RemoveFromWorld` and `Update`. **Use `ForEachEnabledHook`, not the plain
  `ForEach`** the parallel line used -- these fire per object per tick, and walking
  every registered script each time would cost more than the bug does. Reference:
  `Shyalya/tortoise-wow@aa0b2be`.
---
id: CORE-03
title: MotionMaster::MoveFall() and MoveJump() are stubs, so bots cannot drop or jump
workstream: WS-10
priority: p1
existing_ot: none
source: src/game/Movement/MotionMaster.h
superseded_by: none
body: |
  `MotionMaster.h:171` is `bool MoveFall() { return false; }`. `MoveJump` at :156
  is an empty body wrapping commented-out code. Every dungeon drop-down and ledge
  jump silently does nothing, stranding bot parties at ledges and open shafts. The
  parallel line logged the failed call **12,415 times for a single bot** in Wailing
  Caverns while the party stood over the shaft.

  **Fix:** implement both as straight `MoveSplineInit` splines. `MoveFall` must also
  mutate an `EffectMovementGenerator`, because callers detect landing via
  `EFFECT_MOTION_TYPE` -- not `MOVEMENTFLAG_FALLING`, which a server-side bot never
  clears.

  **Validate before merging.** The reference implementation uses a `300.0f`
  height-search distance and an `EffectMovementGenerator(0)`, both magic numbers,
  and its `MoveJump` silently ignores the `max_height` and `id` arguments. Check
  those against our routes rather than porting on faith. Reference:
  `Shyalya/tortoise-wow@d56cc86`, `@7e41c74`.
---
id: CORE-04
title: LoadScriptNames() runs after spell loading, silently disabling SQL spell scripts
workstream: WS-10
priority: p1
existing_ot: none
source: src/game/World.cpp
superseded_by: none
body: |
  In `World::SetInitialWorldSettings`, `GetScriptId` runs against an empty name map
  while spells are constructed, assigns `ScriptId 0`, and every SQL-bound custom
  spell script is silently disabled. Confirmed on the parallel line against a
  concrete case (Tome of Disguise: Gilnean Worgen).

  **Fix:** call `ScriptMgr::LoadScriptNames()` before spells load.

  **Do not also take their DBC branch.** Its author recorded an unresolved caveat:
  `LoadSpellDBCStore()` there runs *before* `LoadDBCStores()`, the reverse of
  upstream, dormant only because the SQL path is the default. That is CORE-09.
  Reference: `Shyalya/tortoise-wow@a9dbfe7`.
---
id: CORE-05
title: A malformed module config fails with no message
workstream: WS-50
priority: p2
existing_ot: none
source: src/shared/Config/Config.cpp
superseded_by: none
body: |
  `Config::LoadModulesConfigs` returns `false` on any ACE `import_config` failure
  and says nothing. Map the return codes and log the file path: `-1` is "file could
  not be opened", `-3` "invalid INI syntax", `-4` "missing a section header".
  Trivially safe, and it is exactly the silence that costs someone an evening.
  Reference: `Shyalya/tortoise-wow@d1ac7ef`.
---
id: CORE-06
title: Field is missing GetInt8, GetInt64 and GetDouble
workstream: WS-20
priority: p2
existing_ot: none
source: src/shared/Database/Field.h
superseded_by: none
body: |
  Three accessors absent from an otherwise complete set. `GetInt64` must use
  `strtoll` -- note the existing `GetInt32` uses `atol`, which cannot represent the
  range. No behaviour change; closes a real gap for module authors.
---
id: CORE-07
title: Decide whether to adopt Eluna, and not the way the parallel line did
workstream: WS-10
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  `Shyalya/tortoise-wow@aa0b2be` integrates the Eluna Lua engine. Adopting that
  integration as-is would be a mistake, and the reasons are worth stating because
  the feature itself may well be wanted:

  - **It forces every continent map motion, object and visibility thread pool to
    zero** whenever Eluna is enabled, because the Lua state is single-threaded. It
    logs an error and continues. On a realm running ~1000 bots that is not a config
    warning, that is the server.
  - Roughly 30 `#ifdef ENABLE_ELUNA` blocks across ten core files, including
    `Player.cpp`, `Map.cpp`, `Object.cpp`, `World.cpp` and `Chat.cpp`. We have a
    hook system precisely so this does not happen.
  - `Item::GetTemplate()` is wrapped in `#ifndef ENABLE_ELUNA` -- a public API that
    exists or not depending on a build flag.
  - `src/game/CMakeLists.txt` reads the pinned submodule `HookHelpers.h` at
    configure time, runs six `string(REPLACE)` calls to rename a template parameter
    pack MSVC chokes on, and writes a patched copy. It fails *open*: a submodule
    bump silently produces an unpatched file.

  **Correction, after reading the code rather than the diff summary.** The thread
  zeroing is *not* a property of Eluna. Eluna keeps **one Lua state per map**
  (`m_elunaInfo`, keyed by map and instance), and the pools are zeroed because
  parallel updates *within a single map* would re-enter that map's single state
  concurrently. Crucially, `Eluna.OnlyOnMaps` already exists as a config key.

  So the damage is scoped to whichever maps load Eluna, and the options are:

  1. **Do not take it.** We have a module system with hooks, and the data-driven
     direction (`DcRosterFile`) already solves reload-without-rebuild for the
     cases that recur.
  2. **`Eluna.OnlyOnMaps = <instance ids>`.** Continents keep full threading --
     that is where the ~1000 bots live and where the pools matter. Instances get
     Lua, and instances are where scripted encounters are. **No code change
     needed** beyond deleting the blanket zeroing.
  3. **Serialise Lua behind a per-map mutex.** Keeps threads for all non-Lua
     work; contention only while a script runs.
  4. **Marshal Lua calls onto the map's own thread.** Cleanest concurrency, but
     hooks become asynchronous, which breaks any hook that returns a value or
     vetoes.

  **Decide whether we want Lua content scripting at all first.** If yes, option 2
  makes the integration unobjectionable and the rest of the objections above
  still need answering separately.
---
id: CORE-08
title: Decide which Penqle content changes to take
workstream: WS-30
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  Independent of the engineering work on the parallel line, real Turtle-WoW
  (`Penqle/tortoise-wow`) has shipped gameplay changes we have not merged. These
  are realm-owner decisions, not code-quality calls:

  - `643d5ba` -- honor and rank rework: honor gains to 10%, immediate ranks, honor
    as currency, new PvP vendors. **The author states the rank 4-14 rating
    thresholds are made up**, derived from the timings of a boosting service.
  - `1f9497e` -- challenge modes
  - `b5ec899` -- warlock rework, +1,529 lines in `spell_warlock.cpp`
  - `dc22345`, `5fb6339`, `df6e971` -- Rend and Deep Wounds stacking
  - `518f8a9`, `b292c7c`, `f38c119` -- paid gossip items

  Decide each on its own merits. Taking them wholesale because they are "upstream"
  would be the wrong reasoning -- the honor thresholds in particular are an
  invention, not a restoration.
---
id: CORE-09
title: Decide on LoadSpellsFromSql, and settle its DBC ordering caveat first
workstream: WS-30
priority: p2
existing_ot: none
source: src/game/World.cpp
superseded_by: none
body: |
  `Shyalya/tortoise-wow@aee9a89` turns the Penqle removal of `spell_template`
  loading into a config switch defaulting to SQL.

  **The caveat is the point.** Its own author recorded that in the DBC branch
  `LoadSpellDBCStore()` is called from a point that runs *before* `LoadDBCStores()`
  -- the reverse of upstream -- and that this is unresolved. It is dormant only
  because the switch defaults to SQL. Anyone flipping the switch gets the bug.

  If we take the switch, settle the ordering as part of taking it. Related to
  CORE-04, the safe half of the same area.
---
id: CORE-10
title: Offer our build and portability fixes to the parallel line
workstream: WS-00
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  We hold fixes the parallel line lacks, and three are **latent MSVC build breaks
  in their tree today**:

  1. `LFTMgr.h` -- the `ObjectGuid.h` include. They removed it; `ObjectGuid` is used
     by value in members and as a container parameter, so a forward declaration
     cannot work.
  2. `WorldSession::QueuePacket(std::unique_ptr<WorldPacket>)` out of line. Their
     inline body instantiates `default_delete<WorldPacket>` against an incomplete
     type.
  3. `TW_PI` instead of `M_PI` in `SharedDefines.h`.

  Plus two that make their binaries unshippable as container or CI artifacts: they
  still pass `--no-warnings`, which hides every diagnostic, and `-march=native`,
  which bakes the CPU of the build host in. And `enum Difficulty : uint8` instead
  of `typedef int`.

  This is the first concrete test of whether the two lines can exchange fixes at
  all -- which is the entire premise of the split.
---
id: PROV-01
title: Correct the 255 modified vendor files provenance claim
workstream: WS-80
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  ADR-0020, ADR-0026 and `docs/issues/10-refactor-tasks.md` present a 255-file
  PlayerBots delta without naming what was compared, which makes it look like an
  upstream-ike3 measurement. It is not.

  The 255 paths are reproducible only for snapshot `ed32ae41` relative to the
  PlayerBots subtree in graft checkpoint
  `0af2567767de69a819287acaab4c5c947cc1e04c`. That checkpoint describes itself as
  "cmangos/playerbots port grafted onto Penqle/tortoise-wow 1181dev" and is already
  a port. Its PlayerBots subtree is content-identical to checkpoint `1af237d` in
  this repository's rewritten history. At tested roster baseline `3c2b931`, the
  same raw comparison reports 267 changed paths. The previously proposed 258-path
  replacement is not reproducible without an undocumented exclusion or path
  normalization and must not become a provenance claim.

  Reword all three documents to identify the graft-relative snapshots and state
  plainly that neither repository records a verified ike3 source commit, tag or
  remote. The true upstream-ike3 delta is unknown. Selecting and verifying such a
  baseline is separate provenance work; merely adding a remote would not establish
  it.
---
id: PROV-02
title: Record the standing decision on the vendored bot tree and enforce it at merge time
workstream: WS-10
priority: p1
existing_ot: none
source: docs/adr/ADR-0021-module-boundaries-and-schema-ownership.md
superseded_by: none
body: |
  **Decision (pending sign-off):** `modules/mod-playerbots/` here is authoritative;
  `src/modules/PlayerBots/` acquired from the parallel line is deleted on every
  merge.

  The evidence: the two bot trees differ by only **22 files / 1,144 lines**, and 14
  of those files are ours by intent -- the whole `PersistentActiveRoster`
  subsystem (1,284 lines plus ~330 of wiring), the runtime module-slot lookup, and
  the hardened LLM path. **Their tree has no bot-persistence mechanism at all.**
  `RandomPlayerbotFactory` there retains raw `Player::DeleteFromDB` calls inside
  the mass regenerate path that ours short-circuits, and their console reset clears
  `ai_playerbot_random_bots` unconditionally where ours refuses. Adopting their
  copy would delete the mechanism enforcing invariant 1.

  Write it into an ADR, add `git rm -r src/modules/PlayerBots` as an explicit step
  in the upstream-merge runbook, and **add a CI check that fails if
  `src/modules/PlayerBots` reappears** -- a delete-vs-modify conflict resolved the
  wrong way once silently resurrects 1,021 files.
---
id: PROV-03
title: Establish a recurring review of the bot-tree commits on the parallel line
workstream: WS-00
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  Given PROV-02, fixes no longer arrive by merge; they must be picked up
  deliberately.

  Set up a recurring review -- monthly is enough at the observed rate:

      cd twow-core && git log --oneline <last-reviewed>..upstream/playerbots-integration-gh -- src/modules/PlayerBots

  Over the last month that was **7 commits, all small and all worth taking** -- they
  are BOT-01 through BOT-07. Record the last-reviewed SHA in a tracked file so the
  next review starts where the last one stopped.

  Note for whoever runs it: **neither line tracks the cmangos playerbots upstream
  by ike3** -- no ike3 remote in either repository, no vendor-sync commits -- so
  this review is the only channel through which fixes from the other line can reach
  us.
---
id: PROV-04
title: Restate the decision to carry an outbound HTTP client in the world server
workstream: WS-70
priority: p2
existing_ot: none
source: modules/mod-playerbots/src/playerbot/PlayerbotLLMInterface.cpp
superseded_by: none
body: |
  `PlayerbotLLMInterface` is roughly 400 lines of HTTP client (`httplib` plus
  rapidjson) that issues outbound POSTs to a configured LLM endpoint, driven by an
  in-game debug command.

  **The parallel line deliberately removed this code** (`758e571 "Remove LLM
  network client"`). We re-added it in hardened form: moderator-only, 64 KiB
  request and response caps, UTF-8 validation, one in-flight request per server,
  executed via `std::async` off the world thread with the future held as a member
  so no destructor blocks the tick.

  The hardening is sound. The point of this item is that a network egress path in a
  game server should be an explicit recorded decision, not something inherited
  silently through a divergence. Write it up: who can trigger it, what leaves the
  process, what the failure modes are, and whether it ships enabled by default.
---
id: OPS-020
title: db-init records failed migrations as applied, so they are never retried
workstream: WS-20
priority: p0
existing_ot: none
source: deploy/compose/db-init.sh
superseded_by: none
body: |
  **A migration that fails is recorded as successfully applied.** Found by the
  smoke job's first real execution, which surfaced a concrete instance:

      ERROR 1146 (42S02) at line 11: Table 'tw_char.ai_playerbot_random_bots' doesn't exist
        while applying 20260708055500_ai_playerbot_random_bots_index.sql

  Three things compound, and each is independently wrong:

  1. **Ordering.** `sql/character_updates/` is applied in `stage 30-updates`, but
     the playerbot tables are created in `stage 40-playerbots` -- afterwards. So
     this migration cannot succeed on a fresh database. Ever.
  2. **The failure is swallowed twice.** `apply_update_dir` runs mariadb with
     `--force` (continue past errors inside the file) AND appends `|| true`
     (discard the exit code). The script sets `set -euo pipefail`, which is then
     defeated deliberately.
  3. **`record_migrations` runs unconditionally.** It walks the same directory
     and inserts a row for every `.sql` file, whether or not it applied. The
     failed migration is now recorded as done and will never be retried -- so the
     index does not exist and the database says it does.

  **Consequence:** on any fresh bootstrap, `ai_playerbot_random_bots` has no
  `idx_owner_bot_event`. Directly relevant to REF-018 and the superseded
  WS20-001, which reasoned about that index; it is not there.

  **It also explains OPS-012.** `record_migrations` inserts `Hash='manual'`. This
  script is the source of the 146 unverifiable rows, so fixing OPS-012 without
  fixing this would only stop new ones.

  **To fix, in order:**
  1. Apply the module SQL before `character_updates`, or move this migration into
     the module that owns the table. Prefer the latter -- a migration for a
     module's table belongs with the module.
  2. Drop `--force` and `|| true`. A migration that fails must fail the
     bootstrap; `set -e` is already there and should be allowed to work.
  3. Record only what actually applied, and record a content hash rather than the
     literal string `manual`.
  4. Add a smoke assertion that the index exists after bootstrap, so this cannot
     regress silently again.
---
