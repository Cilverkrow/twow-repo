$ErrorActionPreference = 'Stop'
$phase1bDirectory = Split-Path -Parent $PSScriptRoot
$beforePath = Join-Path $phase1bDirectory 'evidence\phase1a-integrity-before.json'
$afterPath = Join-Path $phase1bDirectory 'evidence\phase1a-integrity-after.json'
$outputPath = Join-Path $phase1bDirectory 'evidence\phase1a-integrity-comparison.json'
if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite: $outputPath" }

$before = Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json
$after = Get-Content -LiteralPath $afterPath -Raw | ConvertFrom-Json
$beforeByPath = @{}
foreach ($entry in $before.files) { $beforeByPath[$entry.relative_path] = $entry }
$afterByPath = @{}
foreach ($entry in $after.files) { $afterByPath[$entry.relative_path] = $entry }
$differences = [System.Collections.Generic.List[object]]::new()

foreach ($relativePath in @($beforeByPath.Keys + $afterByPath.Keys | Sort-Object -Unique)) {
    $left = $beforeByPath[$relativePath]
    $right = $afterByPath[$relativePath]
    if ($null -eq $left) {
        $differences.Add([ordered]@{ relative_path = $relativePath; difference = 'added' })
    } elseif ($null -eq $right) {
        $differences.Add([ordered]@{ relative_path = $relativePath; difference = 'removed' })
    } elseif (
        $left.size_bytes -ne $right.size_bytes -or
        $left.sha256 -ne $right.sha256 -or
        $left.last_write_utc -ne $right.last_write_utc
    ) {
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
$result = [ordered]@{
    schema_version = 1
    result = if ($match) { 'PHASE1A_HARDENING_INTEGRITY=UNCHANGED' } else { 'PHASE1A_HARDENING_INTEGRITY=CHANGED' }
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
[System.IO.File]::WriteAllText(
    $outputPath,
    ($result | ConvertTo-Json -Depth 8) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output $result.result
if (-not $match) { exit 1 }
