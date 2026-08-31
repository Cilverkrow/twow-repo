[CmdletBinding()]
param([string]$OutputTag = 'after-user-start')

$ErrorActionPreference = 'Stop'
$RunRoot = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02-20260829-204358'
$Evidence = Join-Path $RunRoot 'evidence'
$SqlPath = Join-Path $Evidence 'prepared-selects.sql'
$ConfigPath = 'C:\TW\ComTW\server\mangosd.conf'
$ClientPath = 'C:\TW\ComTW\DB\bin\mariadb.exe'
$StdoutPath = Join-Path $Evidence ("live-schema-selects-$OutputTag.stdout.txt")
$StderrPath = Join-Path $Evidence ("live-schema-selects-$OutputTag.stderr.txt")
$MetadataPath = Join-Path $Evidence ("live-schema-selects-$OutputTag.metadata.json")

foreach ($path in @($StdoutPath, $StderrPath, $MetadataPath)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite: $path" }
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

$sql = [IO.File]::ReadAllText($SqlPath)
$statements = @($sql -split "`r?`n" | Where-Object { $_.Trim() })
if ($statements.Count -ne 7) { throw "Expected seven statements, got $($statements.Count)" }
foreach ($statement in $statements) {
    if ($statement.TrimStart() -notmatch '^SELECT\s') { throw 'Non-SELECT statement rejected' }
}

$descriptor = (Get-ConfigValue $ConfigPath 'LoginDatabase.Info') -split ';'
if ($descriptor.Count -lt 5) { throw 'Invalid LoginDatabase.Info descriptor' }

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $ClientPath
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
foreach ($arg in @(
    '--no-defaults', '--protocol=TCP', '--skip-ssl', '--connect-timeout=3', '--batch', '--raw', '--skip-column-names',
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

[IO.File]::WriteAllText($StdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($StderrPath, $stderr, [Text.UTF8Encoding]::new($false))
$metadata = [ordered]@{
    task = 'SSC-SOURCE-BASELINE-02'
    continuation = 'after explicit user confirmation that MariaDB is running'
    statement_count = $statements.Count
    statement_class = 'SELECT only'
    transport = 'TCP loopback with TLS disabled after the preceding Windows TLS credential handshake failed before SQL execution'
    prepared_sql_path = $SqlPath
    prepared_sql_sha256 = (Get-FileHash -LiteralPath $SqlPath -Algorithm SHA256).Hash
    prepared_sql_matches_initial_attempt = ((Get-Content -Raw -LiteralPath (Join-Path $Evidence 'live-schema-selects.metadata.json') | ConvertFrom-Json).prepared_sql_sha256 -eq (Get-FileHash -LiteralPath $SqlPath -Algorithm SHA256).Hash)
    target = [ordered]@{ host = $descriptor[0]; port = $descriptor[1]; login_schema = $descriptor[4]; username = '<redacted>'; password = '<redacted>' }
    started_utc = $startedUtc.ToString('o')
    finished_utc = $finishedUtc.ToString('o')
    exit_code = $process.ExitCode
    stdout_size_bytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
    stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stdout)))
    stderr_size_bytes = [Text.Encoding]::UTF8.GetByteCount($stderr)
    credentials_emitted = $false
    database_writes = @()
}
[IO.File]::WriteAllText($MetadataPath, ($metadata | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
$metadata | ConvertTo-Json -Depth 5
if ($process.ExitCode -ne 0) { exit $process.ExitCode }
