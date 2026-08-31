#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1' -Force -ErrorAction Stop

$Root = 'C:\TW\ComTW'
$ReviewedRunbook = Join-Path $Root 'runbooks\tw-char-migration-F92F86D6.ps1'
$ExpectedReviewedRunbookSha256 = 'F92F86D66FEB4C1743F1E09B1CA14101B8249E858CB5B18DC2894AA27E06F881'
$MigrationPath = Join-Path $Root 'source\sql\logon\donation_point_progress.sql'
$ExpectedMigrationSha256 = 'EDD4D4BCD78AA8DA96179797C54B375477DBEA4DCA6CF06ECB3925F122248103'
$BackupParent = 'E:\TWoW-Migration-Backups'
$BackupPath = Join-Path $BackupParent 'tw_logon-before-donation-point-progress-20260829-173126.sql'
$EvidenceDirectory = Join-Path $Root 'runbooks\donation-point-progress-migration-20260829-173126'
$DatabaseRoot = Join-Path $Root 'DB'
$DataDir = Join-Path $DatabaseRoot 'data'
$DatabaseLauncher = Join-Path $DatabaseRoot 'start-database.bat'
$MariaDbServer = Join-Path $DatabaseRoot 'bin\mysqld.exe'
$MariaDbClient = Join-Path $DatabaseRoot 'bin\mariadb.exe'
$MariaDbDump = Join-Path $DatabaseRoot 'bin\mariadb-dump.exe'
$MariaDbAdmin = Join-Path $DatabaseRoot 'bin\mariadb-admin.exe'
$MyIni = Join-Path $DataDir 'my.ini'
$ProductionExe = Join-Path $Root 'server\mangosd.exe'
$DatabaseName = 'tw_logon'
$DatabaseHost = '127.0.0.1'
$DatabasePort = 3307
$DatabaseUser = 'root'
$MariaDbPasswordlessTlsWarning = 'WARNING: option --ssl-verify-server-cert is disabled, because of an insecure passwordless login.'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

$ApprovedFiles = @{
    DatabaseLauncher = @{ Path = $DatabaseLauncher; Sha256 = 'C0EEC81CE8797DDE77685D5639E90AD36892EE473CAD01F8558B6A8C6237336A' }
    MyIni = @{ Path = $MyIni; Sha256 = '7039B21A8D50E85511EDF7D5BC2ECD501830AD151D9EF0331243B43ADA4BA9B8' }
    MariaDbServer = @{ Path = $MariaDbServer; Sha256 = 'FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7' }
    MariaDbClient = @{ Path = $MariaDbClient; Sha256 = '9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95' }
    MariaDbDump = @{ Path = $MariaDbDump; Sha256 = 'FD6E467EAA49F166E355A5660952E2488ABB2BE80CB90B2DB229DF7253D24EDB' }
    MariaDbAdmin = @{ Path = $MariaDbAdmin; Sha256 = '1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E' }
}

$script:RunState = @{
    Database = @{ LaunchAttempted = $false; LaunchUtc = $null; LauncherPid = $null; PreExistingPids = @(); OwnedPid = $null; OwnedStartTimeUtcTicks = $null; ExpectedPath = $MariaDbServer }
    World = @{ LaunchAttempted = $false; LaunchUtc = $null; LauncherPid = $null; PreExistingPids = @(); OwnedPid = $null; OwnedStartTimeUtcTicks = $null; ExpectedPath = $ProductionExe }
}

$result = [ordered]@{
    Result = 'ABORTED'
    SelectedDatabase = $DatabaseName
    MigrationPath = $MigrationPath
    MigrationBytes = 0
    MigrationSha256 = ''
    StaticSqlExact = $false
    CommentDefectRecorded = $false
    ReviewedRunbookSha256 = ''
    DatabaseOwnedPid = $null
    PreTablePresent = $null
    PreTableNamesCount = $null
    PreExistingSchemaDigest = ''
    BackupPath = ''
    BackupBytes = 0
    BackupSha256 = ''
    DumpExitCode = $null
    DumpAcceptedWarningCount = 0
    MigrationExitCode = $null
    MigrationAcceptedWarningCount = 0
    PostShowCreate = ''
    PostRowCount = $null
    PostSchemaIdentity = ''
    LogicalAddedTables = @()
    LogicalRemovedTables = @()
    PostExistingSchemaDigest = ''
    EvidenceDirectory = $EvidenceDirectory
    CleanupDatabaseStopped = $false
    FinalProcesses = @()
    FinalServices = @()
    FinalPort3307Owners = @()
    FinalPort3724Owners = @()
    FinalPort8090Owners = @()
    PrimaryError = $null
    CleanupErrors = @()
}

$functionsImported = $false

function Import-ReviewedDatabaseFunctions {
    if ((Get-FileHash -LiteralPath $ReviewedRunbook -Algorithm SHA256).Hash -cne $ExpectedReviewedRunbookSha256) {
        throw 'Reviewed runbook hash mismatch.'
    }
    $result.ReviewedRunbookSha256 = $ExpectedReviewedRunbookSha256
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ReviewedRunbook, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "Reviewed runbook parser error count is $($errors.Count)."
    }
    $required = @(
        'Get-Sha256', 'Assert-Hash', 'Assert-Administrator', 'Get-NormalizedPath',
        'Get-ProcessPath', 'Get-ProcessCandidates', 'Test-PortOpen', 'Get-PortOwnerPids',
        'Set-LaunchAttempt', 'Set-LauncherPid', 'Get-VerifiedOwnedProcess',
        'Try-AdoptLaunchedProcess', 'Wait-ForOwnedProcess', 'Wait-ForProcessExit',
        'Assert-DatabaseProgramFiles', 'Assert-RestoredDatabaseConfiguration',
        'Resolve-MariaDbClientResult', 'ConvertTo-WindowsCommandLineArgument',
        'Invoke-ProcessWithCapturedOutput', 'Invoke-MariaDb', 'Assert-SingleValue',
        'Assert-DatabaseIdentity', 'Assert-DatabasePortOwnership', 'Wait-ForDatabaseReady',
        'Assert-ReviewedDatabaseConfiguration', 'Stop-OwnedDatabase', 'Start-ReviewedDatabase'
    )
    $definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $source = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        $matches = @($definitions | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            throw "Reviewed function '$name' count is $($matches.Count), expected one."
        }
        $source.Add($matches[0].Extent.Text)
    }
    return ($source -join "`n`n")
}

function Get-ListenerOwners {
    param([int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
}

function Get-MatchingServices {
    return @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        $_.State -eq 'Running' -and (
            $_.Name -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
            $_.DisplayName -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
            $_.PathName -match '(?i)\\TW\\ComTW\\(DB|server)\\'
        )
    })
}

function Assert-CleanInitialState {
    $processes = @()
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        $processes += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    $services = @(Get-MatchingServices)
    $port3307 = @(Get-ListenerOwners -Port 3307)
    $port3724 = @(Get-ListenerOwners -Port 3724)
    $port8090 = @(Get-ListenerOwners -Port 8090)
    if ($processes.Count -ne 0 -or $services.Count -ne 0 -or $port3307.Count -ne 0 -or $port3724.Count -ne 0 -or $port8090.Count -ne 0) {
        throw "Initial clean-state gate failed: processes=$($processes.Count), services=$($services.Count), port3307=$($port3307.Count), port3724=$($port3724.Count), port8090=$($port8090.Count)."
    }
}

function Assert-MigrationSource {
    $matches = @(Get-ChildItem -LiteralPath 'C:\TW' -Recurse -File -Filter 'donation_point_progress.sql')
    if ($matches.Count -ne 1 -or $matches[0].FullName -ine $MigrationPath) {
        throw "Migration file uniqueness failed: count=$($matches.Count)."
    }
    $item = Get-Item -LiteralPath $MigrationPath
    $hash = (Get-FileHash -LiteralPath $MigrationPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hash -cne $ExpectedMigrationSha256) {
        throw "Migration hash mismatch: $hash"
    }
    $bytes = [IO.File]::ReadAllBytes($MigrationPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Migration unexpectedly contains UTF-8 BOM.'
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n").Replace("`r", "`n")
    $sql = (($text -split "`n" | Where-Object { $_ -notmatch '^\s*--' }) -join "`n").Trim()
    $expected = @(
        'CREATE TABLE IF NOT EXISTS `donation_point_progress` ('
        '  `account_id`     INT UNSIGNED NOT NULL PRIMARY KEY,'
        '  `accumulated_ms` INT UNSIGNED NOT NULL DEFAULT 0'
        ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;'
    ) -join "`n"
    if ($sql -cne $expected -or ([regex]::Matches($sql, ';')).Count -ne 1) {
        throw 'Static SQL audit failed.'
    }
    $result.MigrationBytes = [long]$item.Length
    $result.MigrationSha256 = $hash
    $result.StaticSqlExact = $true
    $result.CommentDefectRecorded = ($text -match 'held in memory only and resets to zero')
}

function Split-Lines {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text.Trim() -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Get-TableNames {
    return @(Split-Lines (Invoke-MariaDb -Sql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='tw_logon' ORDER BY TABLE_NAME" -AllowEmpty))
}

function Get-ExistingSchemaDigest {
    $queries = @(
        "SELECT CONCAT('T|',TABLE_NAME,'|',ENGINE,'|',IFNULL(ROW_FORMAT,''),'|',IFNULL(TABLE_COLLATION,''),'|',IFNULL(CREATE_OPTIONS,'')) FROM information_schema.TABLES WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME<>'donation_point_progress' ORDER BY TABLE_NAME"
        "SELECT CONCAT('C|',TABLE_NAME,'|',ORDINAL_POSITION,'|',COLUMN_NAME,'|',COLUMN_TYPE,'|',IS_NULLABLE,'|',IF(COLUMN_DEFAULT IS NULL,'<NULL>',COLUMN_DEFAULT),'|',EXTRA,'|',IFNULL(COLLATION_NAME,'')) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME<>'donation_point_progress' ORDER BY TABLE_NAME,ORDINAL_POSITION"
        "SELECT CONCAT('I|',TABLE_NAME,'|',INDEX_NAME,'|',NON_UNIQUE,'|',SEQ_IN_INDEX,'|',COLUMN_NAME,'|',INDEX_TYPE) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME<>'donation_point_progress' ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX"
        "SELECT CONCAT('K|',TABLE_NAME,'|',CONSTRAINT_NAME,'|',CONSTRAINT_TYPE) FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME<>'donation_point_progress' ORDER BY TABLE_NAME,CONSTRAINT_NAME"
        "SELECT CONCAT('R|',TRIGGER_NAME,'|',EVENT_MANIPULATION,'|',EVENT_OBJECT_TABLE,'|',ACTION_TIMING) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='tw_logon' AND EVENT_OBJECT_TABLE<>'donation_point_progress' ORDER BY TRIGGER_NAME"
    )
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($query in $queries) {
        foreach ($line in @(Split-Lines (Invoke-MariaDb -Sql $query -AllowEmpty))) { $all.Add($line) }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($all -join "`n"))))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Get-SchemaSnapshot {
    $identity = Invoke-MariaDb -Sql "SELECT CONCAT(TABLE_SCHEMA,'|',TABLE_NAME,'|',ENGINE,'|',SUBSTRING_INDEX(TABLE_COLLATION,'_',1),'|',TABLE_COLLATION) FROM information_schema.TABLES WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress'" -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($identity)) { return $null }
    return [pscustomobject]@{
        Identity = $identity
        ShowCreate = Invoke-MariaDb -Sql 'SHOW CREATE TABLE `donation_point_progress`'
        Rows = [int](Invoke-MariaDb -Sql 'SELECT COUNT(*) FROM `donation_point_progress`')
    }
}

function Assert-ExactSchema {
    $snapshot = Get-SchemaSnapshot
    if ($null -eq $snapshot) { throw 'donation_point_progress is absent during exact-schema verification.' }
    if ($snapshot.Identity -notmatch '^tw_logon\|donation_point_progress\|InnoDB\|utf8mb4\|utf8mb4_') {
        throw "Table identity mismatch: $($snapshot.Identity)"
    }
    $checks = @(
        @{ Sql = "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress'"; Expected = '2'; Name = 'column count' }
        @{ Sql = "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress' AND ORDINAL_POSITION=1 AND COLUMN_NAME='account_id' AND DATA_TYPE='int' AND LOWER(COLUMN_TYPE) LIKE 'int%unsigned%' AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL AND COLUMN_KEY='PRI'"; Expected = '1'; Name = 'account_id definition' }
        @{ Sql = "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress' AND ORDINAL_POSITION=2 AND COLUMN_NAME='accumulated_ms' AND DATA_TYPE='int' AND LOWER(COLUMN_TYPE) LIKE 'int%unsigned%' AND IS_NULLABLE='NO' AND COLUMN_DEFAULT='0' AND COLUMN_KEY=''"; Expected = '1'; Name = 'accumulated_ms definition' }
        @{ Sql = "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress'"; Expected = '1'; Name = 'index row count' }
        @{ Sql = "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress' AND INDEX_NAME='PRIMARY' AND NON_UNIQUE=0 AND SEQ_IN_INDEX=1 AND COLUMN_NAME='account_id' AND INDEX_TYPE='BTREE'"; Expected = '1'; Name = 'primary key definition' }
        @{ Sql = "SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='tw_logon' AND TABLE_NAME='donation_point_progress' AND REFERENCED_TABLE_NAME IS NOT NULL"; Expected = '0'; Name = 'foreign key count' }
    )
    foreach ($check in $checks) {
        $actual = Invoke-MariaDb -Sql $check.Sql
        if ($actual -cne $check.Expected) {
            throw "$($check.Name) mismatch: expected $($check.Expected), found $actual."
        }
    }
    return $snapshot
}

function Count-KnownWarnings {
    param([AllowEmptyString()][string]$Stderr)
    if ([string]::IsNullOrWhiteSpace($Stderr)) { return 0 }
    $lines = @($Stderr.Replace("`r`n", "`n").Replace("`r", "`n").Trim() -split "`n" | Where-Object { $_ -ne '' })
    foreach ($line in $lines) {
        if ($line -cne $MariaDbPasswordlessTlsWarning) { throw "Unexpected MariaDB stderr: $line" }
    }
    return $lines.Count
}

function Invoke-CompleteLoginDump {
    if (Test-Path -LiteralPath $BackupPath) { throw "Backup target already exists: $BackupPath" }
    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--default-character-set=utf8mb4', '--single-transaction', '--quick', '--routines', '--events',
        '--triggers', '--hex-blob', "--result-file=$BackupPath", '--databases', $DatabaseName
    )
    $native = Invoke-ProcessWithCapturedOutput -FilePath $MariaDbDump -ArgumentList $arguments
    $result.DumpExitCode = $native.ExitCode
    $result.DumpAcceptedWarningCount = Count-KnownWarnings $native.Stderr
    if ($native.ExitCode -ne 0) { throw "Logical dump failed with exit code $($native.ExitCode): $($native.Stderr.Trim())" }
    if (-not [string]::IsNullOrWhiteSpace($native.Stdout)) { throw 'Logical dump unexpectedly wrote to stdout.' }
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw 'Logical dump file was not created.' }
    $item = Get-Item -LiteralPath $BackupPath
    if ($item.Length -le 1024) { throw "Logical dump is unexpectedly small: $($item.Length) bytes." }
    $result.BackupPath = $BackupPath
    $result.BackupBytes = [long]$item.Length
    $result.BackupSha256 = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Invoke-ExactMigrationFile {
    if ((Get-FileHash -LiteralPath $MigrationPath -Algorithm SHA256).Hash.ToUpperInvariant() -cne $ExpectedMigrationSha256) {
        throw 'Migration source changed immediately before use.'
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $MariaDbClient
    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--batch', '--raw', '--skip-column-names', '--default-character-set=utf8mb4', "--database=$DatabaseName"
    )
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $Utf8NoBom
    $startInfo.StandardErrorEncoding = $Utf8NoBom
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Migration client did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::OpenRead($MigrationPath)
        try {
            $stream.CopyTo($process.StandardInput.BaseStream)
            $process.StandardInput.BaseStream.Flush()
        }
        finally {
            $stream.Dispose()
            $process.StandardInput.Close()
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        $result.MigrationExitCode = $exitCode
        $result.MigrationAcceptedWarningCount = Count-KnownWarnings $stderr
        if ($exitCode -ne 0) { throw "Migration client failed with exit code ${exitCode}: $($stderr.Trim())" }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { throw "Migration client produced unexpected stdout: $($stdout.Trim())" }
    }
    finally { $process.Dispose() }
}

function Get-FinalState {
    $processes = @()
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $processes += "name=$($process.ProcessName),pid=$($process.Id)"
        }
    }
    $result.FinalProcesses = @($processes)
    $result.FinalServices = @(Get-MatchingServices | ForEach-Object { "name=$($_.Name),state=$($_.State),pid=$($_.ProcessId)" })
    $result.FinalPort3307Owners = @(Get-ListenerOwners -Port 3307)
    $result.FinalPort3724Owners = @(Get-ListenerOwners -Port 3724)
    $result.FinalPort8090Owners = @(Get-ListenerOwners -Port 8090)
}

$primaryError = $null
$provisionalResult = 'ABORTED'
try {
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "Windows PowerShell 5.1 required; found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }
    $reviewedFunctionSource = Import-ReviewedDatabaseFunctions
    Invoke-Expression $reviewedFunctionSource
    $functionsImported = $true
    Assert-Administrator
    Assert-CleanInitialState
    if (-not (Test-Path -LiteralPath $BackupParent -PathType Container)) { throw "Approved backup parent is missing: $BackupParent" }
    Assert-MigrationSource
    foreach ($key in @('DatabaseLauncher', 'MyIni', 'MariaDbServer', 'MariaDbClient', 'MariaDbDump', 'MariaDbAdmin')) {
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
    }
    $owned = Start-ReviewedDatabase -RequireDump
    $result.DatabaseOwnedPid = $owned.Id
    if (@(Get-Process -Name mangosd -ErrorAction SilentlyContinue).Count -ne 0 -or @(Get-Process -Name realmd -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Game-server process appeared after database startup.'
    }
    $identity = Invoke-MariaDb -Sql 'SELECT DATABASE()'
    if ($identity -cne 'tw_logon') { throw "Selected database mismatch: $identity" }
    $preTables = @(Get-TableNames)
    $result.PreTableNamesCount = $preTables.Count
    $result.PreExistingSchemaDigest = Get-ExistingSchemaDigest
    $prePresent = ($preTables -ccontains 'donation_point_progress')
    $result.PreTablePresent = $prePresent
    if ($prePresent) {
        $snapshot = Assert-ExactSchema
        $result.PostShowCreate = $snapshot.ShowCreate
        $result.PostRowCount = $snapshot.Rows
        $result.PostSchemaIdentity = $snapshot.Identity
        $result.PostExistingSchemaDigest = Get-ExistingSchemaDigest
        if ($result.PostExistingSchemaDigest -cne $result.PreExistingSchemaDigest) { throw 'Existing LOGIN schema digest changed during present-table verification.' }
        $provisionalResult = 'ALREADY_PRESENT_VERIFIED'
    }
    else {
        Invoke-CompleteLoginDump
        Invoke-ExactMigrationFile
        $snapshot = Assert-ExactSchema
        if ($snapshot.Rows -ne 0) { throw "Initial row count mismatch: expected 0, found $($snapshot.Rows)." }
        $postTables = @(Get-TableNames)
        $added = @($postTables | Where-Object { $preTables -cnotcontains $_ })
        $removed = @($preTables | Where-Object { $postTables -cnotcontains $_ })
        $result.LogicalAddedTables = @($added)
        $result.LogicalRemovedTables = @($removed)
        if ($added.Count -ne 1 -or $added[0] -cne 'donation_point_progress' -or $removed.Count -ne 0) {
            throw "Unexpected table-list delta: added=$($added -join ','), removed=$($removed -join ',')."
        }
        $result.PostExistingSchemaDigest = Get-ExistingSchemaDigest
        if ($result.PostExistingSchemaDigest -cne $result.PreExistingSchemaDigest) { throw 'An existing LOGIN schema object changed during migration.' }
        $result.PostShowCreate = $snapshot.ShowCreate
        $result.PostRowCount = $snapshot.Rows
        $result.PostSchemaIdentity = $snapshot.Identity
        $provisionalResult = 'PASS'
    }
}
catch {
    $primaryError = $_
    $result.PrimaryError = $_.Exception.Message
}
finally {
    if ($functionsImported) {
        try {
            $ownedNow = Get-VerifiedOwnedProcess -Kind Database
            if ($null -ne $ownedNow) {
                $result.CleanupDatabaseStopped = [bool](Stop-OwnedDatabase)
            }
            else { $result.CleanupDatabaseStopped = $true }
        }
        catch { $result.CleanupErrors += @($_.Exception.Message) }
    }
    else { $result.CleanupDatabaseStopped = $true }
    try { Get-FinalState }
    catch { $result.CleanupErrors += @("Final state inspection failed: $($_.Exception.Message)") }
}

if ($result.FinalProcesses.Count -ne 0 -or $result.FinalServices.Count -ne 0 -or $result.FinalPort3307Owners.Count -ne 0 -or $result.FinalPort3724Owners.Count -ne 0 -or $result.FinalPort8090Owners.Count -ne 0) {
    $result.CleanupErrors += @('Final clean-state gate failed.')
}
if ($null -eq $primaryError -and $result.CleanupErrors.Count -eq 0) { $result.Result = $provisionalResult }
[Console]::Out.WriteLine('RESULT_JSON_BEGIN')
[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
[Console]::Out.WriteLine('RESULT_JSON_END')
if ($result.Result -eq 'PASS' -or $result.Result -eq 'ALREADY_PRESENT_VERIFIED') { exit 0 }
exit 1
