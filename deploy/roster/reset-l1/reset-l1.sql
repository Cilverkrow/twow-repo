-- Roster reset to level 1 with homebind in the race's starting area (twow-repo#334).
--
-- Run ONLY through run-reset-l1.sh, against tw_char, with the world server stopped.
-- The character tables are MyISAM: there is no rollback. Every guard therefore runs
-- BEFORE the first mutation and aborts the client (CHECK constraint violation under
-- --abort-source-on-error); the post-asserts are proof, not protection. The only
-- rollback is the cold volume backup taken before the run.
--
-- Scope: the active roster version's members (ai_playerbot_roster_current). Kept:
-- name, class, race, account, specNo and profession_pair events, BotBrain identity.
-- Reset: level/XP/money, position and homebind (playercreateinfo), inventory to the
-- starter outfit, quests, profession skills, level-range skills clamped to level 1,
-- auras, cooldowns, action bars, pets, mail, reputation, forgotten skills, bot
-- key/value store, group membership, corpses; spells and talents via at_login.
--
-- Target scope (#366): the wrapper sets @scope_from/@scope_to (ordinals, inclusive) and,
-- for a partial scope, @expected_guid_sha256 = SHA-256 (lowercase hex) of
-- "ordinal:guid" pairs in ordinal order joined by ",". Members outside the scope are
-- non-targets and fall under every non_target_* assert.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';
SET SESSION group_concat_max_len = 1048576;

CREATE TEMPORARY TABLE reset_targets (guid INT UNSIGNED NOT NULL PRIMARY KEY, ordinal INT UNSIGNED NOT NULL) ENGINE=MEMORY
SELECT rm.character_guid AS guid, rm.ordinal AS ordinal
FROM ai_playerbot_roster_current rc
JOIN ai_playerbot_roster_member rm ON rm.version_id = rc.version_id
WHERE rc.singleton_id = 1 AND rm.ordinal BETWEEN @scope_from AND @scope_to;
SET @scope_guid_sha256 = (SELECT SHA2(GROUP_CONCAT(CONCAT(ordinal, ':', guid) ORDER BY ordinal SEPARATOR ','), 256) FROM reset_targets);

-- ------------------------------------------------------------------ guards
CREATE TEMPORARY TABLE reset_guard (
    label VARCHAR(80) NOT NULL PRIMARY KEY,
    ok TINYINT NOT NULL CHECK (ok = 1)
) ENGINE=MEMORY;
INSERT INTO reset_guard VALUES ('guard_target_count',
    (SELECT COUNT(*) = @expected_targets FROM reset_targets));
-- Full scope needs no hash; a partial scope must match the approved list exactly.
INSERT INTO reset_guard VALUES ('guard_scope_guid_sha256',
    (SELECT (@scope_from = 1 AND @scope_to = 4294967295 AND @expected_guid_sha256 IS NULL)
         OR @scope_guid_sha256 = @expected_guid_sha256));
INSERT INTO reset_guard VALUES ('guard_all_targets_exist',
    (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid));
INSERT INTO reset_guard VALUES ('guard_all_offline',
    (SELECT COUNT(*) = 0 FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.online <> 0));
INSERT INTO reset_guard VALUES ('guard_all_rndbot_accounts',
    (SELECT COUNT(*) = 0 FROM characters c JOIN reset_targets t ON t.guid = c.guid
     LEFT JOIN tw_logon.account a ON a.id = c.account
     WHERE a.id IS NULL OR a.username NOT LIKE 'RNDBOT%'));
INSERT INTO reset_guard VALUES ('guard_start_position_known',
    (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid
     JOIN tw_world.playercreateinfo info ON info.race = c.race AND info.class = c.class));
INSERT INTO reset_guard VALUES ('guard_specno_present',
    (SELECT COUNT(DISTINCT e.bot) = @expected_targets FROM cv_bots.ai_playerbot_random_bots e
     JOIN reset_targets t ON t.guid = e.bot WHERE e.owner = 0 AND e.event = 'specNo'));
INSERT INTO reset_guard VALUES ('guard_profession_pair_present',
    (SELECT COUNT(DISTINCT e.bot) = @expected_targets FROM cv_bots.ai_playerbot_random_bots e
     JOIN reset_targets t ON t.guid = e.bot WHERE e.owner = 0 AND e.event = 'profession_pair'));
SELECT CONCAT(label, '=PASS') FROM reset_guard ORDER BY label;

-- Baseline of everything that must NOT change (non-target characters).
CREATE TEMPORARY TABLE reset_baseline (label VARCHAR(80) NOT NULL PRIMARY KEY, v BIGINT NOT NULL) ENGINE=MEMORY;
INSERT INTO reset_baseline
SELECT 'characters', COUNT(*) FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL
UNION ALL SELECT 'characters_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.account, c.level, c.xp, c.money,
    c.map, c.position_x, c.position_y, c.position_z, c.online, c.at_login))), 0)
    FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL
UNION ALL SELECT 'inventory', COUNT(*) FROM character_inventory x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'queststatus', COUNT(*) FROM character_queststatus x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'skills_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', x.guid, x.skill, x.value, x.max))), 0)
    FROM character_skills x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'homebind_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', x.guid, x.map, x.zone, x.position_x))), 0)
    FROM character_homebind x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'reputation', COUNT(*) FROM character_reputation x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'pets', COUNT(*) FROM character_pet x LEFT JOIN reset_targets t ON t.guid = x.owner WHERE t.guid IS NULL
UNION ALL SELECT 'mail', COUNT(*) FROM mail x LEFT JOIN reset_targets t ON t.guid = x.receiver WHERE t.guid IS NULL
UNION ALL SELECT 'db_store', COUNT(*) FROM ai_playerbot_db_store x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'item_instance_non_target', COUNT(*) FROM item_instance x LEFT JOIN reset_targets t ON t.guid = x.owner_guid WHERE t.guid IS NULL;

-- ------------------------------------------------------------------ collect
CREATE TEMPORARY TABLE reset_groups (group_id INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY
SELECT DISTINCT gm.groupId AS group_id FROM group_member gm JOIN reset_targets t ON t.guid = gm.memberGuid;
CREATE TEMPORARY TABLE reset_items (item_guid INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY
SELECT ci.item AS item_guid FROM character_inventory ci JOIN reset_targets t ON t.guid = ci.guid
UNION SELECT mi.item_guid FROM mail_items mi JOIN reset_targets t ON t.guid = mi.receiver;
CREATE TEMPORARY TABLE reset_pets (pet_id INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY
SELECT p.id AS pet_id FROM character_pet p JOIN reset_targets t ON t.guid = p.owner;
CREATE TEMPORARY TABLE reset_mail (mail_id INT UNSIGNED NOT NULL PRIMARY KEY, text_id INT UNSIGNED NOT NULL) ENGINE=MEMORY
SELECT m.id AS mail_id, m.itemTextId AS text_id FROM mail m JOIN reset_targets t ON t.guid = m.receiver;

-- ------------------------------------------------------------------ mutate
DELETE x FROM character_action x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM character_aura x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM character_spell_cooldown x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM character_queststatus x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM character_skills x JOIN reset_targets t ON t.guid = x.guid
WHERE x.skill IN (129, 142, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 755);
-- Level-range skills (weapons, defence, class schools): the core clamps only max to
-- the level on login (Player::_LoadSkills, SKILL_RANGE_LEVEL), never value.
UPDATE character_skills x JOIN reset_targets t ON t.guid = x.guid
SET x.value = LEAST(x.value, 5), x.max = 5
WHERE x.max > 5 AND x.max <> 300;
DELETE x FROM character_forgotten_skills x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM character_reputation x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM pet_spell x JOIN reset_pets p ON p.pet_id = x.guid;
DELETE x FROM pet_spell_cooldown x JOIN reset_pets p ON p.pet_id = x.guid;
DELETE x FROM character_pet x JOIN reset_pets p ON p.pet_id = x.id;
DELETE x FROM mail_items x JOIN reset_mail m ON m.mail_id = x.mail_id;
DELETE x FROM mail x JOIN reset_mail m ON m.mail_id = x.id;
DELETE x FROM item_text x JOIN reset_mail m ON m.text_id = x.id AND m.text_id <> 0
LEFT JOIN mail other ON other.itemTextId = x.id
LEFT JOIN item_instance item ON item.text = x.id
WHERE other.id IS NULL AND item.guid IS NULL;
DELETE x FROM ai_playerbot_db_store x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM corpse x JOIN reset_targets t ON t.guid = x.player;
DELETE x FROM group_member x JOIN reset_targets t ON t.guid = x.memberGuid;
DELETE g FROM groups g JOIN reset_groups rg ON rg.group_id = g.groupId
LEFT JOIN group_member remaining ON remaining.groupId = g.groupId WHERE remaining.groupId IS NULL;
DELETE x FROM character_inventory x JOIN reset_targets t ON t.guid = x.guid;
DELETE x FROM item_instance x JOIN reset_items i ON i.item_guid = x.guid;

SET @next_item_guid = (SELECT COALESCE(MAX(guid), 0) FROM item_instance);
CREATE TEMPORARY TABLE reset_starter_items AS
SELECT
    @next_item_guid + ROW_NUMBER() OVER (ORDER BY c.guid, pci.itemid) AS item_guid,
    c.guid AS owner_guid,
    pci.itemid AS item_entry,
    pci.amount AS item_count,
    item.max_durability AS durability,
    CASE item.inventory_type
        WHEN 1 THEN 0 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 3
        WHEN 5 THEN 4 WHEN 6 THEN 5 WHEN 7 THEN 6 WHEN 8 THEN 7
        WHEN 9 THEN 8 WHEN 10 THEN 9 WHEN 11 THEN 10 WHEN 12 THEN 12
        WHEN 13 THEN 15 WHEN 14 THEN 16 WHEN 15 THEN 17 WHEN 16 THEN 14
        WHEN 17 THEN 15
        WHEN 18 THEN 19 + ROW_NUMBER() OVER (PARTITION BY c.guid, item.inventory_type ORDER BY pci.itemid) - 1
        WHEN 19 THEN 18 WHEN 20 THEN 4 WHEN 21 THEN 15 WHEN 22 THEN 16
        WHEN 23 THEN 16 WHEN 25 THEN 17 WHEN 26 THEN 17
        WHEN 27 THEN 19 + ROW_NUMBER() OVER (PARTITION BY c.guid, item.inventory_type ORDER BY pci.itemid) - 1
        WHEN 28 THEN 17
        ELSE 23 + ROW_NUMBER() OVER (PARTITION BY c.guid ORDER BY item.inventory_type, pci.itemid) - 1
    END AS inventory_slot
FROM characters c
JOIN reset_targets target ON target.guid = c.guid
JOIN tw_world.playercreateinfo_item pci ON pci.race = c.race AND pci.class = c.class
JOIN tw_world.item_template item ON item.entry = pci.itemid;

INSERT INTO item_instance
    (guid, itemEntry, owner_guid, creatorGuid, giftCreatorGuid, count, duration,
     charges, flags, enchantments, randomPropertyId, transmogrifyId, durability, text, generated_loot)
SELECT item_guid, item_entry, owner_guid, 0, 0, item_count, 0, '', 0, '', 0, 0, durability, 0, 0
FROM reset_starter_items;
INSERT INTO character_inventory (guid, bag, slot, item, item_template)
SELECT owner_guid, 0, inventory_slot, item_guid, item_entry FROM reset_starter_items;

INSERT INTO character_homebind (guid, map, zone, position_x, position_y, position_z)
SELECT c.guid, info.map, info.zone, info.position_x, info.position_y, info.position_z
FROM characters c
JOIN reset_targets t ON t.guid = c.guid
JOIN tw_world.playercreateinfo info ON info.race = c.race AND info.class = c.class
ON DUPLICATE KEY UPDATE map = VALUES(map), zone = VALUES(zone),
    position_x = VALUES(position_x), position_y = VALUES(position_y), position_z = VALUES(position_z);

UPDATE characters c
JOIN reset_targets t ON t.guid = c.guid
JOIN tw_world.playercreateinfo info ON info.race = c.race AND info.class = c.class
JOIN tw_world.player_classlevelstats class_stats ON class_stats.class = c.class AND class_stats.level = 1
SET c.level = 1, c.xp = 0, c.money = 100000,
    c.position_x = info.position_x, c.position_y = info.position_y, c.position_z = info.position_z,
    c.map = info.map, c.orientation = info.orientation, c.zone = info.zone, c.area = info.zone,
    c.online = 0, c.leveltime = 0, c.rest_bonus = 0, c.death_expire_time = 0,
    c.trans_x = 0, c.trans_y = 0, c.trans_z = 0, c.trans_o = 0, c.transguid = 0,
    c.taxi_path = '', c.health = class_stats.basehp, c.power1 = class_stats.basemana,
    c.power2 = 0, c.power3 = 0, c.power4 = 0, c.power5 = 0,
    c.equipmentCache = '',
    c.ammoId = COALESCE((SELECT pci.itemid FROM tw_world.playercreateinfo_item pci
        JOIN tw_world.item_template item ON item.entry = pci.itemid
        WHERE pci.race = c.race AND pci.class = c.class AND item.inventory_type = 24
        ORDER BY pci.itemid LIMIT 1), 0),
    c.actionBars = 0, c.at_login = c.at_login | 6;  -- AT_LOGIN_RESET_SPELLS | AT_LOGIN_RESET_TALENTS

-- ------------------------------------------------------------------ asserts
CREATE TEMPORARY TABLE reset_assert (label VARCHAR(80) NOT NULL PRIMARY KEY, ok TINYINT NOT NULL) ENGINE=MEMORY;
INSERT INTO reset_assert VALUES
 ('level1_xp0', (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.level = 1 AND c.xp = 0)),
 ('ten_gold', (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.money = 100000)),
 ('reset_flags', (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.at_login & 6 = 6 AND c.online = 0)),
 ('position_start_area', (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid
    JOIN tw_world.playercreateinfo i ON i.race = c.race AND i.class = c.class
    WHERE c.map = i.map AND c.zone = i.zone AND c.position_x = i.position_x AND c.position_y = i.position_y)),
 ('homebind_start_area', (SELECT COUNT(*) = @expected_targets FROM character_homebind h JOIN reset_targets t ON t.guid = h.guid
    JOIN characters c ON c.guid = h.guid JOIN tw_world.playercreateinfo i ON i.race = c.race AND i.class = c.class
    WHERE h.map = i.map AND h.zone = i.zone AND h.position_x = i.position_x AND h.position_y = i.position_y AND h.position_z = i.position_z)),
 ('inventory_is_starter_outfit', (SELECT COUNT(*) = (SELECT COUNT(*) FROM reset_starter_items)
    FROM character_inventory x JOIN reset_targets t ON t.guid = x.guid)),
 ('no_quests', (SELECT COUNT(*) = 0 FROM character_queststatus x JOIN reset_targets t ON t.guid = x.guid)),
 ('no_profession_skills', (SELECT COUNT(*) = 0 FROM character_skills x JOIN reset_targets t ON t.guid = x.guid
    WHERE x.skill IN (129, 142, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393, 755))),
 ('skills_level1', (SELECT COUNT(*) = 0 FROM character_skills x JOIN reset_targets t ON t.guid = x.guid
    WHERE x.max <> 300 AND (x.max > 5 OR x.value > 5))),
 ('no_pets_mail_reputation_store', (SELECT
    (SELECT COUNT(*) FROM character_pet x JOIN reset_targets t ON t.guid = x.owner)
  + (SELECT COUNT(*) FROM mail x JOIN reset_targets t ON t.guid = x.receiver)
  + (SELECT COUNT(*) FROM character_reputation x JOIN reset_targets t ON t.guid = x.guid)
  + (SELECT COUNT(*) FROM ai_playerbot_db_store x JOIN reset_targets t ON t.guid = x.guid) = 0)),
 ('specno_kept', (SELECT COUNT(DISTINCT e.bot) = @expected_targets FROM cv_bots.ai_playerbot_random_bots e
    JOIN reset_targets t ON t.guid = e.bot WHERE e.owner = 0 AND e.event = 'specNo')),
 ('profession_pair_kept', (SELECT COUNT(DISTINCT e.bot) = @expected_targets FROM cv_bots.ai_playerbot_random_bots e
    JOIN reset_targets t ON t.guid = e.bot WHERE e.owner = 0 AND e.event = 'profession_pair'));

CREATE TEMPORARY TABLE reset_after (label VARCHAR(80) NOT NULL PRIMARY KEY, v BIGINT NOT NULL) ENGINE=MEMORY;
INSERT INTO reset_after
SELECT 'characters', COUNT(*) FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL
UNION ALL SELECT 'characters_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.account, c.level, c.xp, c.money,
    c.map, c.position_x, c.position_y, c.position_z, c.online, c.at_login))), 0)
    FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL
UNION ALL SELECT 'inventory', COUNT(*) FROM character_inventory x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'queststatus', COUNT(*) FROM character_queststatus x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'skills_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', x.guid, x.skill, x.value, x.max))), 0)
    FROM character_skills x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'homebind_crc', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', x.guid, x.map, x.zone, x.position_x))), 0)
    FROM character_homebind x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'reputation', COUNT(*) FROM character_reputation x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'pets', COUNT(*) FROM character_pet x LEFT JOIN reset_targets t ON t.guid = x.owner WHERE t.guid IS NULL
UNION ALL SELECT 'mail', COUNT(*) FROM mail x LEFT JOIN reset_targets t ON t.guid = x.receiver WHERE t.guid IS NULL
UNION ALL SELECT 'db_store', COUNT(*) FROM ai_playerbot_db_store x LEFT JOIN reset_targets t ON t.guid = x.guid WHERE t.guid IS NULL
UNION ALL SELECT 'item_instance_non_target', COUNT(*) FROM item_instance x LEFT JOIN reset_targets t ON t.guid = x.owner_guid WHERE t.guid IS NULL;
INSERT INTO reset_assert
SELECT CONCAT('non_target_', b.label), b.v = a.v FROM reset_baseline b JOIN reset_after a ON a.label = b.label;

SELECT CONCAT('RESET_TARGETS=', COUNT(*), ' SCOPE=', MIN(ordinal), '-', MAX(ordinal), ' GUID_SHA256=', @scope_guid_sha256) FROM reset_targets;
SELECT CONCAT('STARTER_ITEMS=', COUNT(*)) FROM reset_starter_items;
SELECT CONCAT('ASSERT_', label, '=', IF(ok = 1, 'PASS', 'FAIL')) FROM reset_assert ORDER BY label;
