SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;
SELECT 'tw_logon.migrations',Id,Name,Hash,AppliedAt FROM tw_logon.migrations ORDER BY Id;
SELECT 'tw_world.migrations',Id,Name,Hash,AppliedAt FROM tw_world.migrations ORDER BY Id;
SELECT 'tw_char.migrations',Id,Name,Hash,AppliedAt FROM tw_char.migrations ORDER BY Id;
SELECT 'donation_point_progress',COUNT(*),COALESCE(SUM(accumulated_ms),0),MIN(accumulated_ms),MAX(accumulated_ms) FROM tw_logon.donation_point_progress;
SELECT 'character_inventory_copy',COUNT(*) FROM tw_char.character_inventory_copy;
