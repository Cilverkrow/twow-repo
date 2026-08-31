$ErrorActionPreference = 'Stop'
$phase1bDirectory = Split-Path -Parent $PSScriptRoot
$bridgeDirectory = Join-Path $phase1bDirectory 'bridge'
$evidencePath = Join-Path $phase1bDirectory 'evidence\extracted-payload-verification.json'
$manifestPath = Join-Path $bridgeDirectory 'sha256-manifest.txt'
$entryListPath = Join-Path $bridgeDirectory 'package-entry-list.txt'
$expectedManifestSha256 = '7494F26C2CBA47084691D57ED7DEA372B5E895C90F58FF86304101B48305FA8E'

if (Test-Path -LiteralPath $evidencePath) {
    throw "Refusing to overwrite: $evidencePath"
}
$actualFiles = @(Get-ChildItem -LiteralPath $bridgeDirectory -Recurse -File)
$actualEntries = @(
    $actualFiles |
        ForEach-Object { [System.IO.Path]::GetRelativePath($bridgeDirectory, $_.FullName).Replace('\', '/') } |
        Sort-Object
)
$expectedEntries = @(Get-Content -LiteralPath $entryListPath | Where-Object { $_ -ne '' } | Sort-Object)
if ($actualFiles.Count -ne 50 -or ($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
    throw 'Extracted payload file count or entry set differs from package-entry-list.txt.'
}

$manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
if ($manifestSha256 -ne $expectedManifestSha256) {
    throw 'Extracted manifest hash differs from the reviewed manifest hash.'
}

$hashFailures = [System.Collections.Generic.List[string]]::new()
$manifestEntries = 0
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') {
        throw "Invalid extracted manifest line: $line"
    }
    $manifestEntries += 1
    $expectedHash = $Matches[1]
    $relativePath = $Matches[2]
    $candidatePath = Join-Path $bridgeDirectory $relativePath
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        $hashFailures.Add("missing:$relativePath")
        continue
    }
    $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        $hashFailures.Add("hash:$relativePath")
    }
}
if ($manifestEntries -ne 49 -or $hashFailures.Count -ne 0) {
    throw "Extracted payload manifest verification failed: $($hashFailures -join ', ')"
}

$result = [ordered]@{
    schema_version = 1
    result = 'PHASE1B_EXTRACTED_PAYLOAD_VERIFICATION=PASS'
    verified_utc = [DateTime]::UtcNow.ToString('o')
    live_execution_started = $false
    bridge_directory = $bridgeDirectory
    file_count = $actualFiles.Count
    entry_list_matches = $true
    manifest_sha256 = $manifestSha256
    manifest_entries = $manifestEntries
    manifest_hash_failures = $hashFailures.Count
    instance_lock_present = Test-Path -LiteralPath (Join-Path $bridgeDirectory 'evidence\.phase1a-instance.lock')
}
[System.IO.File]::WriteAllText(
    $evidencePath,
    ($result | ConvertTo-Json -Depth 6) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Output $result.result
Write-Output "files=$($result.file_count) manifest_entries=$manifestEntries hash_failures=$($hashFailures.Count)"
Write-Output "instance_lock_present=$($result.instance_lock_present)"
