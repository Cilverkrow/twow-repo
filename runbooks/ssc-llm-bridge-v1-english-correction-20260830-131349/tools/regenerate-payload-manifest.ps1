$ErrorActionPreference = 'Stop'

$runbookRoot = Split-Path -Parent $PSScriptRoot
$bridgeRoot = Join-Path $runbookRoot 'bridge'
$expectedBridgeRoot = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-v1-english-correction-20260830-131349\bridge'
$resolvedBridgeRoot = [System.IO.Path]::GetFullPath($bridgeRoot)
if ($resolvedBridgeRoot -ne $expectedBridgeRoot) {
    throw "Unexpected bridge root: $resolvedBridgeRoot"
}

$entryListPath = Join-Path $bridgeRoot 'package-entry-list.txt'
$manifestPath = Join-Path $bridgeRoot 'sha256-manifest.txt'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$payloadFiles = @(
    Get-ChildItem -LiteralPath $bridgeRoot -Recurse -File |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName
)
$expectedEntries = @(
    $payloadFiles |
        ForEach-Object { [System.IO.Path]::GetRelativePath($bridgeRoot, $_.FullName).Replace('\', '/') }
    'sha256-manifest.txt'
) | Sort-Object -Unique
[System.IO.File]::WriteAllText($entryListPath, ($expectedEntries -join "`n") + "`n", $utf8NoBom)

$manifestFiles = @(
    Get-ChildItem -LiteralPath $bridgeRoot -Recurse -File |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName
)
$manifestLines = foreach ($file in $manifestFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($bridgeRoot, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$hash *$relativePath"
}
[System.IO.File]::WriteAllText($manifestPath, ($manifestLines -join "`n") + "`n", $utf8NoBom)

$actualEntries = @(
    Get-ChildItem -LiteralPath $bridgeRoot -Recurse -File |
        ForEach-Object { [System.IO.Path]::GetRelativePath($bridgeRoot, $_.FullName).Replace('\', '/') } |
        Sort-Object
)
if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
    throw 'Payload entry set changed during manifest generation.'
}

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') {
        $failures.Add("format:$line")
        continue
    }
    $candidate = Join-Path $bridgeRoot $Matches[2]
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $failures.Add("missing:$($Matches[2])")
    } elseif ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $Matches[1]) {
        $failures.Add("hash:$($Matches[2])")
    }
}
if ($failures.Count -ne 0) {
    throw "Manifest verification failed: $($failures -join ', ')"
}

[pscustomobject]@{
    result = 'V1_ENGLISH_PAYLOAD_MANIFEST=PASS'
    files = $actualEntries.Count
    manifest_entries = (Get-Content -LiteralPath $manifestPath).Count
    manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    entry_list_sha256 = (Get-FileHash -LiteralPath $entryListPath -Algorithm SHA256).Hash
    failures = 0
}
