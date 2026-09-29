# Code-side values

Some values that the client shows or predicts live in **code or config**, not
in `spell_template`. Neither `sql:` delta values nor the
`spell-matches-server` consistency rule can see them, so they are kept here
by hand (design 3.4, OB-20 review). Every tooltip delta that uses one of them
cites the entry id in its `note` column.

Stage 2 pins each source to file and line at a pinned twow-core commit.
The rogue entries CV-2 and CV-4 to CV-10 are pinned at twow-core `15fc5da4` (#367).

| id | spell | value | source | player-visible |
|---|---|---|---|---|
| CV-1 | Earthen Bulwark (58128-58130) | cap 13 / 27 / 40 %; the tooltip text says "cannot exceed 20%" | `src/scripts/spells/spell_shaman.cpp` | yes |
| CV-2 | Agitating Poison 45613 (bot item 90140) | threat/damage by caster level band L20 +150 / L30 +210 / L40 +275 / L50 +335 / L60 +395 (`AGITATING_POISON_RANKS`); players use ranks I-IV 90200-90203 with their own values in `spell_template` and enchantments 90141-90144, so their tooltips need no code value | `src/scripts/spells/spell_rogue.cpp:43` | bots only |
| CV-3 | Stormstrike, +10 % per charge | applies to bots only | #357 | **no**, never in a player tooltip |
| CV-4 | Spit 90140 | up to 2 extra targets within 8 yd of the main target; text emote 89 | `src/scripts/spells/spell_rogue.cpp:65-66` | yes ("up to two enemies within 8 yards") |
| CV-5 | Shadow Dance 90142-90144 | threat per dodge/parry = the rank's aura amount (50/90/130, `spell_template.effectBasePoints1`); buffs 90145/90146 | `src/scripts/spells/spell_rogue.cpp:747-764` | yes, via `$s1` (no literal) |
| CV-6 | Flowing Blades 90154/90155 | 1 s off Flourish, Cold Blood, Adrenaline Rush, Preparation, Mark for Death | `src/scripts/spells/spell_rogue.cpp:781-784` | yes ("by 1 sec") |
| CV-7 | Riposte Flow 90169-90171 | at most once per second; the extra attack causes double threat | `src/scripts/spells/spell_rogue.cpp:843-876` | yes ("double threat", "once per second") |
| CV-8 | Arcane Evasion 90172-90174 | resistance = (dodge % + parry %) x 15/30/45 % x 1/2/3 points, no cap | `src/game/FunserverRogueTalents.h:67` | yes, via `$s1`/`$s2` |
| CV-9 | Coup de Grace 90175-90177 | applies below 35 % target health | `src/game/FunserverRogueTalents.h:41` | yes ("below 35% health") |
| CV-10 | Deep Wounds 90187 / helper 90193 | Hemorrhage bonus stacks up to 5 times for 15 s (helper `stackAmount`/`durationIndex`) | `sql/database_updates/20260927200000_world.sql` | yes ("up to 5 times", "15 sec") |

## Server-side-only talent ranks

Some talent effects stay on the server and get no client rank spell:

- **90110 is intentionally empty** (#357). A `Talent.dbc` rank that points
  to 90110 fails the `talent-ranks-on-server` rule, and that is correct.
- **Ghost Wolf rank 3 stays server-side.** Improved Ghost Wolf 2/2 is
  -3000 ms, which makes Ghost Wolf instant; no client rank spell carries it
  (OB-20 review of #431).
