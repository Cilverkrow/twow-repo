# Roster respec and profession change (twow-repo#366 A6)

Applies the talent path (as `specNo`) and the profession pair of an ordinal range of an
approved roster CSV to the active roster, for bots that keep their level (plan v2: 13
respecs, 75 profession changes among ordinals 1–136). Maintenance window only, world
server stopped, from a merge commit, after a cold backup.

```bash
h=$(deploy/roster/reset-l1/run-reset-l1.sh --hash-from-csv deploy/roster/expand-272/v4-272-roster-plan.csv --ordinals 1-136)
deploy/roster/respec/run-respec-roster.sh --container <db-container> \
    --csv deploy/roster/expand-272/v4-272-roster-plan.csv --ordinals 1-136 \
    --expect-guid-sha256 "$h" [--conf <runtime mangosd.conf>] --apply
```

## What it changes

- **Respec** (plan path ≠ stored `specNo`): `specNo` event := index + 1 of the path in
  `premade-spec-index.tsv` (taken from core `aiplayerbot.conf.dist.in`
  `PremadeSpecName.<class>.<index>`; checked against the live roster: 136/136), and
  `characters.at_login |= 4` (`AT_LOGIN_RESET_TALENTS`). With free talent points a roster
  bot picks talents for its `specNo` itself (`PlayerbotAI.cpp`, `ChangeTalentsAction`,
  `AutoPickTalents = full`).
- **Profession change** (plan pair ≠ stored `profession_pair`): event := new pair (1–7);
  primary profession skills outside the new pair are removed together with their spells and
  recipes (`tw_world.skill_line_ability`). Secondary professions stay.
- Level, XP, money, items, quests, reputation and every other spell stay untouched.

**Talents only, no spell reset (decision).** In 1.12 a spec is the talent tree; class spells
do not depend on it. A spell reset would also remove quest-bound class spells (Bear Form,
Defensive Stance, warlock pets) that `AutoLearnQuestSpells` only gives back on the next
level-up, and every recipe. When a full level-1 reset follows (`reset-l1`, which sets
`at_login |= 6`), spells are reset there anyway.

A talent path that is not in the index (e.g. `bear` before twow-core#308 adds 11.3) or an
unknown profession label aborts before the database is touched: add the path to
`premade-spec-index.tsv` from the core pin that ships it.

## Safety model

Eight guards before the first mutation (CHECK violation aborts): row count, GUID hash of the
range = approved value, every row is the active roster member at its ordinal, class matches,
all offline, all `RNDBOT%` accounts, `specNo` and `profession_pair` events present, plan
values in range. Eleven asserts: `specNo` and pair equal the plan, respec bots carry the
talent-reset flag, no foreign primary skill or profession spell left, and non-targets
(skills, spells, events, characters) plus the targets' level/XP/money/inventory unchanged.
Idempotent: a second run reports `RESPEC=0 PAIR_CHANGE=0`.

## Test

`test-respec-roster.sh --container <disposable-db> --csv <plan> --ordinals A-B` (refuses
containers not labelled `twow.purpose=*disposable*`): bear missing from the index, wrong
hash, unknown pair, bot online (each aborts with no change), apply (synthetic profession
state: a leaving skill and its spell are removed, a kept one stays), repeat.
