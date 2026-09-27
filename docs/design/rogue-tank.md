# Rogue as a tank variant — analysis and design

Refs #367. Status: **design only**. This document changes no spell, DBC, SQL or
core code. Section 3 holds the owner's design of 2026-09-27; the open points
are in [section 5](#5-owner-decisions). The spell/rule part is a
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
first idea ("+30 % … +100 %") would have been a different mechanic. The owner
has since decided to keep the flat amount and grade it by level (3.1).

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
enchantment type `TOTEM` would need a core change. (The owner decided
against a Rockbiter-style imbue for the rogue, D-3; this section is kept as
background.)

## 3. Owner design (decided 2026-09-27)

The owner reviewed the first draft and decided the kit below in two rounds
on 2026-09-27. It replaces the earlier variants (percentage threat poison,
Rockbiter-style parry imbue). The owner still has to approve it as a rule
change (single approval, OB-20) before anything is implemented.

**Scope: bots only first, for release train 7.** Players come later (3.4).

The rogue tank kit has three parts: the **threat poison**, the **Spit** taunt,
and a **tank stance**. There is **no** extra Rockbiter-style weapon imbue. The
poison already takes the weapon's temporary-enchant slot.

### 3.1 Threat poison: Agitating Poison in ranks (flat threat)

The existing mechanic stays: a flat threat amount per proc, as in `45613`
(+395). What changes is that it becomes available **from level 20 in ranks
every 10 levels**, starting at +150 and reaching today's +395 at level 60.
The intermediate values are linear. The owner may round them.

The proc's Nature damage **scales in the same ratio** as the threat (owner
decision). Values are rounded from rank V's 67–85:

| Rank | Level | Threat per proc | Nature damage | Proc spell | Status |
|---|---|---|---|---|---|
| I | 20 | +150 | 25–32 | new | new |
| II | 30 | +211 | 36–45 | new | new |
| III | 40 | +273 | 46–59 | new | new |
| IV | 50 | +334 | 57–72 | new | new |
| V | 60 | +395 | 67–85 | `45613` | exists (item `65032`, trainer `47312`) |

Level 20 fits the Poisons skill, which rogues get from the level-20 class
quests (2.2).

Full change set per new rank (I–IV), cloned from rank V. This is what the
**player** version needs; the bots-only version for train 7 needs less (3.4):

- world DB:
  - proc spell (effect 2 + effect 63)
  - coating spell (effect 54, 20 % proc, 115 charges)
  - item (`required_level` = rank level)
  - recipe (skill line 40, a skill window matching the level)
  - trainer-teach spell
  - `npc_trainer` rows for all 16 rogue trainers
- **`SpellItemEnchantment.dbc`**: one new enchantment per rank. The
  enchantment decides which proc spell fires (`3006` → `45613`), just as each
  Deadly Poison rank has its own enchantment. The server reads this DBC from
  client data. For players the client needs the same entries (client patch,
  see 3.4).

A DBC-free shortcut exists but does not match the owner's stepped ranks: one
proc spell with `effectRealPointsPerLevel` scales continuously with the
caster's level (`WorldObject::CalculateSpellDamage`,
`src/game/Objects/Object.cpp`).

### 3.2 Taunt: Spit

A new rogue ability, **Spit**: the rogue spits at the enemy.

| Property | Owner decision | Implementation note |
|---|---|---|
| Effect | taunt | effect 114 (ATTACK_ME) + aura 11 (MOD_TAUNT), as in Taunt `355` |
| Range | 15 yards | new or existing range index for 15 yd |
| Targets | main target plus **two more around it** | target area around the main target, `maxAffectedTargets = 3`, main target always included |
| Emote | the rogue plays a spit emote on the target | `TEXTEMOTE_SPIT` (89) exists in `src/game/SharedDefines.h`; triggered by a spell script or an emote effect |
| Level | **12** | |
| Cost | **30 energy** | `powerType` energy, `manaCost 30` |
| Cooldown | **10 s** | `recoveryTime 10000` |

The spell itself is world-DB data. The emote and the
"main target plus two around it" selection need a small spell script
(`src/scripts/spells/spell_rogue.cpp` in twow-core already exists) if no
existing target type fits. That is core code, so it goes to a twow-core PR.

### 3.3 Tank stance: Shadow Dance (Schattentanz)

A stance or toggle buff that makes the rogue alternate between dodge and
parry. It also makes each avoided hit generate threat.

| Trigger | Effect |
|---|---|
| the rogue **parries** | +5 % dodge for 3 s |
| the rogue **dodges** | +5 % parry for 3 s |
| every dodge **and** every parry | a fixed amount of threat on the attacker, rising with rank |

Ranks (owner decision): learned at **level 20**, threat raised at **level 40**
and again at **level 60**.

| Rank | Level | Threat per dodge/parry |
|---|---|---|
| I | 20 | open (proposal: 50) |
| II | 40 | open (proposal: 90) |
| III | 60 | open (proposal: 130) |

Each rank is a new set of three spells (stance aura, parry proc, dodge proc).
The +5 % buffs themselves stay the same for all ranks.

Implementation (data only, no core code):

- The stance is a self-aura. A rogue has no stance bar (stealth is its only
  form), so a toggle buff like Righteous Fury is the simpler form. A real
  shapeshift form is possible but costs a form ID and client work.
- Two passive proc auras (aura 42, PROC_TRIGGER_SPELL), with rows in
  `spell_proc_event`:
  - `procEx` = `PROC_EX_PARRY` (0x20) triggers the "+5 % dodge, 3 s" buff plus
    the threat effect on the attacker;
  - `procEx` = `PROC_EX_DODGE` (0x10) triggers the "+5 % parry, 3 s" buff plus
    the threat effect.

  `spell_proc_event` already supports both flags in this core (for example
  entry `23547`, `procEx 32`). Two auras are needed because a spell has only
  one `spell_proc_event` row.
- The buffs refresh rather than stack.

The name stays **Shadow Dance** (Schattentanz), by owner decision, although
a rogue ability in later expansions has the same name. Only the threat values
per rank are still open (O-4a).

### 3.4 Bots only (release train 7), players later

For train 7 the kit is **bots only**. Players cannot learn, buy or see any of
it. That changes the change set:

- **No `npc_trainer` rows, recipes or vendor rows.** A trainer row would teach
  Spit and Shadow Dance to players too. Bots learn the spells directly
  instead, the way `PlayerbotFactory::InitAvailableSpells` already grants
  Bear Form and other spells that are on no trainer (`bot->learnSpell(...)`).
  The grant is by level, for rogues on the tank path (4.1):
  - Spit at 12
  - Shadow Dance I/II/III at 20/40/60 (a higher rank replaces the lower one)
- **Poison items without recipes.** Bots get the poison items from
  `PlayerbotFactory` (`StoreItem`, 4.3). The items exist in `item_template`,
  but no vendor, trainer or loot table hands them out, so players never get
  them.
- **No client patch.** Bots do not need tooltips or icons.
- **Server-side enchantments (O-9).** The server reads
  `SpellItemEnchantment.dbc` from client data, not from SQL, so new
  enchantments for poison ranks I–IV would still need a server-side DBC edit
  (outside Git). Two ways to avoid that for train 7:
  - **(a, recommended)** Ranks I–IV use the existing enchantment `3006`, so
    every coating fires `45613`. A small spell script on `45613` in twow-core
    (`src/scripts/spells/spell_rogue.cpp`) sets threat and Nature damage from
    the table in 3.1 by the caster's level band (20–29 → rank I, …, 60 →
    rank V). For bots this is the same thing, because they always use the
    highest poison their level allows.
  - **(b)** Server-side DBC entries for ranks I–IV, as described in 3.1.
    That needs client-data handling outside Git, and the same entries again
    later for the player client.

**Later, for players:** trainer rows and recipes, a vendor or recipe source
for the poisons, and a client patch (`Spell.dbc`, `SpellItemEnchantment.dbc`,
icons, tooltips). With option (a), players would also need proper per-rank
enchantments (option b); otherwise a level-60 player would get rank V from a
rank I poison.

### 3.5 Talents

The tank rogue gets **no new talent tree**. The owner will supply a template
that extends the existing rogue trees. The premade path (4.1) is built from
that template once it arrives. Until then no talent links are written.

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
  `aiplayerbot.conf.dist.in`. There is no new talent tree (3.5): the links
  come from the owner's template that extends the existing trees, and they
  are generated and validated with `tools/build_premade_specs.py` against
  Turtle's `Talent.dbc`.
- `IsRogueTankSpec(player)` next to `IsBearSpec` in `AiFactory.cpp`, reading
  `specNo` the same way.
- Decision order as for the feral druid: forced role
  (`facade->GetForcedRole()` has `BOT_ROLE_TANK`) wins, then the premade path.
- `GetPlayerRoles(const Player*)` returns `BOT_ROLE_TANK` for a rogue on path
  `tank`; `IsTank` then works unchanged via `STRATEGY_TYPE_TANK`.
- Below the Spit level the tank path plays as `combat` DPS (like the druid
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
| MOVE+4 | `lose aggro` | `spit` (hits up to three targets, so also for adds around the main target) |
| MOVE | `taunt on snare target` | `spit` |
| HIGH+5 | `medium health` + combo points ≥ 3 | `flourish` (+20 % parry, level 42+) |
| HIGH+4 | `riposte` (after parry) | `riposte` |
| HIGH+3 | `ghostly strike` available | `ghostly strike` |
| HIGH+2 | `enemy is casting` | `kick` |
| HIGH+1 | 5 combo points | `expose armor` or `slice and dice` (by group setting) |
| NORMAL | default | `sinister strike` |

Never: `feint` (lowers own threat), `blind`/`sap` on the tanked target.
The tank strategy must also stop `ApplyPoisonAction` from putting a DPS poison
on the main hand (see 4.3).

Tank stance (3.3): a non-combat and combat buff trigger `tank stance` keeps
the self-aura up (like `righteous fury` for the paladin). The two short
dodge/parry buffs are procs and need no bot logic.

### 4.3 Poison upkeep

`ApplyPoisonAction` (`strategy/rogue/RogueActions.h`) picks the highest
usable item from a fixed ID list per poison type. Proposed:

- New `ApplyThreatPoisonAction` with the item IDs of ranks I–IV (new) and V
  (`65032`), `apply threat poison`, **main hand**. The off hand also gets
  the threat poison: with a flat amount per proc, more procs mean more
  threat, and the off hand swings faster.
- A `tank rogue poisons` strategy (analogous to
  `CombatRoguePoisonsPveStrategy`) replacing the DPS poison triggers when the
  rogue is on the tank path.
- Supply: bots get poisons from `PlayerbotFactory` (`StoreItem(CONSUM_ID_*)`
  by level, `PlayerbotFactory.cpp` around line 512). Add the new item IDs to
  `CONSUM_ID_*` and hand them out by level for tank-path rogues.

### 4.4 Stat priorities

The issue points to "#141" for the stat row; in `twow-repo` #141 is a closed
PR about an MSVC rename, so the intended reference is presumably #308
(roles/stats). Proposed row:

| Role | Priority |
|---|---|
| rogue tank | Stamina > Agility (dodge, armor, AP) > Defense > Parry/Dodge > Hit > Armor > Strength/AP |

Weapons: fast weapons in both hands, because every hit is a chance for a
flat-threat poison proc. The weapon types follow the owner's talent template. Defense and parry/dodge as item stats need a check against Turtle's
item data before they go into the table.

### 4.5 Tests

Like #357: policy/source contract tests in
`modules/mod-playerbots/t/` (role mapping for path 4.3 with and without
forced role; `tank rogue` never adds `behind`/`stealth`/`dps assist`;
`feint` never in the tank action list; the threat poison is picked by rank
level), and a runtime acceptance in 5-man
test groups: the rogue tank holds threat, no regression for rogue DPS paths
4.0–4.2.

## 5. Owner decisions

Decided by the owner on 2026-09-27 (still subject to the formal rule-change
approval, OB-20):

| # | Decision |
|---|---|
| D-1 | Threat poison: keep the flat-threat mechanic of Agitating Poison, in ranks from level 20 (+150) to level 60 (+395), one rank every 10 levels (3.1). |
| D-2 | Taunt: **Spit**, level 12, 30 energy, 10 s cooldown, 15 yd range, main target plus two targets around it, plays a spit emote on the target (3.2). |
| D-3 | No Rockbiter-style weapon imbue for the rogue; the poison covers that slot. |
| D-4 | Tank stance **Shadow Dance** (the name stays): parry → +5 % dodge for 3 s, dodge → +5 % parry for 3 s, fixed threat per dodge and parry; learned at 20, threat raised at 40 and 60 (3.3). |
| D-5 | No new talent tree. The owner provides a template that extends the existing trees; the bot's tank path is built from it (3.5, 4.1). |
| D-6 | Bots only first, for release train 7; players later (3.4). |
| D-7 | The poison's Nature damage scales with the rank, in the same ratio as the threat (3.1). |

Still open:

| # | Decision | Recommendation |
|---|---|---|
| O-3b | Round the intermediate poison threat values (211/273/334)? | owner's choice |
| O-4a | Shadow Dance threat per dodge/parry for ranks I/II/III | 50 / 90 / 130 |
| O-6 | Mitigation beyond Shadow Dance | none at first; measure in 5-man runs |
| O-7 | Stat reference: #141 as written in the issue, or #308 | confirm **#308** |
| O-8 | How many rogues get path 4.3 (#366: 22 new rogues in 137–272) | decide together with D-A in #366 |
| O-9 | Poison ranks for bots: spell script on `45613` with level bands, or server-side DBC entries (3.4) | **spell script** (no client-data work for train 7) |

## 6. What this document does not do

No spell, item, trainer, DBC or core change; no config change; no build
(`BUILD_REQUIRED=NO`, docs only). For train 7, implementation needs the
rule-change approval, O-4a, O-9 and the owner's talent template. It then goes
as separate PRs in `Cilverkrow/twow-core`:
- world data: spells and poison items, no trainer or vendor rows (OB-20);
- spell scripts for Spit and, with O-9 (a), for the poison proc (core);
- mod-playerbots: spell grants, tank path, strategy and poison upkeep (OB-10).

The pin bump comes here.
