# Enhancement shaman as a tank variant: phase 1 design (bots first)

Refs #357. Status: **design only**. This document changes no spell, DBC, SQL or
core code. It follows the owner decision of 2026-09-27 (#357, #367):

- **Phase 1 is bots only.** The tank abilities are **server-side passive
  spells/auras**, granted automatically by level and spec. There is **no client
  patch**.
- **Phase 2** (a real 4th talent tree "Tank" with a client patch) follows only
  if phase 1 works.

Every change below is a proposal that needs the owner decisions in
[section 6](#6-owner-decisions) first. The spell/rule part is a rule and
balance change (OB-20); the bot part belongs to OB-10.

Related: #367 (rogue tank, same approach, [rogue-tank.md in PR
#386](https://github.com/Cilverkrow/twow-repo/pull/386)), #356 (auto-learn and
ClassGrant), #308 (premade paths, bear 11.3, role-aware gear).

## 1. Evidence base

All numbers below were read from data or code. None are recalled from memory.

- **World data.** The source is the world data in `Cilverkrow/twow-core` at
  `main` = `e50b648`: `sql/base/tw_world_*.sql`, then
  `sql/database_updates/world/*.sql` and the top-level
  `sql/database_updates/*.sql`. It was loaded into a throwaway local MariaDB
  10.11, queried read-only, and discarded afterwards. The load order differs
  slightly from `setup_databases.sh`. That does not matter for the rows quoted
  here.
- **Tables used:** `spell_template`, `spell_proc_event`, `spell_threat`,
  `npc_trainer`, `creature_template`, `skill_line_ability`,
  `skill_race_class_info_mod`, `playercreateinfo_spell`.
- **Code references** point to the same twow-core commit. Paths to the bot
  module are relative to `modules/mod-playerbots/src/playerbot/`.

**Reading convention.** A spell's effective value is `effectBasePoints + 1`,
because every row quoted here has `effectDieSides = effectBaseDice = 1`. For
example, Spirit Armor `bp2 = 4` means +5 %.

**Not verifiable here.** These are client data and are not in Git (see
`docs/EXTERNAL-REQUIREMENTS.md`):

- `Talent.dbc` / `TalentTab.dbc`: which tree, row and column a talent sits in,
  and therefore the exact premade talent links.
- `SkillRaceClassInfo.dbc`: whether shamans may use swords at the DBC level.
- `Spell.dbc`: which spell IDs the client already uses, and how the client
  shows unknown aura IDs.

Every statement that depends on these files is marked **(not verifiable)**.

## 2. What Turtle 1.18 already has

### 2.1 Enhancement tank talents (spell data)

The talents exist in `spell_template`. Their tree position is **not
verifiable** (see 1).

| Talent | IDs (ranks) | Effect (effective values) |
|---|---|---|
| Shield Specialization | `16253`, `16298`, `16299`, `16300`, `16301` | aura 51 MOD_BLOCK_PERCENT **+1/2/3/4/5 % block**; aura 150 MOD_SHIELD_BLOCKVALUE_PCT **+6/12/18/24/30 % block value** |
| Stable Shields | `16261`, `16290`, `16291` | aura 107 on Lightning Shield (class mask `0x400`): SPELLMOD_CHARGES **+2/4/6 charges**, SPELLMOD_PROC_COOLDOWN (29) **+1 s** between shield procs |
| Spirit Armor | `45951`, `45952` | **only while a shield is equipped** (`equippedItemClass 4`, subclass mask `64`): **+15/30 % armor from shields**, aura 10 MOD_THREAT **+5/10 % threat** (all schools); core script `spell_spirit_armor` |
| Ancestral Guardian | `45545`, `45546`, `45547` | aura 142 **+5/10/15 % armor from items**; aura 49 **+2/4/6 % dodge** |
| Elemental Weapons, Rockbiter part | `16266`, `29079`, `29080` | "Physical damage builds up an Earthen Bulwark … **tripled while wearing a shield**"; absorb `58128`–`58130`; scripted in `src/scripts/spells/spell_shaman.cpp` (`spell_shaman_elemental_weapons`, `spell_shaman_earthen_bulwark`) |
| Toughness (shaman) | `16252`, `16306`, `16307`, `16308`, `16309` | +2/4/6/8/10 % armor from items (whether Turtle still uses it next to Ancestral Guardian is **not verifiable**) |

Two talents work **against** a tank: Calming Winds (`51383`–`51385`,
**−8/16/25 % threat** from physical attacks and weapon imbues, scripted as
`spell_shaman_calming_winds`), and Windfury-focused picks. A tank path must
not take Calming Winds.

### 2.2 Taunt: Earthshaker Slam `51365`

| Field | Value |
|---|---|
| Effects | effect 114 ATTACK_ME + aura 11 MOD_TAUNT (same shape as Taunt `355`, Growl `6795`) |
| Requirement | **shield equipped** (`equippedItemClass 4`, subclass mask `64`) |
| Cooldown | 10 s (`category 82`, `categoryRecoveryTime 10000`) |
| Range / cost | melee (`rangeIndex 2`), **no mana cost** |
| Level | `spellLevel 10`; taught by `51366` at **10 of 14 shaman trainers**, `reqlevel 10`, 400 copper. The four without it are Meela Dawnstrider, Narm Skychaser, Shikrik and Swart, which are starting-area trainers. |
| Skill line | Enhancement (373), `skill_line_ability` row `6470` (`database_updates/world/20260513084003_world.sql`) |

Since train 5 (`AiPlayerbot.AutoLearnTrainerSpells = 1`, #356), shaman bots
**already learn Earthshaker Slam at level 10**. No mod-playerbots code uses it
yet (`51365` does not appear in the module source).

### 2.3 Lightning Shield

| Rank | Spell | Level | Nature damage per proc (damage spell) | Mana |
|---|---|---|---|---|
| 1 | `324` | 8 | 13 (`26364`) | 40 |
| 2 | `325` | 16 | 29 (`26365`) | 70 |
| 3 | `905` | 24 | 51 (`26366`) | 105 |
| 4 | `945` | 32 | 80 (`26367`) | 150 |
| 5 | `8134` | 40 | 114 (`26369`) | 200 |
| 6 | `10431` | 48 | 154 (`26370`) | 255 |
| 7 | `10432` | 56 | 198 (`26363`) | 310 |

- **Mechanics.** Every rank is aura 42 PROC_TRIGGER_SPELL with 3 charges and
  `procFlags 139944` (hit taken). It has a 3 s internal cooldown
  (`spell_proc_event.Cooldown = 3`) and lasts 10 min.
- **Core handling.** The proc is handled by the AuraScript
  `spell_shaman_lightning_shield` (`spell_shaman.cpp` ~l.783). It maps rank to
  damage spell in `GetLightningShieldDamageSpell` (~l.495) and casts that spell
  on the attacker. Each proc spends one charge.
- **Related Turtle pieces:**
  - Thunderhead `45508` (cast on allies).
  - Lightning Strike `51387`/`52420`/`52422`, which consumes shield charges
    through `52679` "Trigger Elemental Shield".
  - Lightning Shield Trigger Passive `51868`.
  - Shaman Shield Charges Bonus `51892` (+2 charges, item bonus).
- **Charge-restore pattern.** The core already restores a shield charge in
  exactly one place: **Undertow** (`51372`/`51373`, AuraScript
  `spell_shaman_undertow`, `spell_shaman.cpp` ~l.1045). It adds one charge to
  the active Water Shield up to its maximum and refreshes the holder. That is
  the pattern for the owner's shield focus (3.2 S-2).

### 2.4 Sword skill (skill line 43)

- **In the world DB, shamans are excluded from swords.** `skill_line_ability`
  row `5` (skill 43, spell `201` One-Handed Swords) has `class_mask 399` =
  warrior, paladin, hunter, rogue, mage, warlock. Shaman is bit 64. Two-Handed
  Swords (row `7`, spell `202`) has `class_mask 7`.
- **Shaman weapons today:**
  - `class_mask` includes 64 for axes (`79`), maces (`1115`), fist weapons
    (`1101`), daggers (`1501`), staves (`1493`) and shield (`9116`, `67`).
  - `playercreateinfo_spell` gives shamans 2H axes/maces, maces, staves,
    Shield `9116`, Block `107` and Defense `204` at creation.
- **Weapon masters.** One-Handed Swords is taught by `1847` at two weapon
  masters only (Woo Ping `11867`, Archibald `11870`, `reqlevel 0`, 1000
  copper).
- **The DB can override the DBC gate.** The core reads
  `skill_race_class_info_mod` on top of `SkillRaceClassInfo.dbc`
  (`src/game/Spells/SpellMgr.cpp`, `LoadSkillRaceClassInfoMap` ~l.2670). A row
  whose id is not in the DBC is accepted when every field is set explicitly
  (no `-1`). Leftover overrides are inserted after the DBC loop (~l.2768). The
  only override today is Dual Wield (`132`).
- **Bot factory.** `PlayerbotFactory::CanEquipWeapon` (~l.2903) allows only
  mace/fist/axe/2H axe/2H mace for enhancement shamans, and `InitSkills`
  (~l.4121) gives shamans no sword skill.

So "swords for shamans" is a **server-data change** (one `skill_line_ability`
class mask plus one `skill_race_class_info_mod` row) plus **bot-factory
changes**. The DBC row it overrides is **not verifiable**.

### 2.5 Reusable spells and auras

| Need | Existing template | Data |
|---|---|---|
| Defense passive | Anticipation (warrior, Turtle) `12297`/`12750`/`12751` | aura 98 MOD_SKILL_TALENT, skill 95 Defense, **+7/14/20** |
| Extra attack on hit | Hand of Justice `15600` → `15601` | aura 42, `procFlags 20` (melee auto hit + melee ability hit), **2 %**, 1 extra attack; no weapon restriction |
| Extra attack, weapon-bound | Sword Specialization `12281`… / Sword Master `51664`–`51668` (1–5 %), Hack and Slash `13960`/`13961` | same, but `equippedItemSubClassMask` sword (and axe) |
| Magic damage reduction | Spell Warding (priest) `27900`/`27901`/`27902` | aura 87 MOD_DAMAGE_PERCENT_TAKEN, school mask 126 (all magic), **−3/−6/−10 %** |
| Magic reduction tied to the shield | Elemental Shell `51847`/`51848` | −4 % spell damage per shield trigger, 3 stacks; **no `script_name`**, so the core probably does not implement it (a dummy aura) |
| Block proc | warrior Shield Specialization `12298` | aura 42, `procFlags 680` (hits taken), `spell_proc_event.procEx = 64` (PROC_EX_BLOCK), 100 % |
| Threat multiplier | Rockbiter Weapon passive `10400` … `16313` | **+35 % threat** (aura 10, all schools) while the imbued weapon is equipped; enchantment type TOTEM is shaman-only (`Player.cpp` ~l.14042) |
| Single-target threat | Earth Shock `8042` … `10414` (L4 … L60) | `spell_threat.multiplier = 2` (×2 threat) |
| Totem threat to the shaman | Totemic Alignment `51379`/`51380` (auras on the totem) via `51381`/`51382` | aura 200 TRANSFER_TOTEM_THREAT, **45/90 %** of totem threat moves to the owner; implemented in `ThreatManager::addThreat` (`src/game/Threat/ThreatManager.cpp` ~l.437) |
| AoE damage | Magma Totem `8190`… (trainer L26), Fire Nova Totem `1535`… (L12), Earthquake `48306`/`48307`/`48308` (L40/50/60, 16 s cooldown, scripted) | AoE threat only through damage, or totems with Totemic Alignment |
| AoE threat templates | Thunder Clap `6343`/`8198`/`11580` (`spell_threat` +17/+40/+143 flat), Challenging Shout `1161` (AoE taunt, 10 min), Consecration `26573` | none of them is a shaman spell |
| Self-heal shield | Earth Shield `45525`/`51525`/`51526` (trainer L40/48/56) | self-only elemental shield; mutually exclusive with Lightning Shield |

### 2.6 Threat calibration

| Tank | Multiplier (from `spell_template`) |
|---|---|
| Protection warrior | Defensive Stance `7376` +30 % × Defiance 5/5 `12792` +20 % ≈ **1.56×** |
| Bear | Bear Form passive `21178` +30 % ≈ **1.30×** (plus feral talents, **not verifiable**) |
| Paladin | Righteous Fury `25780` +60 % (holy only) |
| **Enhancement shaman with shield** | Rockbiter +35 % × Spirit Armor 2/2 +10 % ≈ **1.49×**, plus Earth Shock ×2 |

The shaman **already reaches warrior-class threat** with existing data, as long
as the tank uses **Rockbiter, not Windfury**, carries a shield, and skips
Calming Winds. So phase 1 needs **no new threat multiplier**. The missing
pieces are mitigation, the owner's shield focus, and AoE threat.

## 3. Phase 1 spell list

### 3.1 Principles

- **Bots only.** New spells get **no `npc_trainer` rows**, so players never
  learn them. Bots get them through a spec-gated grant (3.3).
- **Passive and hidden.** Every new aura copies the talent attributes
  (`attributes 464` = passive, hidden client-side, not in the combat log), as
  on `16253`/`45545`. Whether a client shows an unknown hidden passive aura on
  an inspected bot is **not verifiable** without `Spell.dbc`. The expected
  answer is no.
- **New IDs from one project range.** The largest `spell_template.entry` today
  is `90006`. Proposal: reserve **`90100`–`90199`** for twow custom spells.
  Collisions with client `Spell.dbc` IDs are **not verifiable** here and must
  be checked once.
- **Talents stay where they are.** In phase 1 the existing Enhancement talents
  (2.1) stay in Enhancement. The tank path takes them through its premade
  talent link (4.1). The owner's plan to move them out of Enhancement and add
  offensive replacements is **phase 2**, because it changes the client talent
  tree.
- **Data first, one small script.** Everything except S-2 is `spell_template`
  plus `spell_proc_event` data. S-2 needs one AuraScript in twow-core
  `spell_shaman.cpp` (a copy of Undertow).

### 3.2 The list

| # | Name (working title) | Function | Source | Level / ranks | Numbers (proposal) | How the bot gets it |
|---|---|---|---|---|---|---|
| S-1 | **Earthshaker Slam** (taunt) | single-target taunt | **existing** `51365` | L10, 1 rank | as shipped: 10 s cooldown, shield required, no mana | trainer, already live via `AutoLearnTrainerSpells` (#356) |
| S-2 | **Stormguard** (shield focus) | when the shaman **blocks**, Lightning Shield **gains one charge** (capped at its maximum) instead of losing one | **new** passive, base `12298` (block-proc shape: `procFlags 680`, `spell_proc_event.procEx 64`), plus `script_name` for a new AuraScript copied from `spell_shaman_undertow` that works on the active Lightning Shield | L10, 1 rank | +1 charge per block, 100 %; cap = rank charges + Stable Shields; internal cooldown 3 s (same as the shield) | spec grant 7.3 |
| S-3 | **Sword skill** | shamans may use one-handed swords | **data**: `skill_line_ability` row `5` `class_mask 399 → 463`, plus a `skill_race_class_info_mod` row for skill 43 with shaman in `ClassMask` | L1 | 1H only (2H swords stay excluded: a tank carries a shield) | skill `201` via spec grant 7.3; factory changes (4.4). The data rows also affect players through the weapon masters (decision D-4) |
| S-4 | **Elemental Fury of Arms** (extra attack) | chance for one extra attack on a white hit **or** a melee ability | **new** passive, 5 ranks, base `15600` (`procFlags 20`) → existing `15601` | L20/28/36/44/52 | **2/4/6/8/10 %** (owner: 5 × 2 %) | spec grant 7.3 |
| S-5 | **Earthen Resolve** (defense) | + Defense skill | **new** passive, 5 ranks, base `12297` (aura 98, skill 95) | L12/24/36/48/60 | **+6 per rank, +30 total** (owner), see D-3 | spec grant 7.3 |
| S-6 | **Grounding Skin** (magic) | less magic damage taken | **new** passive, 3 ranks, base `27900`–`27902` (aura 87, school mask 126) | L30/45/60 | **−3/−6/−10 %** (priest parity) | spec grant 7.3 |
| S-7 | **AoE threat**, variant A (recommended) | totem damage threat counts for the shaman | **existing** Totemic Alignment `51381` (45 %) / `51382` (90 %) as auto-granted passives, used with Magma Totem (L26) and Fire Nova Totem (L12) | R1 L26, R2 L40 | 45 % / 90 % transfer | spec grant 7.3; rotation (4.2) |
| S-7b | **AoE threat**, variant B (option) | active AoE threat ability | **new** "Earthshaker Stomp", base Thunder Clap `6343` (school Nature, no attack-speed debuff, mana cost) + `spell_threat` row | L20/40/60 (3 ranks) | 8 yd, 6 s cooldown, damage like Thunder Clap, flat threat +40/+90/+150 | spec grant 7.3 |
| S-8 | Spirit Armor, Shield Specialization, Ancestral Guardian, Stable Shields, Elemental Weapons | shield armor, threat, block, dodge, bulwark | **existing talents** (2.1) | talent levels | as shipped | premade path 7.3 (tree position **not verifiable**) |

What is **not** on the list:

- **No new threat multiplier.** Rockbiter plus Spirit Armor gives 1.49× (2.6).
- **No change to Lightning Shield itself.** S-2 is a separate aura, so
  enhancement DPS shamans and players are unaffected.

### 3.3 Grant mechanism (bots only)

- **Where it hooks in.** The grant builds on #356 "ClassGrant"
  (twow-core draft PR
  [#163](https://github.com/Cilverkrow/twow-core/pull/163), not merged; the
  name does not exist on `main` yet). That PR already has a level-up hook, a
  catch-up at login, idempotence, `[ClassGrant]` logging, and the switch
  `AiPlayerbot.ClassGrant.Enabled` (default 0).
- **Proposed extension.** An explicit table
  `{class, premade path name, level, spell}` that runs only for bots whose
  `specNo` resolves to the premade path `tank` (the same lookup as
  `IsBearSpec`, `AiFactory.cpp` ~l.27).
  - At each level-up the bot learns all rows up to its level.
  - Higher ranks replace lower ones (`learnSpell` + `removeSpell` of the
    previous rank).
- **Path change.** When a bot leaves the tank path (a forced role change, or
  `ChangeTalentsAction`), the rows are removed again, again idempotently.
  Without this a DPS shaman would keep Defense +30. See D-6.
- **Fail closed.** With the switch off, or the path not `tank`, nothing is
  granted and the shaman plays as today (ADR-0024 invariants 4 and 6).

## 4. Bot logic (mod-playerbots)

Code lives in `Cilverkrow/twow-core`, `modules/mod-playerbots/src/playerbot/`.
Nothing here is implemented. It is the plan for a later PR there.

### 4.1 Role mapping and premade path 7.3

Today:

- `AiFactory::GetPlayerRoles(cls, tab)` (~l.211) makes shaman tab 2 HEALER and
  everything else DPS. There is no tank.
- `AddDefaultCombatStrategies` (~l.403) gives tab 1 `enhancement, aoe, cc,
  close` plus `dps assist, cure, totems, buff, boost` for all shamans.

The shaman tank is an Enhancement build, so the tree cannot tell it apart.
It follows the **bear 11.3 pattern** (#308):

- **New path.** Add `AiPlayerbot.PremadeSpecName.7.3 = tank` plus links for
  levels 10…60 in `aiplayerbot.conf.dist.in`, generated and validated with
  `modules/mod-playerbots/tools/build_premade_specs.py` (add BUILDS[7] and
  PROBABILITY). The picks are Shield Specialization 5/5, Spirit Armor 2/2,
  Ancestral Guardian 3/3, Stable Shields 3/3, Elemental Weapons, the armor
  talents, and **not** Calming Winds. The exact link needs `Talent.dbc`
  **(not verifiable)**.
- **Spec check.** Add `IsShamanTankSpec(player)` next to `IsBearSpec`
  (`AiFactory.cpp` ~l.27), reading `specNo` the same way.
- **Decision order** (as for the feral druid, ~l.475): the forced role wins
  (`GetForcedRole() & BOT_ROLE_TANK`), then the premade path.
- **`GetPlayerRoles(const Player*)`** (~l.302) returns `BOT_ROLE_TANK` for a
  shaman on path `tank`. `PlayerbotAI::IsTank` (`PlayerbotAI.cpp` ~l.2784)
  then works unchanged via `STRATEGY_TYPE_TANK`.
- **Required fix.** `ChangeTalentsAction::getPremadePaths`
  (`strategy/actions/ChangeTalentsAction.cpp` ~l.170) filters paths with
  `GetPlayerRoles(cls, highestTree) != role`. A forced-tank shaman therefore
  matches **no** path today, because tab 1 maps to DPS. The filter has to
  accept path 7.3 for `BOT_ROLE_TANK`, for example through a path-name-to-role
  map ("tank" → TANK).
- **Below level 10** (no taunt, no talents) the tank path plays as
  `enhancement` DPS, as the druid does below bear form.
- **Combat engine for a shaman tank:**
  `"tank shaman", "tank assist", "pull", "pull back", "close", "totems", "cure", "buff", "boost"`
  — **without** `dps assist` and without the generic `enhancement` strategy.

The PvP/BG block (~l.713) and the free-bot override (~l.602) need the same
branch. The bear flip at ~l.602–615 looks inverted and should not be copied.

### 4.2 `tank shaman` strategy

This is a new `TankShamanStrategy` (`strategy/shaman/TankShamanStrategy.{h,cpp}`)
with `GetType()` = `STRATEGY_TYPE_TANK | STRATEGY_TYPE_MELEE`. It is registered
as `"tank shaman"` in `ShamanAiObjectContext.cpp`, next to `enhancement`
(~l.221). `SPEC_COMPOSE_*` (`strategy/SpecComposition.h`) exists but no spec
uses it, so follow the plain pattern of `TankFeralDruidStrategy`.

Triggers, by priority:

| Priority | Trigger | Action |
|---|---|---|
| EMERGENCY | `critical health` | `lesser healing wave` on self, then `healing wave` (no healer in the group, or the healer is out of mana) |
| EMERGENCY | `has blessing of salvation` | remove it (as for the protection warrior) |
| MOVE+4 | `lose aggro` (`GenericTriggers.cpp` ~l.53) | **`earthshaker slam`** (new action for spell `51365`; requires a shield, so the action's `isUseful` checks for a shield) |
| MOVE | `taunt on snare target` | `earthshaker slam` |
| HIGH+5 | `lightning shield` (buff missing, existing trigger ~l.260) | `lightning shield` (**not** Earth Shield or Water Shield on the tank path) |
| HIGH+4 | `shaman weapon` (~l.258) | **`rockbiter weapon`** as the first choice (the enhancement chain `windfury weapon → rockbiter weapon`, `EnhancementShamanStrategy.cpp` ~l.38, is reversed for the tank) |
| HIGH+3 | `enemy is casting` / `wind shear` | `earth shock` (interrupt, ×2 threat) |
| HIGH+2 | ≥ 3 attackers (`medium aoe`) | `magma totem`, below L26 `fire nova totem` (threat through Totemic Alignment, S-7); variant S-7b: `earthshaker stomp` |
| HIGH+1 | `shock` (Earth Shock debuff / cooldown ready) | `earth shock` (threat rotation) |
| NORMAL+1 | `stormstrike` (~l.292) | `stormstrike`, or `lightning strike` from L20 (consumes shield charges, so it runs only when Lightning Shield has ≥ 2 charges) |
| NORMAL | default | melee |

Never: `windfury weapon` (it replaces Rockbiter and loses 35 % threat),
`frost shock` on the tanked target (it wastes mana), `ghost wolf` in combat,
or `purge` before the taunt.

Totems: keep `totems` with tank-friendly defaults. The earth totem is
Stoneskin, not Strength of Earth when the group has a warrior. In AoE, the fire
totem is Magma or Fire Nova. **Searing Totem** threat also counts through
Totemic Alignment.

### 4.3 Pull

`pull` is Lightning Bolt for shamans today (`ShamanAiObjectContext.cpp`
~l.25). A tank pull with Lightning Bolt followed by `earthshaker slam` in
melee is fine. No change is needed.

### 4.4 Equipment and skills

Today, every rule below keeps a shield away from an enhancement shaman:

- `PlayerbotFactory::CanEquipWeapon` (~l.2903): enhancement is mace, fist,
  axe, 2H axe or 2H mace, and never a sword.
- `RandomItemMgr` (~l.668–687): `enhance` has 2H main hands and **no
  `oh_weapons`**, so no shield.
- The tank off-hand filter (`PlayerbotFactory.cpp` ~l.3463) only applies to
  `specId == 3 || 5` (warrior and paladin protection).

For path 7.3:

- **Main hand.** One-handed mace, axe or fist weapon. **Swords** only after S-3
  and decision D-4.
- **Off hand.** **Shield only.** Add the shaman tank spec id to the filter at
  ~l.3463.
- **Skills.** `InitSkills` (~l.4121) adds `SKILL_SWORDS` for path 7.3 once
  S-3 exists.
- **Item filter.** `RandomItemMgr` gets a new weight scale `shamantank`
  (class 7) with `mh_weapons = {AXE, MACE, FIST[, SWORD]}` and
  `oh_weapons = {SHIELD}`.

### 4.5 Stat priorities (#308)

- **Where weights live.** Weights are DB-driven
  (`modules/mod-playerbots/sql/world/classic/ai_playerbot_weightscales.sql`).
  Proposal: a new spec **`shamantank`** next to `prot` (3), `prot` paladin (5)
  and `feraltank` (30). `RandomItemMgr::GetPlayerSpecName` (~l.2597) returns
  it for path 7.3.
- **Why this order:**
  - A shaman tank's avoidance comes from **block** (Shield Specialization) and
    **armor** (Spirit Armor, Ancestral Guardian).
  - **Strength** raises block value and attack power.
  - **Intellect** keeps the shields, shocks and totems going.
  - **Agility** gives less than it does for a bear.

| Role | Priority |
|---|---|
| shaman tank | Stamina > Defense > Armor > Block value > Block chance > Strength > Intellect > Hit > Agility > Attack power > Spell damage (Nature, for Lightning Shield and Earth Shock) |

Weapons: a slow one-handed main hand. Rockbiter adds per swing, and a slow
weapon gives more threat per hit and more Earthen Bulwark per hit.

### 4.6 Tests

- **Source contract,** like `t/bear_path_source_contract_tests.cmake`.
  - The config has `PremadeSpecName.7.3 = tank`.
  - `AiFactory.cpp` has the same number of `IsShamanTankSpec(player)` branches
    in each place where `IsBearSpec` is checked.
  - `tank shaman` never adds `dps assist` or `windfury weapon`.
  - `getPremadePaths` returns 7.3 for `BOT_ROLE_TANK`.
- **Policy tests:**
  - role mapping for path 7.3 with and without a forced role;
  - the grant table (level gating, rank replacement, removal on path change,
    switch off grants nothing);
  - the shield off-hand filter.
- **Runtime acceptance** (5-man test groups): the shaman tank holds threat on
  1 and 3+ targets, and there is no regression for enhancement DPS on paths
  7.0–7.2.

## 5. Delivery plan (after the decisions)

1. **twow-core, world data (OB-20).**
   - `spell_template` rows for S-2, S-4, S-5, S-6 (and S-7b), in the project ID
     range, plus `spell_proc_event` rows for S-2 (procEx BLOCK) and S-4.
   - Optionally the S-3 rows in `skill_line_ability` and
     `skill_race_class_info_mod`.
   - Forward-only migrations under `sql/database_updates/world/`.
2. **twow-core, spell script.** The S-2 AuraScript (copy of
   `spell_shaman_undertow` for the active Lightning Shield) in
   `src/scripts/spells/spell_shaman.cpp`, with `script_name` in the S-2 row.
3. **twow-core, mod-playerbots (OB-10).** Grant table (3.3), path 7.3,
   `IsShamanTankSpec`, `TankShamanStrategy`, the Earthshaker Slam action,
   equipment and weights, and tests.
4. **twow-repo.** Pin bump, then the funserver-test overlay (`ClassGrant`
   switch on).

Each step builds on the previous one and can be tested alone. Step 3 works
without step 1 at reduced strength (taunt, Rockbiter and existing talents
only). That is a reasonable first measurement.

## 6. Owner decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D-1 | Shield focus S-2 | (a) block → +1 Lightning Shield charge (capped); (b) block → shield damage fires **without** spending a charge; (c) both | **(a)**: it is exactly the Undertow mechanic (one small script), and threat still comes from the normal shield procs. (b) needs its own internal cooldown so blocks do not bypass the 3 s shield cooldown |
| D-2 | Extra attack S-4 | 5 × 2 % (owner) on white hit and ability / only white hits / sword-only like Sword Master | **5 × 2 % on white hit and ability, any weapon** (Hand of Justice shape). Up to 10 % at L52. Watch the interaction with Hand of Justice and Windfury in measurement (the tank uses Rockbiter, so Windfury does not apply) |
| D-3 | Defense S-5 | +6 × 5 = +30 (owner) / +4 × 5 = +20 (warrior Anticipation parity) | **+30 as the owner wants**, because the shaman has no Defensive Stance −10 % damage taken. Measure crit immunity in 5-man and raise or lower after that |
| D-4 | Sword skill S-3 | (a) skip swords in phase 1 (tank uses mace, axe or fist weapon + shield) / (b) server data rows from S-3; these also let the two weapon masters teach swords to **player** shamans, so it is a rule change for everyone, and how the client shows it is **not verifiable** / (c) bots only: the factory gives path 7.3 the skill without the data rows; whether the core accepts a skill the class/race table does not allow is **not verified** | **(a) in phase 1**: a shield tank loses little without swords (maces, axes and fist weapons are available), and it needs no rule change for players. Swords come in phase 2 together with the client patch. If the owner wants swords now: **(b)**, as a conscious rule change |
| D-5 | AoE threat S-7 | A: Totemic Alignment + Magma/Fire Nova (existing spells) / B: new "Earthshaker Stomp" / both | **A first**: no new active spell, and the core already implements it. Build B only if the 5-man measurement shows AoE threat is too low |
| D-6 | Grant lifetime | granted spells stay after a path change / are removed | **removed** (idempotent), otherwise a DPS shaman keeps tank passives |
| D-7 | Magic reduction S-6 | −3/−6/−10 % (priest parity) / −5/−10/−15 % / none in phase 1 | **−3/−6/−10 %** |
| D-8 | New spell ID range | `90100`–`90199` / another range | **`90100`–`90199`**, after a one-time check against the client `Spell.dbc` **(not verifiable here)** |
| D-9 | Share of the roster | how many shamans get path 7.3 (bear 11.3 has probability 50) | decide together with #366; proposal: **Prob 30** until the acceptance run passes |
| D-10 | Earthshaker Slam in the starting areas | leave it (4 of 14 trainers lack it) / add it | **leave it**: bots learn trainer spells without a trainer visit (#356), so it does not matter for bots |

## 7. What this document does not do

- It makes no spell, item, trainer, DBC, SQL or core change, and no config
  change.
- It runs no build: `BUILD_REQUIRED=NO`, docs only.
- The talent-tree positions, the client spell ID collisions, and the DBC
  sword gate are **not verifiable** here (section 1). They must be checked
  against the client data before step 1 of section 5.
