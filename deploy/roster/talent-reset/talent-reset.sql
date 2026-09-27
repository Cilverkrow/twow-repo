-- Talent reset for roster bots of one class and a set of specNo values (twow-repo#366, #357).
--
-- Run ONLY through run-talent-reset.sh, against tw_char, with the world server stopped.
-- After a deploy that changes a class's premade links or adds path auras (OB-10 SpecAura,
-- #357), the bots on those paths must re-learn their talents: at_login |= 4
-- (AT_LOGIN_RESET_TALENTS). Nothing else changes: level, items, spells, specNo, professions.
-- The operation is idempotent (the bit stays set until the bot logs in).
--
-- The wrapper sets @class, @spec_list (comma-separated specNo values),
-- @expected_targets and @expected_guid_sha256 (SHA-256 of the target GUIDs in ascending order,
-- joined by ","). A dry run sends only the part above the guards (read-only) and prints them.
-- Characters are MyISAM: every guard runs before the
-- first mutation (CHECK violation aborts the client); the asserts are proof.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';
SET SESSION group_concat_max_len = 1048576;

CREATE TEMPORARY TABLE reset_targets (guid INT UNSIGNED NOT NULL PRIMARY KEY, ordinal INT UNSIGNED NOT NULL) ENGINE=MEMORY
SELECT rm.character_guid AS guid, rm.ordinal AS ordinal
FROM ai_playerbot_roster_current rc
JOIN ai_playerbot_roster_member rm ON rm.version_id = rc.version_id
JOIN characters c ON c.guid = rm.character_guid AND c.class = @class
JOIN cv_bots.ai_playerbot_random_bots e ON e.owner = 0 AND e.bot = rm.character_guid AND e.event = 'specNo'
WHERE rc.singleton_id = 1 AND FIND_IN_SET(e.value, @spec_list) > 0;
SET @target_count = (SELECT COUNT(*) FROM reset_targets);
SET @target_sha256 = (SELECT SHA2(COALESCE(GROUP_CONCAT(guid ORDER BY guid SEPARATOR ','), ''), 256) FROM reset_targets);
SELECT CONCAT('TARGETS=', @target_count, ' GUID_SHA256=', @target_sha256,
              ' ORDINALS=', COALESCE((SELECT GROUP_CONCAT(ordinal ORDER BY ordinal) FROM reset_targets), ''));

-- ------------------------------------------------------------------ guards
CREATE TEMPORARY TABLE reset_guard (
    label VARCHAR(80) NOT NULL PRIMARY KEY,
    ok TINYINT NOT NULL CHECK (ok = 1)
) ENGINE=MEMORY;
INSERT INTO reset_guard VALUES ('guard_target_count', (SELECT @target_count = @expected_targets AND @target_count > 0));
INSERT INTO reset_guard VALUES ('guard_target_guid_sha256', (SELECT @target_sha256 = @expected_guid_sha256));
INSERT INTO reset_guard VALUES ('guard_all_offline',
    (SELECT COUNT(*) = 0 FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.online <> 0));
INSERT INTO reset_guard VALUES ('guard_all_rndbot_accounts',
    (SELECT COUNT(*) = 0 FROM characters c JOIN reset_targets t ON t.guid = c.guid
     LEFT JOIN tw_logon.account a ON a.id = c.account
     WHERE a.id IS NULL OR a.username NOT LIKE 'RNDBOT%'));
SELECT CONCAT(label, '=PASS') FROM reset_guard ORDER BY label;

-- Baseline of everything that must NOT change.
SET @others_before = (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name, c.level, c.xp, c.money,
                          c.map, c.position_x, c.at_login))), 0)
                      FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL);
SET @targets_before = (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name, c.level, c.xp, c.money,
                           c.map, c.position_x, c.at_login | 4))), 0)
                       FROM characters c JOIN reset_targets t ON t.guid = c.guid);
SET @events_before = (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', owner, bot, event, value, data))), 0)
                      FROM cv_bots.ai_playerbot_random_bots);

-- ------------------------------------------------------------------ mutation
UPDATE characters c JOIN reset_targets t ON t.guid = c.guid SET c.at_login = c.at_login | 4;

-- ------------------------------------------------------------------ asserts
CREATE TEMPORARY TABLE reset_assert (label VARCHAR(80) NOT NULL PRIMARY KEY, ok TINYINT NOT NULL) ENGINE=MEMORY;
INSERT INTO reset_assert VALUES
 ('flag_set_on_all_targets', (SELECT COUNT(*) = @expected_targets FROM characters c JOIN reset_targets t ON t.guid = c.guid WHERE c.at_login & 4 = 4)),
 ('targets_otherwise_unchanged', (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name, c.level, c.xp, c.money,
      c.map, c.position_x, c.at_login))), 0) = @targets_before FROM characters c JOIN reset_targets t ON t.guid = c.guid)),
 ('non_targets_unchanged', (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name, c.level, c.xp, c.money,
      c.map, c.position_x, c.at_login))), 0) = @others_before FROM characters c LEFT JOIN reset_targets t ON t.guid = c.guid WHERE t.guid IS NULL)),
 ('events_unchanged', (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', owner, bot, event, value, data))), 0) = @events_before
      FROM cv_bots.ai_playerbot_random_bots));
SELECT CONCAT('ASSERT_', label, '=', IF(ok = 1, 'PASS', 'FAIL')) FROM reset_assert ORDER BY label;
