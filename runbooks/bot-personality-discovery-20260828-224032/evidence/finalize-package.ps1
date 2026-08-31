param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false, $true)
$Root = 'C:\TW\ComTW'
$EvidenceDirectory = Join-Path $OutputDirectory 'evidence'
$ZipPath = $OutputDirectory + '.zip'
$Base64Path = $ZipPath + '.base64.txt'
$ChunkMetadataPath = $ZipPath + '.base64-chunks.tsv'

function Write-Utf8Lf {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n","`n").Replace("`r","`n"), $Utf8NoBom)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-Tsv {
    param([string]$Path, [string[]]$Columns, [object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($Columns -join "`t"))
    foreach ($row in $Rows) {
        $values = foreach ($column in $Columns) { if ($null -eq $row.$column) { '' } else { [string]$row.$column } }
        $lines.Add(($values -join "`t"))
    }
    Write-Utf8Lf -Path $Path -Text (($lines -join "`n") + "`n")
}

function Get-PortListeners {
    param([int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

foreach ($name in @('mysqld','mariadbd','mangosd','realmd')) {
    if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -ne 0) { throw "Server process is active: $name" }
}
if (@(Get-PortListeners -Port 3307).Count -ne 0 -or @(Get-PortListeners -Port 8090).Count -ne 0) { throw 'A prohibited server port is listening.' }

$runtimeFiles = @(
    [pscustomobject]@{ key='DatabaseLauncher'; path=(Join-Path $Root 'DB\start-database.bat'); expected='C0EEC81CE8797DDE77685D5639E90AD36892EE473CAD01F8558B6A8C6237336A' },
    [pscustomobject]@{ key='MyIni'; path=(Join-Path $Root 'DB\data\my.ini'); expected='7039B21A8D50E85511EDF7D5BC2ECD501830AD151D9EF0331243B43ADA4BA9B8' },
    [pscustomobject]@{ key='MariaDbServer'; path=(Join-Path $Root 'DB\bin\mysqld.exe'); expected='FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7' },
    [pscustomobject]@{ key='MariaDbClient'; path=(Join-Path $Root 'DB\bin\mariadb.exe'); expected='9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95' },
    [pscustomobject]@{ key='MariaDbDump'; path=(Join-Path $Root 'DB\bin\mariadb-dump.exe'); expected='FD6E467EAA49F166E355A5660952E2488ABB2BE80CB90B2DB229DF7253D24EDB' },
    [pscustomobject]@{ key='MariaDbAdmin'; path=(Join-Path $Root 'DB\bin\mariadb-admin.exe'); expected='1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E' }
)
$runtimeRows = New-Object System.Collections.Generic.List[object]
foreach ($runtime in $runtimeFiles) {
    $item = Get-Item -LiteralPath $runtime.path
    $actual = Get-Sha256 -Path $runtime.path
    if ($actual -cne $runtime.expected) { throw "Runtime hash mismatch for $($runtime.key): $actual" }
    $runtimeRows.Add([pscustomobject]@{ key=$runtime.key; path=$runtime.path; bytes=$item.Length; sha256=$actual; status='verified' })
}
Write-Tsv -Path (Join-Path $EvidenceDirectory 'database-runtime-hashes.tsv') -Columns @('key','path','bytes','sha256','status') -Rows ([object[]]$runtimeRows)

foreach ($name in @('result-row-counts.tsv','database-engine-runtime-changes.tsv','reviewed-function-imports.tsv')) {
    $path = Join-Path $EvidenceDirectory $name
    $text = [IO.File]::ReadAllText($path)
    $normalized = $text.Replace('\t', "`t")
    Write-Utf8Lf -Path $path -Text $normalized
}

$rootEntries = @(
    'bot-personality-discovery-report.md',
    'bot-personality-mapping-v1.json',
    'bot-populations.tsv',
    'race-summary.tsv',
    'class-summary.tsv',
    'race-class-combinations.tsv',
    'profession-summary.tsv',
    'bot-professions.tsv',
    'unmapped-skills.tsv',
    'mapping-provenance.tsv'
)
$evidenceEntries = @(
    'evidence/read-only-sql-transcript.txt',
    'evidence/sql-write-capability-audit.json',
    'evidence/schema-definitions.txt',
    'evidence/authoritative-assets.tsv',
    'evidence/database-runtime-hashes.tsv',
    'evidence/result-row-counts.tsv',
    'evidence/query-result-hashes.tsv',
    'evidence/database-engine-runtime-changes.tsv',
    'evidence/database-harness-result.json',
    'evidence/database-harness-console.txt',
    'evidence/reviewed-function-imports.tsv',
    'evidence/source-excerpts.txt',
    'evidence/config-evidence.txt',
    'evidence/validation-result.json'
)
$baseEntries = @($rootEntries + $evidenceEntries)
foreach ($entry in $baseEntries) {
    if (-not (Test-Path -LiteralPath (Join-Path $OutputDirectory $entry) -PathType Leaf)) { throw "Package entry is missing: $entry" }
}

$mapping = Get-Content -LiteralPath (Join-Path $OutputDirectory 'bot-personality-mapping-v1.json') -Raw | ConvertFrom-Json -Depth 20
$botTsvCount = @(Get-Content -LiteralPath (Join-Path $OutputDirectory 'bot-professions.tsv')).Count - 1
if (@($mapping.bots).Count -ne 4500 -or $botTsvCount -ne 4500) { throw 'Final bot count validation failed.' }
if (@($mapping.races).Count -ne 10 -or @($mapping.classes).Count -ne 9 -or @($mapping.professions).Count -ne 14) { throw 'Final mapping namespace count validation failed.' }
if (@($mapping.race_variants).Count -ne 0) { throw 'An unproven race variant was emitted.' }
if (@($mapping.bots | Where-Object { @($_.professions).Count -ne 0 }).Count -ne 0) { throw 'Unexpected learned profession data was emitted.' }
if (@($mapping.bots | Group-Object population_key,bot_guid | Where-Object { $_.Count -ne 1 }).Count -ne 0) { throw 'Duplicate population/GUID rows were emitted.' }

$sqlAudit = Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'sql-write-capability-audit.json') -Raw | ConvertFrom-Json
if ([int]$sqlAudit.statement_count -ne 15 -or [int]$sqlAudit.write_capable_statement_count -ne 0) { throw 'SQL audit validation failed.' }
$harnessResult = Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'database-harness-result.json') -Raw | ConvertFrom-Json
if ($harnessResult.status -cne 'completed' -or [int]$harnessResult.logical_database_writes -ne 0) { throw 'Database capture result validation failed.' }

$forbiddenPattern = '(?i)\b(account_id|account_name|character_name|password_hash|password|session_key|sessionkey|last_ip|last_attempt_ip|email_address|email)\b'
foreach ($entry in $baseEntries) {
    $path = Join-Path $OutputDirectory $entry
    $extension = [IO.Path]::GetExtension($path)
    if ($extension -in @('.md','.json','.tsv','.txt')) {
        $text = [IO.File]::ReadAllText($path)
        if ($text -match $forbiddenPattern) { throw "Sanitization scan failed for ${entry}: $($Matches[0])" }
    }
}

$entryListPath = Join-Path $OutputDirectory 'package-entry-list.txt'
$manifestPath = Join-Path $OutputDirectory 'sha256-manifest.txt'
$allEntries = @($baseEntries + 'package-entry-list.txt' + 'sha256-manifest.txt')
Write-Utf8Lf -Path $entryListPath -Text (($allEntries -join "`n") + "`n")

$manifestLines = New-Object System.Collections.Generic.List[string]
foreach ($entry in @($allEntries | Where-Object { $_ -cne 'sha256-manifest.txt' } | Sort-Object)) {
    $manifestLines.Add(('{0}  {1}' -f (Get-Sha256 -Path (Join-Path $OutputDirectory $entry)), $entry.Replace('\','/')))
}
Write-Utf8Lf -Path $manifestPath -Text (($manifestLines -join "`n") + "`n")

if (Test-Path -LiteralPath $ZipPath) { throw "ZIP already exists: $ZipPath" }
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($entryName in $allEntries) {
            $sourcePath = Join-Path $OutputDirectory $entryName
            $entry = $archive.CreateEntry($entryName.Replace('\','/'), [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset](Get-Item -LiteralPath $sourcePath).LastWriteTime
            $input = [IO.File]::OpenRead($sourcePath)
            $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
finally { $stream.Dispose() }

$zipBytes = [IO.File]::ReadAllBytes($ZipPath)
$base64 = [Convert]::ToBase64String($zipBytes)
Write-Utf8Lf -Path $Base64Path -Text ($base64 + "`n")
$chunkLines = New-Object System.Collections.Generic.List[string]
$chunkRows = New-Object System.Collections.Generic.List[object]
$chunkCount = [int][Math]::Ceiling($base64.Length / 4000.0)
for ($index = 0; $index -lt $chunkCount; $index++) {
    $start = $index * 4000
    $length = [Math]::Min(4000, $base64.Length - $start)
    $chunk = $base64.Substring($start, $length)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $chunkHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($chunk)))).Replace('-','') } finally { $sha.Dispose() }
    $number = $index + 1
    $chunkLines.Add("ZIP_BASE64_CHUNK_${number}_OF_${chunkCount}_BEGIN")
    $chunkLines.Add($chunk)
    $chunkLines.Add("ZIP_BASE64_CHUNK_${number}_OF_${chunkCount}_END")
    $chunkRows.Add([pscustomobject]@{ chunk_number=$number; total_chunks=$chunkCount; length=$length; sha256=$chunkHash })
}
Write-Utf8Lf -Path ($Base64Path + '.chunks.txt') -Text (($chunkLines -join "`n") + "`n")
Write-Tsv -Path $ChunkMetadataPath -Columns @('chunk_number','total_chunks','length','sha256') -Rows ([object[]]$chunkRows)

foreach ($name in @('mysqld','mariadbd','mangosd','realmd')) {
    if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -ne 0) { throw "Final server process is active: $name" }
}
if (@(Get-PortListeners -Port 3307).Count -ne 0 -or @(Get-PortListeners -Port 8090).Count -ne 0) { throw 'A final server port is listening.' }

Write-Output 'PACKAGE_FINALIZATION=PASSED'
Write-Output "ZIP_PATH=$ZipPath"
Write-Output "ZIP_BYTES=$($zipBytes.Length)"
Write-Output "ZIP_SHA256=$(Get-Sha256 -Path $ZipPath)"
Write-Output "ZIP_ENTRIES=$($allEntries.Count)"
Write-Output "BASE64_LENGTH=$($base64.Length)"
Write-Output "BASE64_CHUNKS=$chunkCount"
