INSERT INTO `cv_bots`.`ai_playerbot_random_bots`
  (`owner`,`bot`,`time`,`event`,`value`)
VALUES (0,0,0,'bot_delete',1)
ON DUPLICATE KEY UPDATE `time`=VALUES(`time`),`validIn`=NULL,
  `value`=VALUES(`value`),`data`=NULL;
