# Bot-bot groups with a group quest log

- Status: **Draft for owner review** (design only; implementation starts after approval)
- Issue: #365 (related: #324 level coherence, #340 / core#147 quest share, #301 / core#152
  singleton group, #28 group lifecycle, #329 quest commitment)
- Owner chat: OB-10 (design), OB-15 (commands)
- Date: 2026-09-27
- Step 1 (config keys + diagnostics, no behaviour change): Cilverkrow/twow-core PR, branch
  `claude/youthful-einstein-pynlk1`

## 1. Goal

Roster bots form **groups of at most 3 bots** (a player group works as before). The goal
is to survive better and progress together. A bot plays **partly in a group and partly
solo**.

While grouped, a bot works on the leader's current quests. When it leaves, the group
quests go away and its **own quest log is exactly as it was**, so it continues where it
stopped.

Not in scope:
- raids, battlegrounds, LFG
- groups with non-roster bots
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

## 3. Design decision: overlay instead of swap

The owner's goal is "the old log is there again exactly as it was". **We reach it by never
removing the personal log.** The group quest log is an **overlay**:

- On join, the bot takes the leader's current quests that it **does not have yet** into
  **free slots**. Each one is marked `origin=group` (journal, §6).
- Quests the bot already had (the **intersection**) remain **personal**. Progress made on
  them in the group stays: that is real progress, not a group artefact.
- On leave, **only `origin=group` quests** are removed (rules in §5). The personal quests
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

## 4. Formation rules

Everything below applies only with `AiPlayerbot.BotGroups.Enabled = 1`. It is independent
of `RandomBotGroupNearby`, which stays 0 live.

With BotGroups enabled:
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
   and restore (§3, §5) apply there too. For the member, only `origin=group` quests are
   removed on leave.

## 5. Leaving: what happens to group quests

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

## 6. Persistence and crash safety

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
| `AiPlayerbot.BotGroups.Enabled` | 0 | 1 (reported only) | master switch; 0 = today's behaviour exactly (invariant 4) |
| `AiPlayerbot.BotGroups.MaxBots` | 3 | 1 | max bots per bot-bot group, clamped 2..5 |
| `AiPlayerbot.BotGroups.LevelWindow` | 3 | 1 | max level spread (max − min) in the group |
| `AiPlayerbot.BotGroups.Diagnostics` | 0 | 1 | `[BotGroup]` / `[GroupQuestLog]` lines |
| `AiPlayerbot.BotGroups.GroupChance` | 10 | 2 | % per seldom tick that a free roster bot starts a group |
| `AiPlayerbot.BotGroups.MinGroupSeconds` | 1200 | 2 | minimum group phase |
| `AiPlayerbot.BotGroups.MaxGroupSeconds` | 3600 | 2 | maximum group phase |
| `AiPlayerbot.BotGroups.SoloCooldownSeconds` | 1800 | 2 | solo phase after leaving |
| `AiPlayerbot.BotGroups.QuestLog.Enabled` | 0 | 3 | overlay group quest log (§3); off = members keep only their own quests |
| `AiPlayerbot.BotGroups.QuestLog.ReserveSlots` | 5 | 3 | slots kept free for group quests |
| `AiPlayerbot.BotGroups.QuestLog.HandInGraceSeconds` | 1800 | 3 | keep complete group quests after an unplanned leave |

- Step 1 ships only the first four. `config_key_usage_tests.py` rejects keys that nothing
  reads, so later keys come with the code that reads them.
- The live profile (`config/canonical/profiles/funserver-test/`) is changed only by an
  owner-approved config PR: first `Diagnostics = 1`, later `Enabled = 1`.

## 8. Diagnostics

**Step 1 (in the core PR):** one line per join/leave of a free bot:

```
[BotGroup] event=join|leave bot=<guid> leader=<guid> group=<id> roster=0|1 leader_real=0|1
  members=<n> bots=<n> level_spread=<n> verdict=player_led|fits|too_many_bots|level_window
  enabled=0|1 max_bots=<n> level_window=<n> bot_quests=<n> leader_quests=<n> shared_quests=<n>
```

It gives a baseline on the live server before any behaviour changes:
- how many bot groups would violate the rules (`verdict`)
- how much quest-log overlap leader and member have today (`shared_quests`)

Later steps:
- `[BotGroup] event=form|invite|reject|phase_end reason=<chance|cooldown|size|level_window|role|goal_reached|stale_leader|deaths|max_time>`
- `[GroupQuestLog] op=add|log_full|keep|drop|close|reconcile bot=… leader=… quest=… reason=…`
- `[QuestShare] path=bot_leader …` (same codes as core#147)

## 9. Acceptance measures

Measured from the logs on the test profile with `Enabled = 1`, over at least 6 h and
≥ 30 roster bots.

1. **Size:** no `[BotGroup]` line with `bots > MaxBots` in a bot-led group.
2. **Coherence (#324):** no bot-led group with `level_spread > LevelWindow` for longer than
   5 min (the phase end is logged).
3. **Mix:**
   - the share of roster-bot time spent grouped is between 20 % and 60 %
   - each grouped bot also has solo phases
4. **Restore:** for every leave, the bot's personal quest set and counters after leaving
   equal those before joining. Test: snapshot `character_queststatus` for 3 bots, group,
   leave, diff. Quests handed in during the group are the only allowed difference.
5. **Crash:** kill `mangosd` while a group has open group quests, then restart. After the
   reconcile there are no journal rows without a matching quest, the group quests are
   dropped or kept per §5, and personal quests are unchanged.
6. **Invariant 1:**
   - roster GUIDs, item counts and levels are identical across the test
   - no personal quest is lost
   - no quest-bound item of a personal quest is destroyed
7. **Survival goal:** deaths per bot-hour grouped vs solo (from the death-count value).
   Grouped must not be worse; target −25 %.
8. **Performance:** bot AI p99 per map update is no worse than without the feature (see
   the #351 regression).
9. **Off means off:** with `Enabled = 0` the behaviour and log output are identical to
   `main` (no `[BotGroup]` lines while `Diagnostics = 0`).

## 10. Implementation steps

| Step | Repo | Content | Behaviour change |
|---|---|---|---|
| 1 | twow-core | the 4 config keys, `BotGroupPolicy.h`, `[BotGroup]` diagnostic on join/leave, tests | none |
| 1b | twow-repo | pin bump; profile `Diagnostics = 1` (owner decision) | log only |
| 2 | twow-core | `form bot group` action (formation §4), leave conditions, solo cooldown | with `Enabled = 1` |
| 3 | twow-core + twow-repo | `cv_bots.ai_playerbot_group_quest` migration, bot-leader admission in `CatchupQuestAction`, overlay/journal/reconcile | with `QuestLog.Enabled = 1` |
| 4 | twow-repo | live test per §9; then owner decision on re-enabling | — |

## 11. Open points for the owner

1. **Overlay vs strict swap (§3):**
   - OK to never remove personal quests and reserve slots instead?
   - a strict swap needs a Core API change and is loss-prone on crash
2. **Complete, not handed in:** grace of 30 min, then drop. Or keep until handed in?
3. **Role mix:** is "max one tank, max one healer" enough, or is a tank/healer required
   for a group of 3?
4. **Level window:** 3 levels spread (the issue suggests configurable). And may the step-2
   formation replace upstream `invite nearby` for roster bots entirely?
5. **Non-roster free bots** in bot-bot groups: excluded (proposal) or allowed?
6. **Bot-leader sharing** extends the core#147 admission: requester "group leader bot"
   instead of "master". Level window 0–8 or the group window?
