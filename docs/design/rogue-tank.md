# Rogue as a tank variant — analysis and design

Refs #367. Status: **design only**. This document changes no spell, DBC, SQL or
core code. Every change it describes is a proposal that needs the owner
decisions in [section 5](#5-owner-decisions) first; the spell/rule part is a
rule and balance change (single owner approval, OB-20), the bot part belongs to
OB-10.

Related: #357 (enhancement shaman tank, same pattern), #308 (premade paths,
bear 11.3), #366 (tank share of the roster).

## 1. Evidence base

All numbers below were read, not recalled. Source: the world data shipped in
`Cilverkrow/twow-core` at `main` = `e50b648`, i.e. `sql/base/tw_world_*.sql`
plus `sql/database_updates/**` applied in order to a throwaway MariaDB 10.11
(local, discarded afterwards). Tables used: `spell_template`, `npc_trainer`,
`skill_line_ability`, `item_template`, `quest_template`. Code references are
to the same commit.

Not available in Git, therefore **not verified here**: `Talent.dbc`,
`TalentTab.dbc` and `SpellItemEnchantment.dbc` (client data, see
`docs/EXTERNAL-REQUIREMENTS.md`). The talent-tree statements and the
enchantment IDs' contents in this document are marked accordingly.

## 2. What Turtle 1.18 has today

### 2.1 The threat poison: Agitating Poison

Turtle has exactly one rogue poison that generates threat. The owner's memory
("only at level 60") is correct.

| What | ID | Data |
|---|---|---|
| Trainer entry | spell `47312` | taught by every rogue trainer (16 entries in `npc_trainer`, e.g. `918`), `reqlevel 60`, cost 41400 copper |
| Recipe | spell `45611` | effect 24 (create item `65032`); skill line 40 *Poisons*, skill window 290–310 |
| Item | item `65032` *Agitating Poison* | `required_level 60`, rogue only, stack 20, vendor price 1200 |
| Weapon coating | spell `45612` | effect 54 (temporary enchant), enchantment ID `3006`, 30 min, 115 charges, `procChance 20` |
| Proc | spell `45613` | effect 2: 67–85 Nature damage; **effect 63 (THREAT): +395 flat threat** |

Important for the design: Agitating Poison adds a **flat** amount of threat per
proc (395 at a 20 % proc chance per hit), not a percentage. The owner's
"+30 % … +100 %" is therefore not a new rank of the existing mechanic but a
different mechanic (see 3.2).

### 2.2 Poison access by level

Rogues get the *Poisons* skill (spell `2842`, via `2995`) from the level-20
class quests `2359` (Klaven's Tower, Alliance) and `2480` (Hinott's
Assistance, Horde). The poison recipes train at 20 (Instant, Crippling),
24 (Mind-numbing), 30/38/46/54 (Deadly), 32 (Wound), 52/60 (Dissolvent),
56 (Corrosive), 60 (Agitating).

Applying a poison *item* checks only `required_level`, not the skill
(`required_skill_rank = 0` on e.g. `6947`, `2892`, `65032`). A poison item
below level 20 is therefore technically usable; only *crafting* it needs the
skill.

### 2.3 Taunt

**There is no rogue taunt in Turtle 1.18.** No family-8 spell uses effect 114
(ATTACK_ME) or aura 11 (MOD_TAUNT). The existing taunts that could serve as a
template, all `spellLevel 10`, effect 114 + aura 11:

| Spell | ID | Class |
|---|---|---|
| Taunt | `355` | warrior |
| Growl | `6795` | druid |
| Hand of Reckoning | `45806` | paladin (Turtle) |
| Earthshaker Slam | `51365` | shaman (Turtle) |

Every rogue threat-related spell today *reduces* threat: Feint `1966/6768/8637/11303/25302`
(-150 … -800), Improved Feint `23558`, Sleight of Hand `30892/30893`,
Reduced Threat `28811`.

### 2.4 Tank-relevant rogue tools that already exist

| Spell | ID | Level / source | Use for a tank |
|---|---|---|---|
| Parry (passive) | `3127` | trainer, level 8 | parry at all |
| Evasion | `5277` | trainer, level 8 | +50 % dodge for a short duration (emergency cooldown) |
| Ghostly Strike | `14278` | trainer, level 20 (talent-gated) | +dodge for a short time, 20 s cooldown |
| Riposte | `14251` | talent | after a parry, damage + disarm |
| Flourish (Turtle) | `45604` | trainer, level 42 | finisher, **+20 % parry**, 8–16 s, 40 s cooldown |
| Surprise Attack (Turtle) | `45603` | trainer, level 22 | usable after the target dodges |
| Kick / Gouge / Kidney Shot | various | trainer | interrupts and control |

Which Turtle talents (Deflection, Lightning Reflexes, etc.) exist in which
tree and row is **not verifiable** without `Talent.dbc` (see 1).

### 2.5 Threat modifiers of the existing tanks (for calibration)

All as aura 10 (MOD_THREAT) in `spell_template`, value = `effectBasePoints + 1`:

| Source | ID | Threat |
|---|---|---|
| Defensive Stance | `7376` | +30 % (all schools) |
| Defiance 1–5 (warrior talent) | `12303/12788/12789/12791/12792` | +4/8/12/15/20 % |
| Righteous Fury | `25780` | +60 % (holy only) |
| Rockbiter Weapon (passive), every rank | `10400` … `16312` | **+35 %** (all schools) while the imbued weapon is equipped |

A protection warrior thus plays at about 1.3 × 1.2 ≈ **1.56×**. A rogue has
no multiplier today (1.0×).

### 2.6 The Rockbiter pattern

Turtle's shaman tank already solves the "a weapon coating that raises
threat by a percentage" problem: Rockbiter Weapon (`8017` … `16316`) is a
temporary weapon enchant whose enchantment casts a passive aura
(`10400` etc.) containing MOD_THREAT +35 %. In the core this is handled in
`src/game/Objects/Player.cpp` (`ApplyEnchantment`):

- `ITEM_ENCHANTMENT_TYPE_EQUIP_SPELL` (line ~13985) casts the enchantment's
  spell on equip and removes it on unequip — **for every class**.
- `ITEM_ENCHANTMENT_TYPE_TOTEM` (line ~14042, "Shaman Rockbiter Weapon") does
  the same **only for `CLASS_SHAMAN`**.

A rogue poison that grants a percentage threat aura is therefore a data change
only if its enchantment uses type `EQUIP_SPELL`. Reusing the Rockbiter
enchantment type `TOTEM` would need a core change.

## 3. What would have to change for the owner's idea

The owner's idea (examples, not a spec): a taunt at level 10–15; the threat
poison earlier and in ranks, roughly +30 % → 50/70/90 % → +100 % at level 60.

### 3.1 Taunt (level 10–15)

New rogue spell cloned from Taunt `355` (effect 114 + aura 11, 10 s cooldown,
melee range), `spellFamilyName 8`, energy cost instead of rage. Trainer rows
in `npc_trainer` for all 16 rogue trainers at the chosen level.

Suggested level: **12** (with Kick; after the other taunts at 10, before the
first dungeons at 13–18).

### 3.2 Graded threat poison

Two technically clean variants:

**Variant A — ranks of the existing flat-threat mechanic.**
New Agitating Poison ranks cloned from `45611/45612/45613`, each with its own
proc spell (threat and damage scaled by level), coating spell, item, recipe
and trainer row. Every rank needs its **own `SpellItemEnchantment.dbc` entry**,
because the enchantment decides which proc spell fires (`3006` → `45613`).
Pro: keeps Turtle's mechanic. Con: DBC work for every rank, and flat threat
does not produce the "+X %" the owner described; scaling is guesswork per
level.

**Variant B — percentage threat like Rockbiter (recommended).**
Each rank is a weapon coating whose enchantment (type `EQUIP_SPELL`) casts a
passive aura with MOD_THREAT +N %, exactly like Rockbiter's `10400`. The
existing `45613` proc can stay as the level-60 rank or be retired.
Pro: gives the owner's "+30 % … +100 %" literally, scales with the rogue's
damage automatically, reuses a pattern Turtle already ships and the core
already handles for all classes. Con: still one new enchantment entry per
rank (DBC), plus aura spells.

Rank ladder for variant B (the owner's numbers, levels at 12-level spacing,
first rank without the Poisons skill because item use is not skill-gated,
see 2.2):

| Rank | Level | Threat | Obtained |
|---|---|---|---|
| I | 12 | +30 % | vendor (poison supplier) or trainer book, no craft |
| II | 24 | +50 % | recipe, Poisons skill |
| III | 36 | +70 % | recipe |
| IV | 48 | +90 % | recipe |
| V | 60 | +100 % | recipe (replaces or accompanies `45611`) |

Per rank, the change set would be: 1 aura spell (MOD_THREAT), 1 coating spell
(effect 54), 1 item, 1 recipe + 1 trainer-teach spell, `npc_trainer` rows,
1 `SpellItemEnchantment` entry. All spell/item/trainer rows are world-DB data
(`spell_template` etc. are loaded from SQL in this core); the enchantment is
DBC.

**Balance note:** +100 % on a rogue (2.0×) is well above a protection
warrior (≈ 1.56×, 2.5) and Rockbiter (1.35×), and it multiplies rogue damage,
which is higher than tank damage. See decision O-3.

### 3.3 Players versus bots only

Server-side only (world DB) is enough for bots: they never read tooltips.
For **players**, new spells and the new enchantments need a **client patch**
(`Spell.dbc`, `SpellItemEnchantment.dbc`, icons/tooltips); otherwise players
see unknown spells. A bots-only variant can even skip the poison items and
grant the MOD_THREAT aura directly by level. See decision O-2.

## 4. Bot design (mod-playerbots)

Code lives in `Cilverkrow/twow-core`, `modules/mod-playerbots/src/playerbot/`.
Nothing here is implemented; this is the plan for a later PR there.

### 4.1 Role mapping (AiFactory)

Today `AiFactory::GetPlayerRoles(cls, tab)` returns `BOT_ROLE_DPS` for every
rogue tree, and `AddDefaultCombatStrategies` picks
`assassination`/`combat`/`subtlety` by tree only.

A rogue tank cannot be told apart by tree (it would be a Combat build), so it
follows the **bear 11.3 pattern** from #308:

- New premade path `AiPlayerbot.PremadeSpecName.4.3 = tank` in
  `aiplayerbot.conf.dist.in`, links generated and validated with
  `tools/build_premade_specs.py` against Turtle's `Talent.dbc` (parry,
  dodge and Riposte talents; exact picks need the DBC).
- `IsRogueTankSpec(player)` next to `IsBearSpec` in `AiFactory.cpp`, reading
  `specNo` the same way.
- Decision order as for the feral druid: forced role
  (`facade->GetForcedRole()` has `BOT_ROLE_TANK`) wins, then the premade path.
- `GetPlayerRoles(const Player*)` returns `BOT_ROLE_TANK` for a rogue on path
  `tank`; `IsTank` then works unchanged via `STRATEGY_TYPE_TANK`.
- Below the taunt level the tank path plays as `combat` DPS (like the druid
  below level 10).

Combat engine for a rogue tank:
`"tank rogue", "tank assist", "pull", "pull back", "close", "poisons", "buff", "boost"`
— without `behind` and `stealth` (a tank must face the target and not open
from stealth), and without `dps assist`.

### 4.2 `tank rogue` strategy

New `TankRogueStrategy` (`strategy/rogue/TankRogueStrategy.{h,cpp}`),
`GetType()` = `STRATEGY_TYPE_TANK | STRATEGY_TYPE_MELEE`, registered as
`"tank rogue"` in `RogueAiObjectContext.cpp`, composed with the PvE/raid
mixins via `SPEC_COMPOSE_4` like the other specs. Triggers, by priority:

| Priority | Trigger | Action |
|---|---|---|
| EMERGENCY | `critical health` | `evasion`, then `vanish` only if the group is wiping (not as a normal cooldown: it drops aggro) |
| EMERGENCY | `has blessing of salvation` | remove it (as for the protection warrior) |
| MOVE+4 | `lose aggro` | `rogue taunt` (the new spell) |
| MOVE | `taunt on snare target` | `rogue taunt` |
| HIGH+5 | `medium health` + combo points ≥ 3 | `flourish` (+20 % parry, level 42+) |
| HIGH+4 | `riposte` (after parry) | `riposte` |
| HIGH+3 | `ghostly strike` available | `ghostly strike` |
| HIGH+2 | `enemy is casting` | `kick` |
| HIGH+1 | 5 combo points | `expose armor` or `slice and dice` (by group setting) |
| NORMAL | default | `sinister strike` |

Never: `feint` (lowers own threat), `blind`/`sap` on the tanked target.
The tank strategy must also stop `ApplyPoisonAction` from putting a DPS poison
on the main hand (see 4.3).

### 4.3 Poison upkeep

`ApplyPoisonAction` (`strategy/rogue/RogueActions.h`) picks the highest
usable item from a fixed ID list per poison type. Proposed:

- New `ApplyThreatPoisonAction` with the IDs of the new ranks (and `65032`),
  `apply threat poison`, **main hand**; off hand keeps Instant/Deadly for
  damage (which also produces threat under a percentage modifier).
- A `tank rogue poisons` strategy (analogous to
  `CombatRoguePoisonsPveStrategy`) replacing the DPS poison triggers when the
  rogue is on the tank path.
- Supply: bots get poisons from `PlayerbotFactory` (`StoreItem(CONSUM_ID_*)`
  by level, `PlayerbotFactory.cpp` around line 512). Add the new item IDs to
  `CONSUM_ID_*` and hand them out by level for tank-path rogues. In variant
  "bots only, aura granted directly" (3.3) this whole point disappears.

### 4.4 Stat priorities

The issue points to "#141" for the stat row; in `twow-repo` #141 is a closed
PR about an MSVC rename, so the intended reference is presumably #308
(roles/stats). Proposed row:

| Role | Priority |
|---|---|
| rogue tank | Stamina > Agility (dodge, armor, AP) > Defense > Parry/Dodge > Hit > Armor > Strength/AP |

Weapons: slow main hand (threat per hit with a percentage modifier, Riposte
damage), fast off hand for poison procs; swords/daggers per the tank talent
path. Defense and parry/dodge as item stats need a check against Turtle's
item data before they go into the table.

### 4.5 Tests

Like #357: policy/source contract tests in
`modules/mod-playerbots/t/` (role mapping for path 4.3 with and without
forced role; `tank rogue` never adds `behind`/`stealth`/`dps assist`;
`feint` never in the tank action list), and a runtime acceptance in 5-man
test groups: the rogue tank holds threat, no regression for rogue DPS paths
4.0–4.2.

## 5. Owner decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| O-1 | Do it at all, and when | backlog (p3) / after the shaman tank #357 / now | **after #357**: same pattern (tank path, taunt, threat enchant), do the one with existing Turtle talents first |
| O-2 | Scope | bots only (server data) / bots and players (client patch) | **bots only first**: no client patch, no effect on players' game; players later if it proves itself |
| O-3 | Threat ladder | owner ladder +30/50/70/90/100 % / capped at the warrior level (≈ +30 … +55 %) | **capped**, start with +30 % and raise after measurement; 2.0× is above every existing tank |
| O-4 | Mechanic | variant A (flat-threat ranks of Agitating Poison) / variant B (percentage aura, Rockbiter pattern) / bots only: aura without a poison item | **B**, or for O-2 = bots only the aura without an item (no DBC work at all) |
| O-5 | Taunt level | 10 / 12 / 15 | **12** |
| O-6 | Mitigation | threat only / also a defensive lever (e.g. armor or Flourish earlier) | **threat only** at first; measure survival in 5-man runs before touching mitigation |
| O-7 | Stat reference | #141 as written / #308 | confirm **#308** |
| O-8 | Roster share | how many rogues get path 4.3 (relevant to #366, 22 new rogues in 137–272) | decide together with D-A in #366 |

## 6. What this document does not do

No spell, item, trainer, DBC or core change; no config change; no build
(`BUILD_REQUIRED=NO`, docs only). Implementation needs O-1…O-5 first and then
separate PRs: world data (OB-20) and mod-playerbots (OB-10) in
`Cilverkrow/twow-core`, pin bump here.
