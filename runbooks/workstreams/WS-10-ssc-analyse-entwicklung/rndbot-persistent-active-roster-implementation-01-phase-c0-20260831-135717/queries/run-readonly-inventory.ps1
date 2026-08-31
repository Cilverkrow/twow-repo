param(
    [string]$ConfigPath = 'C:\TW\ComTW\server\mangosd.conf',
    [string]$ClientPath = 'C:\TW\ComTW\DB\bin\mariadb.exe',
    [string]$QueryPath = (Join-Path $PSScriptRoot 'READONLY-ROSTER-INVENTORY.sql'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence'),
    [string]$EvidenceStem = 'DB-READONLY-INVENTORY-ATTEMPT-2'
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Read-DatabaseInfo([string]$Key) {
    $match = Select-String -LiteralPath $ConfigPath -Pattern ('^\s*' + [regex]::Escape($Key) + '\s*=') | Select-Object -First 1
    if (!$match) { throw "Missing config key: $Key" }
    $value = ($match.Line -split '=', 2)[1].Trim().Trim('"')
    $parts = $value.Split(';')
    if ($parts.Count -ne 5) { throw "Unexpected database-info field count for $Key" }
    return [pscustomobject]@{ Host=$parts[0]; Port=$parts[1]; User=$parts[2]; Password=$parts[3]; Schema=$parts[4] }
}

if (@(Get-Process -Name mangosd -ErrorAction SilentlyContinue).Count -ne 0) { throw 'mangosd must be stopped' }
if (@(Get-Process -Name realmd -ErrorAction SilentlyContinue).Count -ne 0) { throw 'realmd must be stopped' }
if (!(Test-Path -LiteralPath $ClientPath -PathType Leaf)) { throw 'MariaDB client missing' }
if (!(Test-Path -LiteralPath $QueryPath -PathType Leaf)) { throw 'query file missing' }

$listenerLines = @(netstat -ano -p tcp | Select-String ':3307\s')
if ($listenerLines.Count -ne 1 -or $listenerLines[0].Line -notmatch '^\s*TCP\s+127\.0\.0\.1:3307\s+0\.0\.0\.0:0\s+\S+\s+(\d+)\s*$') {
    throw 'expected exactly one TCP listener on 127.0.0.1:3307'
}
$listenerPid = [int]$Matches[1]
$listenerProcess = Get-Process -Id $listenerPid -ErrorAction Stop
if ($listenerProcess.ProcessName -notin @('mysqld', 'mariadbd')) { throw '3307 owner is not MariaDB' }

$queryText = [IO.File]::ReadAllText($QueryPath, $utf8)
$forbidden = [regex]::Matches($queryText, '(?im)^\s*(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|REPLACE|TRUNCATE|CALL|SET|START|COMMIT|ROLLBACK|GRANT|REVOKE)\b')
if ($forbidden.Count -ne 0) { throw 'query file contains a non-SELECT statement' }

$character = Read-DatabaseInfo 'CharacterDatabase.Info'
$login = Read-DatabaseInfo 'LoginDatabase.Info'
if ($character.Host -ne '127.0.0.1' -or $character.Port -ne '3307' -or $character.Schema -ne 'tw_char') { throw 'unexpected Character DB endpoint/schema' }
if ($login.Host -ne '127.0.0.1' -or $login.Port -ne '3307' -or $login.Schema -ne 'tw_logon') { throw 'unexpected Login DB endpoint/schema' }

$stdoutPath = Join-Path $EvidenceDirectory ($EvidenceStem + '.raw.tsv')
$stderrPath = Join-Path $EvidenceDirectory ($EvidenceStem + '.stderr.txt')
$runPath = Join-Path $EvidenceDirectory ($EvidenceStem + '-RUN.txt')
foreach ($path in @($stdoutPath, $stderrPath, $runPath)) {
    if (Test-Path -LiteralPath $path) { throw "refusing to overwrite evidence: $path" }
}

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $ClientPath
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8
$credentialPath = Join-Path $PSScriptRoot ('.c0-db-client-' + [Guid]::NewGuid().ToString('N') + '.cnf')
$escapedUser = $character.User.Replace('\', '\\').Replace('"', '\"')
$escapedPassword = $character.Password.Replace('\', '\\').Replace('"', '\"')
$credentialText = "[client]`nuser=`"$escapedUser`"`npassword=`"$escapedPassword`"`nhost=127.0.0.1`nport=3307`nprotocol=tcp`nssl=0`n"
[IO.File]::WriteAllText($credentialPath, $credentialText, $utf8)
try {
    $identitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($identitySid)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identitySid, 'FullControl', 'Allow'))
    Set-Acl -LiteralPath $credentialPath -AclObject $acl
} catch {
    Remove-Item -LiteralPath $credentialPath -Force -ErrorAction SilentlyContinue
    throw 'could not restrict temporary client credential file'
}
foreach ($argument in @(
    ('--defaults-extra-file=' + $credentialPath),
    '--skip-ssl', ('--database=' + $character.Schema),
    '--default-character-set=utf8mb4', '--batch', '--raw', '--column-names',
    '--skip-auto-rehash', '--init-command=SET SESSION TRANSACTION READ ONLY',
    ('--execute=source ' + $QueryPath.Replace('\', '/'))
)) { $psi.ArgumentList.Add($argument) }

$startedUtc = [DateTime]::UtcNow
$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
try {
    if (!$process.Start()) { throw 'failed to start MariaDB client' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
} finally {
    $process.Dispose()
    $character.Password = $null
    $escapedPassword = $null
    $credentialText = $null
    if (Test-Path -LiteralPath $credentialPath) { Remove-Item -LiteralPath $credentialPath -Force }
}
$finishedUtc = [DateTime]::UtcNow

[IO.File]::WriteAllText($stdoutPath, $stdout, $utf8)
[IO.File]::WriteAllText($stderrPath, $stderr, $utf8)
$stdoutHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stdoutPath).Hash
$stderrHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stderrPath).Hash
$queryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $QueryPath).Hash
$run = @(
    'TASK_ID=RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-C0',
    ('STARTED_UTC=' + $startedUtc.ToString('o')),
    ('FINISHED_UTC=' + $finishedUtc.ToString('o')),
    ('LISTENER_PID=' + $listenerPid),
    ('LISTENER_PROCESS=' + $listenerProcess.ProcessName),
    'ENDPOINT=127.0.0.1:3307',
    'CHARACTER_SCHEMA=tw_char',
    'LOGIN_SCHEMA=tw_logon',
    ('QUERY_SHA256=' + $queryHash),
    'QUERY_MUTATING_STATEMENT_COUNT=0',
    'SESSION_TRANSACTION_MODE=READ_ONLY',
    'PASSWORD_TRANSPORT=TEMPORARY_ACL_RESTRICTED_DEFAULTS_FILE_NOT_COMMAND_LINE',
    'TEMPORARY_CREDENTIAL_FILE_REMOVED=YES',
    'TLS=DISABLED_FOR_LOOPBACK_ONLY',
    ('EXIT_CODE=' + $exitCode),
    ('STDOUT_BYTES=' + ([IO.FileInfo]$stdoutPath).Length),
    ('STDOUT_SHA256=' + $stdoutHash),
    ('STDERR_BYTES=' + ([IO.FileInfo]$stderrPath).Length),
    ('STDERR_SHA256=' + $stderrHash),
    'DATABASE_CHANGED=NO'
) -join "`n"
[IO.File]::WriteAllText($runPath, $run + "`n", $utf8)

if ($exitCode -ne 0) { throw "MariaDB client failed with exit code $exitCode" }
Write-Output $run
