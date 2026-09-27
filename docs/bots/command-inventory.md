# Bot commands: what do the roster bots really accept?

Status: 2026-09-27 · Code state `twow-core@e50b6481` (playerbots module) · Owner chat: OB-15 · Issues: twow-repo#290, #292, #354, #389

This document is the source for extending the BotMenu addon (`twow-core/modules/mod-playerbots/addon/BotMenu-1.12`).
It is **generated from the code** (registries of the chat triggers, the chat command strategy and the action classes) and
supplemented by hand for the player-relevant commands. Where the owner has already verified a command live, it says so.

## 1. How a command reaches the bot

| Channel | Who receives it | Code |
|---|---|---|
| `/w <Bot> <command>` | exactly this bot | `PlayerbotMgr::HandleCommand`, `RandomPlayerbotMgr::HandleCommand` |
| `/p <command>` | all bots **in your group** | `RandomPlayerbotMgr::HandleCommand` (`IsInGroup`) |
| `/raid <command>` | all bots in your raid | same |
| `/s <command>` | your own bots / bots with you as master, ≤ 25 yd | `PlayerbotMgr::HandleCommand` |
| `/y <command>` | same, ≤ 300 yd | same |
| `/g <command>` | roster bots in your guild | `RandomPlayerbotMgr::HandleCommand` |

**Chaining and helpers**
- `a \\ b` runs several commands one after the other (`CommandSeparator`).
- `#p `, `#r `, `#w `, `#g ` in front of a command sets the **reply channel**.
- `queue <command>` staggers the command by position in the group (party/raid only).
- `wait <s>` pauses for up to 20 s.

**Chat filters** (in front of the command, e.g. `/p @tank attack`): only the matching bots react.

| Filter | Examples |
|---|---|
| Role | `@tank`, `@heal`, `@dps`, `@notank`, `@ranged`, `@melee` |
| Class / spec | `@rogue`, `@warlock` … · `@frost`, `@holy` … |
| Level | `@60`, `@10-20` |
| Group | `@group`, `@group2`, `@group4-6`, `@raid`, `@noraid` |
| State | `@needrepair`, `@inside`, `@outside` |
| Raid marker | `@star`, `@circle` … (marked or targeting that mark) |
| Item use | `@use=[Item]`, `@need=[Item]`, `@sell=[Item]` |
| Other | `@guild`, `@rank=…`, `@random`, `@random=25`, `@tier1`, `@dun morogh`, `@nc=rpg` |

## 2. Permissions (who may do what)

- **Chat commands** need the security level `ALLOW_ALL`. That level is held by:
  - a GM (from `AiPlayerbot.RosterControl.GmMinSecurity`, default **3**; #354/#145);
  - the same account;
  - **anyone in the bot's group**.
- Otherwise only `who, where, wts, sendmail, invite, leave, join, lfg, guild invite, guild leave` are allowed
  (`PlayerbotAI::IsAllowedCommand`). Level gap > 30 or a different faction → no reaction.
- **Roster control (#292):** `summon`, `leave`, `train` are allowed only for the bot's **own master in the same group** (or a GM).
  - summon has a safety check (combat/BG/instance/flight/boat/dead) and a 300 s cooldown.
  - leave comes only from the master, the group leader or a GM; any player may resolve a stuck one-person group (#301).
- **`.bot …` / `.rndbot …`:** the admin subcommands (gear/init/levelup/random/train/consumables/pet/delete/debug/…) are **GM only** (#354). A normal player may only use `.bot add/login/remove` for their own account and `.bot summon` for their own bots.
- Chat `cheat` is GM only; chat `debug …` only after the full permission check (#354).

## 3. Player commands in detail (NPC, trade, quests, items)

Prerequisite for NPC commands: **the bot stands next to the NPC**. For `talk`, `trainer`, `home` the NPC must be **selected by the player** (or be the nearest suitable one).

| Command | Syntax / parameters | Effect | Response (examples) | Verified live |
|---|---|---|---|---|
| `talk` | `talk` · `talk N` · `talk [N]` (#170) | shows the NPC's gossip options / selects option N exactly | `[1] Make this inn your home.` · `… - this inn is my new home` · vendor/trainer/bank/flight master/quest list → points to the chat command · invalid → `Usage: talk <number from the list>` | ✅ 2026-09-27 (video) |
| `home` | `home` | makes the selected/nearest inn home | `This inn is my new home` | – (via `talk 1` ✅) |
| `b` / `buy` | `b [Item]` · `b vendor` / `buy usefull` (by item usage) | buys from the nearest vendor | `Buying [Item]` · `Nobody sells [Item] nearby` · `There are no vendors nearby` | ✅ `b [Tough Jerky]` |
| `s` / `sell` | `s` = **grey** · `s gray` · `s vendor` · `s equip` · `s [Item] [Item]` | sells at the nearest vendor | `Selling [Item]` | ✅ (owner, video) |
| `bb` | `bb all` · `bb [Item]` | buyback | `No buyback items found` | – |
| `repair` | `repair` | repairs everything at the nearest NPC | `Cannot find any npc to repair at` | – |
| `bank` | `bank` / `bank ?` (list) · `bank [Item]` (deposit) · `bank -[Item]` (withdraw) | bank at the nearest banker | `=== Bank ===` · `Cannot find banker nearby` | – |
| `trainer` | `trainer` (list) · `trainer learn` · `trainer [Spell]` | class trainer: list/learn (cost by config) | `--- Can learn from … ---` · `… - learned` · `Total cost` | ✅ (raid 2026-09-26, autonomous) |
| `train` | `train` | own roster bot learns at a class trainer in reach (#292) | `No trainer for my class in reach. Bring me …` | – |
| `accept` | `accept [Quest]` · `accept *` (all from the nearby quest giver) | accepts quests | `Quest accepted` / `I can't take this quest` | – |
| `catchup quest` | `catchup quest [Quest]` | catch-up of the master's quest (#340, level window 8) | `Quest accepted` / `Cannot catch up on this quest: <code>` | ✅ via share button (#159) |
| Share button | quest log → share | roster bots take the quest (catch-up), all quests sharable (#159) | `X has accepted your quest` | ✅ 42039 2/2 |
| `r` | `r [Item]` (reward choice) | turns in, chooses the reward | `quest_choose_reward` / `quest_error_talk` | – |
| `drop` | `drop [Quest]` · `drop all` | **abandons** quests | `Quest removed` | – (caution) |
| `quests` | `quests` · `quests all/summary/incompleted/completed` | quest list | `--- Summary --- Total: 7 / 25 …` | ✅ |
| `q` | `q [Quest]` · `q [Item]` | quest objective status / item usage | objective lines | – |
| `loot` | `loot` | picks up loot in reach | – | – |
| `ll` | `ll normal/gray/all/disenchant/skill` · `ll [Item]` (always loot) · `ll ![Item]` (never) · `ll -[Item]` (remove from list) · `ll ?[Item]` (query) | loot strategy | current strategy | – |
| `roll` | `roll need/greed/pass/auto [Item]` | loot roll | – | – |
| `u` / `use` | `u [Item]` · `u [Item] [target]` | use an item (also recipe/open/socket) | `Opening …` · `Learning …` | – |
| `e` / `equip` | `e [Item]` · `e ?` · `e mh [Item]` / `e oh [Item]` | equip | `equip_command` text | – |
| `ue` | `ue [Item]` | unequip | `unequip_command` text | – |
| `c` / `inv` | `c` · `c all/inventory/bank/buyback/equip` · `c [Item]` | item count / inventory | `=== Inventory ===` | – |
| `t` | `t [Item] …` · `t 1g 20s` | offers items/money in an open trade window | – | – |
| `destroy` | `destroy [Item]` | **destroys** items | – | – (caution) |
| `keep` | `keep need/equip/none/? [Item]` | protects/releases items from sale/destruction | `keep ?` lists | – |

Other groups: combat (`follow, stay, guard, free, attack, flee, pull, tank attack, max dps, rti, pet`), formation/position (`formation …`, `stance …`), death (`release, revive, self res`), info (`stats, where, who, talents, spells, skill, reputation`), group (`summon, leave, give leader, ready`). Everything is in the full table below.

## 4. Verified live (owner sessions)

| Session | Commands | Result |
|---|---|---|
| 2026-09-26 16:03–16:20 UTC, raid of 27 (train 5) | `summon` ×4, `follow` ×4, `formation shield/queue/spear/circle/line/arrow/melee/chaos/?`, `free` | ✅ command path via `/p`/`/raid`; formation shapes see #389 |
| 2026-09-27 08:40–08:45 UTC, group of 2 (train 6) | `summon`, `talk`, `talk 1/2`, `b [Item]`, `s [Item]`, `follow`, `quests`, `formation spear`, `leave`, share button 42039 | ✅ everything as described (#290 acceptance); `talk [1]` needed #170 |

Evidence: `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-10\video\…` (standard #388).

## 5. Addon proposal (BotMenu)

**Today (1.1, #170):** Kampf · Formation · Beute · Berufe · Quests · Gruppe · Händler & NPC (45 entries).

**Proposed additions** (all verified in the code, harmless for players):

| Category | New entries |
|---|---|
| Kampf | Tank greift an (`tank attack`), Volle Kraft (`max dps`), Ziehen (`pull`), Markiertes Ziel (`attack rti`), Wandern (`wander`) |
| **Rolle** (new, filter prefix) | "Nur Tanks …", "Nur Heiler …", "Nur Fernkampf …": puts `@tank ` / `@heal ` / `@ranged ` in front of the next command |
| Formation | `stance behind/tank/near` (only if #389 does not replace it) |
| Beute | Würfeln Bedarf/Gier/Passen/Auto (`roll need/greed/pass/auto`) |
| Quests | Belohnung wählen… (`r `), Questziel prüfen… (`q `) |
| Händler & NPC | Zurückkaufen (`bb all`), Bank (`bank ?`) |
| Inventar (new) | Inventar (`c`), Ausrüsten… (`e `), Benutzen… (`u `), Handeln… (`t `) |
| Tod (new) | Freilassen (`release`), Wiederbeleben (`revive`), Selbst wiederbeleben (`self res`) |
| Info (new) | Status (`stats`), Wo bist du? (`where`), Talente (`talents`), Zauber (`spells`) |
| Gruppe | Anführer geben (`give leader`), Bereitschaftscheck (`ready`) |

**Deliberately hidden:** all "caution" and "no" commands in the table: `destroy`, `drop`, `sendmail`, `ah`/`ah bid`, `cast`, guild rank changes, `reset strats/ai`, `set value`, `debug`, `cheat`, `glyph` (WotLK).

### Owner decisions
1. **Role filter menu** ("only tanks/healers/ranged …") as its own category? (Very useful in a raid, but a two-step click.)
2. **Inventory/trade** in the menu, or leave it to typing because of item links?
3. **`drop` (abandon quest)** stays hidden? (Risk: abandons quests by mistake.)
4. **Menu size:** max. 32 entries per submenu (UIMenu), today 7 categories. OK to go up to about 11 categories?
5. **Order** of the categories (proposal: Kampf, Formation, Rolle, Gruppe, Quests, Händler & NPC, Beute, Berufe, Inventar, Tod, Info).

## 6. Full table of all chat commands (generated)

Columns: command (chat trigger) · action(s) from `ChatCommandHandlerStrategy` · action class (file under `mod-playerbots/src/playerbot/strategy/`) ·
category · suitable for players (`yes` / `caution` = destructive or economic / `no` = admin/diagnostics) · addon status.

| Command | Action(s) | Code | Category | For players | Addon |
|---|---|---|---|---|---|
| `accept` | accept quest | – | Quests | yes | in menu |
| `add all loot` | add all loot + loot + move to loot + open loot | AddAllLootAction (`actions/AddLootAction.cpp`) | Beute | yes | hidden (=loot) |
| `ah` | ah | AhAction (`actions/AhAction.cpp`) | NPC | caution | hidden |
| `ah bid` | ah bid | AhBidAction (`actions/AhAction.cpp`) | NPC | caution | hidden |
| `all` | all | ChangeAllStrategyAction (`actions/ChangeStrategyAction.cpp`) | Strategie | yes | hidden |
| `attack` | attack my target | AttackMyTargetAction (`actions/AttackAction.cpp`) | Kampf | yes | in menu |
| `attack rti` | attack rti target | AttackRTITargetAction (`actions/AttackAction.cpp`) | Kampf | yes | propose |
| `attackers` | attackers | – | Info | yes | hidden |
| `b` | buy | BuyAction (`actions/BuyAction.cpp`) | NPC | yes | in menu (NPC) |
| `bank` | bank | BankAction (`actions/BankAction.cpp`) | NPC | yes | propose |
| `bb` | buy back | BuyBackAction (`actions/BuyAction.cpp`) | NPC | yes | propose |
| `bg free` | bg free | BGLeaveAction (`actions/BattleGroundJoinAction.cpp`) | PvP | yes | hidden |
| `boost target` | boost targets | SetBoostTargetsAction (`actions/ValueActions.h`) | Kampf | yes | hidden |
| `buff` | buff | BuffAction (`actions/BuffAction.cpp`) | Kampf | yes | hidden |
| `buff target` | buff targets | SetBuffTargetsAction (`actions/ValueActions.h`) | Kampf | yes | hidden |
| `c` | item count | TellItemCountAction (`actions/TellItemCountAction.cpp`) | Inventar | yes | propose |
| `cast` | cast | CastCustomSpellAction (`actions/CastCustomSpellAction.cpp`) | Kampf | caution | hidden |
| `castnc` | – | – | Kampf | caution | hidden |
| `catchup quest` | catchup quest | CatchupQuestAction (`actions/ShareQuestAction.cpp`) | Quests | yes | in menu |
| `cdebug` | cdebug | DebugAction (`actions/DebugAction.cpp`) | Admin | no | hidden |
| `chat` | chat | ChangeChatAction (`actions/ChangeChatAction.cpp`) | Sozial | yes | hidden |
| `cheat` | cheat | CheatAction (`actions/CheatAction.cpp`) | Admin | no (GM only) | hidden |
| `co` | co | ChangeCombatStrategyAction (`actions/ChangeStrategyAction.cpp`) | Strategie | yes | in menu (passive) |
| `corpse run` | corpse run | CorpseRunAction (`actions/ReleaseSpiritAction.h`) | Tod | yes | hidden |
| `craft` | craft | SetCraftAction (`actions/SetCraftAction.cpp`) | Berufe | yes | hidden |
| `cs` | cs | CustomStrategyEditAction (`actions/CustomStrategyEditAction.cpp`) | Admin | no | hidden |
| `de` | de | ChangeDeadStrategyAction (`actions/ChangeStrategyAction.cpp`) | Strategie | yes | hidden |
| `debug` | debug | DebugAction (`actions/DebugAction.cpp`) | Admin | no (#354) | hidden |
| `destroy` | destroy | DestroyItemAction (`actions/DestroyItemAction.cpp`) | Inventar | caution | hidden |
| `doquest` | doquest | FocusTravelTargetAction (`actions/ChooseTravelTargetAction.cpp`) | Quests | yes | hidden |
| `drop` | drop | DropQuestAction (`actions/DropQuestAction.cpp`) | Quests | caution | hidden |
| `e` | equip | EquipAction (`actions/EquipAction.cpp`) | Inventar | yes | propose |
| `emote` | emote | EmoteAction (`actions/EmoteAction.cpp`) | Sozial | yes | hidden |
| `equip` | equip | EquipAction (`actions/EquipAction.cpp`) | Inventar | yes | hidden (=e) |
| `faction` | faction | FactionAction (`actions/FactionAction.cpp`) | Info | yes | hidden |
| `flag` | flag | FlagAction (`actions/FlagAction.cpp`) | Info | yes | hidden |
| `flee` | flee chat shortcut | FleeChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | in menu |
| `focus heal` | focus heal targets | SetFocusHealTargetsAction (`actions/ValueActions.cpp`) | Kampf | yes | propose |
| `follow` | follow chat shortcut | FollowChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | in menu |
| `follow target` | follow target | SetFollowTargetAction (`actions/ValueActions.cpp`) | Kampf | yes | hidden |
| `formation` | formation | SetFormationAction | Formation | yes | in menu |
| `free` | free chat shortcut | FreeChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | in menu |
| `gb` | gb | GuildBankAction (`actions/GuildBankAction.cpp`) | NPC | yes | hidden |
| `gbank` | – | – | NPC | yes | hidden |
| `give leader` | give leader | GiveLeaderAction (`actions/PassLeadershipToMasterAction.h`) | Gruppe | yes | propose |
| `glyph` | glyph | GlyphAction (`actions/GlyphAction.cpp`) | – | no (WotLK) | hidden |
| `go` | go | GoAction (`actions/GoAction.cpp`) | Reise | yes | hidden |
| `grind` | grind chat shortcut | GrindChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | hidden |
| `guard` | guard chat shortcut | GuardChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | in menu |
| `guild demote` | guild demote | GuildDemoteAction (`actions/GuildManagementActions.h`) | Gilde | caution | hidden |
| `guild invite` | guild invite | GuildInviteAction (`actions/GuildManagementActions.h`) | Gilde | yes | hidden |
| `guild join` | guild join | GuildJoinAction (`actions/GuildManagementActions.h`) | Gilde | yes | hidden |
| `guild leader` | guild leader | GuildLeaderAction (`actions/GuildManagementActions.h`) | Gilde | caution | hidden |
| `guild leave` | guild leave | GuildLeaveAction (`actions/GuildManagementActions.cpp`) | Gilde | yes | hidden |
| `guild promote` | guild promote | GuildPromoteAction (`actions/GuildManagementActions.h`) | Gilde | caution | hidden |
| `guild remove` | guild remove | GuildRemoveAction (`actions/GuildManagementActions.h`) | Gilde | caution | hidden |
| `help` | help | HelpAction (`actions/HelpAction.cpp`) | Info | yes | hidden |
| `hire` | hire | HireAction (`actions/HireAction.cpp`) | Gruppe | yes | hidden |
| `home` | home | SetHomeAction (`actions/SetHomeAction.cpp`) | NPC | yes | in menu (NPC) |
| `inv` | item count | TellItemCountAction (`actions/TellItemCountAction.cpp`) | Inventar | yes | hidden (=c) |
| `inventory` | – | – | Inventar | yes | hidden (=c) |
| `invite` | invite | InviteToGroupAction (`actions/InviteToGroupAction.h`) | Gruppe | yes | hidden |
| `items` | item count | TellItemCountAction (`actions/TellItemCountAction.cpp`) | Inventar | yes | hidden (=c) |
| `join` | join | JoinGroupAction (`actions/InviteToGroupAction.h`) | Gruppe | yes | hidden |
| `jump` | jump | JumpAction (`actions/MovementActions.cpp`) | Formation | yes | hidden |
| `keep` | keep | KeepItemAction (`actions/KeepItemAction.cpp`) | Beute | yes | hidden |
| `leave` | leave | LeaveGroupAction (`actions/LeaveGroupAction.h`) | Gruppe | yes (#292) | in menu |
| `lfg` | lfg | LfgAction (`actions/InviteToGroupAction.h`) | Gruppe | yes | hidden |
| `list ai` | list ai | ListAiAction (`actions/ResetAiAction.cpp`) | Admin | no | hidden |
| `ll` | ll | LootStrategyAction (`actions/LootStrategyAction.cpp`) | Beute | yes | in menu |
| `load ai` | load ai | LoadAiAction (`actions/ResetAiAction.cpp`) | Admin | no | hidden |
| `log` | log | LogLevelAction (`actions/LogLevelAction.cpp`) | Info | yes | hidden |
| `loot` | add all loot + loot + move to loot + open loot | AddAllLootAction (`actions/AddLootAction.cpp`) | Beute | yes | in menu |
| `los` | los | TellLosAction (`actions/TellLosAction.cpp`) | Info | yes | hidden |
| `mail` | mail | MailAction (`actions/MailAction.cpp`) | NPC | yes | hidden |
| `max dps` | max dps chat shortcut | MaxDpsChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | propose |
| `move style` | move style | MoveStyleAction (`actions/MoveStyleAction.cpp`) | Formation | yes | hidden |
| `nc` | nc | ChangeNonCombatStrategyAction (`actions/ChangeStrategyAction.cpp`) | Strategie | yes | in menu (loot/gather) |
| `nt` | trade | TradeAction (`actions/TradeAction.cpp`) | Handel | yes | hidden |
| `outfit` | outfit | OutfitAction (`actions/OutfitAction.cpp`) | Inventar | yes | hidden |
| `pet` | pet | SetPetAction (`actions/GenericActions.cpp`) | Kampf | yes | propose |
| `position` | position | PositionAction (`actions/PositionAction.cpp`) | Formation | yes | hidden |
| `possible attack targets` | tell possible attack targets | TellPossibleAttackTargetsAction (`actions/TellTargetAction.cpp`) | Info | yes | hidden |
| `pull` | pull my target | PullMyTargetAction (`actions/PullActions.h`) | Kampf | yes | propose |
| `pull rti` | pull rti target | PullRTITargetAction (`actions/PullActions.h`) | Kampf | yes | hidden |
| `q` | query quest + query item usage | QueryQuestAction (`actions/QueryQuestAction.cpp`) | Quests | yes | hidden |
| `quest reward` | quest reward | QuestRewardAction (`actions/QuestRewardActions.cpp`) | Quests | yes | hidden |
| `quests` | quests | ListQuestsAction (`actions/ListQuestsActions.cpp`) | Quests | yes | in menu |
| `r` | reward | RewardAction (`actions/RewardAction.cpp`) | Quests | yes | propose |
| `ra` | ra | RemoveAuraAction (`actions/RemoveAuraAction.cpp`) | Kampf | yes | hidden |
| `range` | range | RangeAction (`actions/RangeAction.cpp`) | Formation | yes | hidden |
| `react` | react | ChangeReactionStrategyAction (`actions/ChangeStrategyAction.cpp`) | Strategie | yes | hidden |
| `ready` | ready check | – | Gruppe | yes | propose |
| `release` | release | ReleaseSpiritAction (`actions/ReleaseSpiritAction.h`) | Tod | yes | propose |
| `rep` | reputation | TellReputationAction (`actions/TellReputationAction.cpp`) | Info | yes | hidden |
| `repair` | repair | RepairAllAction (`actions/RepairAllAction.cpp`) | NPC | yes | in menu (NPC) |
| `reputation` | reputation | TellReputationAction (`actions/TellReputationAction.cpp`) | Info | yes | hidden |
| `reset ai` | reset ai | ResetAiAction (`actions/ResetAiAction.cpp`) | Admin | no | hidden |
| `reset strats` | reset strats | ResetStratsAction (`actions/ResetAiAction.cpp`) | Admin | caution | hidden |
| `reset values` | reset values | ResetValuesAction (`actions/ResetAiAction.cpp`) | Admin | no | hidden |
| `revive` | spirit healer | SpiritHealerAction (`actions/ReviveFromCorpseAction.cpp`) | Tod | yes | propose |
| `revive target` | revive targets | SetReviveTargetsAction (`actions/ValueActions.h`) | Kampf | yes | hidden |
| `roll` | roll | RollAction (`actions/LootRollAction.cpp`) | Beute | yes | propose |
| `rti` | rti | RtiAction (`actions/RtiAction.cpp`) | Kampf | yes | propose |
| `rtsc` | rtsc | RTSCAction (`actions/RtscAction.cpp`) | Formation | yes | hidden |
| `runaway` | runaway chat shortcut | GoawayChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | hidden |
| `s` | sell | SellAction (`actions/SellAction.cpp`) | NPC | yes | in menu (NPC) |
| `save ai` | save ai | SaveAiAction (`actions/ResetAiAction.cpp`) | Admin | no | hidden |
| `save mana` | save mana | SaveManaAction (`actions/SaveManaAction.cpp`) | Kampf | yes | hidden |
| `self res` | self resurrect | SelfResurrectAction (`actions/ReleaseSpiritAction.h`) | Tod | yes | propose |
| `sendmail` | sendmail | SendMailAction (`actions/SendMailAction.cpp`) | NPC | caution | hidden |
| `set value` | set value | SetValueAction (`actions/SetValueAction.cpp`) | Admin | no | hidden |
| `share` | share | ShareQuestAction (`actions/ShareQuestAction.cpp`) | Quests | yes | hidden |
| `skill` | skill | SkillAction (`actions/SkillAction.cpp`) | Berufe | yes | in menu |
| `speak` | speak | SpeakAction (`actions/SayAction.cpp`) | Sozial | yes | hidden |
| `spell` | spell | TellSpellAction (`actions/TellCastFailedAction.cpp`) | Kampf | yes | hidden |
| `spells` | spells | ListSpellsAction (`actions/ListSpellsAction.cpp`) | Berufe | yes | propose |
| `ss` | ss | SkipSpellsListAction (`actions/SkipSpellsListAction.cpp`) | Kampf | yes | hidden |
| `stance` | stance | SetStanceAction | Formation | yes | propose |
| `stats` | stats | StatsAction (`actions/StatsAction.cpp`) | Info | yes | propose |
| `stay` | stay chat shortcut | StayChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | in menu |
| `summon` | summon | SummonAction (`actions/UseMeetingStoneAction.cpp`) | Gruppe | yes (#292) | in menu |
| `t` | trade | TradeAction (`actions/TradeAction.cpp`) | Handel | yes | propose |
| `talents` | talents | ChangeTalentsAction (`actions/ChangeTalentsAction.cpp`) | Info | yes | propose |
| `talk` | gossip hello + talk to quest giver | GossipHelloAction (`actions/GossipHelloAction.cpp`) | NPC | yes | in menu (NPC) |
| `tank attack` | tank attack chat shortcut | TankAttackChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | propose |
| `taxi` | taxi | TaxiAction (`actions/TaxiAction.cpp`) | Reise | yes | propose |
| `teleport` | teleport | TeleportAction (`actions/TeleportAction.cpp`) | Reise | yes | hidden |
| `train` | train | TrainCommandAction (`actions/TrainerAction.cpp`) | Berufe | yes | in menu |
| `trainer` | trainer | TrainerAction (`actions/TrainerAction.cpp`) | Berufe | yes | in menu |
| `u` | use | UseAction (`actions/UseItemAction.cpp`) | Inventar | yes | propose |
| `ue` | unequip | UnequipAction (`actions/UnequipAction.cpp`) | Inventar | yes | hidden |
| `use` | – | – | Inventar | yes | hidden (=u) |
| `wait for attack time` | wait for attack time | SetWaitForAttackTimeAction (`actions/ValueActions.cpp`) | Kampf | yes | hidden |
| `wander` | wander chat shortcut | WanderChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | propose |
| `warning` | runaway chat shortcut | GoawayChatShortcutAction (`actions/ChatShortcutActions.cpp`) | Kampf | yes | hidden |
| `where` | where | GoAction (`actions/GoAction.cpp`) | Info | yes | propose |
| `who` | who | WhoAction (`actions/WhoAction.cpp`) | Info | yes | hidden |
| `wts` | wts | WtsAction (`actions/WtsAction.cpp`) | Handel | yes | hidden |


_Generated from `ChatTriggerContext.h` (139 triggers), `ChatCommandHandlerStrategy.cpp` and `ChatActionContext.h`/`ActionContext.h`; help texts (syntax) from `sql/world/ai_playerbot_texts.sql`. Regenerate for a new core pin._
