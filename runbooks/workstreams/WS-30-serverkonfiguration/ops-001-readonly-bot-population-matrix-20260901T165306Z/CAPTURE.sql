-- TASK_ID=OPS-001-READONLY-BOT-POPULATION-MATRIX
-- Read-only evidence query. The runner permits only the two session-local SETs
-- below and SELECT statements, verifies SELECT-only grants before execution,
-- and replaces the token-salt placeholder in memory. No names or account IDs
-- are projected. Character and group identifiers are one-run pseudonyms.

SET @capture_epoch = UNIX_TIMESTAMP();
SET @token_salt = '__TOKEN_SALT__';

SELECT 'CAPTURE_META', UTC_TIMESTAMP(6), @capture_epoch;

SELECT 'DML_COUNTER_BEFORE', VARIABLE_NAME, VARIABLE_VALUE
FROM information_schema.GLOBAL_STATUS
WHERE VARIABLE_NAME IN (
  'COM_INSERT','COM_INSERT_SELECT','COM_UPDATE','COM_UPDATE_MULTI',
  'COM_DELETE','COM_DELETE_MULTI','COM_REPLACE','COM_REPLACE_SELECT',
  'COM_CREATE_DB','COM_CREATE_EVENT','COM_CREATE_FUNCTION','COM_CREATE_INDEX',
  'COM_CREATE_PROCEDURE','COM_CREATE_ROLE','COM_CREATE_SERVER','COM_CREATE_TABLE',
  'COM_CREATE_TEMPORARY_TABLE','COM_CREATE_TRIGGER','COM_CREATE_USER','COM_CREATE_VIEW',
  'COM_ALTER_DB','COM_ALTER_DB_UPGRADE','COM_ALTER_EVENT','COM_ALTER_FUNCTION',
  'COM_ALTER_PROCEDURE','COM_ALTER_SERVER','COM_ALTER_TABLE','COM_ALTER_USER',
  'COM_DROP_DB','COM_DROP_EVENT','COM_DROP_FUNCTION','COM_DROP_INDEX',
  'COM_DROP_PROCEDURE','COM_DROP_ROLE','COM_DROP_SERVER','COM_DROP_TABLE',
  'COM_DROP_TEMPORARY_TABLE','COM_DROP_TRIGGER','COM_DROP_USER','COM_DROP_VIEW',
  'COM_TRUNCATE','COM_GRANT','COM_REVOKE','COM_LOAD','COM_LOCK_TABLES',
  'COM_UNLOCK_TABLES','COM_RENAME_TABLE','COM_CALL_PROCEDURE'
)
ORDER BY VARIABLE_NAME;

SELECT 'SCHEMA_COLUMN', TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION,
       COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY
FROM information_schema.COLUMNS
WHERE (TABLE_SCHEMA = 'tw_char' AND (
        (TABLE_NAME = 'ai_playerbot_random_bots' AND COLUMN_NAME IN
          ('id','owner','bot','time','validIn','event','value')) OR
        (TABLE_NAME = 'characters' AND COLUMN_NAME IN
          ('guid','account','class','online','active','deleteDate')) OR
        (TABLE_NAME = 'group_member' AND COLUMN_NAME IN
          ('groupId','memberGuid')) OR
        (TABLE_NAME = 'groups' AND COLUMN_NAME IN
          ('groupId','leaderGuid'))
      ))
   OR (TABLE_SCHEMA = 'tw_logon' AND TABLE_NAME = 'account' AND COLUMN_NAME IN
          ('id','username','online','active','locked','banned'))
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;

SELECT 'SCHEMA_INDEX', TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE,
       SEQ_IN_INDEX, COLUMN_NAME, INDEX_TYPE
FROM information_schema.STATISTICS
WHERE (TABLE_SCHEMA = 'tw_char' AND TABLE_NAME IN
          ('ai_playerbot_random_bots','characters','group_member','groups'))
   OR (TABLE_SCHEMA = 'tw_logon' AND TABLE_NAME = 'account')
ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;

SELECT 'EVENT_ROW', r.id, r.event,
       SHA2(CONCAT(@token_salt, ':character:', r.bot), 256),
       r.value, r.time, r.validIn,
       CASE WHEN r.value <> 0 AND r.validIn IS NOT NULL
                  AND r.time <= @capture_epoch
                  AND @capture_epoch - r.time < r.validIn
            THEN 1 ELSE 0 END
FROM tw_char.ai_playerbot_random_bots r
WHERE r.owner = 0 AND r.event IN ('add','login','specNo')
ORDER BY r.event, r.bot, r.id;

SELECT 'EVENT_DUPLICATE_SUMMARY', COUNT(*)
FROM (
  SELECT r.bot, r.event
  FROM tw_char.ai_playerbot_random_bots r
  WHERE r.owner = 0 AND r.event IN ('add','login','specNo')
  GROUP BY r.bot, r.event
  HAVING COUNT(*) <> 1
) duplicate_events;

SELECT 'EVENT_DUPLICATE', r.event,
       SHA2(CONCAT(@token_salt, ':character:', r.bot), 256), COUNT(*)
FROM tw_char.ai_playerbot_random_bots r
WHERE r.owner = 0 AND r.event IN ('add','login','specNo')
GROUP BY r.event, r.bot
HAVING COUNT(*) <> 1
ORDER BY r.event, r.bot;

SELECT 'SPEC_DISTRIBUTION',
       CASE WHEN a.id IS NULL THEN 'MISSING_ACCOUNT'
            WHEN UPPER(a.username) LIKE 'RNDBOT%' THEN 'RNDBOT'
            ELSE 'NON_RNDBOT' END,
       c.class, r.value, COUNT(*)
FROM tw_char.ai_playerbot_random_bots r
LEFT JOIN tw_char.characters c ON c.guid = r.bot
LEFT JOIN tw_logon.account a ON a.id = c.account
WHERE r.owner = 0 AND r.event = 'specNo'
GROUP BY CASE WHEN a.id IS NULL THEN 'MISSING_ACCOUNT'
              WHEN UPPER(a.username) LIKE 'RNDBOT%' THEN 'RNDBOT'
              ELSE 'NON_RNDBOT' END,
         c.class, r.value
ORDER BY 2, 3, 4;

SELECT 'RNDBOT_SPEC_COVERAGE',
       COUNT(*),
       COALESCE(SUM(CASE WHEN s.bot IS NOT NULL THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN s.bot IS NULL THEN 1 ELSE 0 END), 0)
FROM tw_char.characters c
JOIN tw_logon.account a ON a.id = c.account
LEFT JOIN (
  SELECT bot
  FROM tw_char.ai_playerbot_random_bots
  WHERE owner = 0 AND event = 'specNo'
  GROUP BY bot
) s ON s.bot = c.guid
WHERE UPPER(a.username) LIKE 'RNDBOT%';

SELECT 'GROUP_MEMBER',
       SHA2(CONCAT(@token_salt, ':group:', g.groupId), 256),
       SHA2(CONCAT(@token_salt, ':character:', gm.memberGuid), 256),
       SHA2(CONCAT(@token_salt, ':character:', g.leaderGuid), 256),
       CASE WHEN ma.id IS NULL THEN 'MISSING_ACCOUNT'
            WHEN UPPER(ma.username) LIKE 'RNDBOT%' THEN 'RNDBOT'
            ELSE 'NON_RNDBOT' END,
       CASE WHEN la.id IS NULL THEN 'MISSING_ACCOUNT'
            WHEN UPPER(la.username) LIKE 'RNDBOT%' THEN 'RNDBOT'
            ELSE 'NON_RNDBOT' END,
       mc.class,
       CASE WHEN mc.guid IS NULL THEN 0 ELSE 1 END,
       COALESCE(mc.active, 0), CASE WHEN mc.deleteDate IS NULL THEN 0 ELSE 1 END,
       COALESCE(mc.online, 0), COALESCE(ma.online, 0),
       CASE WHEN lc.guid IS NULL THEN 0 ELSE 1 END,
       COALESCE(lc.active, 0), CASE WHEN lc.deleteDate IS NULL THEN 0 ELSE 1 END,
       COALESCE(lc.online, 0), COALESCE(la.online, 0),
       CASE WHEN gm.memberGuid <> g.leaderGuid
                  AND mc.guid IS NOT NULL AND mc.active = 1 AND mc.deleteDate IS NULL
                  AND ma.id IS NOT NULL AND UPPER(ma.username) LIKE 'RNDBOT%'
                  AND ma.active = 1 AND ma.locked = 0 AND ma.banned = 0
                  AND lc.guid IS NOT NULL AND lc.active = 1 AND lc.deleteDate IS NULL
                  AND la.id IS NOT NULL AND UPPER(la.username) NOT LIKE 'RNDBOT%'
                  AND la.active = 1 AND la.locked = 0 AND la.banned = 0
            THEN 1 ELSE 0 END
FROM tw_char.group_member gm
JOIN tw_char.groups g ON g.groupId = gm.groupId
LEFT JOIN tw_char.characters mc ON mc.guid = gm.memberGuid
LEFT JOIN tw_logon.account ma ON ma.id = mc.account
LEFT JOIN tw_char.characters lc ON lc.guid = g.leaderGuid
LEFT JOIN tw_logon.account la ON la.id = lc.account
ORDER BY g.groupId, gm.memberGuid;

SELECT 'GROUP_SUMMARY',
       COUNT(DISTINCT CASE WHEN gm.memberGuid <> g.leaderGuid
                  AND mc.guid IS NOT NULL AND mc.active = 1 AND mc.deleteDate IS NULL
                  AND ma.id IS NOT NULL AND UPPER(ma.username) LIKE 'RNDBOT%'
                  AND ma.active = 1 AND ma.locked = 0 AND ma.banned = 0
                  AND lc.guid IS NOT NULL AND lc.active = 1 AND lc.deleteDate IS NULL
                  AND la.id IS NOT NULL AND UPPER(la.username) NOT LIKE 'RNDBOT%'
                  AND la.active = 1 AND la.locked = 0 AND la.banned = 0
            THEN gm.memberGuid END),
       COUNT(DISTINCT CASE WHEN gm.memberGuid <> g.leaderGuid
                  AND mc.guid IS NOT NULL AND mc.active = 1 AND mc.deleteDate IS NULL
                  AND ma.id IS NOT NULL AND UPPER(ma.username) LIKE 'RNDBOT%'
                  AND ma.active = 1 AND ma.locked = 0 AND ma.banned = 0
                  AND lc.guid IS NOT NULL AND lc.active = 1 AND lc.deleteDate IS NULL
                  AND la.id IS NOT NULL AND UPPER(la.username) NOT LIKE 'RNDBOT%'
                  AND la.active = 1 AND la.locked = 0 AND la.banned = 0
                  AND COALESCE(lc.online, 0) <> 0
            THEN gm.memberGuid END)
FROM tw_char.group_member gm
JOIN tw_char.groups g ON g.groupId = gm.groupId
LEFT JOIN tw_char.characters mc ON mc.guid = gm.memberGuid
LEFT JOIN tw_logon.account ma ON ma.id = mc.account
LEFT JOIN tw_char.characters lc ON lc.guid = g.leaderGuid
LEFT JOIN tw_logon.account la ON la.id = lc.account;

SELECT 'MISSING_REFERENCE',
       COALESCE(SUM(CASE WHEN g.groupId IS NULL THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN mc.guid IS NULL THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN g.groupId IS NOT NULL AND lc.guid IS NULL THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN mc.guid IS NOT NULL AND ma.id IS NULL THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN lc.guid IS NOT NULL AND la.id IS NULL THEN 1 ELSE 0 END), 0)
FROM tw_char.group_member gm
LEFT JOIN tw_char.groups g ON g.groupId = gm.groupId
LEFT JOIN tw_char.characters mc ON mc.guid = gm.memberGuid
LEFT JOIN tw_logon.account ma ON ma.id = mc.account
LEFT JOIN tw_char.characters lc ON lc.guid = g.leaderGuid
LEFT JOIN tw_logon.account la ON la.id = lc.account;

SELECT 'ONLINE_FLAGS',
       COALESCE(SUM(CASE WHEN UPPER(a.username) LIKE 'RNDBOT%' AND COALESCE(c.online,0) <> 0 THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN UPPER(a.username) LIKE 'RNDBOT%' AND COALESCE(a.online,0) <> 0 THEN 1 ELSE 0 END), 0),
       (SELECT COUNT(*) FROM tw_char.group_member gm
        JOIN tw_char.characters mc ON mc.guid = gm.memberGuid
        WHERE COALESCE(mc.online,0) <> 0),
       (SELECT COUNT(*) FROM tw_char.groups g
        JOIN tw_char.characters lc ON lc.guid = g.leaderGuid
        WHERE COALESCE(lc.online,0) <> 0)
FROM tw_char.characters c
JOIN tw_logon.account a ON a.id = c.account;

SELECT 'DML_COUNTER_AFTER', VARIABLE_NAME, VARIABLE_VALUE
FROM information_schema.GLOBAL_STATUS
WHERE VARIABLE_NAME IN (
  'COM_INSERT','COM_INSERT_SELECT','COM_UPDATE','COM_UPDATE_MULTI',
  'COM_DELETE','COM_DELETE_MULTI','COM_REPLACE','COM_REPLACE_SELECT',
  'COM_CREATE_DB','COM_CREATE_EVENT','COM_CREATE_FUNCTION','COM_CREATE_INDEX',
  'COM_CREATE_PROCEDURE','COM_CREATE_ROLE','COM_CREATE_SERVER','COM_CREATE_TABLE',
  'COM_CREATE_TEMPORARY_TABLE','COM_CREATE_TRIGGER','COM_CREATE_USER','COM_CREATE_VIEW',
  'COM_ALTER_DB','COM_ALTER_DB_UPGRADE','COM_ALTER_EVENT','COM_ALTER_FUNCTION',
  'COM_ALTER_PROCEDURE','COM_ALTER_SERVER','COM_ALTER_TABLE','COM_ALTER_USER',
  'COM_DROP_DB','COM_DROP_EVENT','COM_DROP_FUNCTION','COM_DROP_INDEX',
  'COM_DROP_PROCEDURE','COM_DROP_ROLE','COM_DROP_SERVER','COM_DROP_TABLE',
  'COM_DROP_TEMPORARY_TABLE','COM_DROP_TRIGGER','COM_DROP_USER','COM_DROP_VIEW',
  'COM_TRUNCATE','COM_GRANT','COM_REVOKE','COM_LOAD','COM_LOCK_TABLES',
  'COM_UNLOCK_TABLES','COM_RENAME_TABLE','COM_CALL_PROCEDURE'
)
ORDER BY VARIABLE_NAME;
