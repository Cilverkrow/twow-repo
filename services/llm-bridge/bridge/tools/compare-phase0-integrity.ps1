$ErrorActionPreference = 'Stop'
$artifactDirectory = Split-Path -Parent $PSScriptRoot
$beforePath = Join-Path $artifactDirectory 'evidence\phase0-integrity-before.json'
$afterPath = Join-Path $artifactDirectory 'evidence\phase0-integrity-after.json'
$outputPath = Join-Path $artifactDirectory 'evidence\phase0-integrity-comparison.json'

$before = Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json
$after = Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json
$differences = [System.Collections.Generic.List[object]]::new()

$beforeByPath = @{}
foreach ($entry in $before.files) { $beforeByPath[$entry.relative_path] = $entry }
$afterByPath = @{}
foreach ($entry in $after.files) { $afterByPath[$entry.relative_path] = $entry }

$allPaths = @($beforeByPath.Keys + $afterByPath.Keys | Sort-Object -Unique)
foreach ($relativePath in $allPaths) {
    $left = $beforeByPath[$relativePath]
    $right = $afterByPath[$relativePath]
    if ($null -eq $left) {
        $differences.Add([ordered]@{ relative_path = $relativePath; difference = 'added' })
    } elseif ($null -eq $right) {
        $differences.Add([ordered]@{ relative_path = $relativePath; difference = 'removed' })
    } elseif ($left.size_bytes -ne $right.size_bytes -or $left.sha256 -ne $right.sha256 -or $left.last_write_utc -ne $right.last_write_utc) {
        $differences.Add([ordered]@{
            relative_path = $relativePath
            difference = 'changed'
            before_size_bytes = $left.size_bytes
            after_size_bytes = $right.size_bytes
            before_sha256 = $left.sha256
            after_sha256 = $right.sha256
            before_last_write_utc = $left.last_write_utc
            after_last_write_utc = $right.last_write_utc
        })
    }
}

$match = $differences.Count -eq 0 -and
    $before.file_count -eq $after.file_count -and
    $before.total_bytes -eq $after.total_bytes -and
    $before.content_fingerprint_sha256 -eq $after.content_fingerprint_sha256

$comparison = [ordered]@{
    schema_version = 1
    result = if ($match) { 'PHASE0_INTEGRITY=UNCHANGED' } else { 'PHASE0_INTEGRITY=CHANGED' }
    compared_utc = [DateTime]::UtcNow.ToString('o')
    before_file_count = $before.file_count
    after_file_count = $after.file_count
    before_total_bytes = $before.total_bytes
    after_total_bytes = $after.total_bytes
    before_fingerprint_sha256 = $before.content_fingerprint_sha256
    after_fingerprint_sha256 = $after.content_fingerprint_sha256
    difference_count = $differences.Count
    differences = @($differences)
}
$json = $comparison | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($outputPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output $comparison.result
if (-not $match) { exit 1 }
