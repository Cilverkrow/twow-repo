$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$runbook = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source'
$isolation = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938'
$parent = Split-Path -Parent $runbook
$zip = Join-Path $parent 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2-20260831-131938.zip'
$audit = "$zip.audit.txt"
$inputZip = Join-Path $parent 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1-20260831-005014.zip'
$expectedInputHash = '89E36EFFEB1A53A138E1ABD065A263CCB6BDD7A10478AF91193639FC7242EE7F'
$contract = Join-Path $isolation 'input-b-r1\input-phase-b\IMPLEMENTATION-CONTRACT-ADDENDUM.md'
$expectedContractHash = '203855E99A7ED2D9B560769E703804CBE4C3AC2594B7C2BFEEED34236452294B'
$candidateExe = Join-Path $source 'bin\Release\mangosd.exe'
$candidatePdb = Join-Path $source 'bin\Release\mangosd.pdb'
$adapterExe = Join-Path $isolation 'build-adapter\adapter-bin\Release\persistent_active_roster_database_tests.exe'
$adapterPdb = Join-Path $isolation 'build-adapter\adapter-bin\Release\persistent_active_roster_database_tests.pdb'
$cmakeCache = Join-Path $isolation 'build-clean-final\CMakeCache.txt'

function Assert-Hash([string] $Path, [string] $Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actual -ne $Expected) { throw "Hash mismatch for $Path : $actual" }
}

Assert-Hash $inputZip $expectedInputHash
Assert-Hash $contract $expectedContractHash
Assert-Hash $candidateExe '965CBEA7EDA8CC28EAFD8E9DCEB58187B167563B2644699B23B0C9FD47967679'
Assert-Hash $candidatePdb '4E5EE6FF1C99012B9282F923249040B1885F43DAA599863338B2A64CB9DC0A80'
Assert-Hash $adapterExe '2C4729F1713CF8FCEE088C3978DBF99A7A231F340904797DC65ADE99F31144BF'

if (Test-Path -LiteralPath $zip) { throw "Output ZIP already exists: $zip" }
if (Test-Path -LiteralPath $audit) { throw "Output audit already exists: $audit" }

$copyRoots = @(
    (Join-Path $runbook 'source-copies'),
    (Join-Path $runbook 'input-contract'),
    (Join-Path $runbook 'artifacts')
)
foreach ($copyRoot in $copyRoots) {
    if (Test-Path -LiteralPath $copyRoot) { throw "Package staging path already exists: $copyRoot" }
    New-Item -ItemType Directory -Path $copyRoot | Out-Null
}

$matrix = Import-Csv -Delimiter "`t" -LiteralPath (Join-Path $runbook 'SOURCE-MATRIX.tsv')
foreach ($row in $matrix) {
    $relative = $row.path.Replace('/', '\')
    $from = Join-Path $source $relative
    Assert-Hash $from $row.sha256
    $to = Join-Path (Join-Path $runbook 'source-copies') $relative
    $toDirectory = Split-Path -Parent $to
    New-Item -ItemType Directory -Force -Path $toDirectory | Out-Null
    Copy-Item -LiteralPath $from -Destination $to
}

Copy-Item -LiteralPath $contract -Destination (Join-Path $runbook 'input-contract\IMPLEMENTATION-CONTRACT-ADDENDUM.md')
New-Item -ItemType Directory -Force -Path (Join-Path $runbook 'artifacts\candidate') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $runbook 'artifacts\test-adapter') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $runbook 'artifacts\build') | Out-Null
Copy-Item -LiteralPath $candidateExe -Destination (Join-Path $runbook 'artifacts\candidate\mangosd.exe')
Copy-Item -LiteralPath $candidatePdb -Destination (Join-Path $runbook 'artifacts\candidate\mangosd.pdb')
Copy-Item -LiteralPath $adapterExe -Destination (Join-Path $runbook 'artifacts\test-adapter\persistent_active_roster_database_tests.exe')
Copy-Item -LiteralPath $adapterPdb -Destination (Join-Path $runbook 'artifacts\test-adapter\persistent_active_roster_database_tests.pdb')
Copy-Item -LiteralPath $cmakeCache -Destination (Join-Path $runbook 'artifacts\build\CMakeCache.txt')

$manifestPath = Join-Path $runbook 'SHA256SUMS.txt'
$files = @(Get-ChildItem -LiteralPath $runbook -Recurse -File | Where-Object { $_.FullName -ne $manifestPath } | Sort-Object FullName)
$manifestLines = foreach ($file in $files) {
    $relative = $file.FullName.Substring($runbook.Length + 1).Replace('\','/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
    "$hash`t$relative"
}
$manifestLines | Set-Content -LiteralPath $manifestPath -Encoding utf8
$manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash

[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $runbook,
    $zip,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

$zipItem = Get-Item -LiteralPath $zip
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $names = @{}
    foreach ($entry in $entries) {
        $name = $entry.FullName.Replace('\','/')
        if ($name.StartsWith('/') -or $name -match '(^|/)\.\.(/|$)' -or $name.Contains(':')) { throw "Unsafe ZIP entry: $name" }
        if ($names.ContainsKey($name)) { throw "Duplicate ZIP entry: $name" }
        $names[$name] = $entry
    }
    if ($entries.Count -ne ($manifestLines.Count + 1)) { throw "ZIP entry count mismatch: $($entries.Count)" }

    $verified = 0
    foreach ($line in $manifestLines) {
        $parts = $line -split "`t", 2
        $expected = $parts[0]
        $name = $parts[1]
        if (-not $names.ContainsKey($name)) { throw "Manifest entry absent from ZIP: $name" }
        $stream = $names[$name].Open()
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
            finally { $sha.Dispose() }
        }
        finally { $stream.Dispose() }
        if ($actual -ne $expected) { throw "ZIP payload hash mismatch: $name" }
        ++$verified
    }
}
finally {
    $archive.Dispose()
}

$auditLines = @(
    'TASK_ID=RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2',
    'ZIP_AUDIT=PASS',
    "ZIP_PATH=$zip",
    "ZIP_SIZE_BYTES=$($zipItem.Length)",
    "ZIP_ENTRY_COUNT=$($entries.Count)",
    "ZIP_SHA256=$zipHash",
    "ROOT_MANIFEST_SHA256=$manifestHash",
    "ROOT_MANIFEST_ENTRY_COUNT=$($manifestLines.Count)",
    "ROOT_MANIFEST_VERIFIED_ENTRIES=$verified",
    "INPUT_B_R1_ZIP_SHA256=$expectedInputHash",
    'PATH_SAFETY=PASS',
    'DUPLICATE_ENTRIES=0',
    'PHASE_C_GATE=AWAIT_B_R2_PACKAGE_AUDIT'
)
$auditLines | Set-Content -LiteralPath $audit -Encoding utf8

Write-Output 'ZIP_AUDIT=PASS'
Write-Output "ZIP_SIZE_BYTES=$($zipItem.Length)"
Write-Output "ZIP_ENTRY_COUNT=$($entries.Count)"
Write-Output "ZIP_SHA256=$zipHash"
Write-Output "ROOT_MANIFEST_SHA256=$manifestHash"
