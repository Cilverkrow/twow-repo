param(
    [string]$Phase1aDirectory = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-hardening-20260829-035317'
)

$ErrorActionPreference = 'Stop'
$phase1bDirectory = Split-Path -Parent $PSScriptRoot
$sourcePackageDirectory = Join-Path $phase1bDirectory 'source-package'
$bridgeDirectory = Join-Path $phase1bDirectory 'bridge'
$evidenceDirectory = Join-Path $phase1bDirectory 'evidence'
$zipName = 'ssc-llm-bridge-phase1a-hardening-20260829-035317-deliverables.zip'
$sourceZipPath = Join-Path $Phase1aDirectory $zipName
$copiedZipPath = Join-Path $sourcePackageDirectory $zipName
$evidencePath = Join-Path $evidenceDirectory 'source-package-verification.json'
$expectedZipSize = [int64]71689
$expectedZipSha256 = 'BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($requiredDirectory in @($Phase1aDirectory, $sourcePackageDirectory, $bridgeDirectory, $evidenceDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Required directory is missing: $requiredDirectory"
    }
}
foreach ($mustNotExist in @($copiedZipPath, $evidencePath)) {
    if (Test-Path -LiteralPath $mustNotExist) {
        throw "Refusing to overwrite: $mustNotExist"
    }
}
if (@(Get-ChildItem -LiteralPath $bridgeDirectory -Force).Count -ne 0) {
    throw "Bridge extraction directory is not empty: $bridgeDirectory"
}

$phase1aFiles = @(Get-ChildItem -LiteralPath $Phase1aDirectory -Recurse -File | Sort-Object FullName)
$phase1aFingerprintLines = foreach ($file in $phase1aFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($Phase1aDirectory, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$relativePath|$($file.Length)|$hash"
}
$phase1aFingerprintBytes = $utf8NoBom.GetBytes(($phase1aFingerprintLines -join "`n") + "`n")
$phase1aFingerprint = [Convert]::ToHexString(
    [System.Security.Cryptography.SHA256]::HashData($phase1aFingerprintBytes)
)
$phase1aTotalBytes = [int64]($phase1aFiles | Measure-Object Length -Sum).Sum

$sourceZipItem = Get-Item -LiteralPath $sourceZipPath
$sourceZipHash = (Get-FileHash -LiteralPath $sourceZipPath -Algorithm SHA256).Hash
if ($sourceZipItem.Length -ne $expectedZipSize -or $sourceZipHash -ne $expectedZipSha256) {
    throw 'The immutable Phase-1A ZIP does not match its independently reviewed size and SHA-256.'
}

Copy-Item -LiteralPath $sourceZipPath -Destination $copiedZipPath
$copiedZipItem = Get-Item -LiteralPath $copiedZipPath
$copiedZipHash = (Get-FileHash -LiteralPath $copiedZipPath -Algorithm SHA256).Hash
if ($copiedZipItem.Length -ne $expectedZipSize -or $copiedZipHash -ne $expectedZipSha256) {
    throw 'The Phase-1B source-package copy differs from the verified Phase-1A ZIP.'
}

Add-Type -AssemblyName System.IO.Compression
$archive = [System.IO.Compression.ZipFile]::OpenRead($copiedZipPath)
try {
    $actualEntries = @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    $uniqueEntries = @($actualEntries | Sort-Object -Unique)
    $unsafeEntries = @($actualEntries | Where-Object {
        $_ -match '(^/|^\\|^[A-Za-z]:|(^|/)\.\.(/|$))'
    })
    if ($actualEntries.Count -ne 50 -or $uniqueEntries.Count -ne 50 -or $unsafeEntries.Count -ne 0) {
        throw 'ZIP entry count, uniqueness, or path safety validation failed.'
    }

    $entryListEntry = $archive.GetEntry('package-entry-list.txt')
    $manifestEntry = $archive.GetEntry('sha256-manifest.txt')
    if ($null -eq $entryListEntry -or $null -eq $manifestEntry) {
        throw 'ZIP is missing its entry list or SHA-256 manifest.'
    }

    $entryListReader = [System.IO.StreamReader]::new($entryListEntry.Open(), $utf8NoBom, $false)
    try { $entryListText = $entryListReader.ReadToEnd() } finally { $entryListReader.Dispose() }
    $expectedEntries = @($entryListText -split "`r?`n" | Where-Object { $_ -ne '' } | Sort-Object)
    if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
        throw 'Embedded package-entry-list.txt does not match the ZIP entries.'
    }

    $manifestReader = [System.IO.StreamReader]::new($manifestEntry.Open(), $utf8NoBom, $false)
    try { $manifestText = $manifestReader.ReadToEnd() } finally { $manifestReader.Dispose() }
    $manifestMap = @{}
    foreach ($line in @($manifestText -split "`r?`n" | Where-Object { $_ -ne '' })) {
        if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') {
            throw "Invalid manifest line: $line"
        }
        if ($manifestMap.ContainsKey($Matches[2])) {
            throw "Duplicate manifest path: $($Matches[2])"
        }
        $manifestMap[$Matches[2]] = $Matches[1]
    }
    if ($manifestMap.Count -ne 49 -or $manifestMap.ContainsKey('sha256-manifest.txt')) {
        throw 'Manifest entry count or self-exclusion rule is invalid.'
    }

    $manifestHashFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -eq 'sha256-manifest.txt') { continue }
        if (-not $manifestMap.ContainsKey($entry.FullName)) {
            $manifestHashFailures.Add("missing:$($entry.FullName)")
            continue
        }
        $stream = $entry.Open()
        try {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            try { $entryHash = [Convert]::ToHexString($hasher.ComputeHash($stream)) }
            finally { $hasher.Dispose() }
        } finally { $stream.Dispose() }
        if ($entryHash -ne $manifestMap[$entry.FullName]) {
            $manifestHashFailures.Add("hash:$($entry.FullName)")
        }
    }
    if ($manifestHashFailures.Count -ne 0) {
        throw "Manifest verification failed: $($manifestHashFailures -join ', ')"
    }
} finally {
    $archive.Dispose()
}

[System.IO.Compression.ZipFile]::ExtractToDirectory($copiedZipPath, $bridgeDirectory)
$extractedFiles = @(Get-ChildItem -LiteralPath $bridgeDirectory -Recurse -File)
if ($extractedFiles.Count -ne 50) {
    throw "Expected 50 extracted files; observed $($extractedFiles.Count)."
}

$verification = [ordered]@{
    schema_version = 1
    result = 'PHASE1B_SOURCE_PACKAGE_VERIFICATION=PASS'
    verified_utc = [DateTime]::UtcNow.ToString('o')
    live_execution_started = $false
    phase1a_directory = $Phase1aDirectory
    phase1a_directory_file_count = $phase1aFiles.Count
    phase1a_directory_total_bytes = $phase1aTotalBytes
    phase1a_directory_fingerprint_sha256 = $phase1aFingerprint
    source_zip_path = $sourceZipPath
    copied_zip_path = $copiedZipPath
    zip_size_bytes = [int64]$copiedZipItem.Length
    zip_sha256 = $copiedZipHash
    zip_entry_count = 50
    zip_unique_entry_count = 50
    unsafe_entry_count = 0
    manifest_entry_count = 49
    manifest_hash_failures = 0
    entry_list_matches = $true
    extracted_file_count = $extractedFiles.Count
}
[System.IO.File]::WriteAllText(
    $evidencePath,
    ($verification | ConvertTo-Json -Depth 6) + "`n",
    $utf8NoBom
)

Write-Output $verification.result
Write-Output "zip_sha256=$copiedZipHash"
Write-Output "zip_entries=$($verification.zip_entry_count)"
Write-Output "manifest_hash_failures=$($verification.manifest_hash_failures)"
Write-Output "phase1a_directory_fingerprint_sha256=$phase1aFingerprint"
