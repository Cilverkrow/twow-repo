# Code-side values

Some values that the client shows or predicts live in **code or config**, not
in `spell_template`. Neither `sql:` delta values nor the
`spell-matches-server` consistency rule can see them, so they are kept here
by hand (design 3.4, OB-20 review). Every tooltip delta that uses one of them
cites the entry id in its `note` column.

Stage 2 pins each source to file and line at a pinned twow-core commit.
The rogue entries CV-2 and CV-4 to CV-10 are pinned at twow-core `15fc5da4` (#367).
CV-4 to CV-10 are taken by the rogue change (#367, #433); the shaman entries
(CV-1, CV-3, CV-11 onwards, #357) continue at CV-11 so the two changes do not
collide. CV-14 to CV-16 are riding and player snares (#295, train 9); they name
file and function on the core branch `feat/295-riding-stages`, and the line pin
follows with the train-9 core commit.

| id | spell | value | source | player-visible |
|---|---|---|---|---|
| CV-1 | Earthen Bulwark (58128-58130) via Elemental Weapons 16266/29079/29080 | cap = build % x 4/3 of max health: 13 / 27 / 40 %; stated literally in the Elemental Weapons description since core#217 (#357) | `src/scripts/spells/spell_shaman.cpp` `GetEarthenBulwarkCap` (core#182) | yes |
| CV-2 | Agitating Poison 45613 (bot item 90140) | threat/damage by caster level band L20 +150 / L30 +210 / L40 +275 / L50 +335 / L60 +395 (`AGITATING_POISON_RANKS`); players use ranks I-IV 61201-61204 with their own values in `spell_template` and enchantments 3060-3063, so their tooltips need no code value | `src/scripts/spells/spell_rogue.cpp:43` | bots only |
| CV-3 | Charged Stormstrike 61118 (talent 9005) on Stormstrike 17364 | up to 3 Lightning Shield charges, +10 % damage each | `src/scripts/spells/spell_shaman.cpp` `STORMSTRIKE_PCT_PER_CHARGE`, `spell_shaman_stormstrike_charges` (core#187) | **yes since stage 2** (#357; was bot-only) |
| CV-4 | Spit 61141 | up to 2 extra targets within 8 yd of the main target; text emote 89 | `src/scripts/spells/spell_rogue.cpp:65-66` | yes ("up to two enemies within 8 yards") |
| CV-5 | Shadow Dance 61143-61145 | threat per dodge/parry = the rank's aura amount (50/90/130, `spell_template.effectBasePoints1`); buffs 61146/61147 | `src/scripts/spells/spell_rogue.cpp:747-764` | yes, via `$s1` (no literal) |
| CV-6 | Flowing Blades 61155/61156 | 1 s off Flourish, Cold Blood, Adrenaline Rush, Preparation, Mark for Death | `src/scripts/spells/spell_rogue.cpp:781-784` | yes ("by 1 sec") |
| CV-7 | Riposte Flow 61170-61172 | at most once per second; the extra attack causes double threat | `src/scripts/spells/spell_rogue.cpp:843-876` | yes ("double threat", "once per second") |
| CV-8 | Arcane Evasion 61173-61175 | resistance = (dodge % + parry %) x 15/30/45 % x 1/2/3 points, no cap | `src/game/FunserverRogueTalents.h:67` | yes, via `$s1`/`$s2` |
| CV-9 | Coup de Grace 61176-61178 | applies below 35 % target health | `src/game/FunserverRogueTalents.h:41` | yes ("below 35% health") |
| CV-10 | Deep Wounds 61188 / helper 61194 | Hemorrhage bonus stacks up to 5 times for 15 s (helper `stackAmount`/`durationIndex`) | `sql/database_updates/20260927200000_world.sql` | yes ("up to 5 times", "15 sec") |
| CV-11 | Shield Constitution 61127-61129, Shield Ward 61130 | +1/2/3 % stamina and -2 % damage taken per active Lightning Shield charge | `spell_shaman_shield_charge_scaling` (core#187) | yes (#357) |
| CV-12 | Storm Wisdom 61119-61123 | stacks are removed by the Lightning Bolt / Chain Lightning cast | `spell_shaman_storm_wisdom` (core#187) | yes (#357) |
| CV-13 | Retaliation 61115-61117 | free Lightning Shield proc + 1 charge, at most once per second (1 s = `spell_proc_event.Cooldown`) | `spell_shaman_retaliation` (core#187) | yes (#357) |
| CV-14 | player mount spells (the 465 of `Spell/0295_mount_spells.csv`); riding teach spells 33389, 33392, 61301, 61303 | mounted speed of players and bots by riding rank (75/150/225/300) and mount family: family 1 (own aura-32 value below 100) +60/+100/+100/+100 %, family 2 (100 and above) +60/+100/+140/+180 %; the mount-speed-100 flag is family 2 and at least +100 %; no riding: level / 2 %; racing cars keep their value; NPCs unchanged. `Funserver.Riding.Stages.Enabled = 0`: 75 -> +60 %, 150 and above -> +100 % | `src/game/FunserverRidingStages.h` `FunserverRiding::MountedSpeedPct`, applied in `Aura::CalculateRidingMountSpeed` (`src/game/Spells/SpellAuras.cpp`) | yes (the texts name the speeds) |
| CV-15 | every slow (aura 33, negative) a player-controlled unit (player, bot, their pets, guardians, totems, traps, charmed units; not a player or bot charmed by an NPC) casts on another unit | amount x (100 + `Funserver.PlayerSnare.SlowPct`) / 100, at most `Funserver.PlayerSnare.MaxSlowPct`; a slow already above the cap keeps its value; funserver profile x1.4, cap 90 % (a 50 % slow becomes 70 %); NPC slows and self-slows unchanged | `src/game/FunserverRidingStages.h` `FunserverSnare::ScaleSlow`, applied in `WorldObject::CalculateSpellDamage` (`src/game/Objects/Object.cpp`); caster rule `FunserverSnare::IsPlayerSnareCaster` (`src/game/FunserverPlayerSnare.h`, defined in `src/game/Objects/Object.cpp`) | **no**: the IDs are shared with NPCs, the tooltips keep the base value |
| CV-16 | every root (aura 26) a player-controlled unit (same caster rule as CV-15, NPC-charmed players excluded) casts on another unit | duration x (100 + `Funserver.PlayerSnare.RootDurationPct`) / 100 before diminishing returns; funserver profile x1.4 (Frost Nova 8 s -> 11.2 s); the whole aura lasts longer, so Entangling Roots deals 40 % more damage | `src/game/FunserverRidingStages.h` `FunserverSnare::ScaleRootDuration`, applied in `Spell::DoSpellHitOnUnit` (`src/game/Spells/Spell.cpp`); caster rule as CV-15 | **no**: the tooltips keep the base duration |

## Server-side-only talent ranks

Some talent effects stay on the server and get no client rank spell:

- **90110 is intentionally empty** (#357). A `Talent.dbc` rank that points
  to 90110 fails the `talent-ranks-on-server` rule, and that is correct.
- **Ghost Wolf rank 3 stays server-side.** Improved Ghost Wolf 2/2 is
  -3000 ms, which makes Ghost Wolf instant; no client rank spell carries it
  (OB-20 review of #431).
