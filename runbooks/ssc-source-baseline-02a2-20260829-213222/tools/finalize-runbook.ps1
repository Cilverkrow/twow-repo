[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$runbook = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222'
$repo = 'C:\TW\ComTW\source'
$commit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$integrityPath = Join-Path $runbook 'evidence\final-integrity.json'
$manifestPath = Join-Path $runbook 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $integrityPath) { throw 'Refusing overwrite: final-integrity.json' }
if (Test-Path -LiteralPath $manifestPath) { throw 'Refusing overwrite: SHA256SUMS.txt' }
$priorIdentity = Get-Content -Raw -LiteralPath 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352\evidence\source-identity.json' | ConvertFrom-Json
$status = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo status --short --untracked-files=all) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
& git -c safe.directory=C:/TW/ComTW/source -C $repo diff --quiet $commit -- sql/database_updates sql/character_updates
$sqlDiffExit = $LASTEXITCODE
$integrity = [ordered]@{
    captured_utc = [DateTime]::UtcNow.ToString('o')
    candidate_commit = $commit
    head = (& git -c safe.directory=C:/TW/ComTW/source -C $repo rev-parse HEAD).Trim()
    source_status_short = $status
    source_status_equals_prior_captured_status = ($status -ceq $priorIdentity.status_short)
    candidate_sql_directories_unchanged = ($sqlDiffExit -eq 0)
    reused_live_select_sha256 = (Get-FileHash -LiteralPath 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358\evidence\live-schema-selects-after-user-start-no-tls.stdout.txt' -Algorithm SHA256).Hash
    new_sql_queries = @()
    sql_writes = @()
    migrations_executed = @()
    process_control_actions = @()
    source_or_config_changes = @()
    build_actions = @()
    clean_build_started = $false
    task_writes_scope = $runbook
}
[IO.File]::WriteAllText($integrityPath, ($integrity | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
$files = @(Get-ChildItem -LiteralPath $runbook -Recurse -File | Sort-Object FullName)
$manifestLines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($runbook.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
[IO.File]::WriteAllLines($manifestPath, $manifestLines, [Text.UTF8Encoding]::new($false))
[ordered]@{
    integrity = $integrity
    manifest_path = $manifestPath
    manifest_entries = $manifestLines.Count
} | ConvertTo-Json -Depth 7
