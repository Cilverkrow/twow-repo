$ErrorActionPreference='Stop'
$runRoot=$PSScriptRoot
$evidence=Join-Path $runRoot 'evidence'
$client='C:\TW\ComTW\DB\bin\mariadb.exe'
$config='C:\TW\ComTW\server\mangosd.conf'
$migration='C:\TW\rndbot-roster-phase-b-20260830-230336\source\sql\character_updates\20260830230336_ai_playerbot_persistent_active_roster.sql'
$rollback='C:\TW\rndbot-roster-phase-b-20260830-230336\source\src\modules\PlayerBots\sql\other\20260830230336_ai_playerbot_persistent_active_roster_rollback.sql'
$schema='ssc_rndbot_phaseb_20260830_230336'
$stdoutPath=Join-Path $evidence 'disposable-db-test.stdout.txt'
$stderrPath=Join-Path $evidence 'disposable-db-test.stderr.txt'
$metadataPath=Join-Path $evidence 'disposable-db-test.json'
foreach($path in @($stdoutPath,$stderrPath,$metadataPath)){if(Test-Path -LiteralPath $path){throw "Refusing overwrite: $path"}}
if($schema -notmatch '^ssc_rndbot_phaseb_[0-9_]+$'){throw 'Unsafe disposable schema name'}

function Get-ConfigValue([string]$key) {
  foreach($line in [IO.File]::ReadAllLines($config)) {
    $trim=$line.Trim();if(-not $trim -or $trim.StartsWith('#') -or $trim.StartsWith(';')){continue}
    $index=$trim.IndexOf('=')
    if($index-gt0 -and $trim.Substring(0,$index).Trim()-eq$key){return $trim.Substring($index+1).Trim().Trim('"')}
  }
  throw "Missing config key: $key"
}
$descriptor=(Get-ConfigValue 'CharacterDatabase.Info') -split ';'
if($descriptor.Count-lt5){throw 'Invalid CharacterDatabase.Info descriptor'}

$allOut=[Text.StringBuilder]::new();$allErr=[Text.StringBuilder]::new();$steps=[Collections.Generic.List[object]]::new()
function Invoke-Db([string]$name,[string]$sql,[bool]$useSchema=$false) {
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$client;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  foreach($arg in @('--no-defaults','--protocol=TCP','--skip-ssl','--connect-timeout=5','--batch','--raw','--skip-column-names',('--host='+$descriptor[0]),('--port='+$descriptor[1]),('--user='+$descriptor[2]))){[void]$psi.ArgumentList.Add($arg)}
  if($useSchema){[void]$psi.ArgumentList.Add('--database='+$schema)}
  [void]$psi.ArgumentList.Add('--execute='+$sql);$psi.Environment['MYSQL_PWD']=$descriptor[3]
  $process=[Diagnostics.Process]::Start($psi);$out=$process.StandardOutput.ReadToEnd();$err=$process.StandardError.ReadToEnd();$process.WaitForExit();$exit=$process.ExitCode;$process.Dispose()
  $err=$err-replace[regex]::Escape($descriptor[3]),'<redacted>'
  [void]$allOut.AppendLine("STEP=$name EXIT=$exit");[void]$allOut.Append($out);[void]$allErr.AppendLine("STEP=$name EXIT=$exit");[void]$allErr.Append($err)
  $steps.Add([pscustomobject]@{name=$name;exit_code=$exit;stdout_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($out)));stderr_bytes=[Text.Encoding]::UTF8.GetByteCount($err)})
  if($exit-ne0){throw "Disposable DB step failed: $name exit=$exit"}
  return $out
}

$created=$false;$passed=$false
try {
  Invoke-Db 'create-schema' "CREATE DATABASE ``$schema`` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" | Out-Null;$created=$true
  Invoke-Db 'apply-migration' ([IO.File]::ReadAllText($migration)) $true | Out-Null
  $tables=Invoke-Db 'verify-created' "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME LIKE 'ai_playerbot_roster_%' ORDER BY TABLE_NAME;"
  if((@($tables.Trim()-split"`n"|Where-Object{$_}).Count)-ne4){throw 'Expected exactly four roster tables'}
  Invoke-Db 'rollback-source' ([IO.File]::ReadAllText($rollback)) $true | Out-Null
  $remaining=Invoke-Db 'verify-rollback' "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME LIKE 'ai_playerbot_roster_%';"
  if($remaining.Trim()-ne'0'){throw 'Rollback left roster tables'}
  $passed=$true
}
finally {
  if($created){try{Invoke-Db 'drop-disposable-schema' "DROP DATABASE ``$schema``;" | Out-Null}catch{[void]$allErr.AppendLine($_.Exception.Message);$passed=$false}}
  [IO.File]::WriteAllText($stdoutPath,$allOut.ToString(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,$allErr.ToString(),[Text.UTF8Encoding]::new($false))
  $metadata=[ordered]@{task='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B';result=if($passed){'PASS'}else{'FAIL'};disposable_schema=$schema;active_schema_accessed=$false;active_schema_name='<redacted>';client_sha256=(Get-FileHash $client -Algorithm SHA256).Hash;migration_sha256=(Get-FileHash $migration -Algorithm SHA256).Hash;rollback_sha256=(Get-FileHash $rollback -Algorithm SHA256).Hash;steps=$steps;credentials_emitted=$false;schema_removed=$created}
  [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 6)+"`n",[Text.UTF8Encoding]::new($false))
}
if(-not$passed){throw 'Disposable schema test failed'}
'DISPOSABLE_SCHEMA_TEST=PASS'
