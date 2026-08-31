[CmdletBinding()]
param([switch]$SkipDatabase)

$ErrorActionPreference = 'Stop'
$RunRoot = 'C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848'
$Evidence = Join-Path $RunRoot 'evidence'
$Repo = 'C:\TW\ComTW\source'
$Server = 'C:\TW\ComTW\server'
$DbRoot = 'C:\TW\ComTW\DB'
$DbData = Join-Path $DbRoot 'data'

function Write-NewUtf8([string]$Path, [AllowEmptyString()][string]$Content) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite evidence: $Path" }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}
function Write-NewJson([string]$Name, $Value) {
    Write-NewUtf8 (Join-Path $Evidence $Name) (($Value | ConvertTo-Json -Depth 12) + "`n")
}
function Invoke-Git([string[]]$Arguments) {
    $output = & git -c safe.directory=C:/TW/ComTW/source -C $Repo @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join "`n")" }
    ($output -join "`n")
}
function Get-HashRecord([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    [ordered]@{ path=$item.FullName; size_bytes=$item.Length; creation_utc=$item.CreationTimeUtc.ToString('o'); last_write_utc=$item.LastWriteTimeUtc.ToString('o'); sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}
function Get-ConfigMap([string]$Path) {
    $map = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#') -or $trim.StartsWith(';')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -gt 0) { $map[$trim.Substring(0,$idx).Trim()] = $trim.Substring($idx+1).Trim() }
    }
    $map
}

# One correctly quoted, finite, read-only MariaDB connection attempt.
if (-not $SkipDatabase) {
$conf = Get-ConfigMap (Join-Path $Server 'mangosd.conf')
$parts = $conf['LoginDatabase.Info'].Trim('"') -split ';'
$client = Join-Path $DbRoot 'bin\mariadb.exe'
$sql = @"
SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;
SELECT 'tw_logon.migrations',Id,Name,Hash,AppliedAt FROM tw_logon.migrations ORDER BY Id;
SELECT 'tw_world.migrations',Id,Name,Hash,AppliedAt FROM tw_world.migrations ORDER BY Id;
SELECT 'tw_char.migrations',Id,Name,Hash,AppliedAt FROM tw_char.migrations ORDER BY Id;
SELECT 'donation_point_progress',COUNT(*),COALESCE(SUM(accumulated_ms),0),MIN(accumulated_ms),MAX(accumulated_ms) FROM tw_logon.donation_point_progress;
SELECT 'character_inventory_copy',COUNT(*) FROM tw_char.character_inventory_copy;
"@
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $client
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($arg in @('--no-defaults','--protocol=TCP','--connect-timeout=3','--batch','--raw','--skip-column-names',("--host="+$parts[0]),("--port="+$parts[1]),("--user="+$parts[2]),("--execute="+$sql))) { [void]$psi.ArgumentList.Add($arg) }
$psi.Environment['MYSQL_PWD'] = $parts[3]
$proc = [Diagnostics.Process]::new()
$proc.StartInfo = $psi
$started = $proc.Start()
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
$dbResult = [ordered]@{
    attempted_utc = [DateTime]::UtcNow.ToString('o')
    client = Get-HashRecord $client
    finite_connect_timeout_seconds = 3
    statements = @($sql -split "`n" | Where-Object { $_.Trim() })
    statement_classification = 'SELECT only'
    write_statements = @()
    exit_code = $proc.ExitCode
    stdout = @($stdout -split "`r?`n" | Where-Object { $_ })
    stderr = @(($stderr -replace [regex]::Escape($parts[3]), '<redacted>') -split "`r?`n" | Where-Object { $_ })
    credentials_emitted = $false
}
Write-NewJson 'database-readonly-query-result.json' $dbResult
}

$head = (Invoke-Git @('rev-parse','HEAD')).Trim()
$integrationSpecs = @(
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp'; patterns=@('Generate\(','curl_easy_perform','LLM generation') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp'; patterns=@('GenerateResponsePackets','std::async','SendDelayedPacket') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/PlayerbotAI.cpp'; patterns=@('UpdateAI\(','UpdateAIInternal','SendDelayedPacket','ReceiveDelayedPacket','detach\(','TellPlayerNoFacing','TellPlayer\(') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/strategy/values/RpgTriggers.cpp'; patterns=@('LLMEnabled','LLMRpgAIChatChance') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/RpgSubActions.cpp'; patterns=@('future','wait_for','get\(') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp'; patterns=@('UpdateAIInternal','UpdateSessions') },
    [pscustomobject]@{ path='src/game/World/World.cpp'; patterns=@('World::Update\(','UpdateSessions','donation_point_progress') },
    [pscustomobject]@{ path='src/game/Server/WorldSession.h'; patterns=@('World::UpdateSessions','packet') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp'; patterns=@('LLMEnabled','LLMMaxSimultaneousGenerations','LLMMaxSimultaniousGenerations','LLMGenerationTimeout') },
    [pscustomobject]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp'; patterns=@('Generate\(','LLM') }
)
$integration = @()
$excerptLines = [Collections.Generic.List[string]]::new()
foreach ($spec in $integrationSpecs) {
    & git -c safe.directory=C:/TW/ComTW/source -C $Repo cat-file -e "HEAD:$($spec.path)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        $integration += [pscustomobject][ordered]@{ path=$spec.path; exists_at_head=$false; head_blob=$null; matches=@() }
        continue
    }
    $content = Invoke-Git @('show',"HEAD:$($spec.path)")
    $lines = $content -split "`n"
    $fileMatches = @()
    for ($i=0; $i -lt $lines.Count; $i++) {
        foreach ($pattern in $spec.patterns) {
            if ($lines[$i] -match $pattern) {
                $fileMatches += [pscustomobject][ordered]@{ line=$i+1; pattern=$pattern; text=$lines[$i].TrimEnd() }
                break
            }
        }
    }
    $integration += [pscustomobject][ordered]@{ path=$spec.path; exists_at_head=$true; head_blob=(Invoke-Git @('rev-parse',"HEAD:$($spec.path)")).Trim(); matches=$fileMatches }
    $excerptLines.Add("===== $($spec.path) =====")
    foreach ($match in $fileMatches) { $excerptLines.Add(('{0,6}: {1}' -f $match.line,$match.text)) }
}
Write-NewJson 'integration-points.json' ([ordered]@{
    candidate_commit=$head
    scope='Candidate-only source landmarks for later revalidation; no source integration performed.'
    files=$integration
    warning='Current SendDelayedPacket/ReceiveDelayedPacket uses detached threads and raw WorldSession pointer capture; it must not be reused for the bounded bridge integration.'
})
Write-NewUtf8 (Join-Path $Evidence 'integration-point-matches.txt') (($excerptLines -join "`n")+"`n")

$cmake = (Invoke-Git @('show','HEAD:CMakeLists.txt')) -split "`n"
$cmakeMatches = @()
for ($i=0; $i -lt $cmake.Count; $i++) { if ($cmake[$i] -match 'rev-parse|GIT_REVISION|revision.h') { $cmakeMatches += ('{0,6}: {1}' -f ($i+1),$cmake[$i]) } }
Write-NewUtf8 (Join-Path $Evidence 'cmake-revision-generation.txt') (($cmakeMatches -join "`n")+"`n")

# Reconcile hashes captured near the beginning with fresh values at the end.
$exeBefore = Get-Content -Raw -LiteralPath (Join-Path $Evidence 'exe-evidence.json') | ConvertFrom-Json
$configBefore = Get-Content -Raw -LiteralPath (Join-Path $Evidence 'config-evidence.json') | ConvertFrom-Json
$offlineBefore = Get-Content -Raw -LiteralPath (Join-Path $Evidence 'offline-schema-evidence.json') | ConvertFrom-Json
$before = [ordered]@{}
$before[$exeBefore.production.path] = $exeBefore.production.sha256
$before[$configBefore.mangosd.active.path] = $configBefore.mangosd.active.sha256
$before[$configBefore.aiplayerbot.active.path] = $configBefore.aiplayerbot.active.sha256
foreach ($record in $offlineBefore.required_files) { $before[$record.path] = $record.sha256 }
$after = [ordered]@{}
foreach ($path in $before.Keys) { $after[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
$changed = @($before.Keys | Where-Object { $before[$_] -ne $after[$_] })
$initialStatus = (Get-Content -Raw -LiteralPath (Join-Path $Evidence 'git-status-short.txt')).TrimEnd("`r","`n")
$finalStatus = (Invoke-Git @('status','--short','--untracked-files=all')).TrimEnd("`r","`n")
Write-NewJson 'integrity-before-after.json' ([ordered]@{
    initial_sources = @('git-status-short.txt','exe-evidence.json','config-evidence.json','offline-schema-evidence.json')
    final_captured_utc = [DateTime]::UtcNow.ToString('o')
    initial_git_status_short = $initialStatus
    final_git_status_short = $finalStatus
    git_status_unchanged = ($initialStatus -eq $finalStatus)
    initial_sha256_by_path = $before
    final_sha256_by_path = $after
    existing_monitored_file_hashes_unchanged = ($changed.Count -eq 0)
    changed_existing_monitored_files = $changed
})
Write-NewJson 'read-only-action-audit.json' ([ordered]@{
    task='SSC-SOURCE-BASELINE-01'
    captured_utc=[DateTime]::UtcNow.ToString('o')
    actions_performed=@('Read Git metadata/status/diff/history/tree objects','Read and hash source/build/config/log/binary/database files','Inspect executable metadata and PDB identity','Run one correctly quoted finite MariaDB client attempt containing SELECT statements only','Create files only within this new runbook directory')
    notes=@('An earlier malformed local client invocation emitted help and did not connect; it is retained as evidence.','No database retry followed the correctly quoted connection result.')
    forbidden_actions_performed=@()
    confirmations=[ordered]@{
        git_checkout_switch_reset_clean_stash_rebase_pull_fetch=$false
        source_or_config_changes=$false
        build_or_compilation=$false
        database_writes_or_migrations=$false
        process_control_of_existing_services=$false
        executable_replacement_or_start=$false
        ollama_inference=$false
        game_chat=$false
        phase1b_code_integration=$false
    }
})

Write-Output "Remainder captured at $Evidence"
