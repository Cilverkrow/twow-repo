# Code-side values

Some values that the client shows or predicts live in **code or config**, not
in `spell_template`. Neither `sql:` delta values nor the
`spell-matches-server` consistency rule can see them, so they are kept here
by hand (design 3.4, OB-20 review). Every tooltip delta that uses one of them
cites the entry id in its `note` column.

Stage 2 pins each source to file and line at a pinned twow-core commit.
CV-4 to CV-10 are taken by the rogue change (#367, #433); the shaman entries
continue at CV-11 so the two changes do not collide.

| id | spell | value | source | player-visible |
|---|---|---|---|---|
| CV-1 | Earthen Bulwark (58128-58130) via Elemental Weapons 16266/29079/29080 | cap = build % x 4/3 of max health: 13 / 27 / 40 %; stated literally in the Elemental Weapons description since core#217 (#357) | `src/scripts/spells/spell_shaman.cpp` `GetEarthenBulwarkCap` (core#182) | yes |
| CV-2 | rogue poisons (ranks by caster level) | scaling by level band in the script | #367 O-9 a | yes |
| CV-3 | Charged Stormstrike 90117 (talent 9005) on Stormstrike 17364 | up to 3 Lightning Shield charges, +10 % damage each | `src/scripts/spells/spell_shaman.cpp` `STORMSTRIKE_PCT_PER_CHARGE`, `spell_shaman_stormstrike_charges` (core#187) | **yes since stage 2** (#357; was bot-only) |
| CV-11 | Shield Constitution 90126-90128, Shield Ward 90129 | +1/2/3 % stamina and -2 % damage taken per active Lightning Shield charge | `spell_shaman_shield_charge_scaling` (core#187) | yes (#357) |
| CV-12 | Storm Wisdom 90118-90122 | stacks are removed by the Lightning Bolt / Chain Lightning cast | `spell_shaman_storm_wisdom` (core#187) | yes (#357) |
| CV-13 | Retaliation 90114-90116 | free Lightning Shield proc + 1 charge, at most once per second (1 s = `spell_proc_event.Cooldown`) | `spell_shaman_retaliation` (core#187) | yes (#357) |

## Server-side-only talent ranks

Some talent effects stay on the server and get no client rank spell:

- **90110 is intentionally empty** (#357). A `Talent.dbc` rank that points
  to 90110 fails the `talent-ranks-on-server` rule, and that is correct.
- **Ghost Wolf rank 3 stays server-side.** Improved Ghost Wolf 2/2 is
  -3000 ms, which makes Ghost Wolf instant; no client rank spell carries it
  (OB-20 review of #431).
