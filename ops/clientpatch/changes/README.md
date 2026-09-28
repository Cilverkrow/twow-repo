# Our client changes (deltas)

Deltas live in `changes/<Dbc>/NNNN_<description>.csv`: one directory per DBC,
with the files applied in name order. The format is described in
[the README](../README.md), section "Delta format". Only values we author go
here, never extracted tables.

Stage 2 (#357/#367) adds the first deltas:

| Delta | What |
|---|---|
| `Talent/0367_rogue_talents.csv` | the owner's rogue talent line: 16 talents in free slots, rank spells 90150-90190 |
| `Spell/0367_rogue_spells.csv` | client rows for 90140-90146 (kit), 90150-90193 (talents, helpers), 90200-90207 (poison ranks), 90208-90219 (recipes, trainer spells); **generated**, see below |
| `SpellItemEnchantment/0367_agitating_poison_ranks.csv` | enchantments 90141-90144 for poison ranks I-IV |
| `SkillLineAbility/0367_rogue_trainer_and_recipes.csv` | spellbook rows for Spit and Shadow Dance (Combat), trade skill rows for the poison recipes I-IV (Poisons); every value from `sql:skill_line_ability` |

**Spell rows for server spells are generated**, never written by hand:
`tools/gen_spell_mirror.py` turns a list `id,copy_from,class_mask,note`
(`tools/inputs/*.csv`) into a delta that takes every mapped column from
`sql:spell_template.<column>`, texts and icon included. The server stays the
only place where a number or a tooltip text is written. A test fails when a
committed generated delta no longer matches its input list.
