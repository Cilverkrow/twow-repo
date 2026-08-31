param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('before', 'after')]
    [string]$Label
)

$ErrorActionPreference = 'Stop'
$phase0Directory = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase0-20260829-015349'
$phase1aDirectory = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $phase1aDirectory "evidence\phase0-integrity-$Label.json"

if (-not (Test-Path -LiteralPath $phase0Directory -PathType Container)) {
    throw "Phase-0 directory not found: $phase0Directory"
}

$entries = @(
    Get-ChildItem -LiteralPath $phase0Directory -Recurse -File |
        ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($phase0Directory, $_.FullName).Replace('\', '/')
            [ordered]@{
                relative_path = $relativePath
                size_bytes = [int64]$_.Length
                last_write_utc = $_.LastWriteTimeUtc.ToString('o')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } |
        Sort-Object { $_.relative_path }
)

$fingerprintLines = foreach ($entry in $entries) {
    '{0}|{1}|{2}' -f $entry.relative_path, $entry.size_bytes, $entry.sha256
}
$fingerprintBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($fingerprintLines -join "`n") + "`n")
$fingerprint = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($fingerprintBytes))
$totalBytes = [int64]0
foreach ($entry in $entries) {
    $totalBytes += [int64]$entry.size_bytes
}

$snapshot = [ordered]@{
    schema_version = 1
    label = $Label
    phase0_directory = $phase0Directory
    captured_utc = [DateTime]::UtcNow.ToString('o')
    file_count = $entries.Count
    total_bytes = $totalBytes
    content_fingerprint_sha256 = $fingerprint
    files = $entries
}

$json = $snapshot | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($outputPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output $outputPath
