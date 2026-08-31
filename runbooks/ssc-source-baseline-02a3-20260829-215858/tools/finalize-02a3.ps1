[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$runbook = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02a3-20260829-215858'
$repo = 'C:\TW\ComTW\source'
$commit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$verificationPath = Join-Path $runbook 'evidence\final-verification.json'
$manifestPath = Join-Path $runbook 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $verificationPath) { throw 'Refusing overwrite: final-verification.json' }
if (Test-Path -LiteralPath $manifestPath) { throw 'Refusing overwrite: SHA256SUMS.txt' }
$matrixPath = Join-Path $runbook 'evidence\external-candidate-baseline-manifest.json'
$csvPath = Join-Path $runbook 'evidence\external-candidate-baseline-manifest.csv'
$matrix = Get-Content -Raw -LiteralPath $matrixPath | ConvertFrom-Json
$csv = @(Import-Csv -LiteralPath $csvPath)
$world = @($csv | Where-Object record_scope -eq 'world')
$character = @($csv | Where-Object record_scope -eq 'character')
$priorIdentity = Get-Content -Raw -LiteralPath 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352\evidence\source-identity.json' | ConvertFrom-Json
$status = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo status --short --untracked-files=all) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
& git -c safe.directory=C:/TW/ComTW/source -C $repo diff --quiet $commit -- sql/database_updates sql/character_updates sql/logon/donation_point_progress.sql
$migrationPathsClean = ($LASTEXITCODE -eq 0)
$requiredWorldFieldsComplete = @($world | Where-Object {
    [string]::IsNullOrWhiteSpace($_.tracker_id) -or
    [string]::IsNullOrWhiteSpace($_.tracker_name) -or
    [string]::IsNullOrWhiteSpace($_.relative_file_path) -or
    [string]::IsNullOrWhiteSpace($_.git_blob_id) -or
    [string]::IsNullOrWhiteSpace($_.candidate_file_sha256) -or
    $_.exact_name_match -ne 'True'
}).Count -eq 0
$verification = [ordered]@{
    captured_utc = [DateTime]::UtcNow.ToString('o')
    decision = $matrix.decision
    binding_select_sha256 = (Get-FileHash -LiteralPath 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.stdout.txt' -Algorithm SHA256).Hash
    candidate_commit = $commit
    head = (& git -c safe.directory=C:/TW/ComTW/source -C $repo rev-parse HEAD).Trim()
    source_status_equals_prior_captured_status = ($status -ceq $priorIdentity.status_short)
    migration_paths_clean = $migrationPathsClean
    json_row_count = @($matrix.rows).Count
    csv_row_count = $csv.Count
    world_row_count = $world.Count
    character_row_count = $character.Count
    required_world_fields_complete = $requiredWorldFieldsComplete
    world_exact_name_matches = @($world | Where-Object exact_name_match -eq 'True').Count
    world_exact_order_matches = @($world | Where-Object exact_order_match -eq 'True').Count
    world_contiguous_id_matches = @($world | Where-Object contiguous_id_match -eq 'True').Count
    world_manual_markers = @($world | Where-Object historical_tracker_hash -CEQ 'manual').Count
    historical_world_byte_equality_claimed = $false
    server_process_inspected = $false
    live_logs_inspected = $false
    new_sql_queries = @()
    database_writes = @()
    tracker_changes = @()
    migrations_executed = @()
    process_control_actions = @()
    source_or_config_changes = @()
    build_actions = @()
    clean_build_started = $false
    task_writes_scope = $runbook
}
if ($verification.binding_select_sha256 -ne 'B866C9F412526AF05D13823D4F3D508F04CDC74005A720DE0FD08195F223888B' -or
    $verification.head -ne $commit -or -not $verification.source_status_equals_prior_captured_status -or
    -not $verification.migration_paths_clean -or $verification.json_row_count -ne 150 -or
    $verification.csv_row_count -ne 150 -or $verification.world_row_count -ne 146 -or
    $verification.character_row_count -ne 4 -or -not $verification.required_world_fields_complete -or
    $verification.world_exact_name_matches -ne 146 -or $verification.world_exact_order_matches -ne 146 -or
    $verification.world_contiguous_id_matches -ne 146 -or $verification.world_manual_markers -ne 146) {
    throw 'Final verification gate failed'
}
[IO.File]::WriteAllText($verificationPath, ($verification | ConvertTo-Json -Depth 7) + "`n", [Text.UTF8Encoding]::new($false))
$files = @(Get-ChildItem -LiteralPath $runbook -Recurse -File | Sort-Object FullName)
$hashLines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($runbook.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
[IO.File]::WriteAllLines($manifestPath, $hashLines, [Text.UTF8Encoding]::new($false))
[ordered]@{
    final_verification = $verification
    sha256_manifest_path = $manifestPath
    sha256_manifest_entries = $hashLines.Count
} | ConvertTo-Json -Depth 8
