SELECT `line` FROM (
SELECT CONCAT('TABLE\t',t.TABLE_NAME,'\t',COALESCE(t.ENGINE,''),'\t',COALESCE(t.TABLE_COLLATION,'')) line
FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA=DATABASE() AND t.TABLE_NAME IN
('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')
UNION ALL
SELECT CONCAT('COLUMN\t',c.TABLE_NAME,'\t',LPAD(c.ORDINAL_POSITION,3,'0'),'\t',c.COLUMN_NAME,'\t',c.COLUMN_TYPE,'\t',
c.IS_NULLABLE,'\t',IF(c.COLUMN_DEFAULT IS NULL,'NULL',CONCAT('HEX:',HEX(c.COLUMN_DEFAULT))),'\t',
COALESCE(c.CHARACTER_SET_NAME,''),'\t',COALESCE(c.COLLATION_NAME,''),'\t',COALESCE(c.EXTRA,''))
FROM information_schema.COLUMNS c WHERE c.TABLE_SCHEMA=DATABASE() AND c.TABLE_NAME IN
('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')
UNION ALL
SELECT CONCAT('INDEX\t',s.TABLE_NAME,'\t',s.INDEX_NAME,'\t',s.NON_UNIQUE,'\t',LPAD(s.SEQ_IN_INDEX,3,'0'),'\t',
s.COLUMN_NAME,'\t',COALESCE(s.COLLATION,''),'\t',COALESCE(s.SUB_PART,''),'\t',s.INDEX_TYPE)
FROM information_schema.STATISTICS s WHERE s.TABLE_SCHEMA=DATABASE() AND s.TABLE_NAME IN
('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')
UNION ALL
SELECT CONCAT('FK\t',k.TABLE_NAME,'\t',k.CONSTRAINT_NAME,'\t',LPAD(k.ORDINAL_POSITION,3,'0'),'\t',k.COLUMN_NAME,'\t',
k.REFERENCED_TABLE_NAME,'\t',k.REFERENCED_COLUMN_NAME,'\t',r.UPDATE_RULE,'\t',r.DELETE_RULE)
FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.TABLE_NAME=k.TABLE_NAME AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME
WHERE k.CONSTRAINT_SCHEMA=DATABASE() AND k.TABLE_NAME IN
('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')
AND k.REFERENCED_TABLE_NAME IS NOT NULL
UNION ALL
SELECT CONCAT('CHECK\t',cc.TABLE_NAME,'\t',cc.CONSTRAINT_NAME,'\t',HEX(cc.CHECK_CLAUSE))
FROM information_schema.CHECK_CONSTRAINTS cc WHERE cc.CONSTRAINT_SCHEMA=DATABASE() AND cc.TABLE_NAME IN
('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change')
) schema_lines ORDER BY `line`;
