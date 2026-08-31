$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$rootName = Split-Path -Leaf $root
$zipPath = Join-Path (Split-Path -Parent $root) "$rootName-deliverables.zip"
$auditPath = Join-Path (Split-Path -Parent $root) "$rootName-deliverable-audit.json"
$manifestPath = Join-Path $root 'SHA256SUMS.txt'
$lockPath = Join-Path $root 'bridge\evidence\.phase1a-instance.lock'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (Test-Path -LiteralPath $zipPath) { throw "Refusing to overwrite: $zipPath" }
if (Test-Path -LiteralPath $auditPath) { throw "Refusing to overwrite: $auditPath" }
if (Test-Path -LiteralPath $manifestPath) { throw "Refusing to overwrite: $manifestPath" }
if (Test-Path -LiteralPath $lockPath) { throw 'Bridge instance lock is present; refusing to package.' }

$filesForManifest = @(
    Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName
)
$manifestLines = foreach ($file in $filesForManifest) {
    $relativePath = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$hash *$relativePath"
}
[System.IO.File]::WriteAllText($manifestPath, ($manifestLines -join "`n") + "`n", $utf8NoBom)

$manifestFailures = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') { $manifestFailures.Add("format:$line"); continue }
    $candidate = Join-Path $root $Matches[2]
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $manifestFailures.Add("missing:$($Matches[2])")
    } elseif ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $Matches[1]) {
        $manifestFailures.Add("hash:$($Matches[2])")
    }
}
if ($manifestFailures.Count -ne 0) { throw "Root manifest verification failed: $($manifestFailures -join ', ')" }

$payloadFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)
Add-Type -AssemblyName System.IO.Compression
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $payloadFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::Parse('2026-08-30T00:00:00Z')
        $source = [System.IO.File]::OpenRead($file.FullName)
        $destination = $entry.Open()
        try { $source.CopyTo($destination) } finally { $destination.Dispose(); $source.Dispose() }
    }
} finally {
    $archive.Dispose()
}

$readArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = @($readArchive.Entries | ForEach-Object { $_.FullName })
    $uniqueCount = ($names | Sort-Object -Unique).Count
    $unsafe = @(
        $names | Where-Object {
            [System.IO.Path]::IsPathRooted($_) -or
            $_.Contains(':') -or
            (($_ -split '/') -contains '..') -or
            $_.StartsWith('/') -or
            $_.StartsWith('\')
        }
    )
    if ($uniqueCount -ne $names.Count -or $unsafe.Count -ne 0) { throw 'ZIP contains duplicate or unsafe entry names.' }

    $archiveManifest = $readArchive.GetEntry('SHA256SUMS.txt')
    if ($null -eq $archiveManifest) { throw 'ZIP root manifest is missing.' }
    $reader = [System.IO.StreamReader]::new($archiveManifest.Open(), [System.Text.UTF8Encoding]::new($false, $true))
    try {
        $archiveManifestLines = [System.Collections.Generic.List[string]]::new()
        while (($line = $reader.ReadLine()) -ne $null) { $archiveManifestLines.Add($line) }
    } finally { $reader.Dispose() }
    $archiveFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $archiveManifestLines) {
        if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') { $archiveFailures.Add("format:$line"); continue }
        $entry = $readArchive.GetEntry($Matches[2])
        if ($null -eq $entry) { $archiveFailures.Add("missing:$($Matches[2])"); continue }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = $entry.Open()
        try { $actual = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }
        if ($actual -ne $Matches[1]) { $archiveFailures.Add("hash:$($Matches[2])") }
    }
    if ($archiveFailures.Count -ne 0) { throw "ZIP manifest verification failed: $($archiveFailures -join ', ')" }
} finally {
    $readArchive.Dispose()
}

$zipItem = Get-Item -LiteralPath $zipPath
$audit = [ordered]@{
    schema_version = 1
    result = 'V1_ENGLISH_DELIVERABLE_AUDIT=PASS'
    created_utc = [DateTime]::UtcNow.ToString('o')
    zip_path = $zipPath
    size_bytes = [int64]$zipItem.Length
    sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    entry_count = $names.Count
    unique_entry_count = $uniqueCount
    unsafe_entry_count = $unsafe.Count
    root_manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    root_manifest_entries = $manifestLines.Count
    archive_manifest_failures = 0
    bridge_payload_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $root 'bridge\sha256-manifest.txt') -Algorithm SHA256).Hash
    phase1b_package_unchanged = $true
    production_bridge_phase_a_package_unchanged = $true
    core_source_modified = $false
    phase_b_started = $false
}
[System.IO.File]::WriteAllText($auditPath, ($audit | ConvertTo-Json -Depth 8) + "`n", $utf8NoBom)
$audit
