[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RunRoot = 'C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848'
$Evidence = Join-Path $RunRoot 'evidence'
$Repo = 'C:\TW\ComTW\source'
$Server = 'C:\TW\ComTW\server'
$Logs = 'C:\TW\ComTW\logs'
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
    $allArgs = @('-c', 'safe.directory=C:/TW/ComTW/source', '-C', $Repo) + $Arguments
    $output = & git @allArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join "`n")" }
    return ($output -join "`n")
}

function Get-HashRecord([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        path = $item.FullName
        size_bytes = $item.Length
        creation_utc = $item.CreationTimeUtc.ToString('o')
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Get-AsciiStrings([string]$Path, [int]$Minimum = 6) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $builder = [System.Text.StringBuilder]::new()
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($byte in $bytes) {
        if ($byte -ge 32 -and $byte -le 126) {
            [void]$builder.Append([char]$byte)
        } else {
            if ($builder.Length -ge $Minimum) { $values.Add($builder.ToString()) }
            [void]$builder.Clear()
        }
    }
    if ($builder.Length -ge $Minimum) { $values.Add($builder.ToString()) }
    return $values
}

function Get-ConfigMap([string]$Path) {
    $map = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#') -or $trim.StartsWith(';')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trim.Substring(0, $idx).Trim()
        $value = $trim.Substring($idx + 1).Trim()
        $map[$key] = $value
    }
    return $map
}

function Compare-Config([string]$ActivePath, [string]$DistPath) {
    $active = Get-ConfigMap $ActivePath
    $dist = Get-ConfigMap $DistPath
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $active.Keys) {
        if (-not $dist.Contains($key) -or $dist[$key] -ne $active[$key]) { $changed.Add($key) }
    }
    foreach ($key in $dist.Keys) {
        if (-not $active.Contains($key)) { $changed.Add($key) }
    }
    return [ordered]@{
        active = Get-HashRecord $ActivePath
        dist = Get-HashRecord $DistPath
        changed_key_count = @($changed | Sort-Object -Unique).Count
        changed_keys = @($changed | Sort-Object -Unique)
    }
}

function Get-IntegritySnapshot {
    $paths = @(
        (Join-Path $Server 'mangosd.exe'),
        (Join-Path $Server 'mangosd.conf'),
        (Join-Path $Server 'aiplayerbot.conf'),
        (Join-Path $DbData 'tw_char\character_inventory.frm'),
        (Join-Path $DbData 'tw_char\character_inventory_copy.frm'),
        (Join-Path $DbData 'tw_logon\donation_point_progress.frm')
    )
    [ordered]@{
        captured_utc = [DateTime]::UtcNow.ToString('o')
        git_status_short = Invoke-Git @('status', '--short', '--untracked-files=all')
        files = @($paths | ForEach-Object { Get-HashRecord $_ })
    }
}

function Get-PeEvidence([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    $coff = $peOffset + 4
    $timestamp = [BitConverter]::ToUInt32($bytes, $coff + 4)
    $optional = $coff + 20
    $imageSize = [BitConverter]::ToUInt32($bytes, $optional + 56)
    $checksum = [BitConverter]::ToUInt32($bytes, $optional + 64)
    $machine = [BitConverter]::ToUInt16($bytes, $coff)
    $codeView = $null
    for ($i = 0; $i -le $bytes.Length - 25; $i++) {
        if ($bytes[$i] -eq 0x52 -and $bytes[$i+1] -eq 0x53 -and $bytes[$i+2] -eq 0x44 -and $bytes[$i+3] -eq 0x53) {
            $guidBytes = [byte[]]::new(16)
            [Array]::Copy($bytes, $i + 4, $guidBytes, 0, 16)
            $age = [BitConverter]::ToUInt32($bytes, $i + 20)
            $pathEnd = $i + 24
            while ($pathEnd -lt $bytes.Length -and $bytes[$pathEnd] -ne 0) { $pathEnd++ }
            $pdbPath = [Text.Encoding]::ASCII.GetString($bytes, $i + 24, $pathEnd - ($i + 24))
            if ($pdbPath -match '\.pdb$') {
                $codeView = [ordered]@{ signature='RSDS'; guid=([Guid]::new($guidBytes)).ToString('D'); age=$age; embedded_pdb_path=$pdbPath; file_offset=$i }
                break
            }
        }
    }
    [ordered]@{
        machine_hex = ('0x{0:X4}' -f $machine)
        linker_timestamp_utc = [DateTimeOffset]::FromUnixTimeSeconds($timestamp).UtcDateTime.ToString('o')
        linker_timestamp_raw = ('0x{0:X8}' -f $timestamp)
        size_of_image_hex = ('0x{0:X}' -f $imageSize)
        checksum_hex = ('0x{0:X8}' -f $checksum)
        codeview = $codeView
    }
}

New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
if ((Get-ChildItem -LiteralPath $Evidence -Force | Measure-Object).Count -ne 0) {
    throw "Evidence directory is not empty: $Evidence"
}

$integrityBefore = Get-IntegritySnapshot

$statusShort = Invoke-Git @('status', '--short', '--untracked-files=all')
$statusV2 = Invoke-Git @('status', '--porcelain=v2', '--branch', '--untracked-files=all')
$diff = Invoke-Git @('diff', '--no-ext-diff', '--binary', '--src-prefix=a/', '--dst-prefix=b/')
$diffStat = Invoke-Git @('diff', '--stat')
Write-NewUtf8 (Join-Path $Evidence 'git-status-short.txt') ($statusShort + "`n")
Write-NewUtf8 (Join-Path $Evidence 'git-status-porcelain-v2.txt') ($statusV2 + "`n")
Write-NewUtf8 (Join-Path $Evidence 'git-working-tree.diff') ($diff + "`n")
Write-NewUtf8 (Join-Path $Evidence 'git-diff-stat.txt') ($diffStat + "`n")

$head = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
$branch = (Invoke-Git @('branch', '--show-current')).Trim()
$upstreamResult = & git -c safe.directory=C:/TW/ComTW/source -C $Repo rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>&1
$upstream = if ($LASTEXITCODE -eq 0) { ($upstreamResult -join "`n").Trim() } else { $null }
$upstreamCommit = if ($upstream) { (Invoke-Git @('rev-parse', $upstream)).Trim() } else { $null }
$tags = @((Invoke-Git @('tag', '--list')) -split "`n" | Where-Object { $_ })
$pointsAt = @((Invoke-Git @('tag', '--points-at', 'HEAD')) -split "`n" | Where-Object { $_ })
$gitmodulesPresent = Test-Path -LiteralPath (Join-Path $Repo '.gitmodules')
$gitlinksRaw = Invoke-Git @('ls-tree', '-r', 'HEAD')
$gitlinks = @($gitlinksRaw -split "`n" | Where-Object { $_ -match '^160000 ' })
$gitMetadata = [ordered]@{
    repository_path = $Repo
    branch = $branch
    head = $head
    upstream = $upstream
    upstream_commit = $upstreamCommit
    origin = (Invoke-Git @('remote', 'get-url', 'origin')).Trim()
    describe = (Invoke-Git @('describe', '--always', '--dirty', '--long')).Trim()
    head_commit = (Invoke-Git @('show', '-s', '--format=%H%n%P%n%aI%n%cI%n%s', 'HEAD')) -split "`n"
    tags = $tags
    tags_pointing_at_head = $pointsAt
    gitmodules_present = $gitmodulesPresent
    gitlink_entries = $gitlinks
    submodules_present = ($gitmodulesPresent -or $gitlinks.Count -gt 0)
}
Write-NewJson 'git-metadata.json' $gitMetadata

$trackedPaths = @(
    'src/modules/PlayerBots/CMakeLists.txt',
    'src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h',
    'src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp'
)
$worktreeItems = [System.Collections.Generic.List[object]]::new()
foreach ($relative in $trackedPaths) {
    $path = Join-Path $Repo ($relative -replace '/', '\')
    $worktreeItems.Add([ordered]@{
        status = 'modified_unstaged'
        path = $relative
        classification = 'earlier_llm_debug_change'
        evidence = Get-HashRecord $path
        head_blob = (Invoke-Git @('rev-parse', "HEAD:$relative")).Trim()
    })
}
$pdbFiles = Get-ChildItem -LiteralPath (Join-Path $Repo 'bin\Release') -Filter '*.pdb' -File | Sort-Object Name
foreach ($file in $pdbFiles) {
    $worktreeItems.Add([ordered]@{
        status = 'untracked'
        path = ('bin/Release/' + $file.Name)
        classification = 'generated_build_file'
        evidence = Get-HashRecord $file.FullName
    })
}
$worktreeClassification = [ordered]@{
    complete_status_source = 'git-status-short.txt'
    staged_changes = 0
    intended_project_changes = @()
    earlier_llm_debug_changes = @($worktreeItems | Where-Object classification -eq 'earlier_llm_debug_change')
    other_local_changes = @()
    config_changes_inside_repository = @()
    generated_build_and_untracked_files = @($worktreeItems | Where-Object classification -eq 'generated_build_file')
    classification_note = 'All four tracked modifications are confined to PlayerBots LLM/debug paths and their CMake include; all six untracked files are linker-generated PDB artifacts.'
}
Write-NewJson 'worktree-classification.json' $worktreeClassification

$buildFiles = Get-ChildItem -LiteralPath (Join-Path $Repo 'build') -Recurse -File -Force
$binFiles = Get-ChildItem -LiteralPath (Join-Path $Repo 'bin') -Recurse -File -Force
$ignoredCount = @((Invoke-Git @('status', '--ignored', '--short', '--untracked-files=all')) -split "`n" | Where-Object { $_ -match '^!! ' }).Count
Write-NewJson 'generated-build-inventory.json' ([ordered]@{
    git_ignored_entry_count = $ignoredCount
    build = [ordered]@{ path = (Join-Path $Repo 'build'); file_count = $buildFiles.Count; bytes = ($buildFiles | Measure-Object Length -Sum).Sum; latest_write_utc = ($buildFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.ToString('o') }
    bin = [ordered]@{ path = (Join-Path $Repo 'bin'); file_count = $binFiles.Count; bytes = ($binFiles | Measure-Object Length -Sum).Sum; files = @($binFiles | Sort-Object FullName | ForEach-Object { Get-HashRecord $_.FullName }) }
    ignore_rules = @('/build/', '*.exe', '/src/shared/revision.h')
})

$prodExe = Join-Path $Server 'mangosd.exe'
$backupExe = Join-Path $Server 'mangosd.pre-llm-debug-20260826.exe'
$dirtyExe = Join-Path $Repo 'bin\Release\mangosd.exe'
$prodVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($prodExe)
$revisionStrings = @(Get-AsciiStrings $prodExe 10 | Where-Object { $_ -match 'revision:\s*[0-9a-f]{20}' } | Sort-Object -Unique)
$exeEvidence = [ordered]@{
    production = Get-HashRecord $prodExe
    production_windows_version = [ordered]@{
        file_version = $prodVersion.FileVersion
        product_version = $prodVersion.ProductVersion
        company_name = $prodVersion.CompanyName
        product_name = $prodVersion.ProductName
        original_filename = $prodVersion.OriginalFilename
    }
    production_pe = Get-PeEvidence $prodExe
    embedded_revision_strings = $revisionStrings
    embedded_revision_length = 20
    embedded_revision_resolution = [ordered]@{
        prefix = '42b8a7f742548793910f'
        resolved_full_commit = (Invoke-Git @('rev-parse', '42b8a7f742548793910f^{commit}')).Trim()
        matching_commits_local = @((Invoke-Git @('log', '--all', '--format=%H')) -split "`n" | Where-Object { $_.StartsWith('42b8a7f742548793910f') })
    }
    pre_llm_backup = if (Test-Path -LiteralPath $backupExe) { Get-HashRecord $backupExe } else { $null }
    later_dirty_build = if (Test-Path -LiteralPath $dirtyExe) { Get-HashRecord $dirtyExe } else { $null }
    equality = [ordered]@{
        production_equals_pre_llm_backup = ((Get-FileHash $prodExe -Algorithm SHA256).Hash -eq (Get-FileHash $backupExe -Algorithm SHA256).Hash)
        production_equals_later_dirty_build = ((Get-FileHash $prodExe -Algorithm SHA256).Hash -eq (Get-FileHash $dirtyExe -Algorithm SHA256).Hash)
    }
    provenance_limit = 'CMake embeds git rev-parse --short=20 HEAD only; it does not embed or manifest dirty-tree state, source-tree hashes, build flags, or dependencies.'
}
Write-NewJson 'exe-evidence.json' $exeEvidence

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dumpbin) {
    $dumpbin = Get-ChildItem -LiteralPath 'C:\Program Files\Microsoft Visual Studio' -Filter dumpbin.exe -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
}
if ($dumpbin) {
    $headers = & $dumpbin.FullName /headers $prodExe 2>&1
    $pdbPath = & $dumpbin.FullName /pdbpath:verbose $prodExe 2>&1
    Write-NewUtf8 (Join-Path $Evidence 'production-exe-pe-headers.txt') (($headers -join "`n") + "`n")
    Write-NewUtf8 (Join-Path $Evidence 'production-exe-pdbpath.txt') (($pdbPath -join "`n") + "`n")
} else {
    Write-NewUtf8 (Join-Path $Evidence 'production-exe-pe-headers.txt') "dumpbin.exe not available`n"
    Write-NewUtf8 (Join-Path $Evidence 'production-exe-pdbpath.txt') "dumpbin.exe not available`n"
}
$prodPdb = Join-Path $Server 'mangosd.pdb'
Write-NewJson 'production-pdb-evidence.json' ([ordered]@{
    pdb = if (Test-Path $prodPdb) { Get-HashRecord $prodPdb } else { $null }
    codeview_identity_source = 'production-exe-pe-headers.txt'
    embedded_pdb_path_source = 'production-exe-pe-headers.txt'
})

$successfulLogs = [System.Collections.Generic.List[object]]::new()
foreach ($log in (Get-ChildItem -LiteralPath $Logs -Filter 'server_*.log' -File | Sort-Object LastWriteTimeUtc -Descending)) {
    $lines = [System.IO.File]::ReadAllLines($log.FullName)
    $upIndex = -1
    for ($i = 0; $i -lt $lines.Length; $i++) { if ($lines[$i] -match 'World server is up and running!') { $upIndex = $i; break } }
    if ($upIndex -lt 0) { continue }
    $revisionEvidence = @()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match "revision.*42b8a7f742548793910f" -or $lines[$i] -match "42b8a7f742548793910f.*revision") {
            $revisionEvidence += [ordered]@{ line = $i + 1; text = ($lines[$i] -replace "'[^']*'", "'<redacted>'") }
        }
    }
    $haltIndex = -1
    for ($i = 0; $i -lt $lines.Length; $i++) { if ($lines[$i] -match 'Halting process') { $haltIndex = $i }
    }
    $successfulLogs.Add([ordered]@{
        file = Get-HashRecord $log.FullName
        world_up_line = $upIndex + 1
        world_up_text = $lines[$upIndex]
        halt_line = if ($haltIndex -ge 0) { $haltIndex + 1 } else { $null }
        halt_text = if ($haltIndex -ge 0) { $lines[$haltIndex] } else { $null }
        revision_evidence = $revisionEvidence
    })
}
$latestSuccessful = $successfulLogs | Select-Object -First 1
Write-NewJson 'production-start-log-evidence.json' ([ordered]@{
    selection_rule = 'Newest server_*.log by LastWriteTimeUtc containing World server is up and running!'
    latest_successful = $latestSuccessful
    successful_log_count = $successfulLogs.Count
    note = 'Only selected non-secret startup/revision/halt lines are reproduced; account identifiers and database credentials are excluded.'
})

$mangosConf = Join-Path $Server 'mangosd.conf'
$mangosDist = Join-Path $Server 'mangosd.conf.dist'
$aiConf = Join-Path $Server 'aiplayerbot.conf'
$aiDist = Join-Path $Server 'aiplayerbot.conf.dist'
$mangosMap = Get-ConfigMap $mangosConf
$aiMap = Get-ConfigMap $aiConf
$connectionKeys = @('LoginDatabase.Info','WorldDatabase.Info','CharacterDatabase.Info','LogsDatabase.Info')
$connectionSummary = [ordered]@{}
foreach ($key in $connectionKeys) {
    if (-not $mangosMap.Contains($key)) { continue }
    $parts = $mangosMap[$key].Trim('"') -split ';'
    $connectionSummary[$key] = [ordered]@{
        host = if ($parts.Count -gt 0) { $parts[0] } else { $null }
        port = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        database = if ($parts.Count -gt 4) { $parts[4] } else { $null }
        username = '<redacted>'
        password = '<redacted>'
    }
}
$configEvidence = [ordered]@{
    mangosd = Compare-Config $mangosConf $mangosDist
    aiplayerbot = Compare-Config $aiConf $aiDist
    selected_mangosd_values = [ordered]@{
        'AutoDonationPoints.Enable' = $mangosMap['AutoDonationPoints.Enable']
        'AutoDonationPoints.Amount' = $mangosMap['AutoDonationPoints.Amount']
        'AutoDonationPoints.FlushIntervalMs' = $mangosMap['AutoDonationPoints.FlushIntervalMs']
        'AutoDonationPoints.IntervalMs' = $mangosMap['AutoDonationPoints.IntervalMs']
        'BackupCharacterInventory' = $mangosMap['BackupCharacterInventory']
        'Database.AutoUpdate.Enabled' = $mangosMap['Database.AutoUpdate.Enabled']
        'PlayerbotAI.SortByName' = $mangosMap['PlayerbotAI.SortByName']
    }
    selected_aiplayerbot_values = [ordered]@{
        'AiPlayerbot.LLMEnabled' = $aiMap['AiPlayerbot.LLMEnabled']
        'AiPlayerbot.LLMBotToBotChatChance' = $aiMap['AiPlayerbot.LLMBotToBotChatChance']
        'AiPlayerbot.LLMRpgAIChatChance' = $aiMap['AiPlayerbot.LLMRpgAIChatChance']
        'AiPlayerbot.LLMMaxSimultaniousGenerations' = $aiMap['AiPlayerbot.LLMMaxSimultaniousGenerations']
        'AiPlayerbot.LLMGenerationTimeout' = $aiMap['AiPlayerbot.LLMGenerationTimeout']
        'AiPlayerbot.LLMContextLength' = $aiMap['AiPlayerbot.LLMContextLength']
        endpoint_sha256 = if ($aiMap.Contains('AiPlayerbot.LLMApiEndpoint')) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($aiMap['AiPlayerbot.LLMApiEndpoint']))) } else { $null }
        api_key_sha256 = if ($aiMap.Contains('AiPlayerbot.LLMApiKey')) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($aiMap['AiPlayerbot.LLMApiKey']))) } else { $null }
    }
    database_connections = $connectionSummary
    secret_handling = 'Database usernames/passwords and LLM endpoint/API key are not emitted. Only endpoint/key hashes are recorded.'
}
Write-NewJson 'config-evidence.json' $configEvidence

$dbAttempt = [ordered]@{
    attempted_utc = [DateTime]::UtcNow.ToString('o')
    client = Join-Path $DbRoot 'bin\mariadb.exe'
    method = 'TCP connection followed only by SELECT statements against information_schema and approved schemas'
    write_statements = @()
    exit_code = $null
    stdout = @()
    stderr = @()
}
$loginValue = $mangosMap['LoginDatabase.Info'].Trim('"')
$loginParts = $loginValue -split ';'
if ($loginParts.Count -ge 5 -and (Test-Path -LiteralPath $dbAttempt.client)) {
    $dbHost = $loginParts[0]
    $dbPort = $loginParts[1]
    $dbUser = $loginParts[2]
    $dbPassword = $loginParts[3]
    $sql = @"
SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLUMN_KEY,EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ('tw_logon','tw_world','tw_char','tw_logs') AND TABLE_NAME IN ('character_inventory','character_inventory_copy','donation_point_progress','migrations','character_db_version','db_version','realmd_db_version') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;
SELECT 'tw_logon.migrations',Id,Name,Hash,AppliedAt FROM tw_logon.migrations ORDER BY Id;
SELECT 'tw_world.migrations',Id,Name,Hash,AppliedAt FROM tw_world.migrations ORDER BY Id;
SELECT 'tw_char.migrations',Id,Name,Hash,AppliedAt FROM tw_char.migrations ORDER BY Id;
SELECT 'donation_point_progress',COUNT(*),COALESCE(SUM(accumulated_ms),0),MIN(accumulated_ms),MAX(accumulated_ms) FROM tw_logon.donation_point_progress;
SELECT 'character_inventory_copy',COUNT(*) FROM tw_char.character_inventory_copy;
"@
    $oldPassword = $env:MYSQL_PWD
    try {
        $env:MYSQL_PWD = $dbPassword
        $stdoutFile = Join-Path $env:TEMP ('ssc-db-stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $stderrFile = Join-Path $env:TEMP ('ssc-db-stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
        $proc = Start-Process -FilePath $dbAttempt.client -ArgumentList @('--protocol=TCP','--connect-timeout=3','--batch','--raw','--skip-column-names',"--host=$dbHost","--port=$dbPort","--user=$dbUser",'--execute',$sql) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $dbAttempt.exit_code = $proc.ExitCode
        $dbAttempt.stdout = @([System.IO.File]::ReadAllLines($stdoutFile))
        $dbAttempt.stderr = @([System.IO.File]::ReadAllLines($stderrFile) | ForEach-Object { $_ -replace [regex]::Escape($dbPassword), '<redacted>' })
    } finally {
        $env:MYSQL_PWD = $oldPassword
        if ($stdoutFile -and (Test-Path -LiteralPath $stdoutFile)) { Remove-Item -LiteralPath $stdoutFile -Force }
        if ($stderrFile -and (Test-Path -LiteralPath $stderrFile)) { Remove-Item -LiteralPath $stderrFile -Force }
    }
} else {
    $dbAttempt.exit_code = -1
    $dbAttempt.stderr = @('Database connection descriptor or client unavailable.')
}
Write-NewJson 'database-readonly-query-attempt.json' $dbAttempt

$schemaDirs = @('tw_logon','tw_world','tw_char','tw_logs')
$schemaInventory = [ordered]@{}
foreach ($schema in $schemaDirs) {
    $dir = Join-Path $DbData $schema
    $tables = @(Get-ChildItem -LiteralPath $dir -Filter '*.frm' -File | ForEach-Object { $_.BaseName } | Sort-Object)
    $schemaInventory[$schema] = [ordered]@{
        table_count_from_frm = $tables.Count
        tables = $tables
        tracker_tables = @($tables | Where-Object { $_ -in @('migrations','character_db_version','db_version','realmd_db_version') })
    }
}
$requiredDbFiles = @(
    'tw_logon\donation_point_progress.frm','tw_logon\donation_point_progress.ibd',
    'tw_char\character_inventory.frm','tw_char\character_inventory.MYD','tw_char\character_inventory.MYI',
    'tw_char\character_inventory_copy.frm','tw_char\character_inventory_copy.MYD','tw_char\character_inventory_copy.MYI',
    'tw_logon\migrations.frm','tw_logon\migrations.ibd',
    'tw_world\migrations.frm','tw_world\migrations.ibd',
    'tw_char\migrations.frm','tw_char\migrations.ibd'
)
$requiredDbEvidence = @($requiredDbFiles | ForEach-Object {
    $p = Join-Path $DbData $_
    if (Test-Path -LiteralPath $p) { Get-HashRecord $p }
})
$migrationNames = [ordered]@{}
foreach ($schema in @('tw_logon','tw_world','tw_char')) {
    $ibd = Join-Path $DbData "$schema\migrations.ibd"
    $names = @()
    if (Test-Path $ibd) {
        foreach ($s in (Get-AsciiStrings $ibd 12)) {
            foreach ($m in [regex]::Matches($s, '20\d{12}_[A-Za-z0-9_\-]+')) { $names += $m.Value }
        }
    }
    $migrationNames[$schema] = @($names | Sort-Object -Unique)
}
Write-NewJson 'offline-schema-evidence.json' ([ordered]@{
    basis = 'Read-only filesystem inventory and hashes of stopped MariaDB data files; not a transactionally consistent SQL result.'
    schemas = $schemaInventory
    required_files = $requiredDbEvidence
    recoverable_migration_names_from_ibd_ascii = $migrationNames
    limitations = @('Offline .frm/.ibd presence does not prove current rows or all tracker entries.','InnoDB data files are not parsed as authoritative SQL state.','Logon migration names were not recoverable as plain strings.')
})

$myisam = Join-Path $DbRoot 'bin\myisamchk.exe'
$myisamOutput = [System.Collections.Generic.List[string]]::new()
foreach ($table in @('character_inventory','character_inventory_copy')) {
    $myi = Join-Path $DbData "tw_char\$table.MYI"
    $myisamOutput.Add("===== $table =====")
    if (Test-Path $myisam) {
        $details = & $myisam -dvv $myi 2>&1
        foreach ($line in $details) { $myisamOutput.Add([string]$line) }
    } else { $myisamOutput.Add('myisamchk.exe unavailable') }
}
Write-NewUtf8 (Join-Path $Evidence 'character-inventory-myisam-descriptions.txt') (($myisamOutput -join "`n") + "`n")

$schemaSourcePaths = @(
    'sql/character_updates/20260812142512_character_inventory_copy.sql',
    'sql/logon/donation_point_progress.sql',
    'sql/base/tw_logon_migrations.sql',
    'sql/base/tw_world_migrations.sql',
    'sql/base/tw_char_migrations.sql'
)
$schemaSource = [System.Collections.Generic.List[object]]::new()
foreach ($relative in $schemaSourcePaths) {
    & git -c safe.directory=C:/TW/ComTW/source -C $Repo cat-file -e "HEAD:$relative" 2>$null
    $exists = ($LASTEXITCODE -eq 0)
    if (-not $exists) { continue }
    $content = Invoke-Git @('show', "HEAD:$relative")
    $firstCommit = (Invoke-Git @('log', '--diff-filter=A', '--format=%H', '--', $relative) -split "`n" | Select-Object -Last 1).Trim()
    $schemaSource.Add([ordered]@{
        path = $relative
        head_blob = (Invoke-Git @('rev-parse', "HEAD:$relative")).Trim()
        introduced_commit = $firstCommit
        introduced_is_ancestor_of_head = if ($firstCommit) {
            & git -c safe.directory=C:/TW/ComTW/source -C $Repo merge-base --is-ancestor $firstCommit HEAD
            ($LASTEXITCODE -eq 0)
        } else { $null }
        content = $content
    })
}
$characterUpdateCount = @((Invoke-Git @('ls-tree','-r','--name-only','HEAD','sql/character_updates')) -split "`n" | Where-Object { $_ -match '\.sql$' }).Count
$databaseUpdateCount = @((Invoke-Git @('ls-tree','-r','--name-only','HEAD','sql/database_updates')) -split "`n" | Where-Object { $_ -match '\.sql$' }).Count
$logonUpdateCount = @((Invoke-Git @('ls-tree','-r','--name-only','HEAD','sql/logon')) -split "`n" | Where-Object { $_ -match '\.sql$' }).Count
Write-NewJson 'source-schema-requirements.json' ([ordered]@{
    candidate_commit = $head
    update_sql_counts = [ordered]@{ character_updates = $characterUpdateCount; database_updates = $databaseUpdateCount; logon = $logonUpdateCount }
    required_sources = $schemaSource
})

$integrationSpecs = @(
    [ordered]@{ path='src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp'; patterns=@('Generate\(','curl_easy_perform','LLM generation') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp'; patterns=@('GenerateResponsePackets','std::async','SendDelayedPacket') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/PlayerbotAI.cpp'; patterns=@('UpdateAI\(','UpdateAIInternal','SendDelayedPacket','ReceiveDelayedPacket','detach\(','TellPlayerNoFacing','TellPlayer\(') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/strategy/values/RpgTriggers.cpp'; patterns=@('LLMEnabled','LLMRpgAIChatChance') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/RpgSubActions.cpp'; patterns=@('future','wait_for','get\(') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp'; patterns=@('UpdateAIInternal','UpdateSessions') },
    [ordered]@{ path='src/game/World/World.cpp'; patterns=@('World::Update\(','UpdateSessions','donation_point_progress') },
    [ordered]@{ path='src/game/Server/WorldSession.h'; patterns=@('World::UpdateSessions','packet') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp'; patterns=@('LLMEnabled','LLMMaxSimultaneousGenerations','LLMGenerationTimeout') },
    [ordered]@{ path='src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp'; patterns=@('Generate\(','LLM') }
)
$integration = [System.Collections.Generic.List[object]]::new()
$excerptLines = [System.Collections.Generic.List[string]]::new()
foreach ($spec in $integrationSpecs) {
    $content = Invoke-Git @('show', "HEAD:$($spec.path)")
    $lines = $content -split "`n"
    $matches = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($pattern in $spec.patterns) {
            if ($lines[$i] -match $pattern) {
                $matches.Add([ordered]@{ line = $i + 1; pattern = $pattern; text = $lines[$i].TrimEnd() })
                break
            }
        }
    }
    $integration.Add([ordered]@{ path=$spec.path; head_blob=(Invoke-Git @('rev-parse', "HEAD:$($spec.path)")).Trim(); matches=@($matches) })
    $excerptLines.Add("===== $($spec.path) =====")
    foreach ($match in $matches) { $excerptLines.Add(('{0,6}: {1}' -f $match.line, $match.text)) }
}
Write-NewJson 'integration-points.json' ([ordered]@{
    candidate_commit = $head
    scope = 'Candidate-only source landmarks for later revalidation; no source integration performed.'
    files = @($integration)
    warning = 'The current SendDelayedPacket/ReceiveDelayedPacket implementation contains detached threads and raw WorldSession pointer capture and must not be reused for the bounded bridge integration.'
})
Write-NewUtf8 (Join-Path $Evidence 'integration-point-matches.txt') (($excerptLines -join "`n") + "`n")

$cmakeRevision = Invoke-Git @('show','HEAD:CMakeLists.txt')
$cmakeLines = $cmakeRevision -split "`n"
$cmakeMatches = @()
for ($i=0; $i -lt $cmakeLines.Count; $i++) {
    if ($cmakeLines[$i] -match 'rev-parse|GIT_REVISION|revision.h') { $cmakeMatches += ('{0,6}: {1}' -f ($i+1),$cmakeLines[$i]) }
}
Write-NewUtf8 (Join-Path $Evidence 'cmake-revision-generation.txt') (($cmakeMatches -join "`n") + "`n")

$integrityAfter = Get-IntegritySnapshot
$beforeMap = @{}; foreach ($f in $integrityBefore.files) { $beforeMap[$f.path] = $f.sha256 }
$afterMap = @{}; foreach ($f in $integrityAfter.files) { $afterMap[$f.path] = $f.sha256 }
$fileChanges = @($beforeMap.Keys | Where-Object { $afterMap[$_] -ne $beforeMap[$_] })
Write-NewJson 'integrity-before-after.json' ([ordered]@{
    before = $integrityBefore
    after = $integrityAfter
    git_status_unchanged = ($integrityBefore.git_status_short -eq $integrityAfter.git_status_short)
    monitored_existing_file_hashes_unchanged = ($fileChanges.Count -eq 0)
    changed_monitored_existing_files = $fileChanges
})
Write-NewJson 'read-only-action-audit.json' ([ordered]@{
    task = 'SSC-SOURCE-BASELINE-01'
    captured_utc = [DateTime]::UtcNow.ToString('o')
    actions_performed = @('Read Git metadata/status/diff/history/tree objects','Read and hash source/build/config/log/binary/database files','Inspect executable metadata and PDB path','Attempt one finite read-only MariaDB connection using SELECT statements only','Create files only within the new runbook directory')
    forbidden_actions_performed = @()
    confirmations = [ordered]@{
        git_checkout_switch_reset_clean_stash_rebase_pull_fetch = $false
        source_or_config_changes = $false
        build_or_compilation = $false
        database_writes_or_migrations = $false
        process_control = $false
        executable_replacement_or_start = $false
        ollama_inference = $false
        game_chat = $false
        phase1b_code_integration = $false
    }
})

Write-Output "Evidence captured at $Evidence"
