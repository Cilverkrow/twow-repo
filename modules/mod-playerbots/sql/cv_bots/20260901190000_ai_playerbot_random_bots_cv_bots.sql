-- Move the PlayerBot event store into the project-owned schema without
-- mutating the legacy source table. The operator must keep mangosd and every
-- other writer stopped while this migration runs.

CREATE TABLE IF NOT EXISTS `cv_bots`.`ai_playerbot_random_bots` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `owner` bigint(20) NOT NULL,
  `bot` bigint(20) NOT NULL,
  `time` bigint(20) NOT NULL,
  `validIn` bigint(20) DEFAULT NULL,
  `event` varchar(45) NOT NULL,
  `value` bigint(20) DEFAULT NULL,
  `data` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_owner_bot_event` (`owner`,`bot`,`event`),
  KEY `bot` (`bot`),
  KEY `event` (`event`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;

DROP TEMPORARY TABLE IF EXISTS `_cv_bots_event_assert`;
CREATE TEMPORARY TABLE `_cv_bots_event_assert` (
  `ok` tinyint(1) NOT NULL CHECK (`ok` = 1)
) ENGINE=InnoDB;

-- Both endpoints and the exact target constraints must exist before any copy.
INSERT INTO `_cv_bots_event_assert` (`ok`)
SELECT IF(
  (SELECT COUNT(*) FROM `information_schema`.`TABLES`
    WHERE `TABLE_SCHEMA`='tw_char' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `TABLE_TYPE`='BASE TABLE') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`TABLES`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `TABLE_TYPE`='BASE TABLE' AND `ENGINE`='InnoDB'
      AND `TABLE_COLLATION`='utf8mb3_general_ci') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots') = 8
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='id' AND `ORDINAL_POSITION`=1
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='NO'
      AND `EXTRA`='auto_increment') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='owner' AND `ORDINAL_POSITION`=2
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='NO'
      AND `EXTRA`='') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='bot' AND `ORDINAL_POSITION`=3
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='NO'
      AND `EXTRA`='') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='time' AND `ORDINAL_POSITION`=4
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='NO'
      AND `EXTRA`='') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='validIn' AND `ORDINAL_POSITION`=5
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='YES'
      AND `EXTRA`='') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='event' AND `ORDINAL_POSITION`=6
      AND `COLUMN_TYPE`='varchar(45)' AND `IS_NULLABLE`='NO'
      AND `EXTRA`=''
      AND `CHARACTER_SET_NAME`='utf8mb3' AND `COLLATION_NAME`='utf8mb3_general_ci') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='value' AND `ORDINAL_POSITION`=7
      AND `COLUMN_TYPE`='bigint(20)' AND `IS_NULLABLE`='YES'
      AND `EXTRA`='') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `COLUMN_NAME`='data' AND `ORDINAL_POSITION`=8
      AND `COLUMN_TYPE`='varchar(255)' AND `IS_NULLABLE`='YES'
      AND `EXTRA`=''
      AND `CHARACTER_SET_NAME`='utf8mb3' AND `COLLATION_NAME`='utf8mb3_general_ci') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='PRIMARY' AND `NON_UNIQUE`=0
      AND `SEQ_IN_INDEX`=1 AND `COLUMN_NAME`='id' AND `INDEX_TYPE`='BTREE') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='PRIMARY') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='uq_owner_bot_event' AND `NON_UNIQUE`=0
      AND `INDEX_TYPE`='BTREE') = 3
  AND
  (SELECT GROUP_CONCAT(`COLUMN_NAME` ORDER BY `SEQ_IN_INDEX` SEPARATOR ',')
    FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='uq_owner_bot_event') = 'owner,bot,event'
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='bot' AND `NON_UNIQUE`=1 AND `SEQ_IN_INDEX`=1
      AND `COLUMN_NAME`='bot' AND `INDEX_TYPE`='BTREE') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots'
      AND `INDEX_NAME`='event' AND `NON_UNIQUE`=1 AND `SEQ_IN_INDEX`=1
      AND `COLUMN_NAME`='event' AND `INDEX_TYPE`='BTREE') = 1
  AND
  (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
    WHERE `TABLE_SCHEMA`='cv_bots' AND `TABLE_NAME`='ai_playerbot_random_bots') = 6,
  1, 0
);
DELETE FROM `_cv_bots_event_assert`;

-- No repair, filtering, or deduplication is permitted.
INSERT INTO `_cv_bots_event_assert` (`ok`)
SELECT IF(
  (SELECT COUNT(*) FROM `tw_char`.`ai_playerbot_random_bots`
    WHERE `event` IS NULL OR `event`='') = 0
  AND
  (SELECT COUNT(*) FROM (
    SELECT `owner`,`bot`,`event`
    FROM `tw_char`.`ai_playerbot_random_bots`
    GROUP BY `owner`,`bot`,`event`
    HAVING COUNT(*) > 1
  ) AS `duplicate_keys`) = 0,
  1, 0
);
DELETE FROM `_cv_bots_event_assert`;

-- A replay may see exact target rows, but never extra or conflicting payload.
INSERT INTO `_cv_bots_event_assert` (`ok`)
SELECT IF(
  (SELECT COUNT(*)
    FROM `cv_bots`.`ai_playerbot_random_bots` AS `target`
    LEFT JOIN `tw_char`.`ai_playerbot_random_bots` AS `source`
      ON `source`.`owner`=`target`.`owner`
     AND `source`.`bot`=`target`.`bot`
     AND `source`.`event`=`target`.`event`
    WHERE `source`.`id` IS NULL
       OR NOT (`source`.`id` <=> `target`.`id`)
       OR NOT (`source`.`time` <=> `target`.`time`)
       OR NOT (`source`.`validIn` <=> `target`.`validIn`)
       OR NOT (`source`.`value` <=> `target`.`value`)
       OR NOT (`source`.`data` <=> `target`.`data`)) = 0
  AND
  (SELECT COUNT(*)
    FROM `tw_char`.`ai_playerbot_random_bots` AS `source`
    JOIN `cv_bots`.`ai_playerbot_random_bots` AS `target`
      ON `target`.`id`=`source`.`id`
    WHERE `target`.`owner`<>`source`.`owner`
       OR `target`.`bot`<>`source`.`bot`
       OR `target`.`event`<>`source`.`event`) = 0,
  1, 0
);
DELETE FROM `_cv_bots_event_assert`;

INSERT INTO `cv_bots`.`ai_playerbot_random_bots`
  (`id`,`owner`,`bot`,`time`,`validIn`,`event`,`value`,`data`)
SELECT
  `source`.`id`,`source`.`owner`,`source`.`bot`,`source`.`time`,
  `source`.`validIn`,`source`.`event`,`source`.`value`,`source`.`data`
FROM `tw_char`.`ai_playerbot_random_bots` AS `source`
LEFT JOIN `cv_bots`.`ai_playerbot_random_bots` AS `target`
  ON `target`.`owner`=`source`.`owner`
 AND `target`.`bot`=`source`.`bot`
 AND `target`.`event`=`source`.`event`
WHERE `target`.`id` IS NULL
ORDER BY `source`.`id`;

-- Verify complete payload equality in both directions.
INSERT INTO `_cv_bots_event_assert` (`ok`)
SELECT IF(
  (SELECT COUNT(*) FROM `tw_char`.`ai_playerbot_random_bots`) =
    (SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots`)
  AND
  (SELECT COUNT(*)
    FROM `tw_char`.`ai_playerbot_random_bots` AS `source`
    WHERE NOT EXISTS (
      SELECT 1 FROM `cv_bots`.`ai_playerbot_random_bots` AS `target`
      WHERE `target`.`id` <=> `source`.`id`
        AND `target`.`owner` <=> `source`.`owner`
        AND `target`.`bot` <=> `source`.`bot`
        AND `target`.`time` <=> `source`.`time`
        AND `target`.`validIn` <=> `source`.`validIn`
        AND `target`.`event` <=> `source`.`event`
        AND `target`.`value` <=> `source`.`value`
        AND `target`.`data` <=> `source`.`data`)) = 0
  AND
  (SELECT COUNT(*)
    FROM `cv_bots`.`ai_playerbot_random_bots` AS `target`
    WHERE NOT EXISTS (
      SELECT 1 FROM `tw_char`.`ai_playerbot_random_bots` AS `source`
      WHERE `source`.`id` <=> `target`.`id`
        AND `source`.`owner` <=> `target`.`owner`
        AND `source`.`bot` <=> `target`.`bot`
        AND `source`.`time` <=> `target`.`time`
        AND `source`.`validIn` <=> `target`.`validIn`
        AND `source`.`event` <=> `target`.`event`
        AND `source`.`value` <=> `target`.`value`
        AND `source`.`data` <=> `target`.`data`)) = 0,
  1, 0
);
DELETE FROM `_cv_bots_event_assert`;

-- Hash an ordered list of length-tagged row fingerprints. NULL and empty
-- strings intentionally have different encodings.
SET SESSION `group_concat_max_len` = 1073741824;
DROP TEMPORARY TABLE IF EXISTS `_cv_bots_source_fingerprint`;
DROP TEMPORARY TABLE IF EXISTS `_cv_bots_target_fingerprint`;
CREATE TEMPORARY TABLE `_cv_bots_source_fingerprint` (`row_hash` char(64) NOT NULL) ENGINE=InnoDB;
CREATE TEMPORARY TABLE `_cv_bots_target_fingerprint` (`row_hash` char(64) NOT NULL) ENGINE=InnoDB;

INSERT INTO `_cv_bots_source_fingerprint` (`row_hash`)
SELECT SHA2(CONCAT(
  'id=',`id`,'|owner=',`owner`,'|bot=',`bot`,'|time=',`time`,
  '|validIn=',IF(`validIn` IS NULL,'N',CONCAT('V',`validIn`)),
  '|event=V',OCTET_LENGTH(`event`),':',`event`,
  '|value=',IF(`value` IS NULL,'N',CONCAT('V',`value`)),
  '|data=',IF(`data` IS NULL,'N',CONCAT('V',OCTET_LENGTH(`data`),':',`data`))
), 256)
FROM `tw_char`.`ai_playerbot_random_bots`;

INSERT INTO `_cv_bots_target_fingerprint` (`row_hash`)
SELECT SHA2(CONCAT(
  'id=',`id`,'|owner=',`owner`,'|bot=',`bot`,'|time=',`time`,
  '|validIn=',IF(`validIn` IS NULL,'N',CONCAT('V',`validIn`)),
  '|event=V',OCTET_LENGTH(`event`),':',`event`,
  '|value=',IF(`value` IS NULL,'N',CONCAT('V',`value`)),
  '|data=',IF(`data` IS NULL,'N',CONCAT('V',OCTET_LENGTH(`data`),':',`data`))
), 256)
FROM `cv_bots`.`ai_playerbot_random_bots`;

INSERT INTO `_cv_bots_event_assert` (`ok`)
SELECT IF(
  (SELECT SHA2(COALESCE(GROUP_CONCAT(`row_hash` ORDER BY `row_hash` SEPARATOR ''),''),256)
    FROM `_cv_bots_source_fingerprint`) =
  (SELECT SHA2(COALESCE(GROUP_CONCAT(`row_hash` ORDER BY `row_hash` SEPARATOR ''),''),256)
    FROM `_cv_bots_target_fingerprint`),
  1, 0
);

DROP TEMPORARY TABLE `_cv_bots_source_fingerprint`;
DROP TEMPORARY TABLE `_cv_bots_target_fingerprint`;
DROP TEMPORARY TABLE `_cv_bots_event_assert`;
