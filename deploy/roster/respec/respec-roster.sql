-- Respec and profession change for roster bots from an approved plan (twow-repo#366 A6).
--
-- Run ONLY through run-respec-roster.sh, against tw_char, with the world server stopped.
-- The wrapper creates and fills respec_plan (ordinal, guid, class, spec_no, pair) for an
-- ordinal range of the approved roster CSV and sets @expected_rows and
-- @expected_guid_sha256. Level, items, quests, spells and reputation stay untouched.
--
-- Respec  : specNo event := plan value, characters.at_login |= 4 (AT_LOGIN_RESET_TALENTS).
--           Talents only: the bot picks talents for its specNo from its free points.
--           No spell reset (it would also drop quest-bound class spells such as Bear Form
--           or Defensive Stance and every recipe).
-- Pairs   : profession_pair event := plan value; the primary profession skills that are
--           not part of the new pair are removed together with their spells/recipes
--           (tw_world.skill_line_ability). Secondary professions stay.
--
-- characters/character_skills/character_spell are MyISAM: every guard runs before the
-- first mutation and aborts via a CHECK violation. Idempotent: rows that already match
-- the plan are not touched.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';
SET SESSION group_concat_max_len = 1048576;

CREATE TEMPORARY TABLE pair_skill (pair TINYINT UNSIGNED NOT NULL, skill SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (pair, skill)) ENGINE=MEMORY;
INSERT INTO pair_skill VALUES (1,182),(1,171),(2,393),(2,165),(3,186),(3,164),(4,186),(4,202),
    (5,186),(5,755),(6,197),(6,333),(7,182),(7,186);
CREATE TEMPORARY TABLE primary_skill (skill SMALLINT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY;
INSERT INTO primary_skill VALUES (164),(165),(171),(182),(186),(197),(202),(333),(393),(755);

CREATE TEMPORARY TABLE current_state ENGINE=MEMORY AS
SELECT p.guid,
       (SELECT e.value FROM cv_bots.ai_playerbot_random_bots e WHERE e.owner = 0 AND e.bot = p.guid AND e.event = 'specNo') AS spec_no,
       (SELECT e.value FROM cv_bots.ai_playerbot_random_bots e WHERE e.owner = 0 AND e.bot = p.guid AND e.event = 'profession_pair') AS pair
FROM respec_plan p;

-- ------------------------------------------------------------------ guards
CREATE TEMPORARY TABLE respec_guard (label VARCHAR(80) NOT NULL PRIMARY KEY, ok TINYINT NOT NULL CHECK (ok = 1)) ENGINE=MEMORY;
INSERT INTO respec_guard VALUES ('guard_row_count',
    (SELECT COUNT(*) = @expected_rows AND COUNT(DISTINCT guid) = @expected_rows FROM respec_plan));
INSERT INTO respec_guard VALUES ('guard_guid_sha256',
    (SELECT SHA2(GROUP_CONCAT(CONCAT(ordinal, ':', guid) ORDER BY ordinal SEPARATOR ','), 256) = @expected_guid_sha256 FROM respec_plan));
INSERT INTO respec_guard VALUES ('guard_active_roster_members',
    (SELECT COUNT(*) = @expected_rows FROM respec_plan p
     JOIN ai_playerbot_roster_current rc ON rc.singleton_id = 1
     JOIN ai_playerbot_roster_member rm ON rm.version_id = rc.version_id AND rm.ordinal = p.ordinal AND rm.character_guid = p.guid));
INSERT INTO respec_guard VALUES ('guard_class_matches',
    (SELECT COUNT(*) = @expected_rows FROM respec_plan p JOIN characters c ON c.guid = p.guid AND c.class = p.class));
INSERT INTO respec_guard VALUES ('guard_all_offline',
    (SELECT COUNT(*) = @expected_rows FROM respec_plan p JOIN characters c ON c.guid = p.guid WHERE c.online = 0));
INSERT INTO respec_guard VALUES ('guard_all_rndbot_accounts',
    (SELECT COUNT(*) = @expected_rows FROM respec_plan p JOIN characters c ON c.guid = p.guid
     JOIN tw_logon.account a ON a.id = c.account WHERE a.username LIKE 'RNDBOT%'));
INSERT INTO respec_guard VALUES ('guard_events_present',
    (SELECT COUNT(*) = @expected_rows FROM current_state WHERE spec_no IS NOT NULL AND pair IS NOT NULL));
INSERT INTO respec_guard VALUES ('guard_plan_values_valid',
    (SELECT COUNT(*) = @expected_rows FROM respec_plan WHERE spec_no BETWEEN 1 AND 10 AND pair BETWEEN 1 AND 7));
SELECT CONCAT(label, '=PASS') FROM respec_guard ORDER BY label;

-- Baseline of everything that must not change for non-targets.
CREATE TEMPORARY TABLE respec_baseline (label VARCHAR(40) NOT NULL PRIMARY KEY, v BIGINT NOT NULL) ENGINE=MEMORY;
INSERT INTO respec_baseline
SELECT 'skills', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', s.guid, s.skill, s.value, s.max))), 0)
  FROM character_skills s LEFT JOIN respec_plan p ON p.guid = s.guid WHERE p.guid IS NULL
UNION ALL SELECT 'spells', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', s.guid, s.spell))), 0)
  FROM character_spell s LEFT JOIN respec_plan p ON p.guid = s.guid WHERE p.guid IS NULL
UNION ALL SELECT 'events', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', e.owner, e.bot, e.event, e.value, e.data))), 0)
  FROM cv_bots.ai_playerbot_random_bots e LEFT JOIN respec_plan p ON p.guid = e.bot WHERE p.guid IS NULL
UNION ALL SELECT 'characters', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.level, c.xp, c.money, c.at_login))), 0)
  FROM characters c LEFT JOIN respec_plan p ON p.guid = c.guid WHERE p.guid IS NULL
UNION ALL SELECT 'target_levels', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.level, c.xp, c.money))), 0)
  FROM characters c JOIN respec_plan p ON p.guid = c.guid
UNION ALL SELECT 'target_inventory', COUNT(*) FROM character_inventory i JOIN respec_plan p ON p.guid = i.guid;

CREATE TEMPORARY TABLE respec_bots (guid INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY
SELECT p.guid FROM respec_plan p JOIN current_state s ON s.guid = p.guid WHERE s.spec_no <> p.spec_no;
CREATE TEMPORARY TABLE pair_bots (guid INT UNSIGNED NOT NULL PRIMARY KEY, new_pair TINYINT UNSIGNED NOT NULL) ENGINE=MEMORY
SELECT p.guid, p.pair AS new_pair FROM respec_plan p JOIN current_state s ON s.guid = p.guid WHERE s.pair <> p.pair;
CREATE TEMPORARY TABLE drop_skill (guid INT UNSIGNED NOT NULL, skill SMALLINT UNSIGNED NOT NULL, PRIMARY KEY (guid, skill)) ENGINE=MEMORY
SELECT s.guid, s.skill FROM character_skills s JOIN pair_bots b ON b.guid = s.guid JOIN primary_skill ps ON ps.skill = s.skill
LEFT JOIN pair_skill keep ON keep.pair = b.new_pair AND keep.skill = s.skill WHERE keep.skill IS NULL;
CREATE TEMPORARY TABLE drop_spell (guid INT UNSIGNED NOT NULL, spell INT UNSIGNED NOT NULL, PRIMARY KEY (guid, spell)) ENGINE=MEMORY
SELECT DISTINCT cs.guid, cs.spell FROM character_spell cs JOIN pair_bots b ON b.guid = cs.guid
JOIN tw_world.skill_line_ability sla ON sla.spell_id = cs.spell JOIN primary_skill ps ON ps.skill = sla.skill_id
LEFT JOIN pair_skill keep ON keep.pair = b.new_pair AND keep.skill = sla.skill_id WHERE keep.skill IS NULL;

SET @respec_count = (SELECT COUNT(*) FROM respec_bots);
SET @pair_count = (SELECT COUNT(*) FROM pair_bots);
SET @drop_skill_count = (SELECT COUNT(*) FROM drop_skill);
SET @drop_spell_count = (SELECT COUNT(*) FROM drop_spell);

-- ------------------------------------------------------------------ mutate
UPDATE cv_bots.ai_playerbot_random_bots e JOIN respec_plan p ON p.guid = e.bot JOIN respec_bots r ON r.guid = p.guid
SET e.value = p.spec_no WHERE e.owner = 0 AND e.event = 'specNo';
UPDATE characters c JOIN respec_bots r ON r.guid = c.guid SET c.at_login = c.at_login | 4;
UPDATE cv_bots.ai_playerbot_random_bots e JOIN pair_bots b ON b.guid = e.bot
SET e.value = b.new_pair WHERE e.owner = 0 AND e.event = 'profession_pair';
DELETE s FROM character_skills s JOIN drop_skill d ON d.guid = s.guid AND d.skill = s.skill;
DELETE s FROM character_spell s JOIN drop_spell d ON d.guid = s.guid AND d.spell = s.spell;

-- ------------------------------------------------------------------ asserts
CREATE TEMPORARY TABLE respec_assert (label VARCHAR(80) NOT NULL PRIMARY KEY, ok TINYINT NOT NULL) ENGINE=MEMORY;
INSERT INTO respec_assert VALUES
 ('spec_no_matches_plan', (SELECT COUNT(*) = @expected_rows FROM respec_plan p JOIN cv_bots.ai_playerbot_random_bots e
    ON e.owner = 0 AND e.bot = p.guid AND e.event = 'specNo' AND e.value = p.spec_no)),
 ('pair_matches_plan', (SELECT COUNT(*) = @expected_rows FROM respec_plan p JOIN cv_bots.ai_playerbot_random_bots e
    ON e.owner = 0 AND e.bot = p.guid AND e.event = 'profession_pair' AND e.value = p.pair)),
 ('respec_bots_reset_talents', (SELECT COUNT(*) = @respec_count FROM characters c JOIN respec_bots r ON r.guid = c.guid WHERE c.at_login & 4 = 4)),
 ('no_foreign_primary_skill', (SELECT COUNT(*) = 0 FROM character_skills s JOIN pair_bots b ON b.guid = s.guid
    JOIN primary_skill ps ON ps.skill = s.skill LEFT JOIN pair_skill keep ON keep.pair = b.new_pair AND keep.skill = s.skill WHERE keep.skill IS NULL)),
 ('no_foreign_profession_spell', (SELECT COUNT(*) = 0 FROM character_spell cs JOIN pair_bots b ON b.guid = cs.guid
    JOIN tw_world.skill_line_ability sla ON sla.spell_id = cs.spell JOIN primary_skill ps ON ps.skill = sla.skill_id
    LEFT JOIN pair_skill keep ON keep.pair = b.new_pair AND keep.skill = sla.skill_id WHERE keep.skill IS NULL));
CREATE TEMPORARY TABLE respec_after (label VARCHAR(40) NOT NULL PRIMARY KEY, v BIGINT NOT NULL) ENGINE=MEMORY;
INSERT INTO respec_after
SELECT 'skills', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', s.guid, s.skill, s.value, s.max))), 0)
  FROM character_skills s LEFT JOIN respec_plan p ON p.guid = s.guid WHERE p.guid IS NULL
UNION ALL SELECT 'spells', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', s.guid, s.spell))), 0)
  FROM character_spell s LEFT JOIN respec_plan p ON p.guid = s.guid WHERE p.guid IS NULL
UNION ALL SELECT 'events', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', e.owner, e.bot, e.event, e.value, e.data))), 0)
  FROM cv_bots.ai_playerbot_random_bots e LEFT JOIN respec_plan p ON p.guid = e.bot WHERE p.guid IS NULL
UNION ALL SELECT 'characters', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.level, c.xp, c.money, c.at_login))), 0)
  FROM characters c LEFT JOIN respec_plan p ON p.guid = c.guid WHERE p.guid IS NULL
UNION ALL SELECT 'target_levels', COALESCE(BIT_XOR(CRC32(CONCAT_WS('|', c.guid, c.level, c.xp, c.money))), 0)
  FROM characters c JOIN respec_plan p ON p.guid = c.guid
UNION ALL SELECT 'target_inventory', COUNT(*) FROM character_inventory i JOIN respec_plan p ON p.guid = i.guid;
INSERT INTO respec_assert SELECT CONCAT('unchanged_', b.label), b.v = a.v FROM respec_baseline b JOIN respec_after a ON a.label = b.label;

SELECT CONCAT('RESPEC=', @respec_count, ' PAIR_CHANGE=', @pair_count,
              ' DROPPED_SKILLS=', @drop_skill_count, ' DROPPED_SPELLS=', @drop_spell_count, ' ROWS=', @expected_rows);
SELECT CONCAT('ASSERT_', label, '=', IF(ok = 1, 'PASS', 'FAIL')) FROM respec_assert ORDER BY label;
