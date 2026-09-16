---
id: WS10-ROSTER-PROFESSION-TRAINING-01
title: Make roster profession plans trainable from level 3
workstream: WS-10
priority: p1
existing_ot: none
source: Live roster audit 2026-09-16; 136 active Roster-v3 GUIDs
superseded_by: none
body: |
  Observed on the 136-bot test roster: all 136 have a stored profession-pair plan, but none has learned a planned primary profession and no profession skill progression is visible. The current factory stores the plan only; the trainer path rejects generic profession training, and the trainability filter skips initial professions below level 10. This conflicts with the intended organic trainer visit and learning from level 3.
  
  Separately, 90/136 live profession-pair values differ from the offline V4 master prefix. Do not overwrite live plans or assume which source is authoritative. Compare the pinned V4 planner, 136-GUID prefix, current persisted event values and runtime mapping; publish a per-GUID mismatch matrix and resolve the intended policy before any migration.
  
  Acceptance: roster bots at level >=3 seek an appropriate trainer, learn only their assigned two primary professions under normal trainer prerequisites, and advance skills through play. Test unavailable trainer, insufficient level, duplicate learning, relog/restart, and non-roster players. Keep normal players unchanged. Report whether free training cost is a test-profile rule or already active. Add low-cost telemetry for plan/trainer/learn failure reasons. Link the existing profession-policy issue #27 and player control issue #292. No production DB mutation without a reviewed migration and backup.
---

---
id: WS10-ROSTER-WRONG-ZONE-LOWLEVEL-01
title: Explain low-level roster bots in Southshore and remote zones
workstream: WS-10
priority: p1
existing_ot: none
source: Live roster location audit 2026-09-16; zone 267 area 271
superseded_by: none
body: |
  The current 136-bot roster has 15 level-1-to-5 bots in Southshore (Hillsbrad Foothills, zone 267/area 271). Five are level 1: Gerolanton (GUID 3970), Nessande (565), Tarcel (1789), Teryl (153), and Wistera (125). At least some are humans whose canonical start is Elwynn Forest, >8,000 yards away. This is not normal level-appropriate progression. A prior snapshot also saw one level-4 bot in Northwind (zone 5581); it was not present after the World restart, so treat Northwind as a transient observation, not proven persistent state.
  
  Read-only diagnosis first: correlate each bot's race/start position, active and focused quests, selected travel target and purpose, BotBrain planner decision, map/transport, death/graveyard/inn state, and recent position history. Determine whether the issue is target selection, stale position, teleport, or zone reporting. Capture reproducible transitions and how long bots remain there; do not assume a cause.
  
  Acceptance: low-level autonomous roster bots choose reachable, level-appropriate quest hubs and do not strand in high-level/remote zones; legitimate player-led group travel remains intact. Regression cases for Southshore, Northwind, relog/restart, transport and death. Link starter-zone progression issue #287, but keep this reverse/out-of-band travel defect separately trackable.
---

---
id: WS10-ROSTER-ROLE-AWARE-EQUIP-01
title: Audit and improve role-aware bot gear selection
workstream: WS-10
priority: p1
existing_ot: none
source: Live roster equipment audit 2026-09-16; 136 active GUIDs
superseded_by: none
body: |
  Live audit: 136/136 bots have four bags; 118 wear at least one item beyond starter gear. Only four green items are equipped while 48 green items are in inventories. Of those, 22 stored green equipment pieces pass the level requirement, but class, weapon, slot and suitability were not yet verified; this is a candidate signal, not proof of an auto-equip bug. The inventory also contains 21 duplicate clubs and 21 gems.
  
  First map the existing gear-evaluation and auto-equip triggers: loot pickup, quest reward selection, level-up, trainer/skill change, login/relog and periodic inventory scan. For the 22 candidate items, record why each is or is not equippable and why current gear wins. Distinguish quest-reward selection from later inventory evaluation; link existing #284.
  
  Then propose a deterministic, class/spec/role-aware scoring matrix tied to the persistent roster spec and actual usable attributes. Review healer Intellect/Spirit/healing/MP5, caster spell damage, physical DPS/Hunter Attack Power, tank defense/mitigation, and Feral Druid Agility/Stamina/Strength/Dodge/Crit with class-specific weights rather than one global priority. Consider hit, weapon proficiency, armor, set bonuses, durability, requirements, unique/equip restrictions and non-destructive bag swaps. BotBrain may suggest preferences, but validated core equip gates must remain authoritative.
  
  Acceptance: a focused sample explains every candidate decision; usable upgrades equip after a bounded event or cheap periodic check, no endless per-tick inventory scan, no inappropriate role downgrade, no loss/overwrite of equipped or bagged items, and existing player gear remains untouched. Instrument outcome/rejection reasons for longitudinal tests.
---
