# Proposed Forward Migration Plan — Do Not Apply

This document is an implementation plan only. No migration, configuration change, source change, DBC change, client patch, skill grant, item grant, or login was performed by `DB-PROFESSION-RIDING-DISCOVERY-01`.

## Preconditions

1. Obtain an explicit operator choice between advanced-riding variant A (level 30) and variant B (level 20).
2. Decide whether early riding must include usable mount items. The existing generic riding items require level 40 or 60; trainer changes alone do not make them usable at levels 5, 20, or 30.
3. Decide which non-deprecated, non-test mount items are in scope. Do not update all mount-aura items as a class.
4. Decide whether mount purchase prices remain unchanged. This plan assumes they remain unchanged unless separately approved.
5. Review and build the required core/Playerbot changes before changing `MaxPrimaryTradeSkill` from 2 to 6.
6. Take verified physical and logical backups using the established database runbook. Stop Worldserver and Realmd and use a controlled, owned MariaDB process.
7. Revalidate the exact current rows and abort on drift.

## Change set 1: player limit 6 and RNDBOT limit 2

This is not a database migration.

- Set `MaxPrimaryTradeSkill = 6` only after the bot-specific enforcement exists.
- Keep normal-player behavior driven by the existing free-primary-profession counter.
- Add an RNDBOT-aware central acquisition guard for primary first-rank spells. It must cover trainer, quest, item, scripted spell, GM/administrative, and other runtime learning paths without interfering with loading already persisted skills.
- Keep the Playerbot factory at two selected primary skills and make its direct `SetSkill` path validate the RNDBOT cap.
- Review automatic trainer and skill-refresh paths in the Playerbot module.
- Do not delete existing skills or recipes. A cap controls future acquisition; it is not a data-cleanup mechanism.

Rollback restores the reviewed executable/source and `MaxPrimaryTradeSkill = 2`. It does not remove professions learned while the limit was 6. Any such removal would require a separate, explicitly approved data policy.

## Change set 2: riding trainer rows

Create a new forward-only world migration under the current `sql/database_updates/world/` convention. Do not edit `sql/base/tw_world_npc_trainer_template.sql` or a historical migration.

### Exact preflight

```sql
SELECT entry, spell, spellcost, reqskill, reqskillvalue, reqlevel
FROM npc_trainer_template
WHERE entry = 1 AND spell IN (33389, 33392)
ORDER BY spell;
```

The migration must require exactly:

| Key | Current row |
| --- | --- |
| `(entry=1, spell=33389)` | `spellcost=900000, reqskill=0, reqskillvalue=0, reqlevel=40` |
| `(entry=1, spell=33392)` | `spellcost=9000000, reqskill=762, reqskillvalue=0, reqlevel=60` |

### Proposed forward values

| Key | Basic target | Advanced variant A | Advanced variant B |
| --- | --- | --- | --- |
| `(1,33389)` | `spellcost=500, reqlevel=5`; keep skill fields | n/a | n/a |
| `(1,33392)` | n/a | `spellcost=10000, reqlevel=30`; keep skill fields | `spellcost=10000, reqlevel=20`; keep skill fields |

Illustrative, not approved SQL:

```sql
-- PROPOSED — DO NOT RUN
UPDATE npc_trainer_template
SET spellcost = 500, reqlevel = 5
WHERE entry = 1 AND spell = 33389
  AND spellcost = 900000 AND reqskill = 0
  AND reqskillvalue = 0 AND reqlevel = 40;

-- Choose exactly one advanced variant after operator approval.
UPDATE npc_trainer_template
SET spellcost = 10000, reqlevel = 30 -- or 20, never both
WHERE entry = 1 AND spell = 33392
  AND spellcost = 9000000 AND reqskill = 762
  AND reqskillvalue = 0 AND reqlevel = 60;
```

The runner must require one affected row per selected update, verify the exact post-state, and register the new immutable migration only after verification. A second execution must not be treated as a fresh success merely because zero rows were changed. State-aware tooling may recognize the exact already-target state, but any third state is drift and must abort.

### Rollback values

Rollback is a separately reviewed forward migration or controlled SQL action with exact target-state preconditions:

```sql
-- PROPOSED ROLLBACK — DO NOT RUN
UPDATE npc_trainer_template
SET spellcost = 900000, reqlevel = 40
WHERE entry = 1 AND spell = 33389
  AND spellcost = 500 AND reqskill = 0
  AND reqskillvalue = 0 AND reqlevel = 5;

UPDATE npc_trainer_template
SET spellcost = 9000000, reqlevel = 60
WHERE entry = 1 AND spell = 33392
  AND spellcost = 10000 AND reqskill = 762
  AND reqskillvalue = 0 AND reqlevel IN (20, 30);
```

Rollback does not remove a riding skill already learned under the lower requirement.

## Change set 3: Playerbot riding behavior

The classic (`MANGOSBOT_ZERO`) Playerbot code has independent level, skill, purchasing, and budget constants. Update and review these as one source patch:

- `PlayerbotFactory.cpp`: direct riding skill values at levels 40 and 60.
- `MountValues.cpp`: minimum riding purchase level 40.
- `BudgetValues.cpp`: basic/epic riding levels 40/60 and mount budgets 40g/1000g.
- `RandomPlayerbotMgr.cpp`: riding hotfix currently skips levels below 20.

Variant A and variant B must be propagated consistently. Basic riding at level 5 conflicts with the current hotfix floor of level 20 and therefore cannot be obtained by a database-only change.

## Change set 4: mount-item usability (operator decision required)

The current generic riding items require:

- nine items: character level 40, skill 762 rank 75;
- two items: character level 60, skill 762 rank 150.

If early riding must be usable, select explicit non-deprecated items and create a separate world migration for their `item_template.required_level`. Keep `required_skill` and `required_skill_rank` unless design explicitly changes them. Do not alter `buy_price` or vendor data without a separate price decision.

Rollback restores each selected item's exact previous level under exact target-state preconditions. It does not remove items or skills already acquired.

## Validation sequence

1. Verify hashes of the reviewed source, config, migration, executable, and database tools.
2. Verify the exact pre-state queries above and the selected mount rows.
3. Execute the reviewed migration once with separate stdout/stderr evidence.
4. Verify exactly two trainer rows, all ten trainer creatures still using template 1, and no unrelated trainer changes.
5. Verify config/core/Playerbot behavior with controlled player and RNDBOT test characters.
6. Verify trainer display, charged copper, learned skill cap (75/150), mount-item usability, and restart persistence.
7. Verify that secondary professions do not consume primary-profession points.
8. Verify that quest/item/script/GM/direct bot paths cannot exceed the RNDBOT cap.
9. Stop services controlled, record logs and hashes, and preserve the evidence package.

## Tracker note

`tw_world.migrations` contains 146 rows whose `Hash` value is `manual`; it does not cryptographically identify the SQL bytes that produced the live rows. The two riding rows match the current base SQL and were introduced into that base file by commit `e1a48b4442d4d6dc369408cbc094087377cb746f`, but no dedicated historical migration references the exact rows. A new migration must therefore carry newly recorded SHA-1/SHA-256 evidence and must not rewrite the base file to simulate provenance.
