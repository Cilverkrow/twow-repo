# Roster reset to level 1 (twow-repo#334)

Resets the members of the **active roster version** (`ai_playerbot_roster_current`)
to a clean level-1 start in the starting area of their race. Everything else in
`tw_char` must stay unchanged, and the scripts prove that.

This replaces the unversioned `fresh-start-136-transaction.sql` +
`candidate-reset-v2.sql` from the 2026-09-22 maintenance (`builds\…`), which Git never
held.

## What changes for each target

| Reset | Kept |
|---|---|
| level 1, XP 0, 10 gold, position = `playercreateinfo` | name, race, class, account |
| homebind = `playercreateinfo` (race's starting area) | `specNo` and `profession_pair` events (`cv_bots`) |
| inventory + bank + mail items → canonical starter outfit | BotBrain identity/personality (`cv_brain`) |
| quests, auras, cooldowns, action bars, group membership, corpses | other `cv_bots` events (trade discounts, multipliers) |
| profession skills deleted; level-range skills clamped to 5/5 | |
| pets (+ pet spells/cooldowns), mail, reputation, forgotten skills, `ai_playerbot_db_store` | |
| spells and talents: `at_login |= 6`, the core resets them at next login | |

Level-range skills (weapons, defence, class schools) need the clamp because the core
only lowers their **max** to the level on login (`Player::_LoadSkills`,
`SKILL_RANGE_LEVEL`), never the value.

## Safety model

The character tables are **MyISAM: no rollback.** So:

1. **Guards run before the first mutation** and abort the client through a `CHECK`
   violation: target count = `--expected`, all targets exist, all offline, all on
   `RNDBOT%` accounts, start position known, `specNo` and `profession_pair` present.
2. **Post-asserts** (23) prove the result, including unchanged counts/CRCs for every
   non-target in characters, inventory, items, quests, skills, homebind, reputation,
   pets, mail and the bot store.
3. **Rollback = the cold volume backup** taken with MariaDB stopped, immediately
   before the run. No backup, no run.

## Usage

World server stopped (targets must be offline), MariaDB up:

```bash
deploy/roster/reset-l1/run-reset-l1.sh --container <db-container> --expected 136 \
    [--conf <runtime mangosd.conf>] --apply
```

`--conf` reads the CharacterDatabase credentials and passes them only through
`MYSQL_PWD`. Exit code 0 and `RESULT=PASS guards=8 asserts_pass=23` are required (the eighth guard is the target scope below).
The script is idempotent: a second run on a reset roster passes again.

## Evidence

Dry run 2026-09-25 on a disposable copy of the live database:
`Y:\backup twwow\workspace-relocation-20260902\evidence\ws-60\ob40-334-roster-reset-l1-20260925\`.

## Target scope (#366)

To reset only part of the active roster, for example the new ordinals 137–272 after an
expansion, pass an ordinal range and the SHA-256 of the approved target list:

```bash
h=$(deploy/roster/reset-l1/run-reset-l1.sh --hash-from-csv deploy/roster/expand-272/v4-272-roster-plan.csv --ordinals 137-272)
deploy/roster/reset-l1/run-reset-l1.sh --container <db-container> --expected 136 \
    --ordinals 137-272 --expect-guid-sha256 "$h" [--conf <runtime mangosd.conf>] --apply
```

The hash covers `ordinal:guid` pairs in ordinal order joined by `,`. The eighth guard,
`guard_scope_guid_sha256`, aborts before the first mutation unless the active roster's
members in that range match it exactly. Members outside the range are non-targets, so
every `non_target_*` assert covers them. Without `--ordinals` the whole roster is the
target, as in #334; `RESULT=PASS guards=8 asserts_pass=23` is required in both modes.

`test-reset-l1-scope.sh` is the disposable-DB matrix for this (argument validation,
wrong hash, player inside the scope, scoped reset with a byte-identical fingerprint
outside the scope, repeat, full scope). It refuses containers that are not labelled
`twow.purpose=*disposable*`.
