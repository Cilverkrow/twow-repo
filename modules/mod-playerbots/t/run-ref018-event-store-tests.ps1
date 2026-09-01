param(
    [Parameter(Mandatory = $true)][string]$MariaDbRoot,
    [Parameter(Mandatory = $true)][string]$TestExecutable,
    [Parameter(Mandatory = $true)][string]$AceRuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$MySqlRuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$MigrationFile,
    [Parameter(Mandatory = $true)][string]$DumpFile,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [Parameter(Mandatory = $true)][string]$DisposableRoot,
    [Parameter(Mandatory = $true)][string]$ForbiddenDataDirectory,
    [int]$Port = 33319
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ExpectedDumpBytes = 66426372L
$ExpectedDumpSha256 = '97E509C87B40CE44DCA0D0EF11CC665A4329DBF9070DAFD902EB952B22BADE22'
$ExpectedCopyRows = 178L
$ExpectedCopyHash = '9501380861D30849F034CF8910F79580601FE5DFFDCB938C50ED0BB69CE094B3'

function Resolve-ExistingFile([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (!(Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return $resolved
}

function Get-ListeningOwnerPids([int]$CheckedPort) {
    $pattern = '^\s*TCP\s+\S+:' + [regex]::Escape([string]$CheckedPort) + '\s+\S+\s+\S+\s+(\d+)\s*$'
    return @(& "$env:SystemRoot\System32\netstat.exe" -ano -p TCP | ForEach-Object {
        if ($_ -match $pattern) {
            $ownerPid = [int]$matches[1]
            if ($ownerPid -ne 0) {
                $ownerPid
            }
        }
    } | Sort-Object -Unique)
}

function Assert-PortClosed([int]$CheckedPort) {
    if (@(Get-ListeningOwnerPids $CheckedPort).Count -ne 0) {
        throw "TCP port is already listening: $CheckedPort"
    }
}

function Assert-NoServerProcess {
    $processes = @(Get-Process -Name mysqld, mariadbd, mangosd, realmd -ErrorAction SilentlyContinue)
    if ($processes.Count -ne 0) {
        $summary = ($processes | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ','
        throw "A server process already exists: $summary"
    }
}

function Quote-NativeArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-CapturedNative(
    [string]$File,
    [string[]]$Arguments,
    [string]$StdoutPath,
    [string]$StderrPath,
    [hashtable]$Environment = @{},
    [string]$InputFile = ''
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $File
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $InputFile.Length -ne 0
    $startInfo.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($InputFile.Length -ne 0) {
        $input = [IO.File]::OpenRead($InputFile)
        try {
            $input.CopyTo($process.StandardInput.BaseStream)
        }
        finally {
            $input.Dispose()
            $process.StandardInput.Close()
        }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    [IO.File]::WriteAllText($StdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($StderrPath, $stderr, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-MariaDb(
    [string]$Sql,
    [string]$Label,
    [string]$Database = '',
    [string]$InputFile = ''
) {
    $arguments = @(
        '--protocol=tcp',
        '--host=127.0.0.1',
        "--port=$Port",
        '--user=root',
        '--disable-ssl',
        '--batch',
        '--skip-column-names'
    )
    if ($Database.Length -ne 0) {
        $arguments += "--database=$Database"
    }
    if ($Sql.Length -ne 0) {
        $arguments += "--execute=$Sql"
    }
    return Invoke-CapturedNative -File $script:client -Arguments $arguments `
        -StdoutPath (Join-Path $script:evidence "$Label.stdout.log") `
        -StderrPath (Join-Path $script:evidence "$Label.stderr.log") `
        -Environment @{ MYSQL_PWD = $script:password } -InputFile $InputFile
}

function Require-Sql([string]$Sql, [string]$Expected, [string]$Label) {
    $result = Invoke-MariaDb -Sql $Sql -Label $Label
    if ($result.ExitCode -ne 0) {
        throw "$Label failed with exit code $($result.ExitCode): $($result.Stderr.Trim())"
    }
    $actual = $result.Stdout.Trim()
    if ($actual -cne $Expected) {
        throw "$Label returned '$actual'; expected '$Expected'."
    }
}

function Apply-Migration([string]$Label, [bool]$ExpectSuccess) {
    $result = Invoke-MariaDb -Sql '' -Label $Label -Database 'cv_bots' -InputFile $script:migration
    if ($ExpectSuccess -and $result.ExitCode -ne 0) {
        throw "$Label failed with exit code $($result.ExitCode): $($result.Stderr.Trim())"
    }
    if (!$ExpectSuccess -and $result.ExitCode -eq 0) {
        throw "$Label unexpectedly succeeded."
    }
    return $result
}

function Reset-Fixture([string]$Label) {
    $reset = Invoke-MariaDb -Sql (
        'DROP DATABASE IF EXISTS `tw_char`;' +
        'DROP DATABASE IF EXISTS `cv_bots`;' +
        'CREATE DATABASE `tw_char` CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;' +
        'CREATE DATABASE `cv_bots` CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;') -Label "$Label-reset"
    if ($reset.ExitCode -ne 0) {
        throw "$Label schema reset failed: $($reset.Stderr.Trim())"
    }
    $import = Invoke-MariaDb -Sql '' -Label "$Label-import" -Database 'tw_char' -InputFile $script:fixture
    if ($import.ExitCode -ne 0) {
        throw "$Label fixture import failed: $($import.Stderr.Trim())"
    }
    Require-Sql 'SELECT COUNT(*) FROM `tw_char`.`ai_playerbot_random_bots`' ([string]$ExpectedCopyRows) "$Label-source-count"
}

function Get-LogicalHashSql([string]$Schema) {
    $sql = @'
SET SESSION group_concat_max_len=1073741824;
SELECT UPPER(SHA2(CONCAT(
  'ROW_COUNT=',COUNT(*),CHAR(10),
  COALESCE(GROUP_CONCAT(UPPER(row_hash) ORDER BY row_hash SEPARATOR '\n'),''),
  IF(COUNT(*)=0,'',CHAR(10))
),256))
FROM (
  SELECT SHA2(CONCAT(
    '1=',CASE WHEN id IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(id AS BINARY)),':',HEX(CAST(id AS BINARY)),';') END,
    '2=',CASE WHEN owner IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(owner AS BINARY)),':',HEX(CAST(owner AS BINARY)),';') END,
    '3=',CASE WHEN bot IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(bot AS BINARY)),':',HEX(CAST(bot AS BINARY)),';') END,
    '4=',CASE WHEN time IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(time AS BINARY)),':',HEX(CAST(time AS BINARY)),';') END,
    '5=',CASE WHEN validIn IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(validIn AS BINARY)),':',HEX(CAST(validIn AS BINARY)),';') END,
    '6=',CASE WHEN event IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(event AS BINARY)),':',HEX(CAST(event AS BINARY)),';') END,
    '7=',CASE WHEN value IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(value AS BINARY)),':',HEX(CAST(value AS BINARY)),';') END,
    '8=',CASE WHEN data IS NULL THEN 'N;' ELSE CONCAT('V',OCTET_LENGTH(CAST(data AS BINARY)),':',HEX(CAST(data AS BINARY)),';') END
  ),256) AS row_hash
  FROM `{SCHEMA}`.`ai_playerbot_random_bots`
) AS fingerprints;
'@
    return $sql.Replace('{SCHEMA}', $Schema)
}

function Verify-MigratedState([string]$Label) {
    Require-Sql 'SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots`' ([string]$ExpectedCopyRows) "$Label-target-count"
    Require-Sql (Get-LogicalHashSql 'tw_char') $ExpectedCopyHash "$Label-source-hash"
    Require-Sql (Get-LogicalHashSql 'cv_bots') $ExpectedCopyHash "$Label-target-hash"
    Require-Sql @'
SELECT GROUP_CONCAT(CONCAT_WS('|',COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,
  IS_NULLABLE,EXTRA,IFNULL(CHARACTER_SET_NAME,''),IFNULL(COLLATION_NAME,''))
  ORDER BY ORDINAL_POSITION SEPARATOR ';')
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='cv_bots' AND TABLE_NAME='ai_playerbot_random_bots';
'@ ('id|1|bigint(20)|NO|auto_increment||;' +
    'owner|2|bigint(20)|NO|||;' +
    'bot|3|bigint(20)|NO|||;' +
    'time|4|bigint(20)|NO|||;' +
    'validIn|5|bigint(20)|YES|||;' +
    'event|6|varchar(45)|NO||utf8mb3|utf8mb3_general_ci;' +
    'value|7|bigint(20)|YES|||;' +
    'data|8|varchar(255)|YES||utf8mb3|utf8mb3_general_ci') "$Label-column-definition"
    Require-Sql @'
SELECT COUNT(*) FROM `tw_char`.`ai_playerbot_random_bots` AS source
WHERE NOT EXISTS (
  SELECT 1 FROM `cv_bots`.`ai_playerbot_random_bots` AS target
  WHERE target.id <=> source.id AND target.owner <=> source.owner
    AND target.bot <=> source.bot AND target.time <=> source.time
    AND target.validIn <=> source.validIn AND target.event <=> source.event
    AND target.value <=> source.value AND target.data <=> source.data);
'@ '0' "$Label-source-anti-join"
    Require-Sql @'
SELECT COUNT(*) FROM `cv_bots`.`ai_playerbot_random_bots` AS target
WHERE NOT EXISTS (
  SELECT 1 FROM `tw_char`.`ai_playerbot_random_bots` AS source
  WHERE source.id <=> target.id AND source.owner <=> target.owner
    AND source.bot <=> target.bot AND source.time <=> target.time
    AND source.validIn <=> target.validIn AND source.event <=> target.event
    AND source.value <=> target.value AND source.data <=> target.data);
'@ '0' "$Label-target-anti-join"
    Require-Sql @'
SELECT CONCAT(IS_NULLABLE,'|',DATA_TYPE,'|',CHARACTER_MAXIMUM_LENGTH,'|',
  CHARACTER_SET_NAME,'|',COLLATION_NAME)
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='cv_bots' AND TABLE_NAME='ai_playerbot_random_bots'
  AND COLUMN_NAME='event';
'@ 'NO|varchar|45|utf8mb3|utf8mb3_general_ci' "$Label-event-definition"
    Require-Sql @'
SELECT CONCAT(INDEX_NAME,'|',NON_UNIQUE,'|',INDEX_TYPE,'|',
  GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','))
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='cv_bots' AND TABLE_NAME='ai_playerbot_random_bots'
  AND INDEX_NAME='uq_owner_bot_event'
GROUP BY INDEX_NAME,NON_UNIQUE,INDEX_TYPE;
'@ 'uq_owner_bot_event|0|BTREE|owner,bot,event' "$Label-unique-key"
}

function Invoke-Adapter([string]$Label) {
    $runtimePath = (Join-Path $script:mariaRoot 'bin') + ';' + $script:aceRuntime + ';' +
        $script:mysqlRuntime + ';' + $env:Path
    $connection = "127.0.0.1;$Port;root;$script:password;tw_char"
    $result = Invoke-CapturedNative -File $script:testExe -Arguments @($connection) `
        -StdoutPath (Join-Path $script:evidence "$Label.stdout.log") `
        -StderrPath (Join-Path $script:evidence "$Label.stderr.log") `
        -Environment @{ Path = $runtimePath }
    if ($result.ExitCode -ne 0) {
        throw "$Label failed with exit code $($result.ExitCode): $($result.Stderr.Trim())"
    }
    foreach ($required in @(
        'PLAYERBOT_EVENT_STORE_DATABASE_TESTS=PASS',
        'SAME_KEY_FAILED_COUNT=0',
        'DIFFERENT_KEY_FAILED_COUNT=0',
        'DEADLOCK_1213_COUNT=0',
        'DUPLICATE_1062_COUNT=0',
        'PRECISE_DELETE_RESULT=PASS')) {
        if ($result.Stdout -notmatch [regex]::Escape($required)) {
            throw "$Label did not report $required."
        }
    }
    $cleanup = Invoke-MariaDb -Sql (
        'DELETE FROM `cv_bots`.`ai_playerbot_random_bots` WHERE `owner`=0 AND `event` LIKE ''ref018_test_%''') `
        -Label "$Label-cleanup"
    if ($cleanup.ExitCode -ne 0) {
        throw "$Label test-row cleanup failed: $($cleanup.Stderr.Trim())"
    }
    Verify-MigratedState "$Label-post-cleanup"
}

function Run-PositiveSuite([string]$Label) {
    Reset-Fixture $Label
    Apply-Migration "$Label-fresh-migration" $true | Out-Null
    Verify-MigratedState "$Label-fresh"
    Apply-Migration "$Label-replay-migration" $true | Out-Null
    Verify-MigratedState "$Label-replay"
    Invoke-Adapter "$Label-adapter"
}

function Run-NegativeTests {
    Reset-Fixture 'negative-null'
    $seed = Invoke-MariaDb -Sql @'
INSERT INTO `tw_char`.`ai_playerbot_random_bots`
  (`id`,`owner`,`bot`,`time`,`validIn`,`event`,`value`,`data`)
VALUES (900001,0,900001,1,NULL,NULL,1,NULL);
'@ -Label 'negative-null-seed'
    if ($seed.ExitCode -ne 0) { throw "NULL seed failed: $($seed.Stderr.Trim())" }
    Apply-Migration 'negative-null-migration' $false | Out-Null
    $script:nullNegative = 'PASS'

    Reset-Fixture 'negative-empty'
    $seed = Invoke-MariaDb -Sql @'
INSERT INTO `tw_char`.`ai_playerbot_random_bots`
  (`id`,`owner`,`bot`,`time`,`validIn`,`event`,`value`,`data`)
VALUES (900002,0,900002,1,NULL,'',1,NULL);
'@ -Label 'negative-empty-seed'
    if ($seed.ExitCode -ne 0) { throw "Empty-event seed failed: $($seed.Stderr.Trim())" }
    Apply-Migration 'negative-empty-migration' $false | Out-Null
    $script:emptyNegative = 'PASS'

    Reset-Fixture 'negative-duplicate'
    $seed = Invoke-MariaDb -Sql @'
INSERT INTO `tw_char`.`ai_playerbot_random_bots`
  (`id`,`owner`,`bot`,`time`,`validIn`,`event`,`value`,`data`)
SELECT 900003,`owner`,`bot`,`time`,`validIn`,`event`,`value`,`data`
FROM `tw_char`.`ai_playerbot_random_bots` ORDER BY `id` LIMIT 1;
'@ -Label 'negative-duplicate-seed'
    if ($seed.ExitCode -ne 0) { throw "Duplicate seed failed: $($seed.Stderr.Trim())" }
    Apply-Migration 'negative-duplicate-migration' $false | Out-Null
    $script:duplicateNegative = 'PASS'

    Reset-Fixture 'negative-conflict'
    Apply-Migration 'negative-conflict-initial-migration' $true | Out-Null
    $seed = Invoke-MariaDb -Sql @'
UPDATE `cv_bots`.`ai_playerbot_random_bots`
SET `value`=COALESCE(`value`,0)+1
ORDER BY `id` LIMIT 1;
'@ -Label 'negative-conflict-seed'
    if ($seed.ExitCode -ne 0) { throw "Conflict seed failed: $($seed.Stderr.Trim())" }
    Apply-Migration 'negative-conflict-migration' $false | Out-Null
    $script:conflictNegative = 'PASS'
}

if ($Port -eq 3307) {
    throw 'Production port 3307 is forbidden.'
}
if ($Port -lt 1024 -or $Port -gt 65535) {
    throw "Disposable port is outside the allowed range: $Port"
}

$script:mariaRoot = (Resolve-Path -LiteralPath $MariaDbRoot -ErrorAction Stop).Path
$installer = Resolve-ExistingFile (Join-Path $mariaRoot 'bin\mariadb-install-db.exe')
$server = Resolve-ExistingFile (Join-Path $mariaRoot 'bin\mariadbd.exe')
$script:client = Resolve-ExistingFile (Join-Path $mariaRoot 'bin\mariadb.exe')
$admin = Resolve-ExistingFile (Join-Path $mariaRoot 'bin\mariadb-admin.exe')
$script:testExe = Resolve-ExistingFile $TestExecutable
$script:migration = Resolve-ExistingFile $MigrationFile
$dump = Resolve-ExistingFile $DumpFile
$script:aceRuntime = (Resolve-Path -LiteralPath $AceRuntimeDirectory -ErrorAction Stop).Path
$script:mysqlRuntime = (Resolve-Path -LiteralPath $MySqlRuntimeDirectory -ErrorAction Stop).Path
$forbiddenData = (Resolve-Path -LiteralPath $ForbiddenDataDirectory -ErrorAction Stop).Path

$dumpInfo = Get-Item -LiteralPath $dump
if ($dumpInfo.Length -ne $ExpectedDumpBytes -or
    (Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash -cne $ExpectedDumpSha256) {
    throw 'The dated source dump identity does not match the reviewed evidence.'
}

$script:evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$disposable = [IO.Path]::GetFullPath($DisposableRoot)
$approvedDisposableParent = [IO.Path]::GetFullPath('C:\TW\disposable')
if (Test-Path -LiteralPath $evidence) { throw "Evidence directory already exists: $evidence" }
if (Test-Path -LiteralPath $disposable) { throw "Disposable directory already exists: $disposable" }
if (!$disposable.StartsWith($approvedDisposableParent + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Disposable root is outside the approved task area: $disposable"
}
if ($disposable.Equals($forbiddenData, [StringComparison]::OrdinalIgnoreCase) -or
    $disposable.StartsWith($forbiddenData + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Disposable data directory resolves inside the forbidden data directory.'
}

Assert-NoServerProcess
Assert-PortClosed $Port
[void](New-Item -ItemType Directory -Path $evidence)
[void](New-Item -ItemType Directory -Path $disposable)
$dataDirectory = Join-Path $disposable 'data'
$script:fixture = Join-Path $disposable 'dated-event-fixture.sql'
$fixtureLines = [Collections.Generic.List[string]]::new()
$lineNumber = 0
foreach ($line in [IO.File]::ReadLines($dump)) {
    ++$lineNumber
    if ($lineNumber -ge 1449914 -and $lineNumber -le 1450119) {
        $fixtureLines.Add($line)
    }
    if ($lineNumber -gt 1450119) { break }
}
if ($fixtureLines.Count -ne 206 -or $fixtureLines[0] -cne 'DROP TABLE IF EXISTS `ai_playerbot_random_bots`;') {
    throw 'The reviewed event fixture boundaries were not found in the dated dump.'
}
[IO.File]::WriteAllLines($fixture, $fixtureLines, [Text.UTF8Encoding]::new($false))
$fixtureLines.Clear()

$script:password = [Guid]::NewGuid().ToString('N')
$databaseProcess = $null
$ownedDatabasePid = 0
$cleanupErrors = [Collections.Generic.List[string]]::new()
$testSucceeded = $false
$completedPositiveSuites = 0
$script:nullNegative = 'NOT_RUN'
$script:emptyNegative = 'NOT_RUN'
$script:duplicateNegative = 'NOT_RUN'
$script:conflictNegative = 'NOT_RUN'
$startedUtc = [DateTime]::UtcNow

try {
    $install = Invoke-CapturedNative -File $installer -Arguments @(
        "--datadir=$dataDirectory", "--password=$password", "--port=$Port",
        '--allow-remote-root-access') `
        -StdoutPath (Join-Path $evidence 'mariadb-install.stdout.log') `
        -StderrPath (Join-Path $evidence 'mariadb-install.stderr.log')
    if ($install.ExitCode -ne 0) {
        throw "Disposable MariaDB initialization failed: $($install.Stderr.Trim())"
    }

    $pidFile = Join-Path $disposable 'mariadb.pid'
    $serverArguments = @(
        '--no-defaults', "--basedir=$mariaRoot", "--datadir=$dataDirectory", "--port=$Port",
        '--bind-address=127.0.0.1', '--skip-name-resolve', '--console',
        '--innodb-print-all-deadlocks=ON', '--general-log=ON',
        "--general-log-file=$(Join-Path $disposable 'mariadb-general.log')",
        "--log-error=$(Join-Path $disposable 'mariadb-error.log')", "--pid-file=$pidFile")
    $databaseProcess = Start-Process -FilePath $server -ArgumentList $serverArguments `
        -RedirectStandardOutput (Join-Path $evidence 'mariadb-server.stdout.log') `
        -RedirectStandardError (Join-Path $evidence 'mariadb-server.stderr.log') `
        -WindowStyle Hidden -PassThru

    for ($attempt = 1; $attempt -le 60 -and !(Test-Path -LiteralPath $pidFile -PathType Leaf); $attempt++) {
        if ($databaseProcess.HasExited) {
            throw "Disposable MariaDB exited before readiness with code $($databaseProcess.ExitCode)."
        }
        Start-Sleep -Milliseconds 250
    }
    if (!(Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        throw 'Disposable MariaDB did not create its PID file.'
    }
    $ownedDatabasePid = [int](Get-Content -LiteralPath $pidFile -Raw)
    $ownedProcess = Get-Process -Id $ownedDatabasePid -ErrorAction Stop
    if ($ownedProcess.Path -cne $server) {
        throw "Disposable MariaDB executable mismatch for PID $ownedDatabasePid."
    }

    $ready = $false
    $lastProbe = ''
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $probe = Invoke-MariaDb -Sql 'SELECT 1' -Label 'readiness'
        $lastProbe = $probe.Stderr.Trim()
        if ($probe.ExitCode -eq 0 -and $probe.Stdout.Trim() -ceq '1') {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (!$ready) { throw "Disposable MariaDB readiness timed out. Last probe: $lastProbe" }
    $owners = @(Get-ListeningOwnerPids $Port)
    if ($owners.Count -ne 1 -or $owners[0] -ne $ownedDatabasePid) {
        throw "Disposable port ownership mismatch; expected PID $ownedDatabasePid."
    }

    Run-PositiveSuite 'suite-1'
    $completedPositiveSuites = 1
    Run-NegativeTests
    Run-PositiveSuite 'suite-2'
    $completedPositiveSuites = 2

    $shutdown = Invoke-CapturedNative -File $admin -Arguments @(
        '--protocol=tcp', '--host=127.0.0.1', "--port=$Port", '--user=root',
        '--disable-ssl', 'shutdown') `
        -StdoutPath (Join-Path $evidence 'mariadb-shutdown.stdout.log') `
        -StderrPath (Join-Path $evidence 'mariadb-shutdown.stderr.log') `
        -Environment @{ MYSQL_PWD = $password }
    if ($shutdown.ExitCode -ne 0) {
        throw "Controlled disposable MariaDB shutdown failed: $($shutdown.Stderr.Trim())"
    }
    $ownedBeforeStop = @(Get-Process -Id $ownedDatabasePid -ErrorAction SilentlyContinue)
    if ($ownedBeforeStop.Count -eq 1 -and !$ownedBeforeStop[0].WaitForExit(30000)) {
        throw 'Controlled disposable MariaDB shutdown timed out.'
    }
    Assert-PortClosed $Port

    $errorLogPath = Join-Path $disposable 'mariadb-error.log'
    $errorText = if (Test-Path -LiteralPath $errorLogPath -PathType Leaf) {
        [IO.File]::ReadAllText($errorLogPath)
    }
    else {
        [IO.File]::ReadAllText((Join-Path $evidence 'mariadb-server.stderr.log'))
    }
    $generalLogPath = Join-Path $disposable 'mariadb-general.log'
    if (!(Test-Path -LiteralPath $generalLogPath -PathType Leaf)) {
        throw 'Disposable MariaDB did not create the required general log.'
    }
    $generalText = [IO.File]::ReadAllText($generalLogPath)
    $deadlockCount = ([regex]::Matches($errorText, '(?i)deadlock')).Count
    $error1213Count = ([regex]::Matches($errorText + $generalText, '(?i)(ERROR\s+1213|Deadlock found)')).Count
    $error1062Count = ([regex]::Matches($errorText + $generalText, '(?i)(ERROR\s+1062|Duplicate entry)')).Count
    if ($deadlockCount -ne 0 -or $error1213Count -ne 0 -or $error1062Count -ne 0) {
        throw "Database diagnostics are not clean: deadlock=$deadlockCount, 1213=$error1213Count, 1062=$error1062Count."
    }

    $testSucceeded = $true
}
finally {
    if ($ownedDatabasePid -ne 0) {
        $owned = @(Get-Process -Id $ownedDatabasePid -ErrorAction SilentlyContinue)
        if ($owned.Count -eq 1 -and $owned[0].Path -ceq $server) {
            try {
                $shutdown = Invoke-CapturedNative -File $admin -Arguments @(
                    '--protocol=tcp', '--host=127.0.0.1', "--port=$Port", '--user=root',
                    '--disable-ssl', 'shutdown') `
                    -StdoutPath (Join-Path $evidence 'mariadb-shutdown.stdout.log') `
                    -StderrPath (Join-Path $evidence 'mariadb-shutdown.stderr.log') `
                    -Environment @{ MYSQL_PWD = $password }
                if ($shutdown.ExitCode -ne 0) {
                    $cleanupErrors.Add("mariadb-admin failed: $($shutdown.Stderr.Trim())")
                }
                [void]$owned[0].WaitForExit(30000)
            }
            catch { $cleanupErrors.Add($_.Exception.Message) }
        }
    }
    $remainingOwned = @(if ($ownedDatabasePid -ne 0) {
        Get-Process -Id $ownedDatabasePid -ErrorAction SilentlyContinue
    })
    $remainingListeners = @(Get-ListeningOwnerPids $Port)
    if ($remainingOwned.Count -ne 0 -or $remainingListeners.Count -ne 0) {
        $cleanupErrors.Add('Owned disposable process or listener remains active.')
    }
    else {
        try {
            Remove-Item -LiteralPath $disposable -Recurse -Force
        }
        catch { $cleanupErrors.Add("Disposable cleanup failed: $($_.Exception.Message)") }
    }

    $result = [ordered]@{
        schema_version = 1
        task_id = 'REF-018-ISSUE-119-CV-BOTS-MIGRATION-AND-ATOMIC-WRITE-IMPLEMENTATION-01'
        source_snapshot_rows = $ExpectedCopyRows
        source_snapshot_logical_sha256 = $ExpectedCopyHash
        positive_suite_count = $completedPositiveSuites
        null_negative = $script:nullNegative
        empty_event_negative = $script:emptyNegative
        duplicate_negative = $script:duplicateNegative
        conflicting_payload_negative = $script:conflictNegative
        deadlock_1213_count = 0
        duplicate_1062_count = 0
        production_port_used = $false
        worldserver_started = $false
        realmserver_started = $false
        disposable_port = $Port
        disposable_database_pid = $ownedDatabasePid
        test_succeeded = $testSucceeded
        cleanup_errors = @($cleanupErrors)
        started_utc = $startedUtc.ToString('o')
        finished_utc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $evidence 'result.json'),
        ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $manifest = Get-ChildItem -LiteralPath $evidence -File |
        Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name | ForEach-Object {
            "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name
        }
    [IO.File]::WriteAllLines((Join-Path $evidence 'SHA256SUMS.txt'), $manifest,
        [Text.UTF8Encoding]::new($false))
}

if ($cleanupErrors.Count -ne 0) {
    throw "Disposable cleanup failed: $($cleanupErrors -join '; ')"
}
if (!$testSucceeded) {
    throw 'Disposable event-store verification did not complete.'
}

Write-Output 'REF018_EVENT_STORE_TEST_RESULT=PASS'
Write-Output "EVIDENCE_DIRECTORY=$evidence"
