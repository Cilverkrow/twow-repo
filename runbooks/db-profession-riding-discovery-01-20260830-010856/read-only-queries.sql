-- DB-PROFESSION-RIDING-DISCOVERY-01
-- Read-only evidence queries. These statements do not alter server state.

-- Product identity and selected schemas.
SELECT DATABASE() AS selected_database, @@port AS port, VERSION() AS server_version;
SELECT table_schema, COUNT(*) AS table_count
FROM information_schema.tables
WHERE table_schema IN ('tw_char', 'tw_logon', 'tw_world')
GROUP BY table_schema
ORDER BY table_schema;

-- Migration trackers.
SELECT 'tw_char' AS database_name, Name, Hash, Module, AppliedAt
FROM tw_char.migrations
ORDER BY Name;
SELECT 'tw_logon' AS database_name, Name, Hash, '' AS Module, AppliedAt
FROM tw_logon.migrations
ORDER BY Name;
SELECT 'tw_world' AS database_name, Name, Hash, '' AS Module, AppliedAt
FROM tw_world.migrations
ORDER BY Name;

-- Local profession-learning spells. Effect 44 is SPELL_EFFECT_SKILL_STEP.
SELECT
    st.entry AS spell_id,
    st.name AS spell_name_en,
    st.effectMiscValue2 AS skill_id,
    st.spellLevel,
    st.baseLevel,
    st.effectBasePoints2,
    CASE st.effectBasePoints2
        WHEN 0 THEN 'Apprentice'
        WHEN 1 THEN 'Journeyman'
        WHEN 2 THEN 'Expert'
        WHEN 3 THEN 'Artisan'
        ELSE CONCAT('Step ', st.effectBasePoints2 + 1)
    END AS inferred_rank
FROM tw_world.spell_template AS st
WHERE st.effect2 = 44
  AND st.effectMiscValue2 IN
      (129,142,164,165,171,182,185,186,197,202,333,356,393,755,762)
ORDER BY st.effectMiscValue2, st.effectBasePoints2, st.entry;

-- Direct creature trainer offerings for profession-learning spells.
SELECT
    'npc_trainer' AS source_table,
    nt.entry AS trainer_key,
    ct.entry AS creature_entry,
    ct.name AS npc_name,
    ct.faction,
    ct.trainer_class,
    ct.trainer_race,
    nt.spell AS trainer_spell,
    st.name AS spell_name_en,
    st.effectMiscValue2 AS skill_id,
    nt.reqlevel,
    nt.reqskill,
    nt.reqskillvalue,
    nt.spellcost
FROM tw_world.npc_trainer AS nt
JOIN tw_world.creature_template AS ct ON ct.entry = nt.entry
JOIN tw_world.spell_template AS st ON st.entry = nt.spell
WHERE st.effect2 = 44
  AND st.effectMiscValue2 IN
      (129,142,164,165,171,182,185,186,197,202,333,356,393,755)
ORDER BY st.effectMiscValue2, nt.spell, nt.entry;

-- Shared trainer-template offerings for profession-learning spells.
SELECT
    'npc_trainer_template' AS source_table,
    ntt.entry AS trainer_key,
    ct.entry AS creature_entry,
    ct.name AS npc_name,
    ct.faction,
    ct.trainer_class,
    ct.trainer_race,
    ntt.spell AS trainer_spell,
    st.name AS spell_name_en,
    st.effectMiscValue2 AS skill_id,
    ntt.reqlevel,
    ntt.reqskill,
    ntt.reqskillvalue,
    ntt.spellcost
FROM tw_world.npc_trainer_template AS ntt
JOIN tw_world.spell_template AS st ON st.entry = ntt.spell
LEFT JOIN tw_world.creature_template AS ct ON ct.trainer_id = ntt.entry
WHERE st.effect2 = 44
  AND st.effectMiscValue2 IN
      (129,142,164,165,171,182,185,186,197,202,333,356,393,755)
ORDER BY st.effectMiscValue2, ntt.spell, ntt.entry, ct.entry;

-- Character-level profession inventory without account names or credentials.
SELECT
    CASE
        WHEN a.username REGEXP '^RNDBOT([0-9]|[1-9][0-9]|[1-4][0-9][0-9])$'
        THEN 'RNDBOT'
        ELSE 'PLAYER'
    END AS account_type,
    c.guid,
    c.race,
    c.class,
    c.level,
    COUNT(DISTINCT CASE WHEN cs.skill IN (164,165,171,182,186,197,202,333,393,755)
                         AND cs.value > 0 THEN cs.skill END) AS primary_profession_count,
    GROUP_CONCAT(DISTINCT CASE WHEN cs.skill IN (164,165,171,182,186,197,202,333,393,755)
                               AND cs.value > 0 THEN CONCAT(cs.skill, ':', cs.value, '/', cs.max)
                          END ORDER BY cs.skill SEPARATOR ';') AS primary_professions,
    COUNT(DISTINCT CASE WHEN cs.skill IN (129,142,185,356)
                         AND cs.value > 0 THEN cs.skill END) AS secondary_profession_count,
    GROUP_CONCAT(DISTINCT CASE WHEN cs.skill IN (129,142,185,356)
                               AND cs.value > 0 THEN CONCAT(cs.skill, ':', cs.value, '/', cs.max)
                          END ORDER BY cs.skill SEPARATOR ';') AS secondary_professions,
    GROUP_CONCAT(DISTINCT CASE WHEN cs.skill = 762 AND cs.value > 0
                               THEN CONCAT(cs.skill, ':', cs.value, '/', cs.max)
                          END ORDER BY cs.skill SEPARATOR ';') AS riding_skill
FROM tw_char.characters AS c
LEFT JOIN tw_logon.account AS a ON a.id = c.account
LEFT JOIN tw_char.character_skills AS cs ON cs.guid = c.guid
GROUP BY account_type, c.guid, c.race, c.class, c.level
ORDER BY account_type, c.guid;

-- Profession-count distribution by account type.
SELECT account_type, primary_profession_count, COUNT(*) AS character_count
FROM (
    SELECT
        CASE
            WHEN a.username REGEXP '^RNDBOT([0-9]|[1-9][0-9]|[1-4][0-9][0-9])$'
            THEN 'RNDBOT'
            ELSE 'PLAYER'
        END AS account_type,
        c.guid,
        COUNT(DISTINCT CASE WHEN cs.skill IN (164,165,171,182,186,197,202,333,393,755)
                             AND cs.value > 0 THEN cs.skill END) AS primary_profession_count
    FROM tw_char.characters AS c
    LEFT JOIN tw_logon.account AS a ON a.id = c.account
    LEFT JOIN tw_char.character_skills AS cs ON cs.guid = c.guid
    GROUP BY account_type, c.guid
) AS per_character
GROUP BY account_type, primary_profession_count
ORDER BY account_type, primary_profession_count;

-- Current generic riding skill spells and their trainer wrappers.
SELECT
    st.entry AS spell_id,
    st.name AS spell_name_en,
    st.spellLevel,
    st.baseLevel,
    st.effect1,
    st.effect2,
    st.effectMiscValue2 AS skill_id,
    st.effectBasePoints2,
    st.effectTriggerSpell1,
    st.effectTriggerSpell2
FROM tw_world.spell_template AS st
WHERE st.entry IN (33388,33389,33391,33392)
ORDER BY st.entry;

-- Every current trainer using the generic riding trainer template.
SELECT
    ntt.entry AS trainer_template,
    ct.entry AS creature_entry,
    ct.name AS npc_name,
    ct.faction,
    ct.trainer_race,
    ct.trainer_class,
    ntt.spell AS trainer_spell,
    st.name AS spell_name_en,
    ntt.reqlevel,
    ntt.reqskill,
    ntt.reqskillvalue,
    ntt.spellcost
FROM tw_world.npc_trainer_template AS ntt
JOIN tw_world.spell_template AS st ON st.entry = ntt.spell
LEFT JOIN tw_world.creature_template AS ct ON ct.trainer_id = ntt.entry
WHERE ntt.spell IN (33389,33392)
ORDER BY ntt.spell, ct.entry;

-- Mount items that cast a mounted-aura spell. Aura 78 is SPELL_AURA_MOUNTED.
SELECT
    it.entry AS item_id,
    it.name AS item_name,
    it.spellid_1 AS mount_spell_id,
    st.name AS mount_spell_name,
    it.required_level,
    it.required_skill,
    it.required_skill_rank,
    it.buy_price,
    it.sell_price,
    it.allowable_race,
    it.allowable_class,
    CASE
        WHEN st.effectApplyAuraName1 = 32 THEN st.effectBasePoints1 + 1
        WHEN st.effectApplyAuraName2 = 32 THEN st.effectBasePoints2 + 1
        WHEN st.effectApplyAuraName3 = 32 THEN st.effectBasePoints3 + 1
        ELSE NULL
    END AS mounted_speed_percent,
    GROUP_CONCAT(DISTINCT CONCAT(nv.entry, ':', ct.name)
                 ORDER BY nv.entry SEPARATOR ';') AS vendor_entries
FROM tw_world.item_template AS it
JOIN tw_world.spell_template AS st ON st.entry = it.spellid_1
LEFT JOIN tw_world.npc_vendor AS nv ON nv.item = it.entry
LEFT JOIN tw_world.creature_template AS ct ON ct.entry = nv.entry
WHERE 78 IN (st.effectApplyAuraName1,
             st.effectApplyAuraName2,
             st.effectApplyAuraName3)
GROUP BY it.entry, it.name, it.spellid_1, st.name,
         it.required_level, it.required_skill, it.required_skill_rank,
         it.buy_price, it.sell_price, it.allowable_race, it.allowable_class,
         mounted_speed_percent
ORDER BY it.required_skill, it.required_skill_rank, it.required_level, it.entry;

-- Riding trainer source rows suitable for a future precondition check.
SELECT entry, spell, spellcost, reqskill, reqskillvalue, reqlevel
FROM tw_world.npc_trainer_template
WHERE entry = 1 AND spell IN (33389,33392)
ORDER BY spell;
