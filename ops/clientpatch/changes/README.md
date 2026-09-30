# Our client changes (deltas)

Deltas live in `changes/<Dbc>/NNNN_<description>.csv`: one directory per DBC,
with the files applied in name order. The format is described in
[the README](../README.md), section "Delta format". Only values we author go
here, never extracted tables.

Stage 2 (#357/#367) adds the first deltas:

| Delta | What |
|---|---|
| `Talent/0367_rogue_talents.csv` | the owner's rogue talent line: 16 talents in free slots, rank spells 61151-61191 |
| `Spell/0367_rogue_spells.csv` | client rows for 61141-61147 (kit), 61151-61194 (talents, helpers), 61201-61208 (poison ranks), 61209-61220 (recipes, trainer spells); **generated**, see below |
| `SpellItemEnchantment/0367_agitating_poison_ranks.csv` | enchantments 3060-3063 for poison ranks I-IV |
| `SkillLineAbility/0367_rogue_trainer_and_recipes.csv` | spellbook rows for Spit and Shadow Dance (Combat), trade skill rows for the poison recipes I-IV (Poisons); every value from `sql:skill_line_ability` |
| `Spell/0455_alterac_item_spells.csv` | client rows for the six Alterac item spells 61002-61007 (#455), so the items show their "Use:" and "Chance on hit:" lines; **generated** |

**Spell rows for server spells are generated**, never written by hand:
`tools/gen_spell_mirror.py` turns a list `id,copy_from,class_mask,note`
(`tools/inputs/*.csv`) into a delta that takes every mapped column from
`sql:spell_template.<column>`, texts and icon included. The server stays the
only place where a number or a tooltip text is written. A test fails when a
committed generated delta no longer matches its input list.

**Spell IDs must fit into 16 bits** (#455). The 1.12 protocol sends spell IDs
as uint16 in `SMSG_INITIAL_SPELLS`, `SMSG_SUPERCEDED_SPELL` and
`SMSG_REMOVED_SPELL`, so a spell above 65535 reaches the client as `id - 65536`
after a relog. The build stops on any added Spell row, Talent rank,
SkillLineAbility spell or spell-type enchantment argument above 65535. Our own
spells use the free block 61002-65535 behind the Turtle spells; train 8b moved
the former 90001-90219 there (`tools/renumber_ids.py` with
`tools/inputs/455-spell-renumber-8b.csv`, new = old - 28999) and the
enchantments 90141-90144 to 3060-3063 (`455-enchant-renumber-8b.csv`).
