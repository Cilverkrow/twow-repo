# Funserver test profile

This optional, versioned profile is selected only with
`CONFIG_PROFILE=funserver-test`. It is a configuration input for a future
authorized image or runtime test, not a deployment action.

It applies the separately approved XP, talent, item-quality, and
`Rate.Drop.Money = 3` test rates, and extends the existing random-bot cheat
set from `repair,breath,item`
to `repair,breath,item,taxi`. It neither adds a taxi mechanic nor changes bot
roster, bags, database state, loot tables, deployment scripts, or the default
profile. `Rate.XP.Explore` is deliberately absent, so its canonical value is
preserved.

The item multipliers affect existing eligible chance rolls only. They do not
create additional independent boss or rare selections, guarantee four useful
items, promise an epic-to-blue ratio, or alter duplicate suppression.
`Rate.Drop.Item.Referenced = 1` applies to referenced loot tables and is not a
quest-item control. Those Core loot semantics remain in issue #288.

No recipe-drop key is rendered. The optional recipe-rate contract is
`BLOCKED_BY_CORE_CONTRACT` until WS-10 lands and documents its exact Core key;
only then may this profile set that key to `0.65`.

Boss and rare bonus loot is enabled only in this profile. Eligible rares and
registered dungeon, raid, and world bosses receive four total safe selection
rounds with a 0.25 duplicate-weight decay. Protected quest, key, reference,
recipe, condition, uniqueness, and ownership semantics remain in the Core.

All twenty-one deviations are classified in `semantic-profile.tsv`.
