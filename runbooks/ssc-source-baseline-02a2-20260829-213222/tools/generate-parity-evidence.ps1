[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$runbook = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222'
$evidence = Join-Path $runbook 'evidence'
$repo = 'C:\TW\ComTW\source'
$commit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$liveOutput = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.stdout.txt'
$liveMetadata = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.metadata.json'

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

function Get-GitBlobBytesSha1([string]$Path) {
    $gitPath = (Get-Command git).Source
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $gitPath
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
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { return [Convert]::ToHexString($sha1.ComputeHash($memory.ToArray())) }
    finally { $sha1.Dispose(); $memory.Dispose(); $process.Dispose() }
}

function Get-TreeEntries([string]$TreePath) {
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Invoke-GitText @('ls-tree', '-r', $commit, '--', $TreePath)) {
        if ($line -notmatch '^\d+\s+blob\s+([0-9a-f]{40})\t(.+\.sql)$') { continue }
        $path = $Matches[2]
        $workingPath = Join-Path $repo ($path.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $workingPath)) { throw "Candidate working file missing: $workingPath" }
        $entries.Add([pscustomobject][ordered]@{
            name = [IO.Path]::GetFileNameWithoutExtension($path)
            path = $path
            git_blob_oid = $Matches[1]
            size_checkout_bytes = (Get-Item -LiteralPath $workingPath).Length
            migration_sha1_checkout_bytes = (Get-FileHash -LiteralPath $workingPath -Algorithm SHA1).Hash
            migration_sha1_git_blob_bytes = Get-GitBlobBytesSha1 $path
            sha256_checkout_bytes = (Get-FileHash -LiteralPath $workingPath -Algorithm SHA256).Hash
        })
    }
    return @($entries)
}

$head = (@(Invoke-GitText @('rev-parse', 'HEAD'))[0]).Trim()
$tree = (@(Invoke-GitText @('rev-parse', "$commit^{tree}"))[0]).Trim()
if ($head -ne $commit) { throw "HEAD differs from candidate: $head" }

& git -c safe.directory=C:/TW/ComTW/source -C $repo diff --quiet $commit -- sql/database_updates sql/character_updates
$candidateDirectoriesMatch = ($LASTEXITCODE -eq 0)
if (-not $candidateDirectoriesMatch) { throw 'Candidate SQL directories differ from the requested commit' }
$sqlStatus = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo status --short --untracked-files=all -- sql/database_updates sql/character_updates)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($sqlStatus.Count -ne 0) { throw 'Candidate SQL directories are not clean' }

$metadata = Get-Content -Raw -LiteralPath $liveMetadata | ConvertFrom-Json
$liveHash = (Get-FileHash -LiteralPath $liveOutput -Algorithm SHA256).Hash
if ($liveHash -ne $metadata.stdout_sha256) { throw 'Captured live SELECT output hash no longer matches its metadata' }
$liveLines = @(Get-Content -LiteralPath $liveOutput)

$worldTracker = @($liveLines | Where-Object { $_.StartsWith("tw_world.migrations`t") } | ForEach-Object {
    $fields = $_ -split "`t", 5
    [pscustomobject][ordered]@{ id = [int]$fields[1]; name = $fields[2]; hash = $fields[3]; applied_at = $fields[4] }
} | Sort-Object id)
$charTracker = @($liveLines | Where-Object { $_.StartsWith("tw_char.migrations`t") } | ForEach-Object {
    $fields = $_ -split "`t", 5
    [pscustomobject][ordered]@{ id = [int]$fields[1]; name = $fields[2]; hash = $fields[3]; applied_at = $fields[4] }
} | Sort-Object id)
$logonTracker = @($liveLines | Where-Object { $_.StartsWith("tw_logon.migrations`t") })

$worldFiles = @(Get-TreeEntries 'sql/database_updates' | Sort-Object name, path)
$worldNames = @($worldFiles.name)
$worldTrackerNames = @($worldTracker.name)
$worldFileByName = @{}
for ($i = 0; $i -lt $worldFiles.Count; $i++) { $worldFileByName[$worldFiles[$i].name] = [pscustomobject]@{ entry = $worldFiles[$i]; index = $i + 1 } }

$worldRows = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $worldTracker.Count; $i++) {
    $tracker = $worldTracker[$i]
    $sourcePair = $worldFileByName[$tracker.name]
    $source = if ($sourcePair) { $sourcePair.entry } else { $null }
    $worldRows.Add([pscustomobject][ordered]@{
        tracker_index = $i + 1
        tracker_id = $tracker.id
        expected_contiguous_id = $worldTracker[0].id + $i
        tracker_name = $tracker.name
        source_index_by_name = if ($sourcePair) { $sourcePair.index } else { $null }
        source_name = if ($source) { $source.name } else { $null }
        source_path = if ($source) { $source.path } else { $null }
        name_match = [bool]($source -and $source.name -ceq $tracker.name)
        order_match = [bool]($sourcePair -and $sourcePair.index -eq ($i + 1))
        id_match = [bool]($tracker.id -eq ($worldTracker[0].id + $i))
        tracker_hash = $tracker.hash
        migration_sha1_checkout_bytes = if ($source) { $source.migration_sha1_checkout_bytes } else { $null }
        migration_sha1_git_blob_bytes = if ($source) { $source.migration_sha1_git_blob_bytes } else { $null }
        stored_hash_matches_checkout_bytes = [bool]($source -and $tracker.hash -ceq $source.migration_sha1_checkout_bytes)
        stored_hash_matches_git_blob_bytes = [bool]($source -and $tracker.hash -ceq $source.migration_sha1_git_blob_bytes)
        hash_classification = if ($tracker.hash -ceq 'manual') { 'manual_marker_not_file_hash' } elseif ($source -and $tracker.hash -ceq $source.migration_sha1_checkout_bytes) { 'exact_checkout_hash' } else { 'hash_mismatch' }
        git_blob_oid = if ($source) { $source.git_blob_oid } else { $null }
        size_checkout_bytes = if ($source) { $source.size_checkout_bytes } else { $null }
        sha256_checkout_bytes = if ($source) { $source.sha256_checkout_bytes } else { $null }
        applied_at = $tracker.applied_at
    })
}

$primaryCharFiles = @(Get-TreeEntries 'sql/character_updates' | Sort-Object name, path)
$legacyCharFiles = @(Get-TreeEntries 'sql/database_updates/character' | Sort-Object name, path)
$primaryCharByName = @{}; foreach ($entry in $primaryCharFiles) { $primaryCharByName[$entry.name] = $entry }
$legacyCharByName = @{}; foreach ($entry in $legacyCharFiles) { $legacyCharByName[$entry.name] = $entry }
$characterRows = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $charTracker.Count; $i++) {
    $tracker = $charTracker[$i]
    $primary = $primaryCharByName[$tracker.name]
    $legacy = $legacyCharByName[$tracker.name]
    $source = if ($primary) { $primary } else { $legacy }
    $scope = if ($primary) { 'sql/character_updates' } elseif ($legacy) { 'sql/database_updates/character' } else { 'missing' }
    $classification = if ($primary) { 'primary_character_update' } elseif ($legacy -and $tracker.name -ceq '20260817151028_character') { 'candidate_auto_updater_character_migration_and_base_integrated' } elseif ($legacy) { 'candidate_auto_updater_character_migration' } else { 'missing_source_file' }
    $characterRows.Add([pscustomobject][ordered]@{
        tracker_index = $i + 1
        tracker_id = $tracker.id
        tracker_name = $tracker.name
        primary_source_name = if ($primary) { $primary.name } else { $null }
        associated_source_path = if ($source) { $source.path } else { $null }
        source_scope = $scope
        classification = $classification
        tracker_hash = $tracker.hash
        migration_sha1_checkout_bytes = if ($source) { $source.migration_sha1_checkout_bytes } else { $null }
        migration_sha1_git_blob_bytes = if ($source) { $source.migration_sha1_git_blob_bytes } else { $null }
        stored_hash_matches_checkout_bytes = [bool]($source -and $tracker.hash -ceq $source.migration_sha1_checkout_bytes)
        stored_hash_matches_git_blob_bytes = [bool]($source -and $tracker.hash -ceq $source.migration_sha1_git_blob_bytes)
        git_blob_oid = if ($source) { $source.git_blob_oid } else { $null }
        size_checkout_bytes = if ($source) { $source.size_checkout_bytes } else { $null }
        sha256_checkout_bytes = if ($source) { $source.sha256_checkout_bytes } else { $null }
        applied_at = $tracker.applied_at
    })
}

$worldMissingNames = @($worldTrackerNames | Where-Object { $_ -notin $worldNames } | Sort-Object -Unique)
$worldAdditionalNames = @($worldNames | Where-Object { $_ -notin $worldTrackerNames } | Sort-Object -Unique)
$worldTrackerDuplicates = @($worldTracker | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })
$worldSourceDuplicates = @($worldFiles | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })
$worldHashMatches = @($worldRows | Where-Object stored_hash_matches_checkout_bytes).Count
$worldManualMarkers = @($worldRows | Where-Object hash_classification -eq 'manual_marker_not_file_hash').Count

$charPrimaryNames = @($primaryCharFiles.name)
$charTrackerNames = @($charTracker.name)
$charMissingFromPrimary = @($charTrackerNames | Where-Object { $_ -notin $charPrimaryNames } | Sort-Object -Unique)
$charAdditionalPrimary = @($charPrimaryNames | Where-Object { $_ -notin $charTrackerNames } | Sort-Object -Unique)

$inventoryCopyRow = $characterRows | Where-Object tracker_name -CEQ '20260812142512_character_inventory_copy'
$fourthCharacterRow = $characterRows | Where-Object tracker_id -eq 4

$donationPath = 'sql/logon/donation_point_progress.sql'
$donationWorkingPath = Join-Path $repo ($donationPath.Replace('/', '\'))
$donationColumns = @($liveLines | Where-Object { $_.StartsWith("tw_logon`tdonation_point_progress`t") })
$donationCountRow = @($liveLines | Where-Object { $_.StartsWith("donation_point_progress`t") })

$result = if ($worldHashMatches -eq 146 -and $worldMissingNames.Count -eq 0 -and $worldAdditionalNames.Count -eq 0 -and $worldTrackerDuplicates.Count -eq 0 -and $worldSourceDuplicates.Count -eq 0) { 'PASS' } else { 'BLOCKED' }

$matrix = [ordered]@{
    schema_version = 1
    task = 'SSC-SOURCE-BASELINE-02A2'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    candidate = [ordered]@{
        repository = $repo
        commit = $commit
        tree = $tree
        head_equals_candidate = ($head -eq $commit)
        sql_directories_match_candidate = $candidateDirectoriesMatch
        sql_status_short = @($sqlStatus)
        core_autocrlf = (@(Invoke-GitText @('config', '--get', 'core.autocrlf'))[0]).Trim()
    }
    hash_algorithm = [ordered]@{
        source = 'src/shared/Database/AutoUpdater.cpp:457-486 and src/shared/Util.cpp:668-689'
        input = 'entire checked-out file read in std::ios::binary as raw bytes'
        digest = 'SHA-1, 20 bytes'
        encoding = 'uppercase hexadecimal, two digits per digest byte, original digest-byte order'
        line_endings = 'not normalized by AutoUpdater; checkout bytes are hashed exactly'
        note = 'Git blob bytes and Windows checkout bytes can differ because core.autocrlf=true; tracker comparison must use the bytes the updater actually reads.'
    }
    live_select_evidence = [ordered]@{
        stdout_path = $liveOutput
        stdout_sha256 = $liveHash
        matches_original_metadata = ($liveHash -eq $metadata.stdout_sha256)
        original_statement_class = $metadata.statement_class
        original_database_writes = @($metadata.database_writes)
    }
    world = [ordered]@{
        tracker_count = $worldTracker.Count
        source_file_count = $worldFiles.Count
        tracker_id_min = $worldTracker[0].id
        tracker_id_max = $worldTracker[-1].id
        ids_contiguous = (@($worldRows | Where-Object { -not $_.id_match }).Count -eq 0)
        order_matches_name_sorted_source = (@($worldRows | Where-Object { -not $_.order_match }).Count -eq 0)
        missing_names = $worldMissingNames
        additional_names = $worldAdditionalNames
        duplicate_tracker_names = $worldTrackerDuplicates
        duplicate_source_names = $worldSourceDuplicates
        stored_hash_exact_checkout_matches = $worldHashMatches
        stored_manual_markers = $worldManualMarkers
        stored_nonmatching_hashes = $worldRows.Count - $worldHashMatches
        assessment = 'Name set, uniqueness, IDs and order are exact 146/146. All 146 stored hashes are the literal manual marker, not AutoUpdater SHA-1 file hashes; content parity is therefore not proven and the updater would not recognize them by hash.'
        rows = @($worldRows)
    }
    character = [ordered]@{
        tracker_count = $charTracker.Count
        primary_source_file_count = $primaryCharFiles.Count
        missing_from_primary_directory = $charMissingFromPrimary
        additional_in_primary_directory = $charAdditionalPrimary
        duplicate_tracker_names = @($charTracker | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })
        duplicate_primary_source_names = @($primaryCharFiles | Group-Object name | Where-Object Count -gt 1 | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })
        associated_file_hash_matches = @($characterRows | Where-Object stored_hash_matches_checkout_bytes).Count
        fourth_row = $fourthCharacterRow
        inventory_copy_confirmation = [ordered]@{
            expected_name = '20260812142512_character_inventory_copy'
            exact_name_match = [bool]($inventoryCopyRow -and $inventoryCopyRow.tracker_name -ceq '20260812142512_character_inventory_copy')
            tracker_hash = $inventoryCopyRow.tracker_hash
            candidate_checkout_sha1 = $inventoryCopyRow.migration_sha1_checkout_bytes
            exact_hash_match = [bool]$inventoryCopyRow.stored_hash_matches_checkout_bytes
            source_path = $inventoryCopyRow.associated_source_path
        }
        assessment = 'Rows 1-3 exactly match the three sql/character_updates files by name and checkout-byte SHA-1. Row 4 is not missing globally: its exact file remains in the candidate AutoUpdater character folder sql/database_updates/character, and its table is also present in create_databases.sql.'
        rows = @($characterRows)
    }
    donation_point_progress = [ordered]@{
        classification = 'intentional_standalone_login_database_migration'
        source_path = $donationPath
        source_sha1_checkout_bytes = (Get-FileHash -LiteralPath $donationWorkingPath -Algorithm SHA1).Hash
        source_sha256_checkout_bytes = (Get-FileHash -LiteralPath $donationWorkingPath -Algorithm SHA256).Hash
        source_contract = 'World.cpp reads and upserts account_id + accumulated_ms via LoginDatabase; mangosd.conf.dist.in names the standalone sql/logon file.'
        auto_updater_scope = 'Database.AutoUpdate.Path plus auth/character/world subfolders; sql/logon is outside that scope.'
        tw_logon_tracker_rows = $logonTracker.Count
        tracker_entry_expected = $false
        live_table_columns = $donationColumns
        live_count_row = $donationCountRow
        table_and_source_contract_match = $true
    }
    limitations = @(
        'A manual tracker marker proves only that a name was recorded; it does not prove which file bytes or SQL effects were applied.',
        'This comparison performed no new SQL query and used the prior successful SELECT artifact.',
        'No build, migration, process control, source edit or database write was performed.'
    )
    tracker_source_parity = $result
    blocking_reason = if ($result -eq 'BLOCKED') { 'All 146 tw_world Hash values are manual instead of the exact SHA-1 hashes calculated from candidate files, so world content provenance cannot be established from the tracker.' } else { $null }
}

$matrixPath = Join-Path $evidence 'tracker-source-parity-matrix.json'
Write-Utf8NoBom $matrixPath @(($matrix | ConvertTo-Json -Depth 12))
Write-Utf8NoBom (Join-Path $evidence 'world-parity.csv') @($worldRows | ConvertTo-Csv -NoTypeInformation)
Write-Utf8NoBom (Join-Path $evidence 'character-parity.csv') @($characterRows | ConvertTo-Csv -NoTypeInformation)

$excerpts = [System.Collections.Generic.List[string]]::new()
function Add-Excerpt([string]$Path, [int]$Start, [int]$End) {
    $lines = @(Invoke-GitText @('show', "$commit`:$Path"))
    $excerpts.Add("===== $Path @ $commit lines $Start-$End =====")
    for ($number = $Start; $number -le [Math]::Min($End, $lines.Count); $number++) {
        $excerpts.Add(('{0,6}: {1}' -f $number, $lines[$number - 1]))
    }
}
Add-Excerpt 'src/shared/Database/AutoUpdater.cpp' 102 129
Add-Excerpt 'src/shared/Database/AutoUpdater.cpp' 133 230
Add-Excerpt 'src/shared/Database/AutoUpdater.cpp' 441 487
Add-Excerpt 'src/shared/Database/AutoUpdater.cpp' 489 530
Add-Excerpt 'src/shared/Util.cpp' 668 689
Add-Excerpt 'src/mangosd/mangosd.conf.dist.in' 42 52
Add-Excerpt 'README.md' 177 189
Add-Excerpt 'INSTALL-WINDOWS.md' 218 249
Add-Excerpt 'src/game/World.cpp' 2890 2995
Add-Excerpt 'src/mangosd/mangosd.conf.dist.in' 2083 2093
Add-Excerpt 'sql/logon/donation_point_progress.sql' 1 30
Add-Excerpt 'sql/database_updates/character/20260817151028_character.sql' 1 30
Write-Utf8NoBom (Join-Path $evidence 'source-excerpts.txt') @($excerpts)

[ordered]@{
    result = $result
    world_tracker_count = $worldTracker.Count
    world_source_count = $worldFiles.Count
    world_name_order_mismatches = @($worldRows | Where-Object { -not $_.order_match }).Count
    world_hash_matches = $worldHashMatches
    world_manual_markers = $worldManualMarkers
    character_tracker_count = $charTracker.Count
    character_primary_source_count = $primaryCharFiles.Count
    character_associated_hash_matches = @($characterRows | Where-Object stored_hash_matches_checkout_bytes).Count
    inventory_copy_hash_match = [bool]$inventoryCopyRow.stored_hash_matches_checkout_bytes
    matrix_path = $matrixPath
} | ConvertTo-Json
