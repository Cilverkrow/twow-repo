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

## Train 9 (#484)

Patch 8 carries the owner's train-9 talent list (#484 issuecomment-5972156860)
next to the riding change (#295). The server side is twow-core
20261003200000 (rogue) and 20261003200500 (shaman); every delta below takes
its values from the export of that state.

| Delta | What |
|---|---|
| `Spell/0484_talent_spells.csv` | client rows for the Riposte Flow strikes 61221/61222 (clones of Riposte 14251) and Charged Stormstrike ranks 2-4 61223-61225 (clones of rank 1 61118); **generated** from `tools/inputs/484-spells.csv` |
| `Spell/0484_backstab_front.csv` | Brazen Strike: `AttributesExB` of the nine Backstab ranks from the server, which drops 0x100000 so the client sends a frontal Backstab; the server keeps "behind the target" via `customFlags` 0x40 plus the below-60 % exception |
| `Spell/0484_rushing_winds_stacks.csv` | Elemental Weapons, Windfury part: `CumulativeAura` of Rushing Winds 52967-52969 from `stackAmount` (3/4/5) |
| `SpellItemEnchantment/0484_agitating_poison_names.csv` | names of the poison enchantments 3061-3063 ("Agitating Poison II-IV", deDE too); the buff bar showed rank I for every rank |
| `Talent/0357_shaman_talents.csv` (regenerated) | Charged Stormstrike (talent 9005) gets ranks 2-4: `tools/inputs/357-shaman-talents.csv` changed, the delta regenerated with `tools/talentdelta.py` |

These need **no delta edit**, only the new export, because the rows are
already mirrored with `sql:` values:

- 61194 Deep Wounds: name, texts, 5 stacks, own visual (`0367_rogue_spells.csv`).
- 61143-61145 Shadow Dance: PASSIVE attribute (`0367_rogue_spells.csv`).
- 61146 Shadow Dance dodge buff: spell family 0, so it no longer replaces Evasion (`0367_rogue_spells.csv`).
- 61213-61220 trainer teach spells: visual 107 and interrupt flags 0 (`0367_rogue_spells.csv`).
- 61101-61105 Attack Speed: the cloned effect 3 is gone (`0357_shaman_spells.csv`).
- 61118 Charged Stormstrike rank 1: rank text (`0357_shaman_spells.csv`).
- 61124/61126 Storm Wisdom buffs: text and icon (`0357_shaman_spells.csv`).
- 29079/29080 Elemental Weapons: rank texts (`0357_shaman_elemental_weapons.csv`).

Talent.dbc and SpellItemEnchantment.dbc are server-loaded. The server copies
from the same build go live in the same window as the core change. Until the
server Talent.dbc has the four ranks of 9005, Charged Stormstrike stays a
one-rank talent with one charge.
