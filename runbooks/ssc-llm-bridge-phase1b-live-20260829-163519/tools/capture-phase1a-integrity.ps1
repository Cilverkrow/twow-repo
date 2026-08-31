param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('before', 'after')]
    [string]$Label
)

$ErrorActionPreference = 'Stop'
$phase1aDirectory = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-hardening-20260829-035317'
$phase1bDirectory = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $phase1bDirectory "evidence\phase1a-integrity-$Label.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to overwrite: $outputPath"
}
$entries = @(
    Get-ChildItem -LiteralPath $phase1aDirectory -Recurse -File |
        ForEach-Object {
            [ordered]@{
                relative_path = [System.IO.Path]::GetRelativePath($phase1aDirectory, $_.FullName).Replace('\', '/')
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
$fingerprintBytes = $utf8NoBom.GetBytes(($fingerprintLines -join "`n") + "`n")
$totalBytes = [int64]0
foreach ($entry in $entries) { $totalBytes += $entry.size_bytes }

$result = [ordered]@{
    schema_version = 1
    label = $Label
    phase1a_directory = $phase1aDirectory
    captured_utc = [DateTime]::UtcNow.ToString('o')
    file_count = $entries.Count
    total_bytes = $totalBytes
    content_fingerprint_sha256 = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($fingerprintBytes)
    )
    files = $entries
}
[System.IO.File]::WriteAllText(
    $outputPath,
    ($result | ConvertTo-Json -Depth 8) + "`n",
    $utf8NoBom
)
Write-Output $outputPath
Write-Output "files=$($result.file_count) bytes=$totalBytes fingerprint=$($result.content_fingerprint_sha256)"
