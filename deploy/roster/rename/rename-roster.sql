-- Rename roster bots from an approved mapping (twow-repo#366 A5).
--
-- Run ONLY through run-rename-roster.sh, against tw_char, with the world server stopped.
-- The wrapper creates and fills the temporary table rename_map (ordinal, guid,
-- old_name, new_name) from the approved mapping file and sets @expected_rows.
-- `characters` is MyISAM and `characters.name` has no unique index (idx_name is
-- non-unique), so every guard runs before the only mutation and aborts the client via
-- a CHECK violation. Comparisons use the column collation (utf8mb3_general_ci), i.e.
-- they are case-insensitive, like the server's own name check.
--
-- Idempotent: a row whose character already carries new_name is accepted and skipped.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';

-- ------------------------------------------------------------------ guards
CREATE TEMPORARY TABLE rename_guard (
    label VARCHAR(80) NOT NULL PRIMARY KEY,
    ok TINYINT NOT NULL CHECK (ok = 1)
) ENGINE=MEMORY;
INSERT INTO rename_guard VALUES ('guard_row_count',
    (SELECT COUNT(*) = @expected_rows AND COUNT(DISTINCT guid) = @expected_rows FROM rename_map));
INSERT INTO rename_guard VALUES ('guard_active_roster_members',
    (SELECT COUNT(*) = @expected_rows FROM rename_map m
     JOIN ai_playerbot_roster_current rc ON rc.singleton_id = 1
     JOIN ai_playerbot_roster_member rm ON rm.version_id = rc.version_id
          AND rm.ordinal = m.ordinal AND rm.character_guid = m.guid));
INSERT INTO rename_guard VALUES ('guard_all_offline',
    (SELECT COUNT(*) = @expected_rows FROM rename_map m JOIN characters c ON c.guid = m.guid WHERE c.online = 0));
INSERT INTO rename_guard VALUES ('guard_all_rndbot_accounts',
    (SELECT COUNT(*) = @expected_rows FROM rename_map m JOIN characters c ON c.guid = m.guid
     JOIN tw_logon.account a ON a.id = c.account WHERE a.username LIKE 'RNDBOT%'));
INSERT INTO rename_guard VALUES ('guard_current_name_is_old_or_new',
    (SELECT COUNT(*) = @expected_rows FROM rename_map m JOIN characters c ON c.guid = m.guid
     WHERE c.name = m.old_name OR BINARY c.name = BINARY m.new_name));
INSERT INTO rename_guard VALUES ('guard_new_name_format',
    (SELECT COUNT(*) = @expected_rows FROM rename_map
     WHERE BINARY new_name REGEXP BINARY '^[A-Z][a-z]{1,11}$' AND new_name NOT REGEXP '(.)\\1\\1'));
INSERT INTO rename_guard VALUES ('guard_new_names_unique_in_map',
    (SELECT COUNT(DISTINCT LOWER(new_name)) = @expected_rows FROM rename_map));
INSERT INTO rename_guard VALUES ('guard_new_name_unused_by_others',
    (SELECT COUNT(*) = 0 FROM rename_map m JOIN characters c ON c.name = m.new_name AND c.guid <> m.guid));
INSERT INTO rename_guard VALUES ('guard_new_name_not_in_bot_name_pool',
    (SELECT COUNT(*) = 0 FROM rename_map m JOIN ai_playerbot_names n ON n.name = m.new_name));
SELECT CONCAT(label, '=PASS') FROM rename_guard ORDER BY label;

SET @others_before = (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name))), 0)
                      FROM characters c LEFT JOIN rename_map m ON m.guid = c.guid WHERE m.guid IS NULL);
SET @already = (SELECT COUNT(*) FROM rename_map m JOIN characters c ON c.guid = m.guid WHERE BINARY c.name = BINARY m.new_name);

-- ------------------------------------------------------------------ mutate
UPDATE characters c JOIN rename_map m ON m.guid = c.guid
SET c.name = m.new_name
WHERE BINARY c.name <> BINARY m.new_name;
SET @changed = ROW_COUNT();

-- ------------------------------------------------------------------ asserts
CREATE TEMPORARY TABLE rename_assert (label VARCHAR(80) NOT NULL PRIMARY KEY, ok TINYINT NOT NULL) ENGINE=MEMORY;
INSERT INTO rename_assert VALUES
 ('all_carry_new_name', (SELECT COUNT(*) = @expected_rows FROM rename_map m JOIN characters c ON c.guid = m.guid WHERE BINARY c.name = BINARY m.new_name)),
 ('changed_plus_already', (SELECT @changed + @already = @expected_rows)),
 ('others_unchanged', (SELECT COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.name))), 0) = @others_before
                       FROM characters c LEFT JOIN rename_map m ON m.guid = c.guid WHERE m.guid IS NULL)),
 ('no_duplicate_new_names', (SELECT COUNT(*) = @expected_rows FROM rename_map m
                             WHERE (SELECT COUNT(*) FROM characters c WHERE c.name = m.new_name) = 1));
SELECT CONCAT('RENAMED=', @changed, ' ALREADY=', @already, ' ROWS=', @expected_rows);
SELECT CONCAT('ASSERT_', label, '=', IF(ok = 1, 'PASS', 'FAIL')) FROM rename_assert ORDER BY label;
