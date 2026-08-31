-- TASK_ID=RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-C0
-- READ-ONLY ONLY. This file contains SELECT statements only.
-- Preconditions enforced outside SQL:
--   * mangosd.exe and realmd.exe are stopped;
--   * MariaDB is user-started and listening only on 127.0.0.1:3307;
--   * the authenticated account has SELECT-only privileges;
--   * configured schemas are tw_char and tw_logon.
-- No result from this file authorizes INITIALIZE or Phase C.

SELECT 'C0_SNAPSHOT_UTC' AS evidence_key,
       UTC_TIMESTAMP(6) AS evidence_value;

SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE,
       IS_NULLABLE, COLUMN_DEFAULT, COLLATION_NAME, COLUMN_KEY, EXTRA
FROM information_schema.COLUMNS
WHERE (TABLE_SCHEMA = 'tw_char' AND TABLE_NAME IN
       ('characters', 'group_member', 'groups', 'ai_playerbot_random_bots'))
   OR (TABLE_SCHEMA = 'tw_logon' AND TABLE_NAME IN
       ('account', 'account_banned'))
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;

SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX,
       COLUMN_NAME, COLLATION, CARDINALITY, INDEX_TYPE
FROM information_schema.STATISTICS
WHERE (TABLE_SCHEMA = 'tw_char' AND TABLE_NAME IN
       ('characters', 'group_member', 'groups', 'ai_playerbot_random_bots'))
   OR (TABLE_SCHEMA = 'tw_logon' AND TABLE_NAME IN
       ('account', 'account_banned'))
ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;

-- The current implementation loads every owner=0/event=add row in GetBots(),
-- but GetEventValue() treats a row as active only while
-- UNIX_TIMESTAMP() - time < validIn.  Future-dated rows are rejected here.
SELECT r.id AS add_row_id, r.bot AS character_guid, r.value AS add_value,
       r.time AS lease_started_unix, r.validIn AS lease_seconds,
       r.time + r.validIn AS lease_expires_unix,
       FROM_UNIXTIME(r.time) AS lease_started_utc_server,
       FROM_UNIXTIME(r.time + r.validIn) AS lease_expires_utc_server,
       UNIX_TIMESTAMP() AS observed_unix,
       CASE WHEN r.value <> 0 AND r.validIn IS NOT NULL
                  AND r.time <= UNIX_TIMESTAMP()
                  AND UNIX_TIMESTAMP() - r.time < r.validIn
            THEN 1 ELSE 0 END AS active_add_lease,
       r.data AS add_data
FROM tw_char.ai_playerbot_random_bots r
WHERE r.owner = 0 AND r.event = 'add'
ORDER BY r.bot, r.id;

-- Complete active add-cohort, including foreign/ineligible rows.  Keeping
-- rejected rows is required evidence that humans and non-RNDBOT accounts were
-- not silently omitted from the audit trail.
SELECT r.bot AS character_guid,
       COUNT(*) AS active_add_row_count,
       c.name AS character_name,
       c.account AS account_id,
       a.username AS account_name,
       c.level AS character_level,
       c.class AS class_id,
       c.race AS race_id,
       c.online AS character_online,
       c.logout_time AS character_logout_unix,
       FROM_UNIXTIME(c.logout_time) AS character_logout_utc_server,
       c.active AS character_active,
       c.deleteDate AS character_delete_unix,
       a.last_login AS account_last_login,
       a.online AS account_online,
       a.active AS account_active,
       a.locked AS account_locked,
       a.banned AS account_banned_flag,
       CASE WHEN a.id IS NOT NULL AND UPPER(a.username) LIKE 'RNDBOT%'
            THEN 1 ELSE 0 END AS rndbot_stock,
       CASE WHEN EXISTS (
            SELECT 1 FROM tw_logon.account_banned ab
            WHERE ab.id = a.id AND ab.active = 1
              AND (ab.unbandate > UNIX_TIMESTAMP() OR ab.bandate = ab.unbandate)
            ) THEN 1 ELSE 0 END AS banned_now,
       (SELECT COUNT(DISTINCT gm.groupId)
        FROM tw_char.group_member gm WHERE gm.memberGuid = r.bot) AS group_count,
       (SELECT GROUP_CONCAT(DISTINCT gm.groupId ORDER BY gm.groupId SEPARATOR ',')
        FROM tw_char.group_member gm WHERE gm.memberGuid = r.bot) AS group_ids,
       'NO_REGISTERED_SESSION_SERVER_STOPPED' AS session_status,
       CASE WHEN COUNT(*) = 1
                  AND c.guid IS NOT NULL
                  AND c.active = 1
                  AND c.deleteDate IS NULL
                  AND a.id IS NOT NULL
                  AND UPPER(a.username) LIKE 'RNDBOT%'
                  AND a.active = 1
                  AND a.locked = 0
                  AND a.banned = 0
                  AND NOT EXISTS (
                      SELECT 1 FROM tw_logon.account_banned ab
                      WHERE ab.id = a.id AND ab.active = 1
                        AND (ab.unbandate > UNIX_TIMESTAMP() OR ab.bandate = ab.unbandate)
                  )
            THEN 1 ELSE 0 END AS eligible_under_c0_gate
FROM tw_char.ai_playerbot_random_bots r
LEFT JOIN tw_char.characters c ON c.guid = r.bot
LEFT JOIN tw_logon.account a ON a.id = c.account
WHERE r.owner = 0 AND r.event = 'add' AND r.value <> 0
  AND r.validIn IS NOT NULL
  AND r.time <= UNIX_TIMESTAMP()
  AND UNIX_TIMESTAMP() - r.time < r.validIn
GROUP BY r.bot, c.guid, c.name, c.account, a.id, a.username, c.level, c.class,
         c.race, c.online, c.logout_time, c.active, c.deleteDate, a.last_login,
         a.online, a.active, a.locked
ORDER BY r.bot;

-- Full RNDBOT-stock inventory.  This is evidence only; rows outside the exact
-- current active cohort are never automatic replacements or top-up choices.
SELECT c.guid AS character_guid, c.name AS character_name,
       c.account AS account_id, a.username AS account_name,
       c.level AS character_level, c.class AS class_id, c.race AS race_id,
       c.online AS character_online, c.logout_time AS character_logout_unix,
       FROM_UNIXTIME(c.logout_time) AS character_logout_utc_server,
       c.active AS character_active, c.deleteDate AS character_delete_unix,
       a.last_login AS account_last_login, a.online AS account_online,
       a.active AS account_active, a.locked AS account_locked,
       a.banned AS account_banned_flag,
       CASE WHEN EXISTS (
            SELECT 1 FROM tw_logon.account_banned ab
            WHERE ab.id = a.id AND ab.active = 1
              AND (ab.unbandate > UNIX_TIMESTAMP() OR ab.bandate = ab.unbandate)
            ) THEN 1 ELSE 0 END AS banned_now,
       (SELECT COUNT(*) FROM tw_char.ai_playerbot_random_bots r
        WHERE r.owner = 0 AND r.event = 'add' AND r.bot = c.guid) AS all_add_rows,
       (SELECT COUNT(*) FROM tw_char.ai_playerbot_random_bots r
        WHERE r.owner = 0 AND r.event = 'add' AND r.bot = c.guid
          AND r.value <> 0 AND r.validIn IS NOT NULL
          AND r.time <= UNIX_TIMESTAMP()
          AND UNIX_TIMESTAMP() - r.time < r.validIn) AS active_add_rows,
       (SELECT COUNT(DISTINCT gm.groupId) FROM tw_char.group_member gm
        WHERE gm.memberGuid = c.guid) AS group_count,
       (SELECT GROUP_CONCAT(DISTINCT gm.groupId ORDER BY gm.groupId SEPARATOR ',')
        FROM tw_char.group_member gm WHERE gm.memberGuid = c.guid) AS group_ids,
       'NO_REGISTERED_SESSION_SERVER_STOPPED' AS session_status
FROM tw_char.characters c
JOIN tw_logon.account a ON a.id = c.account
WHERE UPPER(a.username) LIKE 'RNDBOT%'
ORDER BY c.guid;

-- Machine-checkable counts. An exact proposal is permissible only when:
-- active_add_distinct=50, active_add_rows=50, active_rndbot=50, eligible=50.
SELECT
  (SELECT COUNT(*) FROM tw_char.ai_playerbot_random_bots r
   WHERE r.owner=0 AND r.event='add' AND r.value<>0 AND r.validIn IS NOT NULL
     AND r.time<=UNIX_TIMESTAMP() AND UNIX_TIMESTAMP()-r.time<r.validIn)
     AS active_add_rows,
  (SELECT COUNT(DISTINCT r.bot) FROM tw_char.ai_playerbot_random_bots r
   WHERE r.owner=0 AND r.event='add' AND r.value<>0 AND r.validIn IS NOT NULL
     AND r.time<=UNIX_TIMESTAMP() AND UNIX_TIMESTAMP()-r.time<r.validIn)
     AS active_add_distinct,
  (SELECT COUNT(DISTINCT r.bot)
   FROM tw_char.ai_playerbot_random_bots r
   JOIN tw_char.characters c ON c.guid=r.bot
   JOIN tw_logon.account a ON a.id=c.account
   WHERE r.owner=0 AND r.event='add' AND r.value<>0 AND r.validIn IS NOT NULL
     AND r.time<=UNIX_TIMESTAMP() AND UNIX_TIMESTAMP()-r.time<r.validIn
     AND UPPER(a.username) LIKE 'RNDBOT%') AS active_rndbot,
  (SELECT COUNT(DISTINCT r.bot)
   FROM tw_char.ai_playerbot_random_bots r
   JOIN tw_char.characters c ON c.guid=r.bot
   JOIN tw_logon.account a ON a.id=c.account
   WHERE r.owner=0 AND r.event='add' AND r.value<>0 AND r.validIn IS NOT NULL
     AND r.time<=UNIX_TIMESTAMP() AND UNIX_TIMESTAMP()-r.time<r.validIn
     AND c.active=1 AND c.deleteDate IS NULL
     AND UPPER(a.username) LIKE 'RNDBOT%' AND a.active=1 AND a.locked=0
     AND a.banned=0
     AND NOT EXISTS (
       SELECT 1 FROM tw_logon.account_banned ab
       WHERE ab.id=a.id AND ab.active=1
         AND (ab.unbandate>UNIX_TIMESTAMP() OR ab.bandate=ab.unbandate)
     )) AS eligible_rndbot,
  (SELECT COUNT(*) FROM tw_char.characters c
   JOIN tw_logon.account a ON a.id=c.account
   WHERE UPPER(a.username) LIKE 'RNDBOT%') AS total_rndbot_characters;
