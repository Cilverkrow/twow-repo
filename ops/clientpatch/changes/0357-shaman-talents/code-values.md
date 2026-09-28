# Code values: #357 shaman talents (stage 2)

Player-visible values that do **not** come from a `spell_template` number
(design #410 §3.4). A tooltip that shows one of them states it literally in the
spell's `description`. When a cited line changes, re-check the entry. Source
pin: twow-core `main` at `15fc5da4` plus core#217.

| ID | Value | Spells | Source | Player-visible | Tooltip |
|---|---|---|---|---|---|
| CV-1 | Earthen Bulwark cap = build % × 4/3 of max health: **13 / 27 / 40 %** | Elemental Weapons 16266 / 29079 / 29080 (bulwark 58128–58130) | `src/scripts/spells/spell_shaman.cpp` `GetEarthenBulwarkCap` (l.399, core#182) | yes | literal in the description (core#217 migration) |
| CV-2 | Charged Stormstrike: up to **3** Lightning Shield charges, **+10 %** damage each | 90117 (talent 9005) on Stormstrike 17364 | `spell_shaman.cpp` `STORMSTRIKE_PCT_PER_CHARGE = 10` (l.71), `spell_shaman_stormstrike_charges` (core#187) | **yes since stage 2** (was bot-only) | literal in the 90117 description |
| CV-3 | Shield Constitution **+1/2/3 %** stamina and Shield Ward **−2 %** damage taken **per active Lightning Shield charge** | 90126–90129 | `spell_shaman_shield_charge_scaling` (core#187) | yes | literal |
| CV-4 | Storm Wisdom stacks are removed by the Lightning Bolt / Chain Lightning cast | 90118–90125 | `spell_shaman_storm_wisdom` (core#187) | yes | literal |
| CV-5 | Retaliation: free Lightning Shield proc + 1 charge, at most once per second | 90114–90116 | `spell_shaman_retaliation` (core#187); 1 s is `spell_proc_event.Cooldown` | yes | literal |
