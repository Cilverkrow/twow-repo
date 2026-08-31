[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RunRoot = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358'
$Evidence = Join-Path $RunRoot 'evidence'
$Baseline01Result = 'C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848\evidence\database-readonly-query-result.json'
$ConfigPath = 'C:\TW\ComTW\server\mangosd.conf'
$ClientPath = 'C:\TW\ComTW\DB\bin\mariadb.exe'

function Write-NewUtf8([string]$Path, [AllowEmptyString()][string]$Content) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite: $Path" }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Get-ConfigValue([string]$Path, [string]$Key) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#') -or $trim.StartsWith(';')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -gt 0 -and $trim.Substring(0, $idx).Trim() -eq $Key) {
            return $trim.Substring($idx + 1).Trim().Trim('"')
        }
    }
    throw "Missing config key: $Key"
}

$baseline = Get-Content -Raw -LiteralPath $Baseline01Result | ConvertFrom-Json
$statements = @($baseline.statements)
if ($statements.Count -ne 7) { throw "Expected seven prepared statements, got $($statements.Count)" }
foreach ($statement in $statements) {
    if ($statement.TrimStart() -notmatch '^SELECT\s') { throw "Non-SELECT statement rejected" }
}
$sql = ($statements -join "`n") + "`n"
Write-NewUtf8 (Join-Path $Evidence 'prepared-selects.sql') $sql

$descriptor = (Get-ConfigValue $ConfigPath 'LoginDatabase.Info') -split ';'
if ($descriptor.Count -lt 5) { throw 'Invalid LoginDatabase.Info descriptor' }

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $ClientPath
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($arg in @(
    '--no-defaults', '--protocol=TCP', '--connect-timeout=3', '--batch', '--raw', '--skip-column-names',
    ('--host=' + $descriptor[0]), ('--port=' + $descriptor[1]), ('--user=' + $descriptor[2]), ('--execute=' + $sql)
)) { [void]$psi.ArgumentList.Add($arg) }
$psi.Environment['MYSQL_PWD'] = $descriptor[3]

$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
$startedUtc = [DateTime]::UtcNow
[void]$process.Start()
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()
$finishedUtc = [DateTime]::UtcNow
$stderr = $stderr -replace [regex]::Escape($descriptor[3]), '<redacted>'

Write-NewUtf8 (Join-Path $Evidence 'live-schema-selects.stdout.txt') $stdout
Write-NewUtf8 (Join-Path $Evidence 'live-schema-selects.stderr.txt') $stderr
$metadata = [ordered]@{
    task = 'SSC-SOURCE-BASELINE-02'
    prepared_source = $Baseline01Result
    statement_count = $statements.Count
    statement_class = 'SELECT only'
    prepared_sql_sha256 = (Get-FileHash -LiteralPath (Join-Path $Evidence 'prepared-selects.sql') -Algorithm SHA256).Hash
    client = [ordered]@{
        path = $ClientPath
        sha256 = (Get-FileHash -LiteralPath $ClientPath -Algorithm SHA256).Hash
    }
    target = [ordered]@{ host = $descriptor[0]; port = $descriptor[1]; login_schema = $descriptor[4]; username = '<redacted>'; password = '<redacted>' }
    connect_timeout_seconds = 3
    started_utc = $startedUtc.ToString('o')
    finished_utc = $finishedUtc.ToString('o')
    exit_code = $process.ExitCode
    stdout_size_bytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
    stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stdout)))
    stderr_size_bytes = [Text.Encoding]::UTF8.GetByteCount($stderr)
    credentials_emitted = $false
    database_writes = @()
}
Write-NewUtf8 (Join-Path $Evidence 'live-schema-selects.metadata.json') (($metadata | ConvertTo-Json -Depth 6) + "`n")
$metadata | ConvertTo-Json -Depth 5
if ($process.ExitCode -ne 0) { exit $process.ExitCode }
