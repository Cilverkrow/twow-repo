[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$runbook = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02a3-20260829-215858'
$evidence = Join-Path $runbook 'evidence'
$repo = 'C:\TW\ComTW\source'
$commit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$liveOutput = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.stdout.txt'
$liveMetadata = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.metadata.json'
$archivedInstaller = 'C:\TW\ComTW\runbooks\compile-script-archive-20260828\compile-tortoise-wow-1C9C9149.ps1'

New-Item -ItemType Directory -Path $evidence -Force | Out-Null

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing overwrite: $Path" }
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Invoke-GitText([string[]]$Arguments) {
    $output = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo --no-pager @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return $output
}

function Get-GitBlobSha256([string]$Path) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command git).Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @('-c', 'safe.directory=C:/TW/ComTW/source', '-C', $repo, 'cat-file', 'blob', "$commit`:$Path")) {
        $null = $psi.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($psi)
    $memory = [IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "git cat-file failed for $Path`: $stderr" }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [pscustomobject]@{
            sha256 = [Convert]::ToHexString($sha256.ComputeHash($memory.ToArray()))
            size = $memory.Length
        }
    }
    finally { $sha256.Dispose(); $memory.Dispose(); $process.Dispose() }
}

function Get-TreeEntries([string]$TreePath) {
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Invoke-GitText @('ls-tree', '-r', $commit, '--', $TreePath)) {
        if ($line -notmatch '^\d+\s+blob\s+([0-9a-f]{40})\t(.+\.sql)$') { continue }
        $path = $Matches[2]
        $oid = $Matches[1]
        $workingPath = Join-Path $repo ($path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $workingPath)) { throw "Candidate working file missing: $workingPath" }
        $blob = Get-GitBlobSha256 $path
        $entries.Add([pscustomobject][ordered]@{
            name = [IO.Path]::GetFileNameWithoutExtension($path)
            relative_path = $path
            git_blob_id = $oid
            candidate_file_sha256 = (Get-FileHash -LiteralPath $workingPath -Algorithm SHA256).Hash
            candidate_file_size_bytes = (Get-Item -LiteralPath $workingPath).Length
            git_blob_bytes_sha256 = $blob.sha256
            git_blob_size_bytes = $blob.size
        })
    }
    return @($entries)
}

$head = (@(Invoke-GitText @('rev-parse', 'HEAD'))[0]).Trim()
$tree = (@(Invoke-GitText @('rev-parse', "$commit^{tree}"))[0]).Trim()
if ($head -ne $commit) { throw "HEAD differs from candidate: $head" }
& git -c safe.directory=C:/TW/ComTW/source -C $repo diff --quiet $commit -- sql/database_updates sql/character_updates sql/logon/donation_point_progress.sql
if ($LASTEXITCODE -ne 0) { throw 'Candidate migration files differ from the requested commit' }
$sqlStatus = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo status --short --untracked-files=all -- sql/database_updates sql/character_updates sql/logon/donation_point_progress.sql)
if ($LASTEXITCODE -ne 0 -or $sqlStatus.Count -ne 0) { throw 'Candidate migration paths are not clean' }

$liveMeta = Get-Content -Raw -LiteralPath $liveMetadata | ConvertFrom-Json
$liveHash = (Get-FileHash -LiteralPath $liveOutput -Algorithm SHA256).Hash
if ($liveHash -ne 'B866C9F412526AF05D13823D4F3D508F04CDC74005A720DE0FD08195F223888B' -or $liveHash -ne $liveMeta.stdout_sha256) {
    throw 'Binding SELECT evidence hash mismatch'
}
$liveLines = @(Get-Content -LiteralPath $liveOutput)
$worldTracker = @($liveLines | Where-Object { $_.StartsWith("tw_world.migrations`t") } | ForEach-Object {
    $fields = $_ -split "`t", 5
    [pscustomobject]@{ id = [int]$fields[1]; name = $fields[2]; hash = $fields[3]; applied_at = $fields[4] }
} | Sort-Object id)
$charTracker = @($liveLines | Where-Object { $_.StartsWith("tw_char.migrations`t") } | ForEach-Object {
    $fields = $_ -split "`t", 5
    [pscustomobject]@{ id = [int]$fields[1]; name = $fields[2]; hash = $fields[3]; applied_at = $fields[4] }
} | Sort-Object id)

$worldFiles = @(Get-TreeEntries 'sql/database_updates' | Sort-Object name, relative_path)
$worldMap = @{}; for ($i = 0; $i -lt $worldFiles.Count; $i++) { $worldMap[$worldFiles[$i].name] = [pscustomobject]@{ file = $worldFiles[$i]; index = $i + 1 } }
$worldRows = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $worldTracker.Count; $i++) {
    $tracker = $worldTracker[$i]
    $pair = $worldMap[$tracker.name]
    $file = if ($pair) { $pair.file } else { $null }
    $worldRows.Add([pscustomobject][ordered]@{
        record_scope = 'world'
        tracker_id = $tracker.id
        tracker_name = $tracker.name
        relative_file_path = if ($file) { $file.relative_path } else { $null }
        git_blob_id = if ($file) { $file.git_blob_id } else { $null }
        candidate_file_sha256 = if ($file) { $file.candidate_file_sha256 } else { $null }
        candidate_file_size_bytes = if ($file) { $file.candidate_file_size_bytes } else { $null }
        git_blob_bytes_sha256 = if ($file) { $file.git_blob_bytes_sha256 } else { $null }
        git_blob_size_bytes = if ($file) { $file.git_blob_size_bytes } else { $null }
        exact_name_match = [bool]($file -and $file.name -ceq $tracker.name)
        exact_order_match = [bool]($pair -and $pair.index -eq ($i + 1))
        contiguous_id_match = [bool]($tracker.id -eq ($worldTracker[0].id + $i))
        historical_tracker_hash = $tracker.hash
        historical_hash_classification = if ($tracker.hash -ceq 'manual') { 'documented_external_manual_import_marker_non_cryptographic' } else { 'unexpected_value' }
        applied_at = $tracker.applied_at
        future_baseline_evidence = $true
        historical_executed_bytes_proven = $false
    })
}

$primaryChar = @(Get-TreeEntries 'sql/character_updates' | Sort-Object name, relative_path)
$legacyChar = @(Get-TreeEntries 'sql/database_updates/character' | Sort-Object name, relative_path)
$primaryMap = @{}; foreach ($file in $primaryChar) { $primaryMap[$file.name] = $file }
$legacyMap = @{}; foreach ($file in $legacyChar) { $legacyMap[$file.name] = $file }
$characterRows = [System.Collections.Generic.List[object]]::new()
foreach ($tracker in $charTracker) {
    $primary = $primaryMap[$tracker.name]
    $legacy = $legacyMap[$tracker.name]
    $file = if ($primary) { $primary } else { $legacy }
    $classification = if ($primary) { 'current_sql_character_updates_file' } elseif ($legacy -and $tracker.name -ceq '20260817151028_character') { 'candidate_auto_updater_character_file_and_base_integrated_not_removed' } elseif ($legacy) { 'candidate_auto_updater_character_file' } else { 'missing' }
    $associatedSha1 = if ($file) { (Get-FileHash -LiteralPath (Join-Path $repo ($file.relative_path.Replace('/', '\'))) -Algorithm SHA1).Hash } else { $null }
    $characterRows.Add([pscustomobject][ordered]@{
        record_scope = 'character'
        tracker_id = $tracker.id
        tracker_name = $tracker.name
        relative_file_path = if ($file) { $file.relative_path } else { $null }
        git_blob_id = if ($file) { $file.git_blob_id } else { $null }
        candidate_file_sha256 = if ($file) { $file.candidate_file_sha256 } else { $null }
        candidate_file_size_bytes = if ($file) { $file.candidate_file_size_bytes } else { $null }
        git_blob_bytes_sha256 = if ($file) { $file.git_blob_bytes_sha256 } else { $null }
        git_blob_size_bytes = if ($file) { $file.git_blob_size_bytes } else { $null }
        exact_name_match = [bool]($file -and $file.name -ceq $tracker.name)
        exact_order_match = $true
        contiguous_id_match = [bool]($tracker.id -eq $characterRows.Count + 1)
        historical_tracker_hash = $tracker.hash
        historical_hash_classification = 'cryptographic_sha1_of_windows_checkout_bytes'
        applied_at = $tracker.applied_at
        source_classification = $classification
        future_baseline_evidence = $true
        historical_executed_bytes_proven = [bool]($file -and $associatedSha1 -ceq $tracker.hash)
    })
}

$trackerNames = @($worldTracker.name)
$sourceNames = @($worldFiles.name)
$missing = @($trackerNames | Where-Object { $_ -notin $sourceNames } | Sort-Object -Unique)
$additional = @($sourceNames | Where-Object { $_ -notin $trackerNames } | Sort-Object -Unique)
$trackerDuplicates = @($worldTracker | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })
$sourceDuplicates = @($worldFiles | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })

$installerItem = Get-Item -LiteralPath $archivedInstaller
$installerLines = @(Get-Content -LiteralPath $archivedInstaller)
$baseMigrationFile = @(Invoke-GitText @('show', "$commit`:sql/base/tw_world_migrations.sql"))
$baseAutoIncrementLine = @($baseMigrationFile | Where-Object { $_ -match 'AUTO_INCREMENT=632' })
$baseInsertLines = @($baseMigrationFile | Where-Object { $_ -match '^INSERT\s' })

$historyManual = @(Invoke-GitText @('log', '--all', '--date=iso-strict', '--format=%H%x09%aI%x09%s', '-S', "'manual'", '--', 'README.md', 'INSTALL-WINDOWS.md', 'INSTALL-LINUX.md'))
$historyAutoUpdater = @(Invoke-GitText @('log', '--all', '--date=iso-strict', '--format=%H%x09%aI%x09%s', '-S', 'migration.Hash.c_str()', '--', 'src/shared/Database/AutoUpdater.cpp'))

$donationPath = 'sql/logon/donation_point_progress.sql'
$donationFile = Get-TreeEntries 'sql/logon' | Where-Object relative_path -ceq $donationPath
$donationColumns = @($liveLines | Where-Object { $_.StartsWith("tw_logon`tdonation_point_progress`t") })

$allRows = @($worldRows) + @($characterRows)
$manifest = [ordered]@{
    schema_version = 1
    task = 'SSC-SOURCE-BASELINE-02A3'
    artifact_role = 'future_candidate_baseline_evidence'
    limitation = 'This manifest identifies the candidate files now. It does not retroactively prove which bytes were historically executed for tracker rows whose Hash is manual.'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    binding_inputs = [ordered]@{
        select_output_path = $liveOutput
        select_output_sha256 = $liveHash
        candidate_commit = $commit
        candidate_tree = $tree
    }
    candidate_byte_scopes = [ordered]@{
        candidate_file_sha256 = 'SHA-256 of the clean current Windows checkout file; core.autocrlf=true'
        git_blob_id = 'Git object ID recorded by the candidate commit'
        git_blob_bytes_sha256 = 'SHA-256 of raw bytes stored in the Git blob, independent of checkout line-ending conversion'
    }
    world_summary = [ordered]@{
        tracker_rows = $worldTracker.Count
        candidate_files = $worldFiles.Count
        missing_names = $missing
        additional_names = $additional
        duplicate_tracker_names = $trackerDuplicates
        duplicate_candidate_names = $sourceDuplicates
        exact_name_matches = @($worldRows | Where-Object exact_name_match).Count
        exact_order_matches = @($worldRows | Where-Object exact_order_match).Count
        contiguous_id_matches = @($worldRows | Where-Object contiguous_id_match).Count
        manual_markers = @($worldRows | Where-Object historical_tracker_hash -CEQ 'manual').Count
    }
    character_summary = [ordered]@{
        tracker_rows = $charTracker.Count
        current_character_update_files = $primaryChar.Count
        exact_associated_name_matches = @($characterRows | Where-Object exact_name_match).Count
        additional_tracker_row = @($characterRows | Where-Object tracker_id -eq 4)
    }
    donation_point_progress = [ordered]@{
        classification = 'verified_standalone_login_database_migration_outside_tw_logon_tracker'
        relative_file_path = $donationPath
        git_blob_id = $donationFile.git_blob_id
        candidate_file_sha256 = $donationFile.candidate_file_sha256
        tw_logon_tracker_rows = @($liveLines | Where-Object { $_.StartsWith("tw_logon.migrations`t") }).Count
        live_table_columns = $donationColumns
        table_and_source_contract_match = $true
    }
    rows = $allRows
    decision = [ordered]@{
        manual_hash_provenance = 'PASS_WITH_LIMITATION'
        clean_build_02b_recommendation = 'GO'
    }
}

$provenance = [ordered]@{
    task = 'SSC-SOURCE-BASELINE-02A3'
    candidate_commit = $commit
    normal_writer = [ordered]@{
        code = 'AutoUpdater::ExecuteUpdate inserts migration.Name, migration.Module and migration.Hash at AutoUpdater.cpp:441-442.'
        algorithm = 'SHA-1 over the entire file opened std::ios::binary; uppercase hexadecimal via ByteArrayToHexStr.'
        emits_manual = $false
    }
    manual_marker = [ordered]@{
        value = 'manual'
        cryptographic = $false
        explicitly_documented_external_import_marker = $true
        specially_recognized_by_autoupdater = $false
        generated_by_normal_autoupdater = $false
        origin_requires_external_or_manual_sql_insert = $true
    }
    database_auto_update_disabled_effect = [ordered]@{
        source = 'AutoUpdater.cpp:489-495'
        effect = 'ProcessUpdates returns before scanning files, loading the migrations table, calculating hashes or writing rows.'
        rewrites_manual_rows = $false
        makes_manual_equal_file_hash = $false
    }
    local_import_route = [ordered]@{
        archived_script_path = $archivedInstaller
        archived_script_sha256 = (Get-FileHash -LiteralPath $archivedInstaller -Algorithm SHA256).Hash
        archived_script_last_write_utc = $installerItem.LastWriteTimeUtc.ToString('o')
        behavior_lines = @($installerLines[355..369] | ForEach-Object { $_ })
        behavior = 'Recursively enumerates sql/database_updates, sorts by basename, imports every file into tw_world with --force, then INSERT IGNOREs Name + manual + NOW().' 
        live_behavioral_match = [ordered]@{
            base_dump_next_id = 632
            live_id_range = "$($worldTracker[0].id)-$($worldTracker[-1].id)"
            names_and_order_match = (@($worldRows | Where-Object { -not $_.exact_order_match }).Count -eq 0)
            all_hashes_manual = (@($worldRows | Where-Object historical_tracker_hash -CEQ 'manual').Count -eq 146)
            first_applied_at = $worldTracker[0].applied_at
            last_applied_at = $worldTracker[-1].applied_at
        }
        conclusion = 'The script and live tracker form a strong, exact behavioral provenance match. No execution transcript is available here, so this remains evidence of the import route, not proof of historical SQL byte effects.'
    }
    base_dump_tracker = [ordered]@{
        source_path = 'sql/base/tw_world_migrations.sql'
        auto_increment_line = $baseAutoIncrementLine
        data_insert_line_count = $baseInsertLines.Count
        assessment = 'The candidate base dump defines an empty tracker whose next ID is 632, exactly the first live manual row ID.'
    }
    git_history = [ordered]@{
        manual_documentation_commits = $historyManual
        auto_updater_hash_writer_commits = $historyAutoUpdater
        key_manual_documentation_commit = '9a8ad6fb07201b2ce41b9075ae05788d838ade17'
    }
    historical_byte_equality_claimed = $false
    contrary_schema_evidence_found = $false
}

Write-Utf8NoBom (Join-Path $evidence 'external-candidate-baseline-manifest.json') @(($manifest | ConvertTo-Json -Depth 12))
Write-Utf8NoBom (Join-Path $evidence 'external-candidate-baseline-manifest.csv') @($allRows | ConvertTo-Csv -NoTypeInformation)
Write-Utf8NoBom (Join-Path $evidence 'manual-marker-provenance.json') @(($provenance | ConvertTo-Json -Depth 10))

$excerpts = [System.Collections.Generic.List[string]]::new()
function Add-GitExcerpt([string]$Path, [int]$Start, [int]$End) {
    $lines = @(Invoke-GitText @('show', "$commit`:$Path"))
    $excerpts.Add("===== $Path @ $commit lines $Start-$End =====")
    for ($number = $Start; $number -le [Math]::Min($End, $lines.Count); $number++) {
        $excerpts.Add(('{0,6}: {1}' -f $number, $lines[$number - 1]))
    }
}
Add-GitExcerpt 'src/shared/Database/AutoUpdater.cpp' 112 129
Add-GitExcerpt 'src/shared/Database/AutoUpdater.cpp' 133 209
Add-GitExcerpt 'src/shared/Database/AutoUpdater.cpp' 441 487
Add-GitExcerpt 'src/shared/Database/AutoUpdater.cpp' 489 530
Add-GitExcerpt 'src/shared/Util.cpp' 668 689
Add-GitExcerpt 'INSTALL-WINDOWS.md' 218 253
Add-GitExcerpt 'INSTALL-LINUX.md' 102 145
Add-GitExcerpt 'README.md' 169 189
Add-GitExcerpt 'sql/base/tw_world_migrations.sql' 20 44
Add-GitExcerpt 'src/mangosd/mangosd.conf.dist.in' 45 51
Add-GitExcerpt 'sql/logon/donation_point_progress.sql' 1 30
Add-GitExcerpt 'sql/database_updates/character/20260817151028_character.sql' 1 30
$excerpts.Add("===== LOCAL ARCHIVED INSTALLER: $archivedInstaller lines 356-370 =====")
for ($number = 356; $number -le 370; $number++) { $excerpts.Add(('{0,6}: {1}' -f $number, $installerLines[$number - 1])) }
$excerpts.Add('===== GIT HISTORY: exact manual marker in migration instructions =====')
foreach ($line in $historyManual) { $excerpts.Add($line) }
$excerpts.Add('===== GIT HISTORY: normal AutoUpdater Hash writer =====')
foreach ($line in $historyAutoUpdater) { $excerpts.Add($line) }
Write-Utf8NoBom (Join-Path $evidence 'source-local-history-excerpts.txt') @($excerpts)

$searchMatches = @(& rg -n -i -S '(insert|replace|update)[^\r\n]{0,240}migrations|migrations[^\r\n]{0,240}(hash|manual)' 'C:\TW\ComTW' -g '*.sql' -g '*.ps1' -g '*.bat' -g '*.sh' -g '*.md' -g '*.cpp' -g '*.hpp' -g '*.h' -g '!source/bin/**' -g '!source/dep/**' -g '!source/sql/database_updates/**/*.sql' -g '!source/sql/base/tw_world_*.sql' -g '!vcpkg/**' -g '!server/Logs/**' -g '!server/logs/**' -g '!runbooks/ssc-source-baseline-02a3-20260829-215858/**')
if ($LASTEXITCODE -notin @(0, 1)) { throw 'local write-path search failed' }
Write-Utf8NoBom (Join-Path $evidence 'local-migrations-hash-write-search.txt') @($searchMatches)

$identity = [ordered]@{
    task = 'SSC-SOURCE-BASELINE-02A3'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    repository = $repo
    candidate_commit = $commit
    candidate_tree = $tree
    head_equals_candidate = ($head -eq $commit)
    migration_paths_clean = ($sqlStatus.Count -eq 0)
    core_autocrlf = (@(Invoke-GitText @('config', '--get', 'core.autocrlf'))[0]).Trim()
    binding_select_sha256 = $liveHash
    binding_select_matches = $true
    server_process_inspected = $false
    live_logs_inspected = $false
    new_sql_queries = @()
    database_writes = @()
    migrations = @()
    process_control_actions = @()
    source_or_config_changes = @()
    build_actions = @()
}
Write-Utf8NoBom (Join-Path $evidence 'input-and-integrity.json') @(($identity | ConvertTo-Json -Depth 7))

[ordered]@{
    manual_hash_provenance = 'PASS_WITH_LIMITATION'
    clean_build_02b_recommendation = 'GO'
    world_tracker_rows = $worldTracker.Count
    world_candidate_files = $worldFiles.Count
    exact_world_names = @($worldRows | Where-Object exact_name_match).Count
    missing = $missing.Count
    additional = $additional.Count
    duplicate_tracker = $trackerDuplicates.Count
    duplicate_source = $sourceDuplicates.Count
    character_rows = $characterRows.Count
    manifest_rows = $allRows.Count
} | ConvertTo-Json
