$ErrorActionPreference = 'Stop'
$artifactDirectory = Split-Path -Parent $PSScriptRoot
$artifactName = Split-Path -Leaf $artifactDirectory
$zipName = "$artifactName-deliverables.zip"
$zipPath = Join-Path $artifactDirectory $zipName
$manifestPath = Join-Path $artifactDirectory 'sha256-manifest.txt'
$entryListPath = Join-Path $artifactDirectory 'package-entry-list.txt'
$packageEvidencePath = Join-Path $artifactDirectory 'evidence\package-evidence.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($target in @($zipPath, $manifestPath, $entryListPath, $packageEvidencePath)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite existing deliverable file: $target"
    }
}

function Get-RelativePayloadFiles {
    return @(
        Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
            Where-Object {
                $_.FullName -ne $zipPath -and
                $_.FullName -ne $packageEvidencePath
            } |
            Sort-Object FullName
    )
}

$initialFiles = @(
    Get-ChildItem -LiteralPath $artifactDirectory -Recurse -File |
        Where-Object {
            $_.FullName -ne $zipPath -and
            $_.FullName -ne $manifestPath -and
            $_.FullName -ne $entryListPath -and
            $_.FullName -ne $packageEvidencePath
        }
)
$expectedEntries = @(
    $initialFiles | ForEach-Object { [System.IO.Path]::GetRelativePath($artifactDirectory, $_.FullName).Replace('\', '/') }
    'package-entry-list.txt'
    'sha256-manifest.txt'
) | Sort-Object
[System.IO.File]::WriteAllText($entryListPath, ($expectedEntries -join "`n") + "`n", $utf8NoBom)

$manifestFiles = Get-RelativePayloadFiles | Where-Object { $_.FullName -ne $manifestPath }
$manifestLines = foreach ($file in $manifestFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($artifactDirectory, $file.FullName).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    "$hash *$relativePath"
}
[System.IO.File]::WriteAllText($manifestPath, ($manifestLines -join "`n") + "`n", $utf8NoBom)

$payloadFiles = Get-RelativePayloadFiles
$actualEntries = @($payloadFiles | ForEach-Object { [System.IO.Path]::GetRelativePath($artifactDirectory, $_.FullName).Replace('\', '/') })
if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
    throw 'Payload entry list changed while constructing the deliverable.'
}

Add-Type -AssemblyName System.IO.Compression
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $payloadFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($artifactDirectory, $file.FullName).Replace('\', '/')
        $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::Parse('2026-08-29T00:00:00Z')
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

$zipItem = Get-Item -LiteralPath $zipPath
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$packageEvidence = [ordered]@{
    schema_version = 1
    zip_path = $zipPath
    size_bytes = [int64]$zipItem.Length
    sha256 = $zipHash
    entry_count = $expectedEntries.Count
    entries = $expectedEntries
    note = 'package-evidence.json is external metadata and is intentionally not inside the ZIP.'
}
[System.IO.File]::WriteAllText(
    $packageEvidencePath,
    ($packageEvidence | ConvertTo-Json -Depth 8) + "`n",
    $utf8NoBom
)

Write-Output $zipPath
Write-Output "size_bytes=$($zipItem.Length)"
Write-Output "sha256=$zipHash"
Write-Output "entries=$($expectedEntries.Count)"
