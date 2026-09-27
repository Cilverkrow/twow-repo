# Bot-bot groups: ad-hoc quest groups, later a group quest log

- Status: **Draft for owner review** (design only; implementation starts after approval)
- Issue: #365 (related: #307 L1 start zones, #324 level coherence, #340 / core#147 quest
  share, #301 / core#152 singleton group, #28 group lifecycle, #329 quest commitment, #351
  tick cost)
- Owner chat: OB-10 (design), OB-15 (commands)
- Date: 2026-09-27; revised 2026-09-27 for the owner gameplay decision "ad-hoc quest
  groups" (#365 comment 5854776547) and the OB-10 review on #387
- Step 1 (config keys + diagnostics, no behaviour change): Cilverkrow/twow-core#168

## 1. Goal

**Step 2, the owner contract of 2026-09-27: ad-hoc quest groups.**
- Roster bots that work on **the same quest objective** at the same place invite each other.
  Groups hold up to 5 bots, and a bot joins an existing ad-hoc group rather than opening a
  new one.
- They share kill credit (vanilla group rules), so nobody waits alone for respawns. That
  is the fix for bots stuck in crowded start zones (#307).
- Each bot leaves **as soon as its own objective is done** or the quest is turned in. It
  meets others again at the next quest if that fits. There is no permanent binding.

**Step 3 (optional, later): leader-driven groups with a shared group quest log.** This is
the original #365 idea: a bot takes over the leader's quests and its own log is restored
on leaving. It is kept in §6. It only matters if the owner still wants bots "playing
together across different quests" after step 2. Ad-hoc groups **share no quests**:
everyone already has the quest, so they need no overlay or restore.

Not in scope:
- raids, battlegrounds, LFG, instances
- groups with non-roster bots or players
- changing how a player-led group forms (invite / share button stay as they are)
- BotBrain / LLM group decisions (#43, #282)

## 2. Where we stand (analysis of `main`, twow-core `e50b648`)

### 2.1 Group formation

| What | Where | Behaviour today |
|---|---|---|
| Strategy `group` | `AiFactory.cpp:1030-1031, 1062-1063` | every free bot that is ungrouped or leads its group; also followers of a bot master |
| `invite nearby` / `invite guild` | `GroupStrategy.cpp:6-38`, `InviteToGroupAction.cpp:291-423` | gated by `AiPlayerbot.RandomBotGroupNearby`; candidates ungrouped, not SOLO grouper type, **±2 levels of the inviter**, in `spellDistance` |
| `lfg` / `join` | `InviteToGroupAction.cpp:36-85, ~205` | ±4 levels |
| `accept invitation` | `AcceptInvitationAction.h:13-90` | security check (`AiPlayerbot.LevelCheck`), Core accept opcode; a free bot takes the inviter as master |
| `leave far away` | `LeaveGroupAction.cpp:94-153` | a grouped bot without an active player master leaves if grouping is off, it is SOLO, too many deaths, level diff > 4, or no XP/honor for 15 min |
| leave primitive | `LeaveGroupAction.cpp:40-92` | always the Core path `HandleGroupDisbandOpcode` → `RemoveMember` → disband below 2; #301: a self-led singleton is left (`SingletonGroupPolicy.h`) |
| control | `RosterControlPolicy.h` (#292) | `leave` for a roster bot only from master / leader / GM |

Live state:
- `config/canonical/profiles/funserver-test/aiplayerbot.overlay.conf:16` has
  `AiPlayerbot.RandomBotGroupNearby = 0` (#321). Bots do not invite each other.
  `leave far away` fires for every bot-led group.
- ADR-0031 holds grouping between bots off until #324 is solved.
- No code implements the #324 level window yet.
- `EvaluateRuntimeBehaviorPolicy` sets `automaticGroupRemoval=false` for roster bots, but
  nothing reads it.

Findings:
1. Group formation exists, but it is upstream's random behaviour:
   - no size limit for bots
   - a level window relative to the inviter only, so a group chain can span 1–13 (#324)
   - no role mix
   - no group/solo phases
2. Leaving is safe: one Core path, #301 fixed. Any new leave rule should use
   `LeaveGroupAction::Leave` and nothing else.

### 2.2 Quest log of a bot in a group

**Adding quests.** A bot receives a quest from its master in two ways:
- the normal share, `HandlePushQuestToParty` → `accept quest share`
- the catch-up from core#102 / core#147: `CatchupQuestAction::Admit`
  (`ShareQuestAction.cpp:71-106`)

Admit's gates:
- the requester is the master
- the bot is a roster bot
- the master has the quest and can share it
- same group, no raid
- reward distance
- level window 0–8
- `QUEST_STATUS_NONE`
- `CanTakeQuestForCatchup` (waives only the minimum level and prerequisites)
- `CanAddQuest`

Then `AddQuest(quest, nullptr)`. Hooks: the chat command `catchup quest`, the share
button (`OnQuestShareRefused`, `PlayerbotScripts.cpp:222-245`) and the
`AcceptQuestShareAction` fallback. **The bot has to be the requester's bot. There is no
bot → bot path yet.**

**Removing quests** (all destructive):
- `PlayerbotAI::DropQuest` (`PlayerbotAI.cpp:2992-3017`)
- `clean quest log` (maintenance strategy, only without an active player master)
- quest-first `RetireOneSafeStaleQuest` → Core `RemoveQuestAtSlot`

**Persistence.** `Player::_SaveQuestStatus` writes `tw_char.character_queststatus`
(status, rewarded, explored, timer, mobcount1-4, itemcount1-4). Quest items are ordinary
inventory. The log has 20 slots (`MAX_QUEST_LOG_SIZE`, `QuestDef.h:35`).

**Two Core facts decide the design:**
- `Player::RemoveQuestAtSlot` (`Player.cpp:15260-15285`) **destroys quest-bound
  objective items** (`BIND_QUEST_ITEM`). It also takes back the quest start items.
- `Player::AddQuest` (`Player.cpp:15030-15054`) **resets the kill/cast/talk counters and
  the delivery counters to 0**.

A "remove personal quest, re-add it later" cycle therefore **loses progress and items**.
Restoring it exactly would mean writing into `mQuestStatus` from the module and giving
back destroyed items. That is a fragile bypass of Core and against ADR-0040.


## 3. Step 2: ad-hoc quest groups (owner contract 2026-09-27)

### 3.1 Formation

The action `ad-hoc group` runs in a new strategy `adhoc group`. It is added to roster bots
only while `AiPlayerbot.BotGroups.Enabled = 1`. It is **independent of
`RandomBotGroupNearby`**, which stays 0 live. The upstream `invite nearby` / `invite guild`
paths are not touched, so they stay off wherever they are off today.

**Candidate check** on bot A, at most once per `BotGroups.AdHoc.ScanIntervalSeconds`
(default 10) per bot:
1. A is a roster bot, has no master, and is not in an instance, battleground or raid.
   It is either ungrouped or in an ad-hoc group that is not full.
2. A's current quest-first travel target is a `QuestObjectiveTravelDestination`, so A is
   working on an objective now, not travelling to a giver or turn-in. Its key is
   `(questId, objective entry)`, where the entry is the creature, GO or item.
3. Neighbours come from `nearest friendly players`, limited to `BotGroups.AdHoc.Radius`
   (default 50 yd). There is no new world scan (#351 lesson). Each neighbour B must:
   - be a roster bot of the same faction, with no master
   - have the **same objective key**, still unfinished for B
   - fit the level window: the whole group's spread (max − min) stays within
     `BotGroups.LevelWindow`
   - not be in a pair cooldown with A (§3.3)
   - be either ungrouped, or in a not-full ad-hoc group of its own
4. **Join instead of open:**
   - If B leads a not-full ad-hoc group, A asks to join it. If A leads one, A invites B.
   - If both are ungrouped, the bot with the lower GUID invites. This is deterministic, so
     two bots never invite each other at the same moment.
   - Invites go through the existing group path: `Invite()` →
     `HandleGroupInviteOpcode`, then the other side runs `accept invitation`.
5. **Size:** at most `BotGroups.MaxBots` bots. The code default is 3; the owner contract
   and the funserver-test profile use 5. The Core party limit is 5.
6. **One ad-hoc group per bot.** A bot in any group that is not ad-hoc is never a
   candidate. That includes player groups and a master.

A group counts as ad-hoc because a module-side registry says so: a bounded in-memory map
from group id to `{objective key, created}`, like `grind_cap::AvoidStore` (#351). There is
no DB row, and a restart simply forgets it. After a restart a leftover group is an
ordinary bot group, and the leave rules of §3.2 still end it, because they check objective
completion rather than the registry.

### 3.2 Leaving

A bot leaves via `LeaveGroupAction::Leave`, the Core path (#301). It leaves at the first of
these:

| Reason | Condition |
|---|---|
| `objective_done` | its own objective for the group's key is complete (kill/item counter reached) |
| `quest_turned_in` | the quest was turned in, or is no longer in its log |
| `out_of_range` | more than `2 × Radius` from the group leader for 60 s |
| `level_window` | the spread left the window after a level-up, for more than 5 min |
| `idle` | no objective progress in the group for 10 min (stale leader / nothing left to kill, #324) |
| `instance` | the bot or the group entered an instance |

- The leader leaving disbands a group that drops below 2 members (Core). The remaining bot
  goes solo.
- The #145 dismiss rule stays: a roster bot leaves on its own, or because its
  master/leader/GM tells it to.
- The bot's own quest log was never changed, so there is nothing to restore. This is the
  "#365 restore" of the owner contract, reached by construction.
- ADR-0010 stays: rotation, lease or population policy never logs out or removes a grouped
  roster bot.

### 3.3 Anti-spam

- **Pair cooldown:** after A and B were in an ad-hoc group together, or an invite between
  them was declined or timed out, they do not invite each other for
  `BotGroups.AdHoc.PairCooldownSeconds` (default 600). The store is a bounded in-memory map
  (at most 8192 pairs, stale entries pruned), not an AI context value (#351).
- At most one invite per bot per scan interval.
- Declined invites count toward the pair cooldown, so there are no invite loops.
- Meeting again at a *different* objective after the cooldown is explicitly allowed (owner
  point 4).

### 3.4 What role mix, phases and solo cooldown mean here

Nothing. They do not apply to ad-hoc groups: "leave as soon as done" would contradict a
minimum group time, and the objective decides who fits, not the role. They stay in §6.2 as
the rules of the optional step 3.

## 4. Kill credit and loot (vanilla rules, verified in Core)

**Kill credit.** `Player::RewardPlayerAndGroupAtEvent` (`Player.cpp:22360-22383`) gives
`KilledMonsterCredit` to **every group member** within `IsAtGroupRewardDistance`, whether
alive or dead but not released. Casts work the same way (`RewardPlayerAndGroupAtCast`).
So "five bots kill kobolds, everyone gets the kill count" works as it is.

**Quest item drops are the risk.**
- Quest-only drops (`needs_quest`) sit in `Loot::m_questItems` and are visible to every
  member who has the quest (`LootItem::AllowedForPlayer`, `LootMgr.cpp:486-500`).
- But an item **without `ITEM_FLAG_PARTY_LOOT` (0x800)** is looted **once per corpse**:
  the first looter sets `is_looted` for everyone (`LootMgr.cpp:729-752, 925-945`).
- Only party-loot items (`freeforall`) go to each eligible member.
- So "five kill wolves, everyone gets their meat" is true only for party-loot items. Other
  item objectives still profit, because the group kills faster and shares tags, but items
  are split rather than multiplied.

Mitigation in step 2:
- ad-hoc groups use **free-for-all** loot, so no roll delay
- each bot loots corpses of kills it was credited for
- the bot whose item objective is **furthest behind** loots first
  (`adhoc loot priority`, a pure policy)
- when the leading bot's own item objective is complete, it stops looting quest items and
  leaves (`objective_done`)

**Open measurement (not live, operator query):** how many Turtle quest items in the
objectives of the start zones are party loot. Query:
`SELECT entry, name FROM item_template WHERE Flags & 0x800` joined with the `ReqItemId*`
of quests in the level 1–15 zones. If most "meat"-type items are not party loot, the owner
decides whether to accept splitting (proposal) or to flag them with a world-DB migration
(`Funserver.*`, as for the "all quests sharable" switch in core#159).

## 5. Tick cost

- The candidate check runs **once per 10 s per bot**, not per tick. It reads the existing
  `nearest friendly players` value within 50 yd and compares one `(questId, entry)` pair per
  neighbour. There are no quest-log scans of other bots and no DB access.
- The registry and pair cooldown are bounded maps with pruning (#351). The leave check
  reads the bot's own quest status for one quest.
- Acceptance includes no p99 regression of the bot AI part of the map update (§9).

## 6. Step 3 (optional, later): leader-driven groups with a shared group quest log

This is the original #365 design. It is kept for the case where the owner still wants bots
of *different* quests playing together. Ad-hoc groups (step 2) need none of it. The §11
questions 5–8 belong only to this step.

### 6.1 Overlay instead of swap

The owner's goal is "the old log is there again exactly as it was". **We reach it by never
removing the personal log.** The group quest log is an **overlay**:

- On join, the bot takes the leader's current quests that it **does not have yet** into
  **free slots**. Each one is marked `origin=group` (journal, §6.4).
- Quests the bot already had (the **intersection**) remain **personal**. Progress made on
  them in the group stays: that is real progress, not a group artefact.
- On leave, **only `origin=group` quests** are removed (rules in §6.3). The personal quests
  were never touched, so counters, items, timers and slots stay exact.
- **Slot budget:** a bot keeps `QuestLog.ReserveSlots` slots free for group quests
  (default 5). Quest-first acquisition stops at `20 - ReserveSlots` personal quests while
  BotGroups is enabled.
  - If fewer free slots exist than the leader has quests, the bot takes as many as fit,
    in the leader's order: nearest objective first, then the lowest level.
  - It logs `reason=log_full` for the rest.
  - **No personal quest is ever dropped to make room.**

Rejected alternative, "snapshot + park + restore" (what the issue originally sketched):
- it needs non-destructive slot clearing and counter restore in Core, which means a
  `ScriptMgr`/Player API change (a request to the core owner, AGENTS.md "Never edit")
- a crash between park and restore loses items (invariant 1: "never lose a bot" includes
  its progression)

If the owner requires a strict swap anyway, that is a separate Core issue. It would need
`Player::SuspendQuestAtSlot`/`ResumeQuest`, which clears the slot and keeps the status and
items. It is not part of this design.

**Union or intersection?**
- The group log is the **leader's current log, filtered through the same admission as
  the catch-up** (`CatchupQuestAction::Admit` gates, extended to a bot leader), **without
  the quests the member already has**.
- No union over all members: the leader drives, the members follow. Members' personal
  quests that happen to lie on the way still progress.
- Quests of other members are **not** shared further. Only one level of sharing, from the
  leader.

**Sharing mechanics.**
- Admit gets a second requester kind, "bot leader of a bot-bot group" (flag
  `requester_kind=bot_leader`).
- All gates stay, except "requester is the master". It becomes "requester is the group
  leader, and leader and member are both roster bots in a BotGroups group".
- No synthetic completion or reward (as in core#147). The quest is handed in at the
  normal NPC.

### 6.2 Formation of leader-driven groups (superseded for step 2)

These rules apply only if step 3 is built. Ad-hoc groups (§3) do not use them. The keys
named here (`BotGroups.GroupChance` 10 %, `MinGroupSeconds` 1200, `MaxGroupSeconds` 3600,
`SoloCooldownSeconds` 1800) would arrive with step 3. The rules are independent of
`RandomBotGroupNearby`, which stays 0 live.

With step 3 enabled:
- the upstream `invite nearby` and `invite guild` paths stay off for roster bots
- the new action `form bot group` is the only way roster bots group with each other
- the old paths remain for non-roster bots

1. **Who starts a group:**
   - a roster bot that is ungrouped, has no master, and is not in its solo cooldown
   - chance `BotGroups.GroupChance` percent per "seldom" tick
   - it becomes the leader
2. **Who is invited:**
   - roster bots only, same faction, ungrouped, no master, not in solo cooldown
   - within `spellDistance × 2`
   - the level spread of the whole group (max − min, leader included) stays
     `≤ BotGroups.LevelWindow` (default 3). This is a group-wide window, not the old
     inviter-relative ±2 that allowed chains (#324).
3. **Size:** at most `BotGroups.MaxBots` bots (default 3, clamped 2..5). Players in a
   player-led group do not count; player groups are unchanged.
4. **Role mix:**
   - at most one tank and one healer
   - the rest dps
   - role from the premade spec (#308)
   - a bot without a known role counts as dps
   - preferred but not required: a group of 3 dps is allowed; a second tank or healer is
     not
5. **Group phase:**
   - a group lives at least `BotGroups.MinGroupSeconds` (1200) and at most
     `BotGroups.MaxGroupSeconds` (3600)
   - it ends early when:
     - all group quests are handed in (goal reached: "quest done, thanks, bye", #324)
     - the level spread leaves the window after a level-up, for more than 5 min
     - the leader is stale (no XP / quest progress 15 min, existing value)
     - a member has more than 4 deaths in the phase
6. **Solo phase:** after leaving, `BotGroups.SoloCooldownSeconds` (1800) with no forming
   or joining. That produces the mix of group and solo time.
7. **Leaving:**
   - always `LeaveGroupAction::Leave` (Core path, #301)
   - the leader leaving disbands the group below 2 members (Core); the rest go solo
   - ADR-0010 "grouped roster bots cannot be logged out by rotation" stays
8. **Player groups:** unchanged (invite, share button, catch-up). The quest-log overlay
   and restore (§6.1, §6.3) apply there too. For the member, only `origin=group` quests are
   removed on leave.

### 6.3 Leaving: what happens to group quests

| Group quest state at leave | Action | Log |
|---|---|---|
| handed in (rewarded) | nothing: the reward is real progress; the journal row is closed | `op=close reason=rewarded` |
| complete, not handed in | kept for `QuestLog.HandInGraceSeconds` (1800); quest-first travel hands it in; after the grace it is dropped | `op=keep` / `op=drop reason=grace_expired` |
| incomplete | dropped via the Core path (`RemoveQuestAtSlot`: group quest items go, start items go back) | `op=drop reason=left_group` |
| also personal before join (intersection) | never touched | none |

- The normal case avoids the "complete, not handed in" row: rule 4.5 ends the phase only
  once the group has handed in.
- The grace applies when the group breaks up unplanned (kick, leader logs out, stale
  leader).

### 6.4 Persistence and crash safety

A module-owned journal in **`cv_bots`** (ADR-0021 assigns it to mod-playerbots; invariant 2
keeps `tw_char` read-only for us). It is a new forward-only, replay-safe migration in
`deploy/sql/playerbots/cv_bots/`.

```sql
CREATE TABLE IF NOT EXISTS `ai_playerbot_group_quest` (
  `bot_guid`     INT UNSIGNED NOT NULL,
  `quest_id`     INT UNSIGNED NOT NULL,
  `leader_guid`  INT UNSIGNED NOT NULL,
  `state`        ENUM('added','kept') NOT NULL,
  `kept_until`   INT UNSIGNED NOT NULL DEFAULT 0,   -- unix time, grace end
  `created_at`   INT UNSIGNED NOT NULL,
  PRIMARY KEY (`bot_guid`, `quest_id`)
);
```

- It stores **only which quests came from the group**, never a copy of the personal log.
  The personal log stays in `character_queststatus`, where Core owns it. Nothing to
  restore means nothing that can be restored wrongly.
- **Write-ahead:** the row is committed **before** `AddQuest`, and deleted only **after**
  the drop or reward.
- **Reconcile at bot login and every 5 min** (idempotent):
  - a row whose quest is not in the log is deleted (the quest was dropped or rewarded,
    or `AddQuest` never ran)
  - a row whose bot is no longer grouped with `leader_guid`, state `added`: incomplete →
    drop, complete → `kept` with grace
  - `kept` past `kept_until`: drop
- A crash at any point leaves at most one extra group quest in the log. It is removed on
  the next reconcile. A personal quest can never be affected, because the journal never
  names one.
- The quest log itself is saved by Core as usual. Journal and Core save need not be
  atomic, because reconcile tolerates both orders.
- Invariant 1: no bot, item or personal progress is removed by this feature. The only
  removals are quests the feature itself added.


## 7. Config keys (default off)

| Key | Default | Step | Meaning |
|---|---|---|---|
| `AiPlayerbot.BotGroups.Enabled` | 0 | 1 (reported only), 2 | master switch; 0 = today's behaviour exactly (invariant 4) |
| `AiPlayerbot.BotGroups.MaxBots` | 3 | 1 | max bots per bot group, clamped 2..5; funserver-test: **5** (owner contract) |
| `AiPlayerbot.BotGroups.LevelWindow` | 3 | 1 | max level spread (max − min) in the group |
| `AiPlayerbot.BotGroups.Diagnostics` | 0 | 1 | `[BotGroup]` / `[AdHocGroup]` lines; funserver-test: on |
| `AiPlayerbot.BotGroups.AdHoc.Radius` | 50 | 2 | yards within which bots with the same objective group (owner: 40–60) |
| `AiPlayerbot.BotGroups.AdHoc.ScanIntervalSeconds` | 10 | 2 | candidate check per bot, at least 10 s |
| `AiPlayerbot.BotGroups.AdHoc.PairCooldownSeconds` | 600 | 2 | no re-invite between the same two bots |
| `AiPlayerbot.BotGroups.QuestLog.*` | — | 3 | only if step 3 is wanted (§6: `Enabled`, `ReserveSlots`, `HandInGraceSeconds`) |

- Step 1 ships only the first four keys (twow-core#168). `config_key_usage_tests.py` rejects
  keys that nothing reads, so later keys come with the code that reads them.
- The live profile (`config/canonical/profiles/funserver-test/`) is changed only by an
  owner-approved config PR:
  - first `Diagnostics = 1` and `MaxBots = 5`
  - then `Enabled = 1`

## 8. Diagnostics

**Step 1 (twow-core#168):** one line per join/leave of a free bot:

```
[BotGroup] event=join|leave bot=<guid> leader=<guid> group=<id> roster=0|1 leader_real=0|1
  members=<n> bots=<n> level_spread=<n> verdict=player_led|fits|too_many_bots|level_window
  enabled=0|1 max_bots=<n> level_window=<n> bot_quests=<n> leader_quests=<n> shared_quests=<n>
```

It gives a baseline on the live server before any behaviour changes:
- how many bot groups would violate the rules (`verdict`)
- how much quest-log overlap leader and member have today (`shared_quests`)

**Step 2 (ad-hoc):**

```
[AdHocGroup] op=form|join|leave|reject bot=<guid> other=<guid> group=<id> quest=<id>
  entry=<id> members=<n> level_spread=<n>
  reason=<objective_done|quest_turned_in|out_of_range|level_window|idle|instance|
          pair_cooldown|full|not_roster|has_master|different_objective|declined>
```

- The step 1 `[BotGroup]` line gets `kind=adhoc|bot|player` in step 2. The registry that
  knows "ad-hoc" arrives with step 2, so #168 does not carry the field.
- Step 3 only: `[GroupQuestLog] op=add|log_full|keep|drop|close|reconcile …` and
  `[QuestShare] path=bot_leader …`.

## 9. Acceptance measures

**Step 2 (ad-hoc)** is measured after a new L1 start on the test profile with
`Enabled = 1`, `MaxBots = 5` and `Diagnostics = 1`, over at least 6 h and ≥ 30 roster bots.

1. **Start zones (owner point 8):** no roster bot stays at level 1 for longer than 2 h
   (proposed X; the owner sets it). The quest turn-in rate in the start zones is higher
   than on the previous L1 start (#307 baseline).
2. **Leave as soon as done:** ≥ 95 % of `[AdHocGroup] op=leave` lines have
   `reason=objective_done|quest_turned_in`. Every such leave comes within 60 s of the
   bot's objective being completed.
3. **No spam:**
   - no pair with more than one `form`/`join` per `PairCooldownSeconds`
   - no bot with more than 6 invites per hour
   - no invite loop, meaning alternating invite and decline between the same two bots
4. **Size and coherence:**
   - no group with `bots > MaxBots`
   - no ad-hoc group with `level_spread > LevelWindow` for longer than 5 min
   - no ad-hoc group in an instance
   - no player in an ad-hoc group
5. **Invariant 1:** roster GUIDs, item counts and levels are identical across the test,
   and no quest was dropped by this feature (it drops none).
6. **Performance:** bot AI p99 per map update is no worse than without the feature (see
   the #351 regression).
7. **Off means off:** with `Enabled = 0` the behaviour is identical to `main`, and there
   are no `[AdHocGroup]` / `[BotGroup]` lines while `Diagnostics = 0`.

**Step 3**, if built, additionally needs these, measured with `QuestLog.Enabled = 1`:
- the personal quest log after leaving equals the log before joining (diff of
  `character_queststatus` for 3 bots)
- after a `mangosd` kill in the middle of a group, reconcile leaves no journal rows without
  a matching quest, and personal quests are unchanged

## 10. Implementation steps

| Step | Repo | Content | Behaviour change |
|---|---|---|---|
| 1 | twow-core | #168: the 4 config keys, `BotGroupPolicy.h`, `[BotGroup]` diagnostic on join/leave, tests | none |
| 1b | twow-repo | pin bump; funserver-test profile `Diagnostics = 1`, `MaxBots = 5` (owner decision) | log only |
| 2 | twow-core | ad-hoc quest groups §3–§5: strategy and action, registry, pair cooldown, leave reasons, loot priority, `[AdHocGroup]`, tests | with `Enabled = 1` |
| 2b | twow-repo | profile `Enabled = 1` after review; live test per §9 | owner decision |
| 3 | twow-core + twow-repo | optional: leader-driven group quest log §6 (journal migration in `cv_bots`, bot-leader admission) | with `QuestLog.Enabled = 1` |

## 11. Open points for the owner

For step 2 (ad-hoc):
1. **Quest items that are not party loot** (§4): accept that items are split between the
   members (proposal), or flag start-zone quest items as party loot via a funserver
   world-DB migration? First the operator query in §4.
2. **Acceptance X:** is "no bot stays at level 1 for more than 2 h" the right threshold?
3. **Radius and level window:** 50 yd and a spread of 3?
4. **Non-roster free bots:** excluded (proposal; the owner contract says "only between
   roster bots").

For step 3 (only if still wanted after step 2):

5. Overlay instead of a strict swap? A strict swap needs a Core API change and can lose
   items on a crash.
6. Complete but not handed in: grace of 30 min, or keep the quest until it is handed in?
7. Bot-leader sharing (extending the core#147 admission): level window 0–8 or the group
   window?
8. Role mix: is "at most one tank and one healer" enough?
