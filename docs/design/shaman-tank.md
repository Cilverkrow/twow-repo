# Shaman tank: Enhancement rework, phase 1 design (bots first)

Refs #357. Status: **design only**. This document changes no spell, DBC, SQL or
core code.

**Binding template:** the owner's talent line of 2026-09-27, transcribed by OB-00
in [#357 issuecomment-5855245331](https://github.com/Cilverkrow/twow-repo/issues/357#issuecomment-5855245331).
In short:

- There is **no 4th talent tree.** The **existing Enhancement tree** is extended
  so that it carries both the **tank** and the **melee DPS**.
- This replaces the 4th-tree idea from #367 for the shaman, and it replaces the
  free spell list of the first version of this document (S-2 … S-7b).
- **Phase 1 is bots first**, with no client patch:
  - **existing** talents are changed as spell changes (server-side, so they also
    affect players);
  - **new** talents are **auras on the premade spec** that mimic the planned
    talent.
- **Phase 2** is a client patch with the real talent slots and tooltips.

The owner approved the direction. The numbers become final only after the design
review ([section 8](#8-owner-decisions-open-numbers)).

**Owner decisions of 2026-09-27, second round** (CL-357 session, on the first
version of this rework). They are worked in below:

- **Windfury** (Elemental Weapons): **6 × 2 %** instead of 6 × 1 %. The earlier
  "2 × 3 %" was a mistake.
- **R2/C4 is Improved Ghost Wolf.** It gets **3 ranks**, and rank 3 makes Ghost
  Wolf **instant**.
- **Shield charges** (R6/C4, R7/C4): **no cap**. Lightning Shield is a consumed
  resource, so the maximum is rarely reached.
- **Storm wisdom** stays as specified: −20 % cast time and −20 % cost per stack.
- **Imbue mastery** stays as specified, **including the effect on Rockbiter
  threat**.
- **Old wishes are dropped** (magic damage reduction, a dedicated AoE ability,
  the standalone extra attack), **except the sword skill with an extra attack**.
  These become a new one-point **weapon talent** on a free slot of the
  Enhancement tree (row W in section 3).

Related: #356 (auto-learn, ClassGrant), #308 (premade paths, bear 11.3, gear),
#367 (the rogue follows the same approach).

## 1. Evidence base

All numbers below were read from data or code; none are recalled from memory.

**World data.** Taken from `Cilverkrow/twow-core` at `main` = `e50b648`:
`sql/base/tw_world_*.sql` plus all `sql/database_updates/**` migrations,
loaded into a throwaway local MariaDB 10.11, queried read-only and discarded.

**Code.** References point to the same commit:

- The shaman spell scripts are in `src/scripts/spells/spell_shaman.cpp`, short
  **`SS`** below.
- Bot paths are relative to `modules/mod-playerbots/src/playerbot/`.

**Effective values.** An effective value is `effectBasePoints + 1`, because every
row quoted here has `effectDieSides = effectBaseDice = 1`.

**Not verifiable here** (client data, not in Git), marked **(nv)** below:

- `Talent.dbc` / `TalentTab.dbc`: which talent sits at which row and column,
  rank counts as the client shows them, and the exact premade links.
- `Spell.dbc`: tooltips, icons, collisions with new spell IDs.
- `SpellDuration.dbc`: durations behind `durationIndex`.

The transcription of the owner screenshot is itself only a transcription. The
original is in the owner chat.

## 2. Two implementation routes

| Route | For | How | Who is affected | Client without a patch |
|---|---|---|---|---|
| **A: spell change** | talents that **already exist** (Elemental Weapons, R2/C4, Stormstrike) | a `spell_template` value change and/or a change to the talent's AuraScript in `SS` | **bots and players** (approved by the owner as a rule change) | old tooltip, new effect |
| **B: bot aura** | **new** talent slots (R1/C1, R1/C4, R4/C1, R4/C4, R6/C1, R6/C4, R7/C1, R7/C4) | a new passive `spell_template` entry, passive and hidden (`attributes 464` like the talents `16253`/`45545`), possibly with a script; granted by level to bots on the right premade path | **bots only** (no trainer row, no talent slot) | invisible; whether the client shows an unknown hidden aura on an inspected bot is **(nv)** |

**Rules for route B**

- **IDs** come from one reserved project range. Today's largest
  `spell_template.entry` is `90006`, so the proposal is **`90100`–`90199`**.
  Collisions with the client `Spell.dbc` are **(nv)** and must be checked once.
- **Grants run through ClassGrant (#356).** ClassGrant is twow-core draft
  [PR #163](https://github.com/Cilverkrow/twow-core/pull/163), not on `main`
  yet. The proposed extension is a table `{class, premade path, level, spell}`
  that is:
  - idempotent;
  - replaces the previous rank when a higher rank is granted;
  - removes the path's auras when the bot leaves the path;
  - behind the switch `AiPlayerbot.ClassGrant.Enabled` (default 0), so it
    fails closed (ADR-0024 invariants 4 and 6).
- **Grant level = the level a player could first take the talent.** A tier-r
  talent needs 5·(r−1) points in the tree, and talent points start at L10. So
  rank k of a tier-r talent is granted at **L 10 + 5·(r−1) + (k−1)**. For
  example, R6 rank 1 is L35 and R6 rank 5 is L39. This keeps bots on the same
  curve as players.
- **Point budget.** A player gets a fixed number of points (the owner line says
  "45 points, L60"). Bots on route B would get their path's new talents **on
  top of** the premade link. Proposal: path 7.1 (DPS) gets the **column-1**
  auras and path 7.3 (tank) gets the **column-4** auras, and the premade link
  of each path gives up an equal number of points. The exact trade needs
  `Talent.dbc` **(nv)**. See decision O-12.

## 3. The owner line, row by row

| Pos. | Talent | Ranks | Owner effect | Existing IDs / template | Route | Path |
|---|---|---|---|---|---|---|
| R1/C1 | **Attack speed** (new) | 5 | +2 % attack speed per rank (10 %) | template **"Haste 2"** `8815` (aura 138 MOD_MELEE_HASTE, passive, `attributes 448`); no shaman talent exists | B | 7.1 (and 7.3, O-12) |
| R1/C4 | **Defense** (new) | 5 | +6 defense per rank (30) | template **Anticipation** `12297`/`12750`/`12751` (aura 98 MOD_SKILL_TALENT, skill 95, warrior +7/14/20) | B | 7.3 |
| R2/C4 | **Improved Ghost Wolf** (existing, owner-confirmed) | 3 (today 2) | rank 3 makes Ghost Wolf instant | `16262`/`16287` (aura 107 SPELLMOD_CASTING_TIME, Ghost Wolf mask `0x800`, −1.0/−2.0 s). The DB has **only 2 ranks**. Ghost Wolf `2645` uses `castingTimeIndex 14`, whose cast time is **(nv)** | A (ranks 1/2) + B (rank 3 in phase 1) | all |
| R4/C1 | **Imbue mastery** (new) | 3 | all weapon imbues +3 % per rank (9 %) | no template; imbue spells: Flametongue proc `8026`… (mask `0x200000`), Frostbrand Attack `8034`… (`0x1000000`), Windfury Weapon `8233`… (`0x800000`), Rockbiter passive `10400`… (`0x400000`); Rockbiter proc `20865`… (mask 0) | B | 7.1, 7.3 |
| R4/C4 | **Retaliation** (new) | 3 | 30/60/90 % on dodge, parry or block: a free Lightning Shield proc against the attacker **and** +1 Lightning Shield charge | block-proc shape of warrior Shield Specialization `12298` (`procFlags 680`, `spell_proc_event.procEx`); charge restore like **Undertow** (`spell_shaman_undertow`, `SS` ~l.1045); free shield proc like `spell_shaman_lightning_strike_shield` (`SS` ~l.908) | B + script | 7.3 |
| R5/C4 | **Stormstrike change** (existing) | – | Stormstrike consumes up to 3 Lightning Shield charges and deals more damage | Stormstrike `17364` (effect 31, 100 % weapon damage, trigger `52412` +25 % Nature, 2 charges, 8 s cooldown); charge consumption exists for Lightning Strike via `52679` → `spell_shaman_lightning_strike_shield` | A | all |
| R6/C1 | **Storm wisdom** (new) | 5 | melee crit → 20/40/60/80/100 % chance: Lightning Bolt cast time and cost −20 %, stacks 5× | shape: proc aura (aura 42, `procEx` CRITICAL_HIT) → stack aura (`stackAmount 5`, aura 108 with SPELLMOD_CASTING_TIME 10 and SPELLMOD_COST 14, Lightning Bolt mask `0x1`) | B + script | 7.1 |
| R6/C4 | **Shield constitution** (new) | 3 | +1/2/3 % stamina per active Lightning Shield charge | aura 137 MOD_TOTAL_STAT_PERCENTAGE (stamina), amount = rank × charges; needs a script | B + script | 7.3 |
| R7/C1 | **Chain storm** (new, needs R6/C1) | 1 | the R6/C1 effect also reduces Chain Lightning cast time | Chain Lightning mask `0x2` (cf. Lightning Mastery `16578`: mask `0x3` = Lightning Bolt + Chain Lightning) | B | 7.1 |
| R7/C4 | **Shield ward** (new, arrow from R5/C4) | 1 | −2 % damage taken per active Lightning Shield charge | aura 87 MOD_DAMAGE_PERCENT_TAKEN, amount = −2 × charges; needs a script | B + script | 7.3 |
| W (free slot, **nv**) | **Weapon talent** (new; working name "Ancestral Arms") | 1 | enables **swords**; swords: **5 % extra attack**; axes: **+4 or 5 % crit**; maces: **+5 expertise**; daggers: **+5 % crit and +5 expertise**; **two-handed: values doubled** | extra attack: Sword Master `51664`–`51668` (aura 42 → `16459`, sword mask `384`); crit: Axe Master `51659`–`51663` (aura 52, axe mask `3`), Close Quarters Combat `13804` (daggers); "expertise": there is **no expertise in the 1.12 core**, so the closest equivalent is weapon skill (aura 98, racial Mace Specialization `20864` +3); sword skill: spells `201`/`202`, skills 43/55 | B + data (sword skill) | 7.1, 7.3 |

### 3.1 Details per row

For each row: what changes, the dependencies, and the test and acceptance.

**R1/C1 Attack speed (B).**
- **Change:** five passives cloned from `8815` with 2/4/6/8/10 % (aura 138).
  Pure data, no script.
- **Dependency:** stacks with Windfury and the new Windfury values (section 4).
- **Test:** a data contract checks the value per rank.
- **Acceptance:** the swing timer of a bot with 5/5 is 1/1.10 of its base timer
  (core `m_modAttackSpeedPct`), measured in `.debug`/combat log.

**R1/C4 Defense (B).**
- **Change:** five passives cloned from `12297` (aura 98, skill 95) with
  +6/12/18/24/30. Pure data.
- **Balance:** this is **+10 over the warrior** (Anticipation 3/3 = +20) (O-3).
- **Test:** the defense skill value of a bot at L60 on path 7.3 = base + 30.
- **Acceptance:** crit taken from a L63 mob in a 5-man test group, compared
  with the warrior.

**R2/C4 Improved Ghost Wolf, 3 ranks (A + B).**
- **Today:** 2 ranks (`16262` −1.0 s, `16287` −2.0 s). The owner wants 3 ranks,
  with an **instant** cast at rank 3.
- **Change:**
  - rank 3 = a new spell cloned from `16287` with −(full Ghost Wolf cast time);
  - if the cast time is 3 s, the ranks are **−1/−2/−3 s**; the cast time behind
    `castingTimeIndex 14` is **(nv)**.
- **A third talent rank is client data** (`Talent.dbc`, phase 2). In phase 1:
  - ranks 1 and 2 stay as they are, for players too;
  - bots on 7.1/7.3 get rank 3 as a bot aura (B) at the rank-3 level of the
    tier-2 formula (**L17**), replacing rank 2;
  - players get rank 3 with the client patch.
- **Test:** Ghost Wolf cast time with rank 3 = 0; with rank 2, 1 s is left (at
  a 3 s base).

**R4/C1 Imbue mastery (B).**
- **Change:** three passives with aura 108 (percent spell mod) on the imbue
  mask `0x1E00000` (Flametongue, Frostbrand, Windfury, Rockbiter passive).
- **Notes:**
  - `SPELLMOD_ALL_EFFECTS` on the Rockbiter passive `10400` also raises its
    effect 2: +35 % threat × 1.09 ≈ **+38 % at 3/3**. The **owner accepted
    this** (second round). So route B needs no special case for threat.
  - The Rockbiter damage proc `20865`… (Turtle, `spell_shaman_rockbiter_proc`)
    has **mask 0**, so the mask does not reach it. It needs a script or a
    changed `spellFamilyFlags` (route A, also affects players).
  - The Windfury AP bonus sits in `8233` effect 1 (`bp 45`).
- **Test:** per imbue, damage, AP or chance is +9 % at 3/3 compared with 0/3.
  Rockbiter threat is ≈ +38 % at 3/3.

**R4/C4 Retaliation (B + script).**
- **Change:** three passives (`procFlags 680`, `spell_proc_event.procEx =
  DODGE|PARRY|BLOCK` = `0x70`, `procChance` 30/60/90) plus a new AuraScript in
  `SS`, `spell_shaman_retaliation`. It:
  - fires the damage spell of the active Lightning Shield rank at the attacker
    **without** spending a charge (`GetLightningShieldDamageSpell`, `SS`
    ~l.495, as in `spell_shaman_lightning_strike_shield`);
  - adds one charge up to the maximum (as `spell_shaman_undertow` does).
- **Dependency:** Lightning Shield must be active; otherwise the proc fails.
- **Open:** the internal cooldown (3 s, shared with the shield?) (O-6).
- **Balance:** at 90 % and a high block/dodge rate, the shield stays nearly
  full, which drives R6/C4 and R7/C4 to their maximum (see O-7).
- **Test:** policy (proc only with a shield, cap at the maximum), and a runtime
  check that the charge counter does not exceed the maximum.

**R5/C4 Stormstrike change (A).**
- **Change:**
  - Stormstrike `17364` gets an effect or script that consumes **up to 3**
    Lightning Shield charges;
  - each charge adds damage;
  - it reuses the Lightning Strike path `52679` / `spell_shaman_lightning_strike_shield`,
    which today consumes exactly 1.
- **Numbers open:** damage per charge, and whether Nature or physical (O-8).
- **Players:** this is a rule change for them too. The tooltip stays old until
  phase 2.
- **Conflict:** a tank lives on its charges (R6/C4, R7/C4). The tank bot
  therefore uses Stormstrike only above a charge threshold (section 6.2).
- **Test:** charges before and after = −min(3, charges); damage grows per
  charge.

**R6/C1 Storm wisdom (B + script).**
- **Change:** five proc passives (melee crit, chance 20…100 %) that trigger one
  new stack aura (`stackAmount 5`, −20 % cast time and −20 % cost per stack on
  Lightning Bolt).
- **Stack removal:** the whole stack is removed when Lightning Bolt is cast.
  That needs a script, because charges and stacks are separate in the core.
- **Values (owner-confirmed):** −20 % cast time and −20 % cost per stack. At
  5 stacks Lightning Bolt is instant and free.
- **Duration:** 30 s (owner decision).
- **Test:** 5 stacks → Lightning Bolt cast time 0 and cost 0; the stacks are
  gone after the cast.

**R6/C4 Shield constitution (B + script).**
- **Change:** three passives. A script sets the stamina percentage =
  rank × current Lightning Shield charges.
- **Hook:** `OnAuraChargesChanged` exists (`ScriptMgr.h` l.1451) but is only
  fired at `Unit.cpp` l.4957 (proc charge drop). Paths that call
  `SetAuraCharges` directly (Undertow, R4/C4) must fire it too, or the script
  recomputes on every shield event.
- **Maximum:** with Stable Shields 3/3 there are 3 + 6 = **9 charges**, so
  **+27 % stamina**. The owner decided on **no cap**: the charges are used up,
  so the maximum is rarely reached. The acceptance run measures the average
  charge count.
- **Test:** stamina follows the charges on charge loss, restore, recast and
  expiry.

**R7/C1 Chain storm (B).**
- **Change:** one passive. Technically a second stack aura with the mask
  Lightning Bolt + Chain Lightning (`0x3`). The R6/C1 script picks this stack
  aura when the bot has Chain storm.
- **Dependency:** R6/C1.
- **Test:** 5 stacks → Chain Lightning cast time reduced as for Lightning Bolt.

**R7/C4 Shield ward (B + script).**
- **Change:** one passive (aura 87), with amount = −2 % × charges, maintained
  by the same script as R6/C4.
- **Dependency:** the arrow from R5/C4. Bots get it only with the R5/C4 change
  in place.
- **Maximum:** 9 charges = **−18 % damage taken** (Defensive Stance `7376`:
  −10 %). No cap (owner decision), as for R6/C4.
- **Test:** as for R6/C4.

**W Weapon talent "Ancestral Arms" (B + data).**
- **Position:** the free slot in the shaman Enhancement tree, 1 rank (owner
  decision, O-16). Its exact row and column are **(nv)** without `Talent.dbc`. The grant level follows
  the tier formula of section 2 once the row is fixed.
- **Effects and templates** (1H value / 2H value):

  | Weapon | Owner effect | 1H | 2H | Template |
  |---|---|---|---|---|
  | Sword | usable + extra attack | 5 % (mask 128) | 10 % (mask 256) | Sword Master `51668` (aura 42 → `16459`, `procFlags 20`) |
  | Axe | crit | +4 % (mask 1) | +8 % (mask 2) | Axe Master `51663` (aura 52) |
  | Mace | "expertise" | +5 skill (skill 54) | +10 skill (skill 160) | racial Mace Specialization `20864` (aura 98) |
  | Dagger | crit + "expertise" | +5 % crit (mask 32768), +5 skill (skill 173) | – (no 2H daggers) | Close Quarters Combat `13804` (aura 52), aura 98 |

  Each line is its own passive, restricted by `equippedItemSubClassMask`, so
  the talent is a bundle of about 8 passives granted together.
- **"Expertise" does not exist in 1.12.** The core has no expertise stat (no
  hit in `src/game`). Weapon skill is the closest equivalent: it lowers miss,
  dodge, parry and glancing like expertise does later. Proposal: **1 expertise
  = 1 weapon skill** (owner decision, O-18). Real TBC expertise (target dodge/parry −0.25 %
  per point) would need core code.
- **The sword skill needs server data, but not for weapon masters:**
  - Without a `skill_race_class_info_mod` row, a shaman **cannot keep** skill
    43/55: the core adds weapon skills on learning only with a race/class entry
    (`Player.cpp` ~l.7573), and drops a "forbidden skill" on character load
    (~l.22935).
  - Therefore: two new `skill_race_class_info_mod` rows (skill 43 and skill
    55), `ClassMask 64` (shaman), all shaman races, all fields explicit (the
    loader rejects `-1` without a DBC row, `SpellMgr.cpp` ~l.2727). The values
    for `Flags` and `SkillTierId` are taken from the DBC rows of the other
    classes **(nv)**.
  - `skill_line_ability` rows `5`/`7` (`class_mask 399`/`7`) stay
    **unchanged**. Weapon masters check that mask
    (`Player::IsSpellFitByClassAndRace`, ~l.21884, via `GetTrainerSpellState`
    ~l.5410), so they **keep refusing** swords for shamans. The skill comes
    only from the talent (phase 1: bot grant of `201`/`202`; phase 2: the
    talent teaches them).
  - Players are therefore unaffected in phase 1.
- **Bot factory:** `InitSkills` (~l.4121), `CanEquipWeapon` (~l.2903) and
  `RandomItemMgr` (~l.668) allow swords only for bots with the talent (7.1:
  1H/2H, 7.3: 1H + shield).
- **Tests:**
  - A shaman bot with the talent has skills 43/55 after relog; without it, it
    has neither.
  - A player shaman at the weapon master still sees swords red.
  - Proc and crit rates per weapon type over N swings (5/10 %, 4/8 %).
  - Weapon skill +5/+10 visible on the character.

## 4. Elemental Weapons 3/3: current vs. owner

- **Talent:** Elemental Weapons `16266`/`29079`/`29080`, AuraScript
  `spell_shaman_elemental_weapons` (`SS` ~l.1114).
- **Route:** A. It affects players, and the tooltip stays old until phase 2.
- **Owner values:** taken from the image, before/after to be verified (see the
  OB-00 note).

| Imbue | Implementation today (rank 3) | Current value (DB) | Owner value | Change |
|---|---|---|---|---|
| Flametongue | trigger `52972` "Enkindled Flames" (aura 79, school Fire) | **+30 %** fire damage (R1/R2: `52970` +10 %, `52971` +20 %) | **+50 %** fire totems and fire spells, 5 s | `52972` value 30 → 50 (R1/R2 proportional: 17/33? O-10). Whether aura 79 also covers **totem** damage (totems are separate units) is to be checked. Otherwise a script is needed |
| Frostbrand | `58250` (aura 107 SPELLMOD_CHANCE_OF_SUCCESS 18) + guaranteed crit on Frost Shock (`spell_shaman_frostbrand_attack`) | **+25 %** trigger chance (R1/R2 +8/+16) | **+50 %** (image partly overwritten: 25/50) | `58250` value 25 → 50 once O-10 is decided; the crit part already exists |
| Windfury | trigger `52969` "Rushing Winds" (aura 9 MOD_ATTACKSPEED) | **+1 % per stack, 6 stacks** (R1 2, R2 4, R3 6) | **6 × 2 %** (owner correction, second round), 5 s | `52969` value 1 → 2, `stackAmount` stays 6. The maximum goes from 6 % to **12 %**. Ranks 1/2 (`52967`/`52968`, 2/4 stacks) are adjusted accordingly (O-10) |
| Rockbiter | effect 3 of the talent (build %) + Earthen Bulwark `58130` (aura 69 absorb) | build **20 %** of damage (×3 with a shield), absorbs **15 %** of incoming damage, cap = **20 % of max health** | build **30 %** (×3 with a shield), absorbs **25 %**, 8 s, cap **40 % of max health** | talent effect 3 value 20 → 30; `58130` 15 → 25. The **cap is tied to the build percentage in code** (`GetEarthenBulwarkCap` = build % × max health, `SS` ~l.376). The 40 % cap therefore needs a **code change** (a separate value, e.g. `58127` "Earthen Bulwark Durability" or a constant) |

All three ranks carry identical base points in effects 1–3. The ranks differ
only through their trigger spells (`52967`…`52969`, `52970`…`52972`,
`58128`…`58130`). A rank curve therefore means changing the trigger spells.

## 5. Other tank facts in the existing data (unchanged)

These results from the first version still hold and do not conflict with the
owner line.

**Taunt: Earthshaker Slam `51365`.**
- effect 114 + aura 11, shield required, 10 s cooldown, melee range, no mana;
- taught at L10 by 10 of 14 shaman trainers (`51366`, 400 copper);
- bots learn it through `AutoLearnTrainerSpells` (#356);
- **no bot code uses it yet.**

**Existing Enhancement tank talents (tree position nv):**
- Shield Specialization `16253`… (+1…5 % block, +6…30 % block value);
- Stable Shields `16261`/`16290`/`16291` (+2/4/6 charges, +1 s proc
  cooldown);
- Spirit Armor `45951`/`45952` (with a shield: +15/30 % shield armor, +5/10 %
  threat);
- Ancestral Guardian `45545`… (+5/10/15 % armor, +2/4/6 % dodge).

**Threat:** Rockbiter +35 % × Spirit Armor +10 % ≈ **1.49×**, against about
1.56× for a protection warrior. Earth Shock has `spell_threat` ×2. Calming
Winds `51383`… (−8/16/25 % threat) is wrong for a tank.

**Lightning Shield `324` … `10432`:**
- 3 charges, 3 s internal cooldown, damage 13 … 198 (`26364` … `26363`);
- AuraScript `spell_shaman_lightning_shield` (`SS` ~l.783).

**AoE threat:** Totemic Alignment `51381`/`51382` (aura 200, 45/90 % of totem
threat to the shaman) is implemented in `ThreatManager::addThreat` (~l.437).

**Swords:** `skill_line_ability` row 5 (skill 43) has `class_mask 399`, which
excludes the shaman. Row W (section 3.1) describes how the weapon talent
unlocks swords through `skill_race_class_info_mod` while the weapon masters
keep refusing shamans.

## 6. Bot logic (mod-playerbots)

Nothing here is implemented. Code lives in twow-core `modules/mod-playerbots/`.

### 6.1 Role and paths

- **Path 7.1 `enhancement` stays the melee DPS path.**
  - It gets the column-1 auras (R1/C1, R4/C1, R6/C1, R7/C1), plus the
    weapon talent W and Improved Ghost Wolf rank 3, through
    ClassGrant.
  - Route-A changes apply to it automatically.
- **Path 7.3 `tank` is new.** It follows the bear 11.3 pattern (#308):
  - `AiPlayerbot.PremadeSpecName.7.3 = tank` plus links generated with
    `tools/build_premade_specs.py`. The picks are Shield Specialization, Spirit
    Armor, Ancestral Guardian, Stable Shields, Elemental Weapons and
    Stormstrike, and **no** Calming Winds. The exact link is **(nv)**.
  - It gets the column-4 auras (R1/C4, R4/C4, R6/C4, R7/C4), plus W and
    Improved Ghost Wolf rank 3.
- **Role mapping:**
  - `IsShamanTankSpec(player)` next to `IsBearSpec` (`AiFactory.cpp` ~l.27).
  - The forced role wins, then the path (as for the feral druid, ~l.475).
  - `GetPlayerRoles(const Player*)` (~l.302) returns `BOT_ROLE_TANK` for
    path 7.3.
- **Required fix:** `ChangeTalentsAction::getPremadePaths`
  (`strategy/actions/ChangeTalentsAction.cpp` ~l.170) filters by tree → role.
  Tab 1 is DPS, so a forced-tank shaman gets **no** path today. The filter
  needs a path-name → role mapping.
- **Combat engine for 7.3:**
  `"tank shaman", "tank assist", "pull", "pull back", "close", "totems", "cure", "buff", "boost"`
  — no `dps assist`.

### 6.2 `tank shaman` strategy

`TankShamanStrategy` (`strategy/shaman/`), `STRATEGY_TYPE_TANK | STRATEGY_TYPE_MELEE`,
registered in `ShamanAiObjectContext.cpp`.

| Priority | Trigger | Action |
|---|---|---|
| EMERGENCY | `critical health` | `lesser healing wave` on self |
| MOVE+4 | `lose aggro` | **`earthshaker slam`** (new action for spell `51365`; requires a shield) |
| HIGH+5 | `lightning shield` missing, **or charges < max − 1** before the pull | `lightning shield` (recast refills the charges, which feeds R6/C4 and R7/C4) |
| HIGH+4 | `shaman weapon` | **`rockbiter weapon`** first (the enhancement chain `windfury → rockbiter`, `EnhancementShamanStrategy.cpp` ~l.38, reversed) |
| HIGH+3 | `enemy is casting` | `earth shock` (interrupt, ×2 threat) |
| HIGH+2 | ≥ 3 attackers | `magma totem` / `fire nova totem` (Totemic Alignment) |
| HIGH+1 | `shock` | `earth shock` |
| NORMAL+1 | `stormstrike` | `stormstrike` **only if charges ≥ threshold** (O-11). R5/C4 consumes up to 3 charges, and each charge costs about 2 % damage reduction and 1–3 % stamina |
| NORMAL | default | melee |

For path 7.1 (DPS), the existing `enhancement` strategy adds:

- `lightning bolt` when the Storm wisdom stack is at 5;
- `chain lightning` when Chain storm is present and there are ≥ 2 targets;
- `stormstrike` without a charge threshold (the DPS spends its charges).

### 6.3 Equipment and stats

**Equipment:**
- The tank off-hand filter (`PlayerbotFactory.cpp` ~l.3463, today
  `specId == 3 || 5`) also applies to the shaman tank spec: shield only.
- `CanEquipWeapon` (~l.2903): 7.3 uses a one-handed mace, axe, fist weapon or,
  with the weapon talent W, a sword. 7.1 may also use two-handed swords with W.
- A new weight scale `shamantank` (`ai_playerbot_weightscales.sql`, next to
  `prot` 3/5 and `feraltank` 30) with the priority:

  **Stamina > Defense > Armor > Block value > Block > Strength > Intellect > Hit > Agility**.

  Stamina is weighted up because of R6/C4.

### 6.4 Tests

- **Source contract,** as in `t/bear_path_source_contract_tests.cmake`:
  - path 7.3 exists;
  - `IsShamanTankSpec` sits wherever `IsBearSpec` is checked;
  - `tank shaman` has no `dps assist` and no `windfury weapon`.
- **Policy tests:**
  - the ClassGrant table: level formula (section 2), rank replacement, removal
    on path change, switch off grants nothing;
  - column 1 → 7.1 and column 4 → 7.3.
- **Script tests (twow-core `src/scripts`):**
  - R4/C4 respects the charge cap;
  - R5/C4 consumes min(3, charges);
  - R6/C4 and R7/C4 follow the charges;
  - R6/C1 clears the whole stack on a Lightning Bolt cast.
- **Runtime acceptance** in 5-man test groups:
  - the 7.3 tank holds threat on 1 and 3+ targets and dies no more often than
    a bear on the same content;
  - 7.1 DPS is not worse than before (route-A changes also hit it);
  - players see no new spells.

## 7. Delivery plan (after the decisions)

1. **twow-core, route A (OB-20).** Forward-only world migrations for Elemental
   Weapons (`52972`, `58250`, `52969`, `16266`/`29079`/`29080` effect 3,
   `58130`), Stormstrike, plus the code changes: Earthen Bulwark cap
   (`SS` ~l.376) and the Stormstrike charge script. The same step adds the two
   `skill_race_class_info_mod` rows for skills 43/55 (row W).
2. **twow-core, route B data and scripts.** The new passives in `90100`–`90199`,
   `spell_proc_event` rows, and AuraScripts for R4/C4, R6/C1 (+R7/C1) and
   R6/C4 + R7/C4 in `SS`. Also Improved Ghost Wolf rank 3 and the weapon talent
   W (about 8 passives).
3. **twow-core, mod-playerbots (OB-10).** ClassGrant path table, path 7.3,
   `IsShamanTankSpec`, `getPremadePaths` fix, `TankShamanStrategy`, the
   Earthshaker Slam action, the 7.1 additions, gear and weights, tests.
4. **twow-repo.** Pin bump, then the funserver-test overlay.

Steps 1 and 2 can be tested separately. Step 3 works at reduced strength even
without step 2 (taunt, Rockbiter, existing talents), which makes a good first
measurement.

## 8. Owner decisions (open numbers)

| # | Question | Recommendation |
|---|---|---|
| O-1 | R2/C4 | **decided:** Improved Ghost Wolf, 3 ranks, rank 3 instant. Open: rank values −1/−2/−3 s (depends on the Ghost Wolf cast time, **nv**) |
| O-2 | Attack speed R1/C1: +2 %/rank as a flat haste aura — also for 7.3? | yes, 7.1 and 7.3 (a tank gets more Rockbiter/bulwark procs) |
| O-3 | Defense R1/C4 +6/rank = +30 (warrior +20) | take the owner value; measure in 5-man |
| O-4 | Imbue mastery R4/C1 | **decided:** stays as specified, +3 %/rank on all imbue effects |
| O-5 | Rockbiter threat under imbue mastery | **decided:** threat rises too (≈ +38 % at 3/3) |
| O-6 | Retaliation R4/C4: internal cooldown of the free shield proc | 3 s shared with Lightning Shield |
| O-7 | Charge scaling R6/C4 and R7/C4 | **decided:** no cap (the charges are used up); measure the average charge count in the acceptance run |
| O-8 | Stormstrike R5/C4: damage per consumed charge, school | the damage of the active shield rank's proc per charge, Nature (like Lightning Strike) |
| O-9 | Storm wisdom R6/C1 | **decided:** −20 % cast time and −20 % cost per stack, duration **30 s** |
| O-10 | Elemental Weapons ranks 1/2 and the unclear Frostbrand value (25/50) | Flametongue 17/33/50, Frostbrand 16/33/50, Windfury **2 % per stack** at 2/4/6 stacks, Rockbiter build 10/20/30, absorb 15/20/25 |
| O-11 | Tank Stormstrike threshold | only at ≥ 4 charges, and only while the tank has aggro |
| O-12 | Point budget of the bot auras (section 2) | 7.1 = column 1, 7.3 = column 4, W on both; each premade link gives up the same number of points |
| O-13 | Earlier brief wishes | **decided:** magic damage reduction, a dedicated AoE ability and the standalone extra attack are dropped; sword + extra attack goes into the weapon talent W |
| O-14 | New spell ID range | `90100`–`90199`, after a one-time check against the client `Spell.dbc` **(nv)** |
| O-15 | Share of path 7.3 in the roster | Prob 30 until the acceptance run passes (together with #366) |
| O-16 | Slot of the weapon talent W | **decided:** the free slot in the shaman Enhancement tree. Its exact row and column come from `Talent.dbc` (**nv** here, section 9); the grant level follows from that row |
| O-17 | W: axe crit | **decided:** **+4 %** (2H +8 %) |
| O-18 | W: "expertise" in 1.12 | **decided:** 1 expertise = 1 weapon skill (maces +5/+10, daggers +5) |
| O-19 | W: two-handed swords | **decided:** yes (2H sword 10 % extra attack) |
| O-20 | W: fist weapons | **decided:** no bonus; fist weapons stay usable as today |

## 9. Client data needed

Several open points need client data. By invariant 5 (`AGENTS.md`, ADR-0024),
**client data does not go into Git**. The proposal: the owner extracts only
the listed fields and posts them as a comment or attachment on #357 (or in the
evidence folder), not in the repo.

| File | What exactly | For |
|---|---|---|
| `Talent.dbc` | all rows of the shaman Enhancement tab: talent ID, row, column, spell ID per rank, prerequisite talent | R2/C4, free slots for W (O-16), exact premade links 7.1/7.3, point budget (O-12) |
| `TalentTab.dbc` | the shaman tab IDs and order | assigning the tab |
| `SkillRaceClassInfo.dbc` | rows for skills 43, 55 (swords) and 44, 54, 160, 172, 173 (for comparison): ID, race mask, class mask, flags, skill tier | the `skill_race_class_info_mod` rows of W |
| `Spell.dbc` | whether IDs `90100`–`90199` are free; tooltips of `16262`/`16287`, `16266`/`29079`/`29080` | O-14, tooltip text for phase 2 |
| `SpellCastTimes.dbc` | index 14 | Ghost Wolf cast time (O-1) |
| `SpellDuration.dbc` | indexes 7, 21, 29, 31 | durations of Rushing Winds, Enkindled Flames, Stormstrike, Earthen Bulwark |

Alternatively, once the files are extracted, `core/tools` or a short Python
script can pull exactly these rows.

## 10. What this document does not do

- No spell, item, trainer, DBC, SQL, config or core change.
- No build: `BUILD_REQUIRED=NO`, docs only.
- Talent positions and ranks as the client shows them, tooltips, durations, and
  client spell ID collisions are **(nv)**. They must be checked against the
  client data (section 9) before step 1 of section 7.

## 11. Owner decisions and implementation (2026-09-27)

The owner decided the open numbers of section 8 (recorded in #357; approval of
release train 7 in #319 issuecomment-5855818540). Where this section differs
from the proposals above, this section applies.

| # | Decision | Implemented in |
|---|---|---|
| O-1 | Ghost Wolf cast time is 3000 ms (`SpellCastTimes.dbc` index 14). **Improved Ghost Wolf 2/2 = instant for players and bots** (rank 2 −3000 ms, rank 1 stays −1000 ms); no bot aura for rank 3. | twow-core#187 |
| O-2 / O-3 | Attack speed and defense are two separate talents with their own points; defense +30. | twow-core#187 (90100–90109) |
| O-4 / O-5 | Imbue mastery +3 %/rank on all imbue effects; Rockbiter threat rises with it (≈ +38 % at 3/3). | twow-core#187 (90111–90113) |
| O-6 | Retaliation internal cooldown **1 s**. | twow-core#187 (90114–90116) |
| O-7 | No cap on the charge-scaled talents; the acceptance run measures the average charge count. | twow-core#187 (90126–90129) |
| O-8 | Stormstrike consumes up to 3 Lightning Shield charges, **+10 % damage per charge (max +30 %)**, bot aura. | twow-core#187 (90117) |
| O-9 | Storm wisdom lasts 30 s; −20 % cast time and −20 % cost per stack. | twow-core#187 (90118–90125) |
| O-10 | Elemental Weapons: Flametongue 17/33/50, Frostbrand 16/33/50, Windfury 2 %/stack at 2/4/6, Rockbiter 10/20/30 + 15/20/25, Earthen Bulwark cap 13/27/40 % of max health. | twow-core#182 (merged) |
| O-11 | Tank Stormstrike only from ≥ 4 charges and with aggro (bot strategy). | OB-10 |
| O-12 | Variant A: bots pay for their auras; premade trims **7.1 = 14, 7.3 = 21 points** (Ghost Wolf no longer counts). | OB-10 |
| O-14 | Bot aura IDs 90100–90199: shaman 90100–90139, rogue 90140–90199. | #357, #367 |
| O-15 | Shaman tanks = 20 % of a faction's tanks. | OB-40 |

## 12. Stage 2: real client talents for all players (2026-09-28)

The owner wants the rework as **real talents in the client for every player**
(#409 issuecomment-5874183685 part B). The phase-1 bot auras become the rank
spells of new `Talent.dbc` rows, with the same spell IDs 90100–90129. The weapon
talent W "Ancestral Arms" (O-16…O-20) gets its server spells in the same step.

- **Client delta, switch plan, acceptance and open points S2-1…S2-7:** 12.1–12.5
  below.
- **Server counterpart:** Cilverkrow/twow-core#217. It contains:
  - W 90130–90139;
  - shaman sword skills via `skill_race_class_info_mod` (flags 0x180, like the
    talent-gated rows 701/702);
  - talent icons;
  - the Elemental Weapons tooltip cap 13/27/40 %;
  - the bot switch `AiPlayerbot.SpecAura.TalentClasses`;
  - `build_premade_specs.py --talent-classes 7`.
- **Layout:** the new talents fill R1/C1, R1/C4, R4/C1, R4/C4, R5/C4, R6/C1, R6/C4,
  R7/C1 and R7/C4 as in the owner line, and W takes R7/C3. That is the only free
  cell that no existing arrow runs through. **The owner confirmed R7/C3 and level
  40+ on 2026-09-28 (S2-1).**
- **Premade links:** they are position-encoded, so the new rows shift every
  Enhancement link. All shaman links are regenerated from the patched
  `Talent.dbc`, and every roster shaman gets a talent reset in the release window.

### 12.1 Client delta (clientpatch pipeline, #431)

The change uses the stage-1 pipeline format (`ops/clientpatch/changes/<Dbc>/NNNN_*.csv`,
`op,key,field,value,note`), so `python -m clientpatch build` applies it with
fingerprint, `dbcdiff`, consistency rules and hashes.

| File | Content |
|---|---|
| `changes/Talent/0357_shaman_talents.csv` | 10 talents in tab 263, IDs 9001–9010. **Generated** by `tools/talentdelta.py` from `tools/inputs/357-shaman-talents.csv`; a test fails when it is stale |
| `changes/SkillRaceClassInfo/0357_shaman_swords.csv` | swords for shamans, talent only: records 90043/90055, copies of Turtle's row 701 (flags 0x180); rule `skillraceclass-mod-values` compares them with core#217's `skill_race_class_info_mod` |
| `changes/Spell/0357_shaman_elemental_weapons.csv` | Elemental Weapons 16266/29079/29080: description from `sql:spell_template.description` (cap 13/27/40 %, CV-1) |
| `changes/Spell/0357_shaman_spells.csv` | **after #433:** client rows for 90100–90139 (without 90110), generated with `tools/gen_spell_mirror.py` from `tools/inputs/357-shaman-spells.csv` (every mapped column `sql:spell_template.*`) |
| `changes/code-values.md` | CV-1 and CV-3 updated, CV-11 … CV-13 added (CV-4 … CV-10 belong to the rogue, #433) |

Rules: `talent-ranks-on-server` (rank spells exist on the server) and the new
`custom-spell-icons-in-client` (every icon of spells 90000–90999 exists in
`SpellIcon.dbc`).

`tools/talentdelta.py` is generic (any class, any tab):

```sh
cd ops/clientpatch
# layout check + write the delta
python3 tools/talentdelta.py --talents tools/inputs/357-shaman-talents.csv \
    --base-cells tools/inputs/357-shaman-base-cells.csv --out changes/Talent/0357_shaman_talents.csv
# against the real base tree (extracted Talent.dbc) instead of the committed cells
python3 tools/talentdelta.py --talents ... --base-dbc <extract>/Talent.dbc --check changes/Talent/0357_shaman_talents.csv
# server sources of a twow-core checkout (migrations, SpecAuraPolicy.h, generator)
python3 tools/talentdelta.py --talents ... --base-cells ... --core ../../core --class 7 \
    --skills changes/SkillRaceClassInfo/0357_shaman_swords.csv
```

`tools/inputs/357-shaman-base-cells.csv` is OB-20's read-out of tab 263 (IDs and
positions only, #357 issuecomment-5857352559) so CI can check the layout
without a client; `--base-dbc` checks the real tree and also the rank counts of
base prerequisites.

### 12.2 The tree after the patch (tab 263, R = tier + 1, C = column + 1)

| | C1 | C2 | C3 | C4 |
|---|---|---|---|---|
| R1 | **Attack Speed 5** (9001) | Ancestral Knowledge 5 | Shield Specialization 5 | **Earthen Guard 5** (9002, defense) |
| R2 | Totemic Alignment 2 | Thundering Strikes 5 | Stable Shields 3 | Improved Ghost Wolf 2 |
| R3 | Calming Winds 3 | *(arrow Thundering Strikes → Flurry)* | Lightning Strike 1 | Ancestral Guardian 3 |
| R4 | **Imbue Mastery 3** (9003) | Flurry 5 | Spirit Armor 2 | **Retaliation 3** (9004) |
| R5 | Enhancing Totems 2 | Elemental Weapons 3 | Stormstrike 1 | **Charged Stormstrike 1** (9005, ← Stormstrike) |
| R6 | **Storm Wisdom 5** (9006) | *(arrow Elemental Weapons → Bloodlust)* | Element's Grace 5 | **Shield Constitution 3** (9007) |
| R7 | **Chain Storm 1** (9008, ↑ Storm Wisdom 5/5) | Bloodlust 1 | **Ancestral Arms 1** (9010, W) | **Shield Ward 1** (9009, ↑ Shield Constitution 3/3) |

`tools/talentdelta.py`: layout PASS, no warnings. Shield Ward requires Shield
Constitution 3/3 (S2-2), so its arrow runs from R6/C4 to R7/C4 in the same
column. The owner's original arrow R5/C4 → R7/C4 would have passed over Shield
Constitution.

### 12.3 Switch plan (one coupled release, world stopped)

**Preconditions:**
- core#217 merged and pinned;
- stage-1 tooling (CL-409) merged;
- `tools/talentdelta.py ... --core core --class 7 --skills ...` PASS on the pin (see 12.1).

1. **Build (owner/OB-15, local):**
   - deltas → client `Talent.dbc`, `Spell.dbc`, `SkillRaceClassInfo.dbc` → `patch-X.mpq` version N, with sha256;
   - from the **same** build, the server's `Talent.dbc` and `SkillRaceClassInfo.dbc` for `data/dbc`;
   - `dbcdiff` `review.csv` lists exactly these rows.
2. **Premade links (OB-10):**
   - `build_premade_specs.py --dbc <patched dbc> --talent-classes 7` → new `PremadeSpecLink.7.*` for **all** shaman paths.
   - Why all paths: the links are position-encoded, and the new rows shift every Enhancement digit.
   - 7.1 gets 14 points and 7.3 gets 21 points in the new talents (what they paid for the auras), plus 1 each for W.
   - The generated links ship in the **same release** as the patched DBC (step 3). The old links would read the new rows 9001–9010 as other talents, and every Enhancement link would shift.
3. **Server (OB-30, release):**
   - core pin with #217 (migration applies itself);
   - patched `data/dbc`;
   - profile `AiPlayerbot.SpecAura.TalentClasses = 7` (SpecAura then no longer grants or removes 90100–90129 for shamans, and the paths pay nothing extra);
   - the new links;
   - all in the same pin/profile.
4. **Bots (OB-40), only after step 3 is live:**
   - `deploy/roster/talent-reset/run-talent-reset.sh --class 7 --spec-nos 1,2,3,4 --dry-run`, then `--apply` with count and hash. This covers every roster shaman on every path, because every link changed.
   - Why after step 3: the bots already know 90100–90129 from phase 1 (`character_spell`). With the patched server `Talent.dbc` the core counts them as bought talent ranks when it loads the bot (`GetTalentSpellCost`), so those points count as spent and the new links apply only partly.
   - At login `ResetTalents` removes all talent ranks of the patched tree, **including the granted 90100–90129** (now talent ranks). The bot then learns its new link.
   - A reset **before** the DBC patch does not help: 90100–90129 are no talents yet, so it leaves them in place.
5. **Players:**
   - **no reset**: the existing talent IDs and positions stay, and the new slots are free to learn;
   - without the patch the client shows the old tree (fail-closed) and cannot learn the new talents.
6. **Publish** patch N (Nostalgia catalogue, #410 §5).

**Rollback (together):**
- previous pin and previous `data/dbc`;
- `TalentClasses` empty and the old links;
- repeat the reset from step 4;
- republish patch N−1.

### 12.4 Acceptance

- `review.csv` = exactly the rows of this change.
- **With the patch:**
  - the 10 slots are in the positions shown above with the right rank counts;
  - the tooltips show the server numbers (Elemental Weapons cap 13/27/40 %; code values CV-1, CV-3, CV-11 … CV-13 in `ops/clientpatch/changes/code-values.md`);
  - learning each new talent on a test character gives the right spell server-side;
  - inspect from a second patched client shows the right points.
- **Ancestral Arms:**
  - swords and the sword skill are available, and still there after a relog;
  - a weapon master still refuses swords to a shaman without the talent;
  - extra attack and crit apply only with the matching weapon;
  - a talent reset removes all of it.
- **Bots:**
  - before and after, a 7.1/7.3 bot has each effect **once**: the talent rank, never talent plus aura;
  - no `[SpecAura] state=grant` or `state=remove` for shamans after the switch.
- **Without the patch:** old tree, no crash.

### 12.5 Open decisions (owner / OB-20)

| # | Question | Recommendation |
|---|---|---|
| S2-1 | Slot of W | **decided (owner, 2026-09-28): R7/C3, level 40+ is fine.** It is the only clean free cell: R3/C2 and R6/C2 lie on the Flurry and Bloodlust arrows (`tools/talentdelta.py` rejects them). R7 needs 30 points in the tree |
| S2-2 | Prerequisite of Shield Ward | **decided (owner, 2026-09-28): Shield Constitution 3/3.** The original arrow from Charged Stormstrike (R5/C4 → R7/C4) would pass over Shield Constitution (R6/C4); the new arrow is clean and the tank column still builds up |
| S2-3 | Chain Storm needs Storm Wisdom at which rank? | 5/5 (as in the delta) |
| S2-4 | IDs: talents 9001–9010, SkillRaceClassInfo 90043/90055 | **done (OB-00 / OB-20, 2026-09-28):** talent IDs 9001–9010 are free in `Talent.dbc` of both clients and the server `data/dbc`; spell IDs 90100–90139 are free in every client `Spell.dbc` (#432 issuecomment-5878036789). The SkillRaceClassInfo **record** IDs 90043/90055 were checked as spell IDs only. Requirement for the stage-1 build: an `insert` onto an existing record ID in `SkillRaceClassInfo.dbc` must stop the build as a hard error |
| S2-5 | Charged Stormstrike hangs sideways off Stormstrike (R5/C3 → R5/C4) | **owner (2026-09-28):** he checks the arrow in game as soon as the patch is online; if the frame does not draw it, the prerequisite goes |
| S2-6 | Names | **decided (owner, 2026-09-28): as given** (Attack Speed, Earthen Guard, Imbue Mastery, Retaliation, Charged Stormstrike, Storm Wisdom, Shield Constitution, Chain Storm, Shield Ward, Ancestral Arms) |
| S2-7 | Bot equipment for swords | **open, OB-10 follow-up:** `PlayerbotFactory::CanEquipWeapon` (shaman tab 1 allows no swords), `RandomItemMgr` (the `enhance` weapon lists are per spec, not per bot, so swords must depend on the bot's skill 43/55 from W, not on the spec). Without it, bots learn W but keep their weapon types |
