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
| R2/C4 | existing talent, purple icon | 3 | rank 3 makes the ability instant | **(nv)**: candidate **Improved Ghost Wolf** `16262`/`16287` (aura 107 SPELLMOD_CASTING_TIME, Ghost Wolf mask `0x800`, −1.0/−2.0 s). The DB has **only 2 ranks**. Ghost Wolf `2645` uses `castingTimeIndex 14` **(nv)** | A | all |
| R4/C1 | **Imbue mastery** (new) | 3 | all weapon imbues +3 % per rank (9 %) | no template; imbue spells: Flametongue proc `8026`… (mask `0x200000`), Frostbrand Attack `8034`… (`0x1000000`), Windfury Weapon `8233`… (`0x800000`), Rockbiter passive `10400`… (`0x400000`); Rockbiter proc `20865`… (mask 0) | B | 7.1, 7.3 |
| R4/C4 | **Retaliation** (new) | 3 | 30/60/90 % on dodge, parry or block: a free Lightning Shield proc against the attacker **and** +1 Lightning Shield charge | block-proc shape of warrior Shield Specialization `12298` (`procFlags 680`, `spell_proc_event.procEx`); charge restore like **Undertow** (`spell_shaman_undertow`, `SS` ~l.1045); free shield proc like `spell_shaman_lightning_strike_shield` (`SS` ~l.908) | B + script | 7.3 |
| R5/C4 | **Stormstrike change** (existing) | – | Stormstrike consumes up to 3 Lightning Shield charges and deals more damage | Stormstrike `17364` (effect 31, 100 % weapon damage, trigger `52412` +25 % Nature, 2 charges, 8 s cooldown); charge consumption exists for Lightning Strike via `52679` → `spell_shaman_lightning_strike_shield` | A | all |
| R6/C1 | **Storm wisdom** (new) | 5 | melee crit → 20/40/60/80/100 % chance: Lightning Bolt cast time and cost −20 %, stacks 5× | shape: proc aura (aura 42, `procEx` CRITICAL_HIT) → stack aura (`stackAmount 5`, aura 108 with SPELLMOD_CASTING_TIME 10 and SPELLMOD_COST 14, Lightning Bolt mask `0x1`) | B + script | 7.1 |
| R6/C4 | **Shield constitution** (new) | 3 | +1/2/3 % stamina per active Lightning Shield charge | aura 137 MOD_TOTAL_STAT_PERCENTAGE (stamina), amount = rank × charges; needs a script | B + script | 7.3 |
| R7/C1 | **Chain storm** (new, needs R6/C1) | 1 | the R6/C1 effect also reduces Chain Lightning cast time | Chain Lightning mask `0x2` (cf. Lightning Mastery `16578`: mask `0x3` = Lightning Bolt + Chain Lightning) | B | 7.1 |
| R7/C4 | **Shield ward** (new, arrow from R5/C4) | 1 | −2 % damage taken per active Lightning Shield charge | aura 87 MOD_DAMAGE_PERCENT_TAKEN, amount = −2 × charges; needs a script | B + script | 7.3 |

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

**R2/C4 (A).**
- **Identity (nv).** If it is Improved Ghost Wolf, Turtle has 2 ranks
  (−1/−2 s) in the DB, while the owner describes **3** ranks with an instant
  cast at rank 3.
- **Change:** a new third rank (a new ID, **as a talent it needs `Talent.dbc`,
  so phase 2**) or re-cut values on the existing 2 ranks (A: rank 2 = full cast
  time).
- **Recommendation:**
  - owner confirms which talent it is (O-1);
  - in phase 1, rank 2 gets the full cast-time reduction, because that needs no
    new slot;
  - the 3-rank split comes in phase 2.
- **Test:** the Ghost Wolf cast time with the full rank is 0.

**R4/C1 Imbue mastery (B).**
- **Change:** three passives with aura 108 (percent spell mod) on the imbue
  mask `0x1E00000` (Flametongue, Frostbrand, Windfury, Rockbiter passive).
- **Caveats:**
  - **`SPELLMOD_ALL_EFFECTS` on the Rockbiter passive `10400` would also raise
    its effect 2 (+35 % threat) to about +38 %.** Either that is accepted, or
    Rockbiter is handled in the script (only the AP effect 1).
  - The Rockbiter damage proc `20865`… (Turtle, `spell_shaman_rockbiter_proc`)
    has **mask 0**, so the mask does not reach it. It needs a script or a
    changed `spellFamilyFlags` (route A, also affects players).
  - The Windfury AP bonus sits in `8233` effect 1 (`bp 45`).
- **Test:** per imbue, damage, AP or chance is +9 % at 3/3 compared with 0/3.
  Rockbiter threat stays +35 % unless O-5 says otherwise.

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
- **Balance:** at 5 stacks Lightning Bolt is **instant and free** (−100 %
  cost). Maelstrom only affected cast time (O-9).
- **Duration:** open (O-9).
- **Test:** 5 stacks → Lightning Bolt cast time 0 and cost 0 (or the value
  from O-9); the stacks are gone after the cast.

**R6/C4 Shield constitution (B + script).**
- **Change:** three passives. A script sets the stamina percentage =
  rank × current Lightning Shield charges.
- **Hook:** `OnAuraChargesChanged` exists (`ScriptMgr.h` l.1451) but is only
  fired at `Unit.cpp` l.4957 (proc charge drop). Paths that call
  `SetAuraCharges` directly (Undertow, R4/C4) must fire it too, or the script
  recomputes on every shield event.
- **Maximum:** with Stable Shields 3/3 there are 3 + 6 = **9 charges**, so
  **+27 % stamina** (O-7).
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
- **Maximum:** 9 charges = **−18 % damage taken**. That is more than Defensive
  Stance `7376` (−10 %) (O-7).
- **Test:** as for R6/C4.

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
| Windfury | trigger `52969` "Rushing Winds" (aura 9 MOD_ATTACKSPEED) | **+1 % per stack, 6 stacks** (R1 2, R2 4, R3 6) | **+3 %** for 5 s, **max 2 stacks** | `52969` value 1 → 3, `stackAmount` 6 → 2. **The maximum stays 6 %**; only the build-up changes |
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
excludes the shaman. An override is possible through
`skill_race_class_info_mod`, but it also opens swords to players at the weapon
masters.

## 6. Bot logic (mod-playerbots)

Nothing here is implemented. Code lives in twow-core `modules/mod-playerbots/`.

### 6.1 Role and paths

- **Path 7.1 `enhancement` stays the melee DPS path.**
  - It gets the column-1 auras (R1/C1, R4/C1, R6/C1, R7/C1) through
    ClassGrant.
  - Route-A changes apply to it automatically.
- **Path 7.3 `tank` is new.** It follows the bear 11.3 pattern (#308):
  - `AiPlayerbot.PremadeSpecName.7.3 = tank` plus links generated with
    `tools/build_premade_specs.py`. The picks are Shield Specialization, Spirit
    Armor, Ancestral Guardian, Stable Shields, Elemental Weapons and
    Stormstrike, and **no** Calming Winds. The exact link is **(nv)**.
  - It gets the column-4 auras (R1/C4, R4/C4, R6/C4, R7/C4).
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
- `CanEquipWeapon` (~l.2903) stays for 7.3 at mace, axe or fist weapon (no
  swords, see O-13).
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
   `58130`), R2/C4, Stormstrike, plus the code changes: Earthen Bulwark cap
   (`SS` ~l.376) and the Stormstrike charge script.
2. **twow-core, route B data and scripts.** The new passives in `90100`–`90199`,
   `spell_proc_event` rows, and AuraScripts for R4/C4, R6/C1 (+R7/C1) and
   R6/C4 + R7/C4 in `SS`.
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
| O-1 | Which talent is R2/C4 (purple, 3 ranks, instant at rank 3)? | Owner confirms from the client; working assumption Improved Ghost Wolf. Phase 1: rank 2 = instant; 3 ranks in phase 2 |
| O-2 | Attack speed R1/C1: +2 %/rank as a flat haste aura — also for 7.3? | yes, 7.1 and 7.3 (a tank gets more Rockbiter/bulwark procs) |
| O-3 | Defense R1/C4 +6/rank = +30 (warrior +20) | take the owner value; measure in 5-man |
| O-4 | Imbue mastery R4/C1: which quantity per imbue is "more effective" (Flametongue damage, Frostbrand damage, Windfury AP, Rockbiter AP and/or bulwark)? | damage/AP/bulwark +3 %/rank, **not** threat and **not** proc chance |
| O-5 | Imbue mastery raises Rockbiter threat to ~38 % if applied flatly | no: threat stays 35 % (script only on the AP effect) |
| O-6 | Retaliation R4/C4: internal cooldown of the free shield proc | 3 s shared with Lightning Shield |
| O-7 | Charge scaling R6/C4 and R7/C4 at 9 charges (Stable Shields 3/3): +27 % stamina, −18 % damage taken | cap the count at **5 charges** (≤ +15 % stamina, ≤ −10 % damage taken = Defensive Stance), or leave Stable Shields out of path 7.3 |
| O-8 | Stormstrike R5/C4: damage per consumed charge, school | the damage of the active shield rank's proc per charge, Nature (like Lightning Strike) |
| O-9 | Storm wisdom R6/C1: −20 % cost per stack (free at 5)? duration? | cast time −20 %/stack as the owner wants, cost −10 %/stack (−50 % max), duration 30 s |
| O-10 | Elemental Weapons ranks 1/2 and the unclear Frostbrand value (25/50) | Flametongue 17/33/50, Frostbrand 16/33/50, Windfury +1/+2/+3 % × 2 stacks, Rockbiter build 10/20/30, absorb 15/20/25 |
| O-11 | Tank Stormstrike threshold | only at ≥ 4 charges, and only while the tank has aggro |
| O-12 | Point budget of the bot auras (section 2) | 7.1 = column 1, 7.3 = column 4; each premade link gives up the same number of points |
| O-13 | Earlier brief wishes that are **not** in the owner line: extra attack 5 × 2 %, magic damage reduction, sword skill, a dedicated AoE threat ability | drop them in phase 1: attack speed replaces the extra attack, AoE runs through Totemic Alignment + Magma Totem, swords would affect players (phase 2). The owner confirms |
| O-14 | New spell ID range | `90100`–`90199`, after a one-time check against the client `Spell.dbc` **(nv)** |
| O-15 | Share of path 7.3 in the roster | Prob 30 until the acceptance run passes (together with #366) |

## 9. What this document does not do

- No spell, item, trainer, DBC, SQL, config or core change.
- No build: `BUILD_REQUIRED=NO`, docs only.
- Talent positions and ranks as the client shows them, tooltips, durations, and
  client spell ID collisions are **(nv)**. They must be checked against the
  client data before step 1 of section 7.
