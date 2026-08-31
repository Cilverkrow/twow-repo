[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$Root='C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352'
$Evidence=Join-Path $Root 'evidence'
$Config='C:\TW\ComTW\server\mangosd.conf'
$Client='C:\TW\ComTW\DB\bin\mariadb.exe'
$SqlPath=Join-Path $Evidence 'db-discovery-selects.sql'
$OutPath=Join-Path $Evidence 'db-discovery-selects.stdout.txt'
$ErrPath=Join-Path $Evidence 'db-discovery-selects.stderr.txt'
$MetaPath=Join-Path $Evidence 'db-discovery-selects.metadata.json'
foreach($p in @($SqlPath,$OutPath,$ErrPath,$MetaPath)){if(Test-Path -LiteralPath $p){throw "Refusing to overwrite $p"}}

function ConfigValue([string]$key){foreach($line in [IO.File]::ReadAllLines($Config)){$t=$line.Trim();if(!$t-or$t.StartsWith('#')-or$t.StartsWith(';')){continue};$i=$t.IndexOf('=');if($i-gt 0-and$t.Substring(0,$i).Trim()-eq$key){return $t.Substring($i+1).Trim().Trim('"')}};throw "Missing $key"}

$sql=@"
SELECT 'SECTION','TABLES';
SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ('tw_logon','tw_char') AND (TABLE_NAME IN ('account','characters','ai_playerbot_random_bots','group_member','groups') OR TABLE_NAME LIKE '%skill%') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT 'SECTION','COLUMNS';
SELECT TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ('tw_logon','tw_char') AND TABLE_NAME IN ('account','characters','ai_playerbot_random_bots','group_member','groups','character_skills') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;
SELECT 'SECTION','RNDBOT_COUNTS';
SELECT COUNT(DISTINCT a.id),COUNT(c.guid) FROM tw_logon.account a JOIN tw_char.characters c ON c.account=a.id WHERE a.username LIKE 'RNDBOT%';
SELECT 'SECTION','EVENT_COUNTS';
SELECT event,COUNT(*),SUM(value<>0),SUM(validIn=0),MIN(bot),MAX(bot) FROM tw_char.ai_playerbot_random_bots WHERE owner=0 AND event IN ('add','login','logout','bot_count') GROUP BY event ORDER BY event;
SELECT 'SECTION','ADD_LOGIN_ROWS';
SELECT bot,event,value,time,validIn FROM tw_char.ai_playerbot_random_bots WHERE owner=0 AND event IN ('add','login') ORDER BY bot,event LIMIT 100;
SELECT 'SECTION','RNDBOT_GROUP_MEMBERS';
SELECT COUNT(*) FROM tw_char.group_member gm JOIN tw_char.characters c ON c.guid=gm.memberGuid JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%';
"@
[IO.File]::WriteAllText($SqlPath,$sql,[Text.UTF8Encoding]::new($false))
$desc=(ConfigValue 'LoginDatabase.Info')-split ';'
$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$Client;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
foreach($arg in @('--no-defaults','--protocol=TCP','--skip-ssl','--connect-timeout=3','--batch','--raw','--skip-column-names',('--host='+$desc[0]),('--port='+$desc[1]),('--user='+$desc[2]),('--execute='+$sql))){[void]$psi.ArgumentList.Add($arg)}
$psi.Environment['MYSQL_PWD']=$desc[3]
$proc=[Diagnostics.Process]::new();$proc.StartInfo=$psi;$start=[DateTime]::UtcNow;[void]$proc.Start();$stdout=$proc.StandardOutput.ReadToEnd();$stderr=$proc.StandardError.ReadToEnd();$proc.WaitForExit();$end=[DateTime]::UtcNow
$stderr=$stderr-replace[regex]::Escape($desc[3]),'<redacted>'
[IO.File]::WriteAllText($OutPath,$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($ErrPath,$stderr,[Text.UTF8Encoding]::new($false))
$meta=[ordered]@{statement_class='SELECT only';sql_sha256=(Get-FileHash $SqlPath -Algorithm SHA256).Hash;started_utc=$start.ToString('o');finished_utc=$end.ToString('o');exit_code=$proc.ExitCode;stdout_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stdout)));stdout_size_bytes=[Text.Encoding]::UTF8.GetByteCount($stdout);stderr=$stderr;database_writes=@();credentials_emitted=$false}
[IO.File]::WriteAllText($MetaPath,($meta|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false));$meta|ConvertTo-Json -Depth 5
if($proc.ExitCode-ne 0){exit $proc.ExitCode}
