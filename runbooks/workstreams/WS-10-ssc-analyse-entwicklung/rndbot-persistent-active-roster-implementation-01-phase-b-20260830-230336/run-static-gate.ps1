$ErrorActionPreference='Stop'
$runRoot=$PSScriptRoot
$source='C:\TW\rndbot-roster-phase-b-20260830-230336\source'
$production='C:\TW\ComTW\source'
$server='C:\TW\ComTW\server'
$beforePath='C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-r1-20260830-194919\evidence\production-before.json'
$outPath=Join-Path $runRoot 'evidence\static-gate-post-build.json'
if(Test-Path -LiteralPath $outPath){throw "Refusing overwrite: $outPath"}
$checks=[Collections.Generic.List[object]]::new()
function Add-Check([string]$name,[bool]$pass,[object]$actual){$checks.Add([pscustomobject]@{name=$name;pass=$pass;actual=$actual});if(-not$pass){throw "Static gate failed: $name"}}
function Invoke-Git([string[]]$arguments){$out=& 'Y:\appentwicklung\Git\cmd\git.exe' -c ('safe.directory='+$source.Replace('\','/')) -C $source @arguments 2>&1;if($LASTEXITCODE-ne0){throw "git failed: $($arguments-join' ') $out"};return @($out)}

$head=[string](Invoke-Git @('rev-parse','HEAD'));$head=$head.Trim()
$tree=[string](Invoke-Git @('rev-parse','HEAD^{tree}'));$tree=$tree.Trim()
Add-Check 'baseline-commit' ($head-eq'42b8a7f742548793910fe8880463aeeb71627fb9') $head
Add-Check 'baseline-tree' ($tree-eq'b2cf4e38fd288a53f61b9f2350f74caa85d606ab') $tree
$diffCheck=& 'Y:\appentwicklung\Git\cmd\git.exe' -c ('safe.directory='+$source.Replace('\','/')) -C $source diff --check 2>&1;$diffExit=$LASTEXITCODE;Add-Check 'git-diff-check' ($diffExit-eq0) @($diffCheck|ForEach-Object{$_.ToString()})
$changed=@(Invoke-Git @('status','--porcelain=v1')|ForEach-Object{$_.Substring(3).Replace('\','/')})
$forbidden=@($changed|Where-Object{$_-match'(^|/)WorldSession\.cpp$|(^|/)Group\.cpp$|PlayerbotLLM|ExternalLLM|DebugAction\.cpp$'})
Add-Check 'forbidden-source-paths-untouched' ($forbidden.Count-eq0) $forbidden
$defaultLine=Select-String -LiteralPath (Join-Path $source 'src\modules\PlayerBots\playerbot\aiplayerbot.conf.dist.in') -Pattern '^AiPlayerbot\.PersistentActiveRoster\.Enabled = 0$'
Add-Check 'feature-default-disabled' ($null-ne$defaultLine) $defaultLine.Line
$newText=(Get-Content -Raw -LiteralPath (Join-Path $source 'src\modules\PlayerBots\playerbot\PersistentActiveRoster.cpp'))+(Get-Content -Raw -LiteralPath (Join-Path $source 'src\modules\PlayerBots\playerbot\PersistentActiveRosterDatabase.cpp'))
Add-Check 'no-llm-or-ollama-code' ($newText-notmatch'(?i)ollama|external.?llm|inference') 'no matches'
Add-Check 'empty-snapshot-vector' ($newText-match'ssc-rndbot-roster-v1\\n.*schema_version=1\\n.*ordinal_base=1\\n.*member_count=') 'canonical serializer present'
$managerText=Get-Content -Raw -LiteralPath (Join-Path $source 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp')
Add-Check 'async-fail-closed' ($managerText-match'Start\(true, sPlayerbotAIConfig\.asyncBotLogin') 'service gate'
Add-Check 'reset-protected' ($managerText-match'Persistent roster enabled: reset rejected') 'reset rejection'
Add-Check 'login-failure-degraded' ($managerText-match'LOGIN_FAILED' -and $managerText-match'no replacement selected') 'DEGRADED diagnostic'
$playerbotMgrText=Get-Content -Raw -LiteralPath (Join-Path $source 'src\modules\PlayerBots\playerbot\PlayerbotMgr.cpp')
Add-Check 'ordinary-logout-protected' ($playerbotMgrText-match'ordinary logout rejected' -and $playerbotMgrText-match'allowMasterLogoutOrShutdown') 'guard plus explicit excluded-path bypass'

$before=Get-Content -Raw -LiteralPath $beforePath|ConvertFrom-Json
$protected=@(
  @{name='production-exe';path=(Join-Path $server 'mangosd.exe');expected=$before.protected_artifacts.production_exe.sha256},
  @{name='mangosd-conf';path=(Join-Path $server 'mangosd.conf');expected=$before.protected_artifacts.mangosd_config.sha256},
  @{name='aiplayerbot-conf';path=(Join-Path $server 'aiplayerbot.conf');expected=$before.protected_artifacts.playerbot_config.sha256}
)
foreach($item in $protected){$actual=(Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash;Add-Check ($item.name+'-unchanged') ($actual-eq$item.expected) $actual}
$productionStatus=@(& 'Y:\appentwicklung\Git\cmd\git.exe' -c ('safe.directory='+$production.Replace('\','/')) -C $production status --short --untracked-files=all)
Add-Check 'production-status-unchanged' (($productionStatus-join"`n")-eq($before.repository.status_lines-join"`n")) $productionStatus
foreach($dirty in $before.repository.dirty_files){$actual=(Get-FileHash -LiteralPath $dirty.file.path -Algorithm SHA256).Hash;Add-Check ('production-dirty-byte-identical:'+[string]$dirty.relative_path) ($actual-eq$dirty.file.sha256) $actual}

$result=[ordered]@{task='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B';result='PASS';captured_utc=[DateTime]::UtcNow.ToString('o');checks=$checks;source_files_changed_only_in_isolated_worktree=$true;production_source_byte_identical=$true;production_exe_changed=$false;active_config_changed=$false;forbidden_files=$forbidden}
[IO.File]::WriteAllText($outPath,($result|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
'STATIC_GATE=PASS'
