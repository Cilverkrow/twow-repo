param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$parent = Split-Path -Parent $root
$zipPath = Join-Path $parent 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1-20260831-005014.zip'
$outerAuditPath = "$zipPath.audit.json"
$manifestPath = Join-Path $root 'SHA256SUMS.txt'
$internalAuditPath = Join-Path $root 'PACKAGE-INTERNAL-AUDIT.json'

function Write-Utf8([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

foreach ($old in @($manifestPath,$internalAuditPath,$zipPath,$outerAuditPath)) {
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
}

$preAuditFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File)
$expectedEntries = $preAuditFiles.Count + 2
$internalAudit = [ordered]@{
    task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1'
    package_root=(Split-Path -Leaf $root)
    expected_entry_count=$expectedEntries
    manifest='SHA256SUMS.txt'
    manifest_policy='SHA-256 over every regular package file except SHA256SUMS.txt itself; UTF-8 paths use forward slashes.'
    path_policy='Relative paths only; no rooted path, parent traversal, duplicate or backslash ZIP entry.'
}
Write-Utf8 $internalAuditPath (($internalAudit | ConvertTo-Json -Depth 5) + "`n")

$manifestLines = [Collections.Generic.List[string]]::new()
$payloadFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -cne $manifestPath } | Sort-Object FullName)
foreach ($file in $payloadFiles) {
    $relative = [IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)' -or $relative.Contains('\')) { throw "Unsafe package path: $relative" }
    $manifestLines.Add("$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)  $relative")
}
Write-Utf8 $manifestPath (($manifestLines -join "`n") + "`n")

Add-Type -AssemblyName System.IO.Compression
$archiveStream = [IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $archive = [IO.Compression.ZipArchive]::new($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$true,[Text.Encoding]::UTF8)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
            $relative = [IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
            $entry = $archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]$file.LastWriteTime
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $archiveStream.Dispose() }

$read = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($read.Entries)
    $names = @($entries | ForEach-Object { $_.FullName })
    $duplicates = @($names | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object Name)
    $unsafe = @($names | Where-Object { [IO.Path]::IsPathRooted($_) -or $_ -match '(^|/)\.\.(/|$)' -or $_.Contains('\') })
    if ($entries.Count -ne $expectedEntries) { throw "ZIP entry count mismatch: $($entries.Count) != $expectedEntries" }
    if ($duplicates.Count -ne 0 -or $unsafe.Count -ne 0) { throw 'ZIP path audit failed' }
} finally { $read.Dispose() }

$zipItem = Get-Item -LiteralPath $zipPath
$outerAudit = [ordered]@{
    task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1'
    created_utc=[DateTime]::UtcNow.ToString('o')
    zip_path=$zipPath
    bytes=[int64]$zipItem.Length
    entry_count=$expectedEntries
    sha256=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    duplicate_entries=0
    unsafe_entries=0
    manifest_entries=$manifestLines.Count
    result='PASS'
}
Write-Utf8 $outerAuditPath (($outerAudit | ConvertTo-Json -Depth 5) + "`n")
$outerAudit | ConvertTo-Json -Depth 5
