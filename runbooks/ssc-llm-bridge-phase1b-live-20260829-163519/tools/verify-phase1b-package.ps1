$ErrorActionPreference = 'Stop'

$artifactDirectory = Split-Path -Parent $PSScriptRoot
$artifactName = Split-Path -Leaf $artifactDirectory
$zipPath = Join-Path $artifactDirectory "$artifactName-deliverables.zip"
$manifestPath = Join-Path $artifactDirectory 'phase1b-sha256-manifest.txt'
$entryListPath = Join-Path $artifactDirectory 'phase1b-package-entry-list.txt'
$packageEvidencePath = Join-Path $artifactDirectory 'evidence\phase1b-package-evidence.json'
$packageAuditPath = Join-Path $artifactDirectory 'evidence\phase1b-package-audit.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (Test-Path -LiteralPath $packageAuditPath) {
    throw "Refusing to overwrite existing package audit: $packageAuditPath"
}
foreach ($requiredPath in @($zipPath, $manifestPath, $entryListPath, $packageEvidencePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required package artifact is missing: $requiredPath"
    }
}

function Write-Utf8CreateNew([string]$Path, [string]$Content) {
    $bytes = $utf8NoBom.GetBytes($Content)
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Assert-SafeRelativeEntry([string]$RelativePath) {
    $segments = $RelativePath.Split([char[]]@('/'), [System.StringSplitOptions]::None)
    if (
        [string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains(':') -or
        $RelativePath.Contains('\') -or
        $segments -contains '' -or
        $segments -contains '.' -or
        $segments -contains '..'
    ) {
        throw "Unsafe Phase-1B package entry: $RelativePath"
    }
}

$packageEvidence = Get-Content -LiteralPath $packageEvidencePath -Raw | ConvertFrom-Json
$fixedTimestampText = '2026-08-29T00:00:00Z'
if ([string]$packageEvidence.result -cne 'CREATED_PENDING_INDEPENDENT_AUDIT') {
    throw 'Unexpected package-evidence lifecycle result.'
}
$expectedFixedTimestamp = [DateTimeOffset]::Parse($fixedTimestampText)
$evidenceFixedTimestamp = [DateTimeOffset]$packageEvidence.fixed_entry_timestamp_utc
if ($evidenceFixedTimestamp.ToUniversalTime() -ne $expectedFixedTimestamp) {
    throw 'Package evidence contains an unexpected fixed entry timestamp.'
}
$zipItem = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
if ([int64]$packageEvidence.size_bytes -ne [int64]$zipItem.Length) {
    throw 'ZIP size does not match external package evidence.'
}
if ([string]$packageEvidence.sha256 -cne $zipHash) {
    throw 'ZIP SHA-256 does not match external package evidence.'
}

$expectedEntries = @(
    (Get-Content -LiteralPath $entryListPath) |
        Where-Object { $_.Length -gt 0 }
)
if ($expectedEntries.Count -eq 0) {
    throw 'Outer package entry list is empty.'
}
if (($expectedEntries | Select-Object -Unique).Count -ne $expectedEntries.Count) {
    throw 'Outer package entry list contains duplicates.'
}
if ([int]$packageEvidence.entry_count -ne $expectedEntries.Count) {
    throw 'Entry count does not match external package evidence.'
}
if (($packageEvidence.entries -join "`n") -cne ($expectedEntries -join "`n")) {
    throw 'External package evidence entry list does not match the canonical list.'
}
$requiredEntries = @(
    'README.md'
    'phase1b-report.md'
    'source-package/ssc-llm-bridge-phase1a-hardening-20260829-035317-deliverables.zip'
    'bridge/package-entry-list.txt'
    'bridge/sha256-manifest.txt'
    'bridge/src/cli.mjs'
    'evidence/action-audit.json'
    'evidence/boundary-observation-after.json'
    'evidence/boundary-observation-before.json'
    'evidence/bridge-stderr.txt'
    'evidence/bridge-stdin.ndjson'
    'evidence/bridge-stdout.ndjson'
    'evidence/bridge-transcript.json'
    'evidence/completion-envelope.json'
    'evidence/consume-first-response.json'
    'evidence/consume-second-response.json'
    'evidence/extracted-payload-verification.json'
    'evidence/instance-lock-present.json'
    'evidence/instance-lock-removed.json'
    'evidence/latency.json'
    'evidence/live-run-result.json'
    'evidence/metrics-before-shutdown.json'
    'evidence/offline-verification.json'
    'evidence/ollama-ps-after.json'
    'evidence/ollama-ps-before.json'
    'evidence/phase1a-integrity-after.json'
    'evidence/phase1a-integrity-before.json'
    'evidence/phase1a-integrity-comparison.json'
    'evidence/phase1b-one-shot.guard.json'
    'evidence/request-envelope.json'
    'evidence/shutdown-response.json'
    'evidence/source-package-verification.json'
    'evidence/submit-response.json'
    'evidence/terminal-status.json'
    'tools/build-phase1b-deliverables.ps1'
    'tools/phase1b-one-shot.mjs'
    'tools/verify-phase1b-evidence.mjs'
    'tools/verify-phase1b-package.ps1'
)
$missingRequiredEntries = @(
    $requiredEntries | Where-Object { $expectedEntries -cnotcontains $_ }
)
if ($missingRequiredEntries.Count -ne 0) {
    throw "Required Phase-1B evidence is absent from the canonical list: $($missingRequiredEntries -join ', ')"
}
$entryListHash = (Get-FileHash -LiteralPath $entryListPath -Algorithm SHA256).Hash
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
if ([string]$packageEvidence.entry_list_sha256 -cne $entryListHash) {
    throw 'Entry-list SHA-256 does not match external package evidence.'
}
if ([string]$packageEvidence.manifest_sha256 -cne $manifestHash) {
    throw 'Manifest SHA-256 does not match external package evidence.'
}

Add-Type -AssemblyName System.IO.Compression
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $archiveEntries = @($archive.Entries)
    $archiveNames = @($archiveEntries | ForEach-Object { $_.FullName })
    if ($archiveEntries.Count -ne $expectedEntries.Count) {
        throw 'ZIP entry count does not match the canonical entry list.'
    }
    if (($archiveNames | Select-Object -Unique).Count -ne $archiveNames.Count) {
        throw 'ZIP contains duplicate entry names.'
    }
    foreach ($entryName in $archiveNames) {
        Assert-SafeRelativeEntry $entryName
    }
    foreach ($archiveEntry in $archiveEntries) {
        if ($archiveEntry.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') -cne '2026-08-29T00:00:00') {
            throw "ZIP entry has a non-deterministic timestamp: $($archiveEntry.FullName)"
        }
    }
    if (($archiveNames -join "`n") -cne ($expectedEntries -join "`n")) {
        throw 'ZIP entries or order differ from the canonical entry list.'
    }

    $entryListEntry = $archive.GetEntry('phase1b-package-entry-list.txt')
    $manifestEntry = $archive.GetEntry('phase1b-sha256-manifest.txt')
    if ($null -eq $entryListEntry -or $null -eq $manifestEntry) {
        throw 'ZIP lacks its entry list or SHA-256 manifest.'
    }

    $reader = [System.IO.StreamReader]::new($entryListEntry.Open(), [System.Text.Encoding]::UTF8, $true)
    try {
        $internalEntryListText = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    $externalEntryListText = [System.IO.File]::ReadAllText($entryListPath)
    if ($internalEntryListText -cne $externalEntryListText) {
        throw 'Internal and external package entry lists differ.'
    }

    $reader = [System.IO.StreamReader]::new($manifestEntry.Open(), [System.Text.Encoding]::UTF8, $true)
    try {
        $manifestText = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if ($manifestText -cne [System.IO.File]::ReadAllText($manifestPath)) {
        throw 'Internal and external SHA-256 manifests differ.'
    }

    $manifestRecords = [ordered]@{}
    foreach ($line in ($manifestText -split "`n")) {
        if ($line.Length -eq 0) {
            continue
        }
        if ($line -cnotmatch '^([A-F0-9]{64}) \*(.+)$') {
            throw "Malformed manifest line: $line"
        }
        $manifestHash = $Matches[1]
        $manifestName = $Matches[2]
        if ($manifestRecords.Contains($manifestName)) {
            throw "Duplicate manifest path: $manifestName"
        }
        $manifestRecords[$manifestName] = $manifestHash
    }

    $expectedManifestNames = @($expectedEntries | Where-Object { $_ -cne 'phase1b-sha256-manifest.txt' })
    if ($manifestRecords.Count -ne $expectedManifestNames.Count) {
        throw 'Manifest entry count is not exactly ZIP entry count minus itself.'
    }
    if ([int]$packageEvidence.manifest_entry_count -ne $manifestRecords.Count) {
        throw 'Manifest entry count does not match external package evidence.'
    }
    if (($manifestRecords.Keys -join "`n") -cne ($expectedManifestNames -join "`n")) {
        throw 'Manifest paths differ from the self-excluding expected entry set.'
    }

    $hashFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($manifestName in $manifestRecords.Keys) {
        $entry = $archive.GetEntry($manifestName)
        if ($null -eq $entry) {
            $hashFailures.Add("missing:$manifestName")
            continue
        }
        $stream = $entry.Open()
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
        } finally {
            $sha256.Dispose()
            $stream.Dispose()
        }
        if ($actualHash -cne [string]$manifestRecords[$manifestName]) {
            $hashFailures.Add("hash:$manifestName")
        }
    }
    if ($hashFailures.Count -ne 0) {
        throw "Archive manifest verification failed: $($hashFailures -join ', ')"
    }
} finally {
    $archive.Dispose()
}

$diskFiles = @(
    Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
        Where-Object {
            $_.FullName -ne $zipPath -and
            $_.FullName -ne $packageEvidencePath -and
            $_.FullName -ne $packageAuditPath
        } |
        Sort-Object { [System.IO.Path]::GetRelativePath($artifactDirectory, $_.FullName).Replace('\', '/') }
)
$diskNames = @(
    $diskFiles | ForEach-Object {
        [System.IO.Path]::GetRelativePath($artifactDirectory, $_.FullName).Replace('\', '/')
    }
)
if (($diskNames -join "`n") -cne ($expectedEntries -join "`n")) {
    throw 'Current on-disk payload differs from the packaged canonical entry list.'
}

$diskHashFailures = [System.Collections.Generic.List[string]]::new()
foreach ($manifestName in $manifestRecords.Keys) {
    $diskPath = Join-Path $artifactDirectory $manifestName.Replace('/', '\')
    $diskHash = (Get-FileHash -LiteralPath $diskPath -Algorithm SHA256).Hash
    if ($diskHash -cne [string]$manifestRecords[$manifestName]) {
        $diskHashFailures.Add($manifestName)
    }
}
if ($diskHashFailures.Count -ne 0) {
    throw "On-disk payload hash verification failed: $($diskHashFailures -join ', ')"
}

$audit = [ordered]@{
    schema_version = 1
    result = 'PASS'
    zip_path = $zipPath
    size_bytes = [int64]$zipItem.Length
    sha256 = $zipHash
    entry_count = $expectedEntries.Count
    unique_entry_count = $expectedEntries.Count
    safe_relative_entries = $true
    required_artifacts_present = $true
    required_artifact_count = $requiredEntries.Count
    exact_entry_list_match = $true
    internal_external_entry_list_match = $true
    internal_external_manifest_match = $true
    entry_list_sha256_match = $true
    manifest_sha256_match = $true
    manifest_entry_count = $manifestRecords.Count
    manifest_self_excluded = $true
    fixed_entry_timestamp_utc = $fixedTimestampText
    all_entry_timestamps_match = $true
    archive_hash_failures = 0
    on_disk_hash_failures = 0
    current_payload_exact_match = $true
    verification_mode = 'offline read-only archive reopen plus on-disk comparison'
}
Write-Utf8CreateNew -Path $packageAuditPath -Content (($audit | ConvertTo-Json -Depth 6) + "`n")

Write-Output 'PHASE1B_PACKAGE_AUDIT=PASS'
Write-Output "zip_path=$zipPath"
Write-Output "size_bytes=$($zipItem.Length)"
Write-Output "sha256=$zipHash"
Write-Output "entries=$($expectedEntries.Count)"
Write-Output "manifest_entries=$($manifestRecords.Count)"
