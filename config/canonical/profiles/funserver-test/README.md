# Funserver test profile

This optional, versioned profile is selected only with
`CONFIG_PROFILE=funserver-test`. It is a configuration input for a future
authorized image or runtime test, not a deployment action.

It applies the separately approved XP, talent, item-quality, and
`Rate.Drop.Money = 3` test rates, and extends the existing random-bot cheat
set from `repair,breath,item`
to `repair,breath,item,taxi`. It neither adds a taxi mechanic nor changes bot
roster, bags, database state, loot tables, deployment scripts, or the default
profile. XP is 1/1/1 (`Rate.XP.Kill`, `Rate.XP.Quest`, `Rate.XP.Explore`) for
the test phase, by owner decision on 2026-09-24 (#321).

The item multipliers affect existing eligible chance rolls only. They do not
create additional independent boss or rare selections, guarantee four useful
items, promise an epic-to-blue ratio, or alter duplicate suppression.
`Rate.Drop.Item.Referenced = 1` applies to referenced loot tables and is not a
quest-item control. Those Core loot semantics remain in issue #288.

No recipe-drop key is rendered. The optional recipe-rate contract is
`BLOCKED_BY_CORE_CONTRACT` until WS-10 lands and documents its exact Core key;
only then may this profile set that key to `0.65`.

Boss and rare bonus loot is enabled only in this profile. Eligible rares and
registered dungeon, raid, and world bosses get their safe selection rounds with
`SelectionMultiplier = 8` (owner decision 2026-09-24, #321; the mechanism is
reworked in #323) and a 0.25 duplicate-weight decay. Protected quest, key, reference,
recipe, condition, uniqueness, and ownership semantics remain in the Core.

Persistent roster profession training (#306) is enabled only in this profile:
free for roster bots, from level 1, trainers within 120 yards, with a
throttled trace (300 s). Core trainer rank and level rules still apply.

Audited open-world rares (#298) respawn faster and spawn outside their pools
only in this profile. Both switches need the `creature_rare_respawn_registry`
migration; with an empty registry they change nothing.

The operating switches that used to be hand-edited into the live runtime
config after rendering are rendered from here since #321: persistent roster,
quest-first progression and its travel trace, `RandomBotGroupNearby = 0`, and
the `BotBrain.*` keys in `mangosd.conf` (mod-bot-brain reads them through
`sConfig`, not from `mod_bot_brain.conf`). No hand edits after rendering.

Release train 2 pins the new bot-death keys at their core defaults (quest
turn-in death-route cap, graveyard bound, bounded master wait) and switches the
equip-decision trace (#308) on for a 24-hour diagnostics window.

Release train 3 switches the bots' auction-house use off
(`AiPlayerbot.AuctionHouse.Enabled = 0`, owner decision 2026-09-25): items are
no longer kept for the auction house, and there are no AH trips or bids. Vendor
buying and selling are unchanged.

Release train 4 pins three quest-routing keys at their core defaults: no
cross-continent quest routes below level 10, quest areas at most five levels
above the bot, and progress-aware quest objectives (0 restores the old time
budget). It also pins the per-destination death rule (a travel target where a
bot died twice is avoided for an hour). Bonus loot is extended to the
reviewed boss reward chests (`Funserver.Loot.Bonus.BossChest = 1`, owner
decision 2026-09-26, #345).

Release train 5 switches on the shared danger map for travel targets,
profession use (gathering within 40 yards, crafting), role- and
profession-aware group rolls, leaving zones clearly above the bot's level and
the follow diagnostics, each with its trace where there is one. The
roster-control keys for player commands are pinned at their code defaults.
Bots also learn their class trainer spells automatically
(`AiPlayerbot.AutoLearnTrainerSpells = 1`, owner decision 2026-09-26, #356).

All seventy-nine deviations are classified in `semantic-profile.tsv`.
