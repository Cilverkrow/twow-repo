[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352'
$manifest = Join-Path $root 'SHA256SUMS.txt'
$zip = 'C:\TW\ComTW\runbooks\SSC-OLLAMA-MANUAL-SCALING-01-PHASE1-20260829-210352.zip'
if (Test-Path -LiteralPath $manifest) { throw 'Refusing to overwrite manifest' }
if (Test-Path -LiteralPath $zip) { throw 'Refusing to overwrite ZIP' }
$files = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName
$lines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
[IO.File]::WriteAllLines($manifest, $lines, [Text.UTF8Encoding]::new($false))
Compress-Archive -LiteralPath $root -DestinationPath $zip -CompressionLevel Optimal
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try { $entryCount = $archive.Entries.Count } finally { $archive.Dispose() }
$item = Get-Item -LiteralPath $zip
[ordered]@{
    zip_path = $zip
    size_bytes = $item.Length
    entry_count = $entryCount
    sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    manifest_path = $manifest
    manifest_entries = $lines.Count
} | ConvertTo-Json
