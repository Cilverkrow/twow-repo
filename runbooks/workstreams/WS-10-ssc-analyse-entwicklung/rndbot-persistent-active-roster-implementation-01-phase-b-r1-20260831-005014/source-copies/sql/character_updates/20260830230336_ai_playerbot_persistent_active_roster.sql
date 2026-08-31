-- Persistent Active RNDBOT Roster, schema version 1.
-- Membership is an immutable, ordered, versioned GUID snapshot. The singleton
-- current pointer and audit row are advanced in the same InnoDB transaction.

CREATE TABLE IF NOT EXISTS `ai_playerbot_roster_version` (
  `version_id` BIGINT UNSIGNED NOT NULL,
  `previous_version_id` BIGINT UNSIGNED NULL,
  `snapshot_sha256` BINARY(32) NOT NULL,
  `member_count` INT UNSIGNED NOT NULL,
  `created_utc` TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  `created_by` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `reason` TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `operation_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `request_sha256` BINARY(32) NOT NULL,
  `canonical_request` MEDIUMBLOB NOT NULL,
  PRIMARY KEY (`version_id`),
  UNIQUE KEY `uq_roster_version_previous` (`previous_version_id`),
  UNIQUE KEY `uq_roster_version_operation` (`operation_id`),
  CONSTRAINT `ck_roster_version_positive` CHECK (`version_id` > 0),
  CONSTRAINT `ck_roster_version_member_count` CHECK (`member_count` > 0),
  CONSTRAINT `fk_roster_version_previous` FOREIGN KEY (`previous_version_id`)
    REFERENCES `ai_playerbot_roster_version` (`version_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS `ai_playerbot_roster_member` (
  `version_id` BIGINT UNSIGNED NOT NULL,
  `ordinal` INT UNSIGNED NOT NULL,
  `character_guid` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`version_id`,`ordinal`),
  UNIQUE KEY `uq_roster_version_guid` (`version_id`,`character_guid`),
  CONSTRAINT `ck_roster_member_ordinal` CHECK (`ordinal` > 0),
  CONSTRAINT `ck_roster_member_guid` CHECK (`character_guid` > 0),
  CONSTRAINT `fk_roster_member_version` FOREIGN KEY (`version_id`)
    REFERENCES `ai_playerbot_roster_version` (`version_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS `ai_playerbot_roster_current` (
  `singleton_id` TINYINT UNSIGNED NOT NULL,
  `version_id` BIGINT UNSIGNED NULL,
  PRIMARY KEY (`singleton_id`),
  UNIQUE KEY `uq_roster_current_version` (`version_id`),
  CONSTRAINT `fk_roster_current_version` FOREIGN KEY (`version_id`)
    REFERENCES `ai_playerbot_roster_version` (`version_id`),
  CONSTRAINT `ck_roster_current_singleton` CHECK (`singleton_id` = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

INSERT IGNORE INTO `ai_playerbot_roster_current` (`singleton_id`,`version_id`) VALUES (1,NULL);

CREATE TABLE IF NOT EXISTS `ai_playerbot_roster_change` (
  `operation_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `request_sha256` BINARY(32) NOT NULL,
  `operation_type` ENUM('INITIALIZE','EXPAND','ADD','REMOVE','REPLACE','ROLLBACK') NOT NULL,
  `expected_current_version_id` BIGINT UNSIGNED NULL,
  `result_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `resulting_version_id` BIGINT UNSIGNED NOT NULL,
  `before_sha256` BINARY(32) NOT NULL,
  `after_sha256` BINARY(32) NOT NULL,
  `actor` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `reason` TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `canonical_request` MEDIUMBLOB NOT NULL,
  `created_utc` TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`operation_id`),
  UNIQUE KEY `uq_roster_change_result_version` (`resulting_version_id`),
  CONSTRAINT `ck_roster_change_result_version` CHECK (`resulting_version_id` > 0),
  CONSTRAINT `fk_roster_change_version` FOREIGN KEY (`resulting_version_id`)
    REFERENCES `ai_playerbot_roster_version` (`version_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
