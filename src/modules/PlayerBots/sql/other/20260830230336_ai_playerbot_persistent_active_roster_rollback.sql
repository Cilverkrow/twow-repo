-- Destructive rollback for an isolated/test database only.
-- Runtime deployment requires a separate gate and a pre-migration backup.
DROP TABLE IF EXISTS `ai_playerbot_roster_change`;
DROP TABLE IF EXISTS `ai_playerbot_roster_current`;
DROP TABLE IF EXISTS `ai_playerbot_roster_member`;
DROP TABLE IF EXISTS `ai_playerbot_roster_version`;
