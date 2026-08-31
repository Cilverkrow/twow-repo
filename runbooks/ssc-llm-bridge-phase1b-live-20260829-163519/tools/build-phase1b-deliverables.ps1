$ErrorActionPreference = 'Stop'

$artifactDirectory = Split-Path -Parent $PSScriptRoot
$artifactName = Split-Path -Leaf $artifactDirectory
$expectedArtifactName = 'ssc-llm-bridge-phase1b-live-20260829-163519'
if ($artifactName -cne $expectedArtifactName) {
    throw "Unexpected artifact directory name: $artifactName"
}

$zipPath = Join-Path $artifactDirectory "$artifactName-deliverables.zip"
$manifestPath = Join-Path $artifactDirectory 'phase1b-sha256-manifest.txt'
$entryListPath = Join-Path $artifactDirectory 'phase1b-package-entry-list.txt'
$packageEvidencePath = Join-Path $artifactDirectory 'evidence\phase1b-package-evidence.json'
$packageAuditPath = Join-Path $artifactDirectory 'evidence\phase1b-package-audit.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixedTimestamp = [DateTimeOffset]::Parse('2026-08-29T00:00:00Z')

foreach ($target in @($zipPath, $manifestPath, $entryListPath, $packageEvidencePath, $packageAuditPath)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite existing Phase-1B package artifact: $target"
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

function Get-RelativePath([System.IO.FileInfo]$File) {
    return [System.IO.Path]::GetRelativePath($artifactDirectory, $File.FullName).Replace('\', '/')
}

function Test-IsExcluded([System.IO.FileInfo]$File) {
    return (
        $File.FullName -eq $zipPath -or
        $File.FullName -eq $packageEvidencePath -or
        $File.FullName -eq $packageAuditPath
    )
}

function Get-PayloadFiles {
    return @(
        Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
            Where-Object { -not (Test-IsExcluded $_) } |
            Sort-Object { Get-RelativePath $_ }
    )
}

$initialFiles = @(
    Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
        Where-Object {
            -not (Test-IsExcluded $_) -and
            $_.FullName -ne $manifestPath -and
            $_.FullName -ne $entryListPath
        } |
        Sort-Object { Get-RelativePath $_ }
)

foreach ($file in $initialFiles) {
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to package reparse-point file: $($file.FullName)"
    }
}

$expectedEntries = @(
    $initialFiles | ForEach-Object { Get-RelativePath $_ }
    'phase1b-package-entry-list.txt'
    'phase1b-sha256-manifest.txt'
) | Sort-Object

if (($expectedEntries | Select-Object -Unique).Count -ne $expectedEntries.Count) {
    throw 'Duplicate normalized Phase-1B package entry detected.'
}
foreach ($relativePath in $expectedEntries) {
    Assert-SafeRelativeEntry $relativePath
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
    throw "Required Phase-1B evidence is missing: $($missingRequiredEntries -join ', ')"
}

Write-Utf8CreateNew -Path $entryListPath -Content (($expectedEntries -join "`n") + "`n")

$manifestFiles = Get-PayloadFiles | Where-Object { $_.FullName -ne $manifestPath }
$manifestLines = foreach ($file in $manifestFiles) {
    $relativePath = Get-RelativePath $file
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$hash *$relativePath"
}
Write-Utf8CreateNew -Path $manifestPath -Content (($manifestLines -join "`n") + "`n")

$payloadFiles = Get-PayloadFiles
$actualEntries = @($payloadFiles | ForEach-Object { Get-RelativePath $_ })
if (($actualEntries -join "`n") -cne ($expectedEntries -join "`n")) {
    throw 'Payload entry list changed while constructing the Phase-1B deliverable.'
}

Add-Type -AssemblyName System.IO.Compression
$zipStream = [System.IO.FileStream]::new(
    $zipPath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $zipStream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $true
    )
    try {
        foreach ($file in $payloadFiles) {
            $relativePath = Get-RelativePath $file
            $entry = $archive.CreateEntry(
                $relativePath,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = $fixedTimestamp
            $sourceStream = [System.IO.File]::OpenRead($file.FullName)
            $entryStream = $entry.Open()
            try {
                $sourceStream.CopyTo($entryStream)
            } finally {
                $entryStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $zipStream.Dispose()
}

$zipItem = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$packageEvidence = [ordered]@{
    schema_version = 1
    result = 'CREATED_PENDING_INDEPENDENT_AUDIT'
    artifact_name = $artifactName
    zip_path = $zipPath
    size_bytes = [int64]$zipItem.Length
    sha256 = $zipHash
    entry_count = $expectedEntries.Count
    fixed_entry_timestamp_utc = $fixedTimestamp.ToString('yyyy-MM-ddTHH:mm:ssZ')
    entry_list_path = 'phase1b-package-entry-list.txt'
    entry_list_sha256 = (Get-FileHash -LiteralPath $entryListPath -Algorithm SHA256).Hash
    manifest_path = 'phase1b-sha256-manifest.txt'
    manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    manifest_entry_count = $manifestLines.Count
    manifest_self_excluded = $true
    entries = $expectedEntries
    note = 'This metadata is external to the ZIP to avoid a circular archive digest. The separate package audit is also external.'
}
Write-Utf8CreateNew -Path $packageEvidencePath -Content (($packageEvidence | ConvertTo-Json -Depth 8) + "`n")

Write-Output 'PHASE1B_PACKAGE_BUILD=CREATED_PENDING_AUDIT'
Write-Output "zip_path=$zipPath"
Write-Output "size_bytes=$($zipItem.Length)"
Write-Output "sha256=$zipHash"
Write-Output "entries=$($expectedEntries.Count)"
