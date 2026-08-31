#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Execute', 'Rollback')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedScriptSha256,

    [string]$BackupParent = '',

    [string]$BackupRunDirectory = '',

    [ValidatePattern('^$|^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedBackupEvidenceAnchorSha256 = '',

    [ValidateRange(60, 3600)]
    [int]$HonorTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This script is canonical only as UTF-8 without BOM, with CRLF line endings.
$ExpectedCanonicalScriptByteCount = 93150

$Root = 'C:\TW\ComTW'
$SourceRoot = Join-Path $Root 'source'
$DatabaseRoot = Join-Path $Root 'DB'
$DataDir = Join-Path $DatabaseRoot 'data'
$DatabaseLauncher = Join-Path $DatabaseRoot 'start-database.bat'
$MariaDbServer = Join-Path $DatabaseRoot 'bin\mysqld.exe'
$MariaDbClient = Join-Path $DatabaseRoot 'bin\mariadb.exe'
$MariaDbDump = Join-Path $DatabaseRoot 'bin\mariadb-dump.exe'
$MariaDbAdmin = Join-Path $DatabaseRoot 'bin\mariadb-admin.exe'
$MyIni = Join-Path $DataDir 'my.ini'
$ServerDir = Join-Path $Root 'server'
$ProductionExe = Join-Path $ServerDir 'mangosd.exe'
$MangosConfig = Join-Path $ServerDir 'mangosd.conf'
$PlayerbotConfig = Join-Path $ServerDir 'aiplayerbot.conf'
$StartWorld = Join-Path $ServerDir 'start-mangosd.bat'
$ShutdownHelper = Join-Path $ServerDir 'shutdown-tortoise-servers-gracefully.ps1'
$LogDir = Join-Path $Root 'logs'
$HonorLog = Join-Path $LogDir 'honor.log'
$ErrorLog = Join-Path $LogDir 'errors.log'
$DatabaseName = 'tw_char'
$DatabaseHost = '127.0.0.1'
$DatabasePort = 3307
$DatabaseUser = 'root'
$MariaDbPasswordlessTlsWarning = 'WARNING: option --ssl-verify-server-cert is disabled, because of an insecure passwordless login.'
$ExpectedProductionExeSha256 = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'

$ApprovedFiles = @{
    DatabaseLauncher = @{ Path = $DatabaseLauncher; Sha256 = 'C0EEC81CE8797DDE77685D5639E90AD36892EE473CAD01F8558B6A8C6237336A' }
    MyIni             = @{ Path = $MyIni;             Sha256 = '7039B21A8D50E85511EDF7D5BC2ECD501830AD151D9EF0331243B43ADA4BA9B8' }
    MariaDbServer     = @{ Path = $MariaDbServer;     Sha256 = 'FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7' }
    MariaDbClient     = @{ Path = $MariaDbClient;     Sha256 = '9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95' }
    MariaDbDump       = @{ Path = $MariaDbDump;       Sha256 = 'FD6E467EAA49F166E355A5660952E2488ABB2BE80CB90B2DB229DF7253D24EDB' }
    MariaDbAdmin      = @{ Path = $MariaDbAdmin;      Sha256 = '1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E' }
    ProductionExe     = @{ Path = $ProductionExe;     Sha256 = $ExpectedProductionExeSha256 }
    MangosConfig      = @{ Path = $MangosConfig;      Sha256 = '2078618151892E41FE5059C22030D25A6E34042E02A457CB3E8E7C42399BB144' }
    PlayerbotConfig   = @{ Path = $PlayerbotConfig;   Sha256 = '757D560F87F2280DF8637B0F2CF8FA12C51286DD5451E9C5935AC6A7CC8502D1' }
    StartWorld        = @{ Path = $StartWorld;        Sha256 = '131A0141358D660BAD04AD540BDC170C7CD1B1A99C8AE6AC308EE165B3E6719E' }
    ShutdownHelper    = @{ Path = $ShutdownHelper;    Sha256 = '6582740F7D452EB74ABA368CB70EB33F1683B5511E0169AA0CB98056A2E79884' }
}

$Migrations = @(
    [pscustomobject]@{
        Name = '20260708055500_ai_playerbot_random_bots_index'
        FileName = '20260708055500_ai_playerbot_random_bots_index.sql'
        Source = Join-Path $SourceRoot 'sql\character_updates\20260708055500_ai_playerbot_random_bots_index.sql'
        Sha1 = '61460E23B54A25F909665D7D1AC3DC768A87166C'
        Sha256 = 'AC7DD9663AA1D67D3EA1E16FBBF42FF0334F5A11835357141B80AF211516DB25'
        Execute = $true
    },
    [pscustomobject]@{
        Name = '20260731160000_guild_bank_money_unsigned'
        FileName = '20260731160000_guild_bank_money_unsigned.sql'
        Source = Join-Path $SourceRoot 'sql\character_updates\20260731160000_guild_bank_money_unsigned.sql'
        Sha1 = '24BD0E3575C54EC1709EE37253D4373677322FCB'
        Sha256 = '6542C795D716CD3E70F34E87C9C306C94512253B7AF12E65D205E0B704D3D8A3'
        Execute = $true
    },
    [pscustomobject]@{
        Name = '20260812142512_character_inventory_copy'
        FileName = '20260812142512_character_inventory_copy.sql'
        Source = Join-Path $SourceRoot 'sql\character_updates\20260812142512_character_inventory_copy.sql'
        Sha1 = '8662106E777C548A1349CB813EE1A47DB7A1785E'
        Sha256 = '0E914EF83F73BA08FC7CF539CFEBDDE6BDA4137E7CD84578ADDA378FE2FAA7AD'
        Execute = $true
    },
    [pscustomobject]@{
        Name = '20260817151028_character'
        FileName = '20260817151028_character.sql'
        Source = Join-Path $SourceRoot 'sql\database_updates\character\20260817151028_character.sql'
        Sha1 = '557CE92CFE4B6C0B6E54316EA781459ED26F1B07'
        Sha256 = '916F19DA19C54C04A094FD12D2D7D20CB40786DBFDA40BD8115B590FEE3A49D5'
        Execute = $false
    }
)

$script:RunState = @{
    AdministratorPassed = $false
    InitialCleanStatePassed = $false
    Database = @{
        LaunchAttempted = $false
        LaunchUtc = $null
        LauncherPid = $null
        PreExistingPids = @()
        OwnedPid = $null
        OwnedStartTimeUtcTicks = $null
        ExpectedPath = $MariaDbServer
    }
    World = @{
        LaunchAttempted = $false
        LaunchUtc = $null
        LauncherPid = $null
        PreExistingPids = @()
        OwnedPid = $null
        OwnedStartTimeUtcTicks = $null
        ExpectedPath = $ProductionExe
    }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-Sha1 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToUpperInvariant()
}

function Assert-Hash {
    param([string]$Path, [string]$ExpectedSha256)
    $actual = Get-Sha256 -Path $Path
    if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, found $actual."
    }
}

function Assert-DualHash {
    param([string]$Path, [string]$ExpectedSha1, [string]$ExpectedSha256)
    Assert-Hash -Path $Path -ExpectedSha256 $ExpectedSha256
    $actualSha1 = Get-Sha1 -Path $Path
    if ($actualSha1 -ne $ExpectedSha1.ToUpperInvariant()) {
        throw "SHA-1 mismatch for '$Path'. Expected $ExpectedSha1, found $actualSha1."
    }
}

function Assert-CanonicalScriptFile {
    param([string]$Path, [string]$ExpectedSha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The exact script file cannot be located: $Path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne $ExpectedCanonicalScriptByteCount) {
        throw "Canonical script byte-count mismatch. Expected $ExpectedCanonicalScriptByteCount, found $($bytes.Length)."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'The canonical script must be UTF-8 without BOM.'
    }
    $text = $Utf8NoBom.GetString($bytes)
    for ($i = 0; $i -lt $text.Length; $i++) {
        $code = [int][char]$text[$i]
        if ($code -eq 10 -and ($i -eq 0 -or [int][char]$text[$i - 1] -ne 13)) {
            throw 'The canonical script contains an LF that is not preceded by CR.'
        }
        if ($code -eq 13 -and ($i + 1 -ge $text.Length -or [int][char]$text[$i + 1] -ne 10)) {
            throw 'The canonical script contains a CR that is not followed by LF.'
        }
    }
    Assert-Hash -Path $Path -ExpectedSha256 $ExpectedSha256
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This runbook requires an elevated Windows PowerShell 5.1 session.'
    }
}

function Get-NormalizedPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ProcessPath {
    param([System.Diagnostics.Process]$Process)
    try { return Get-NormalizedPath -Path $Process.Path } catch { return $null }
}

function Get-ProcessCandidates {
    param([ValidateSet('Database', 'World')][string]$Kind)
    $names = if ($Kind -eq 'Database') { @('mysqld', 'mariadbd') } else { @('mangosd') }
    $items = @()
    foreach ($name in $names) {
        $items += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    return @($items)
}

function Test-PortOpen {
    param([int]$Port = $DatabasePort)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect($DatabaseHost, $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($result)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-PortOwnerPids {
    try {
        return @(Get-NetTCPConnection -State Listen -LocalPort $DatabasePort -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique)
    }
    catch { return @() }
}

function Get-ServerStatusLines {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = Get-ProcessPath -Process $process
            if ([string]::IsNullOrWhiteSpace($path)) { $path = '<unavailable>' }
            $lines.Add(("PROCESS name={0} pid={1} path={2}" -f $process.ProcessName, $process.Id, $path))
        }
    }
    if ($lines.Count -eq 0) { $lines.Add('PROCESS none') }
    $portOpen = Test-PortOpen
    $owners = @(Get-PortOwnerPids)
    $ownerText = if ($owners.Count -eq 0) { '<unknown-or-none>' } else { $owners -join ',' }
    $lines.Add(("PORT 3307 open={0} ownerPids={1}" -f $portOpen, $ownerText))
    return @($lines)
}

function Write-ServerStatus {
    param([string]$Prefix = 'STATUS')
    foreach ($line in @(Get-ServerStatusLines)) {
        [Console]::Error.WriteLine(("[{0}] {1}" -f $Prefix, $line))
    }
}

function Assert-NoServerServices {
    $processes = @()
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        $processes += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    if ($processes.Count -gt 0 -or (Test-PortOpen)) {
        throw "The clean-state gate failed. No service was touched. $(@(Get-ServerStatusLines) -join '; ')"
    }
}

function Set-LaunchAttempt {
    param([ValidateSet('Database', 'World')][string]$Kind)
    $state = $script:RunState[$Kind]
    $state.LaunchAttempted = $true
    $state.LaunchUtc = [DateTime]::UtcNow
    $state.LauncherPid = $null
    $state.PreExistingPids = @(Get-ProcessCandidates -Kind $Kind | Select-Object -ExpandProperty Id)
    $state.OwnedPid = $null
    $state.OwnedStartTimeUtcTicks = $null
}

function Set-LauncherPid {
    param([ValidateSet('Database', 'World')][string]$Kind, [int]$ProcessId)
    $script:RunState[$Kind].LauncherPid = $ProcessId
}

function Get-VerifiedOwnedProcess {
    param([ValidateSet('Database', 'World')][string]$Kind)
    $state = $script:RunState[$Kind]
    if ($null -eq $state.OwnedPid -or $null -eq $state.OwnedStartTimeUtcTicks) { return $null }
    $process = Get-Process -Id ([int]$state.OwnedPid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $actualPath = Get-ProcessPath -Process $process
    if ($null -eq $actualPath -or $actualPath -ine (Get-NormalizedPath -Path $state.ExpectedPath)) { return $null }
    try { $ticks = $process.StartTime.ToUniversalTime().Ticks } catch { return $null }
    if ($ticks -ne [long]$state.OwnedStartTimeUtcTicks) { return $null }
    return $process
}

function Try-AdoptLaunchedProcess {
    param([ValidateSet('Database', 'World')][string]$Kind)
    $state = $script:RunState[$Kind]
    if (-not $state.LaunchAttempted -or $null -eq $state.LaunchUtc -or $null -eq $state.LauncherPid) { return $null }
    $eligible = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-ProcessCandidates -Kind $Kind)) {
        if ($state.PreExistingPids -contains $process.Id) { continue }
        $path = Get-ProcessPath -Process $process
        if ($null -eq $path -or $path -ine (Get-NormalizedPath -Path $state.ExpectedPath)) { continue }
        try {
            $startUtc = $process.StartTime.ToUniversalTime()
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $process.Id) -ErrorAction Stop
        }
        catch { continue }
        if ($startUtc -lt $state.LaunchUtc.AddSeconds(-2)) { continue }
        if ([int]$cim.ParentProcessId -ne [int]$state.LauncherPid) { continue }
        $eligible.Add([pscustomobject]@{ Process = $process; StartUtc = $startUtc })
    }
    if ($eligible.Count -gt 1) { throw "$Kind launch ownership is ambiguous." }
    if ($eligible.Count -eq 0) { return $null }
    $state.OwnedPid = $eligible[0].Process.Id
    $state.OwnedStartTimeUtcTicks = $eligible[0].StartUtc.Ticks
    return Get-VerifiedOwnedProcess -Kind $Kind
}

function Wait-ForOwnedProcess {
    param([ValidateSet('Database', 'World')][string]$Kind, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $owned = Get-VerifiedOwnedProcess -Kind $Kind
        if ($null -ne $owned) { return $owned }
        $owned = Try-AdoptLaunchedProcess -Kind $Kind
        if ($null -ne $owned) { return $owned }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Kind did not produce one uniquely attributable process within $TimeoutSeconds seconds."
}

function Wait-ForProcessExit {
    param([int]$ProcessId, [long]$StartTimeUtcTicks, [int]$TimeoutSeconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return }
        try {
            if ($process.StartTime.ToUniversalTime().Ticks -ne $StartTimeUtcTicks) { return }
        }
        catch { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Process PID $ProcessId did not exit within $TimeoutSeconds seconds."
}

function Assert-DatabaseProgramFiles {
    foreach ($key in @('DatabaseLauncher', 'MariaDbServer', 'MariaDbClient', 'MariaDbAdmin')) {
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
    }
}

function Assert-RestoredDatabaseConfiguration {
    Assert-Hash -Path $MyIni -ExpectedSha256 $ApprovedFiles.MyIni.Sha256
}

function Assert-DatabaseRuntimeFiles {
    Assert-DatabaseProgramFiles
    Assert-RestoredDatabaseConfiguration
    Assert-Hash -Path $MariaDbDump -ExpectedSha256 $ApprovedFiles.MariaDbDump.Sha256
}

function Assert-PlayerbotLlmDisabled {
    if (-not (Test-Path -LiteralPath $PlayerbotConfig -PathType Leaf)) {
        throw "Playerbot configuration is missing: $PlayerbotConfig"
    }
    $required = @{
        'AiPlayerbot.LLMEnabled' = '0'
        'AiPlayerbot.LLMBotToBotChatChance' = '0'
        'AiPlayerbot.LLMRpgAIChatChance' = '0'
    }
    $lines = Get-Content -LiteralPath $PlayerbotConfig
    foreach ($name in $required.Keys) {
        $matches = @($lines | Where-Object { $_ -match ('^\s*{0}\s*=\s*(\S+)\s*$' -f [regex]::Escape($name)) })
        if ($matches.Count -ne 1) { throw "Expected exactly one active '$name' setting." }
        $value = [regex]::Match($matches[0], '=\s*(\S+)\s*$').Groups[1].Value
        if ($value -ne '0') { throw "$name must remain 0 for this controlled run." }
    }
}

function Assert-WorldRuntimeFiles {
    foreach ($key in @('ProductionExe', 'MangosConfig', 'PlayerbotConfig', 'StartWorld', 'ShutdownHelper')) {
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
    }
    Assert-PlayerbotLlmDisabled
}

function Assert-SourceMigrationFiles {
    foreach ($migration in $Migrations) {
        Assert-DualHash -Path $migration.Source -ExpectedSha1 $migration.Sha1 -ExpectedSha256 $migration.Sha256
    }
}

function Assert-StagedMigrationFiles {
    param([string]$MigrationDirectory)
    foreach ($migration in $Migrations) {
        $staged = Join-Path $MigrationDirectory $migration.FileName
        Assert-DualHash -Path $staged -ExpectedSha1 $migration.Sha1 -ExpectedSha256 $migration.Sha256
    }
}

function Resolve-MariaDbClientResult {
    param(
        [AllowEmptyString()][string]$Stdout,
        [AllowEmptyString()][string]$Stderr,
        [int]$ExitCode,
        [switch]$AllowEmpty
    )

    $stdoutText = if ($null -eq $Stdout) { '' } else { $Stdout.Trim() }
    $stderrText = if ($null -eq $Stderr) { '' } else { $Stderr.Trim() }

    if ($ExitCode -ne 0) {
        $diagnostic = if ([string]::IsNullOrWhiteSpace($stderrText)) { '<empty>' } else { $stderrText }
        throw "MariaDB client failed with exit code $ExitCode. stderr: $diagnostic"
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        if ($stderrText -cne $MariaDbPasswordlessTlsWarning) {
            throw "MariaDB client returned unexpected stderr on successful exit: $stderrText"
        }
        [Console]::Error.WriteLine("[ACCEPTED MARIADB CLIENT WARNING] $stderrText")
    }

    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($stdoutText)) {
        throw 'MariaDB query unexpectedly returned no output.'
    }
    return $stdoutText
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) { $Argument = '' }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-ProcessWithCapturedOutput {
    param([string]$FilePath, [string[]]$ArgumentList)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $Utf8NoBom
    $startInfo.StandardErrorEncoding = $Utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Process did not start: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
            ExitCode = $process.ExitCode
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MariaDb {
    param([string]$Sql, [switch]$AllowEmpty)
    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--batch', '--raw', '--skip-column-names', '--default-character-set=utf8mb4',
        "--database=$DatabaseName", "--execute=$Sql"
    )

    $result = Invoke-ProcessWithCapturedOutput -FilePath $MariaDbClient -ArgumentList $arguments
    return Resolve-MariaDbClientResult -Stdout $result.Stdout -Stderr $result.Stderr -ExitCode $result.ExitCode -AllowEmpty:$AllowEmpty
}

function Invoke-MariaDbExport {
    param([string]$Sql, [string]$OutputPath)
    $executeArgument = '--execute="' + $Sql + '"'
    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--batch', '--raw', '--skip-column-names', '--default-character-set=utf8mb4',
        "--database=$DatabaseName", $executeArgument
    )
    $stderr = "$OutputPath.stderr.log"
    $process = Start-Process -FilePath $MariaDbClient -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $OutputPath -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        throw "Database export failed with exit code $($process.ExitCode). See $stderr."
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Database export did not create $OutputPath."
    }
}

function Invoke-SqlFile {
    param([string]$SqlPath, [string]$StdoutPath, [string]$StderrPath)
    $client = $MariaDbClient.Replace('"', '""')
    $escapedInput = $SqlPath.Replace('"', '""')
    $command = ('""{0}" --protocol=TCP --host={1} --port={2} --user={3} --default-character-set=utf8mb4 --database={4} < "{5}""' -f
        $client, $DatabaseHost, $DatabasePort, $DatabaseUser, $DatabaseName, $escapedInput)
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', $command) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    if ($process.ExitCode -ne 0) {
        throw "Migration client failed with exit code $($process.ExitCode). See $StdoutPath and $StderrPath."
    }
}

function Assert-SingleValue {
    param([string]$Sql, [string]$Expected, [string]$Description)
    $actual = Invoke-MariaDb -Sql $Sql
    if ($actual -ne $Expected) {
        throw "$Description failed. Expected '$Expected', found '$actual'."
    }
}

function Assert-DatabaseIdentity {
    Assert-SingleValue -Sql 'SELECT DATABASE()' -Expected $DatabaseName -Description 'Selected database identity'
}

function Assert-RecordedOfflineSchema {
    Assert-DatabaseIdentity
    $sql = @'
SELECT CONCAT_WS('|',
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_inventory'),
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_inventory_copy'),
 (SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='ai_playerbot_random_bots' AND index_name='idx_owner_bot_event'),
 (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='guild_bank_money' AND column_name='money' AND data_type='int' AND column_type NOT LIKE '%unsigned%' AND is_nullable='NO' AND CAST(column_default AS CHAR)='0'),
 (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='migrations' AND column_name='Module'),
 (SELECT COUNT(*) FROM migrations),
 (SELECT COUNT(*) FROM saved_variables sv WHERE sv.key=0 AND sv.honorMaintenanceMarker=1)
)
'@
    $actual = Invoke-MariaDb -Sql $sql
    if ($actual -ne '1|0|0|1|0|0|1') {
        throw "Live preflight differs from the recorded offline schema. Found '$actual'."
    }
}

function Assert-MigrationsModuleColumn {
    $sql = @'
SELECT COALESCE((
  SELECT CONCAT_WS('|',
    COLUMN_NAME,
    DATA_TYPE,
    COLUMN_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE,
    COALESCE(HEX(COLUMN_DEFAULT),'<NULL>'),
    CHARACTER_SET_NAME,
    COLLATION_NAME,
    ORDINAL_POSITION
  )
  FROM information_schema.columns
  WHERE table_schema=DATABASE()
    AND table_name='migrations'
    AND column_name='Module'
),'<missing>')
'@

    $expected = 'Module|varchar|varchar(255)|255|NO|2727|utf8mb3|utf8mb3_general_ci|3'
    $actual = Invoke-MariaDb -Sql $sql
    if ($actual -cne $expected) {
        throw "migrations.Module exact definition failed. Expected '$expected', found '$actual'."
    }
}

function Enable-MigrationsModuleColumn {
    [void](Invoke-MariaDb -Sql "ALTER TABLE migrations ADD COLUMN Module VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci' AFTER Name" -AllowEmpty)
    Assert-MigrationsModuleColumn
}

function Register-Migration {
    param($Migration)
    $name = $Migration.Name.Replace("'", "''")
    $hash = $Migration.Sha1.Replace("'", "''")
    [void](Invoke-MariaDb -Sql "INSERT INTO migrations (Name, Hash, Module, AppliedAt) VALUES ('$name', '$hash', '', UTC_TIMESTAMP())" -AllowEmpty)
    Assert-SingleValue -Sql "SELECT COUNT(*) FROM migrations WHERE Name='$name' AND UPPER(Hash)='$hash' AND Module=''" -Expected '1' -Description "Tracking row for $($Migration.Name)"
}

function Assert-IndexMigrationEffect {
    $sql = @'
SELECT CONCAT(
  COUNT(DISTINCT index_name),'|',
  COUNT(*),'|',
  MIN(non_unique),'|',
  MAX(non_unique),'|',
  COUNT(DISTINCT index_type),'|',
  MIN(index_type),'|',
  COALESCE(GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR ','),'')
)
FROM information_schema.statistics
WHERE table_schema=DATABASE()
  AND table_name='ai_playerbot_random_bots'
  AND index_name='idx_owner_bot_event'
'@
    Assert-SingleValue -Sql $sql -Expected '1|3|1|1|1|BTREE|owner,bot,event' -Description 'idx_owner_bot_event exact non-unique BTREE definition'
}

function Assert-GuildMoneySchema {
    $sql = @'
SELECT COUNT(*) FROM information_schema.columns
WHERE table_schema=DATABASE() AND table_name='guild_bank_money' AND column_name='money'
  AND data_type='int' AND column_type LIKE '%unsigned%' AND is_nullable='NO'
  AND CAST(column_default AS CHAR)='0'
'@
    Assert-SingleValue -Sql $sql -Expected '1' -Description 'guild_bank_money.money unsigned definition'
}

function Normalize-CreateTable {
    param([string]$Definition, [string[]]$TableNames = @())
    $value = $Definition
    foreach ($name in $TableNames) {
        $value = [regex]::Replace($value, "(?i)\b$([regex]::Escape($name))\b", '<table>')
    }
    $value = [regex]::Replace($value, '(?i)CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS', 'CREATE TABLE')
    $value = $value.Replace([char]96, '')
    $value = [regex]::Replace($value, '(?i)\s+AUTO_INCREMENT=\d+', '')
    $value = [regex]::Replace($value, '\s+', ' ')
    return $value.Trim().TrimEnd(';').Trim().ToLowerInvariant()
}

function Get-ShowCreateDefinition {
    param([string]$Table)
    $tick = [char]96
    $result = Invoke-MariaDb -Sql ("SHOW CREATE TABLE {0}{1}{0}" -f $tick, $Table)
    $parts = $result -split ([string][char]9), 2
    if ($parts.Count -ne 2) { throw "Unexpected SHOW CREATE TABLE output for $Table." }
    return $parts[1]
}

function Assert-InventoryCopySchema {
    Assert-SingleValue -Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_inventory_copy'" -Expected '1' -Description 'character_inventory_copy existence'
    $source = Normalize-CreateTable -Definition (Get-ShowCreateDefinition -Table 'character_inventory') -TableNames @('character_inventory')
    $copy = Normalize-CreateTable -Definition (Get-ShowCreateDefinition -Table 'character_inventory_copy') -TableNames @('character_inventory_copy')
    if ($source -ne $copy) { throw 'Normalized character_inventory_copy does not match character_inventory.' }
    Assert-SingleValue -Sql 'SELECT COUNT(*) FROM character_inventory_copy' -Expected '0' -Description 'character_inventory_copy pre-start row count'
}

function Assert-PvpCurrencyMaterialized {
    param([string]$StagedMigrationPath)
    $sqlText = $Utf8NoBom.GetString([System.IO.File]::ReadAllBytes($StagedMigrationPath))
    $match = [regex]::Match($sqlText, '(?is)CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+.+?;\s*$')
    if (-not $match.Success) { throw 'The staged pvp migration has no expected CREATE TABLE statement.' }
    $expected = Normalize-CreateTable -Definition $match.Value -TableNames @('character_pvp_currency')
    $actual = Normalize-CreateTable -Definition (Get-ShowCreateDefinition -Table 'character_pvp_currency') -TableNames @('character_pvp_currency')
    if ($actual -ne $expected) {
        throw 'The live character_pvp_currency definition does not match the staged committed migration.'
    }
}

function Assert-FinalMigrationTracking {
    $expected = @($Migrations | ForEach-Object { "$($_.Name)|$($_.Sha1)|" })
    $actual = @((Invoke-MariaDb -Sql 'SELECT CONCAT(Name,''|'',UPPER(Hash),''|'',Module) FROM migrations ORDER BY Name') -split "\r?\n")
    if ($actual.Count -ne 4) { throw "Expected four tracking rows, found $($actual.Count)." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            throw "Migration tracking mismatch at row $i."
        }
    }
}

function Get-TreeManifestLines {
    param([string]$Directory)
    $rootPath = Get-NormalizedPath -Path $Directory
    foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        "{0}|{1}|{2}" -f $relative, $file.Length, $hash
    }
}

function Get-AclManifestLines {
    param([string]$Directory)
    $rootPath = Get-NormalizedPath -Path $Directory
    $entries = @((Get-Item -LiteralPath $rootPath -Force)) + @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force)
    foreach ($entry in @($entries | Sort-Object FullName)) {
        $relative = if ($entry.FullName -eq $rootPath) { '.' } else { $entry.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/') }
        $type = if ($entry.PSIsContainer) { 'D' } else { 'F' }
        "{0}|{1}|{2}" -f $type, $relative, (Get-Acl -LiteralPath $entry.FullName -Audit -ErrorAction Stop).Sddl
    }
}

function Write-Utf8Lines {
    param([string]$Path, [AllowEmptyCollection()][string[]]$Lines)
    $crlf = ([string][char]13) + ([string][char]10)
    $content = if ($Lines.Count -eq 0) { '' } else { ($Lines -join $crlf) + $crlf }
    [System.IO.File]::WriteAllText($Path, $content, $Utf8NoBom)
}

function New-TreeManifest {
    param([string]$Directory, [string]$ManifestPath)
    Write-Utf8Lines -Path $ManifestPath -Lines @(Get-TreeManifestLines -Directory $Directory)
    if ((Get-Item -LiteralPath $ManifestPath).Length -eq 0) { throw "Manifest is empty: $ManifestPath" }
}

function New-AclManifest {
    param([string]$Directory, [string]$ManifestPath)
    Write-Utf8Lines -Path $ManifestPath -Lines @(Get-AclManifestLines -Directory $Directory)
}

function Assert-ManifestMatchesDirectory {
    param([string]$ManifestPath, [string]$Directory)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Manifest is missing: $ManifestPath" }
    $expected = @(Get-Content -LiteralPath $ManifestPath)
    $actual = @(Get-TreeManifestLines -Directory $Directory)
    if ($expected.Count -ne $actual.Count) { throw "Manifest count differs for $Directory." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -cne $actual[$i]) { throw "Manifest mismatch for $Directory at line $($i + 1)." }
    }
}

function Assert-AclManifestMatchesDirectory {
    param([string]$ManifestPath, [string]$Directory)
    $expected = @(Get-Content -LiteralPath $ManifestPath)
    $actual = @(Get-AclManifestLines -Directory $Directory)
    if ($expected.Count -ne $actual.Count) { throw "ACL manifest count differs for $Directory." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i] -cne $actual[$i]) { throw "ACL manifest mismatch for $Directory at line $($i + 1)." }
    }
}

function ConvertTo-UnsignedAccessMask {
    param([int]$AccessMask)
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$AccessMask), 0)
}

function Resolve-FileSystemAccessMask {
    param([int]$AccessMask)
    $value = ConvertTo-UnsignedAccessMask -AccessMask $AccessMask
    $genericRead = [uint32]2147483648
    $genericWrite = [uint32]1073741824
    $genericExecute = [uint32]536870912
    $genericAll = [uint32]268435456
    $resolved = [uint32]($value -band [uint32]268435455)
    if (($value -band $genericRead) -ne 0) { $resolved = [uint32]($resolved -bor [uint32]1179785) }
    if (($value -band $genericWrite) -ne 0) { $resolved = [uint32]($resolved -bor [uint32]1179926) }
    if (($value -band $genericExecute) -ne 0) { $resolved = [uint32]($resolved -bor [uint32]1179808) }
    if (($value -band $genericAll) -ne 0) { $resolved = [uint32]($resolved -bor [uint32]2032127) }
    return $resolved
}

function ConvertTo-NormalizedAclRelativePath {
    param([string]$Relative, [string]$Context)
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Empty ACL manifest path in $Context." }
    if ($Relative -eq '.') { return '.' }
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw "Unsafe rooted or drive-qualified ACL path in ${Context}: $Relative"
    }
    $normalized = $Relative.Replace('\', '/')
    $segments = @([regex]::Split($normalized, '/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Unsafe or non-normalized ACL path in ${Context}: $Relative"
    }
    return ($segments -join '/')
}

function ConvertFrom-AclManifestLine {
    param([string]$Line, [string]$Context)
    $match = [regex]::Match($Line, '^(D|F)\|([^|]+)\|(.+)$')
    if (-not $match.Success) { throw "Malformed ACL manifest line in ${Context}: $Line" }
    $relative = ConvertTo-NormalizedAclRelativePath -Relative $match.Groups[2].Value -Context $Context
    try {
        $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($match.Groups[3].Value)
    }
    catch {
        throw "Invalid SDDL in ${Context} for '$relative': $($_.Exception.Message)"
    }
    if ($null -eq $descriptor.Owner -or $null -eq $descriptor.Group) {
        throw "ACL manifest entry lacks an owner or group SID in ${Context}: $relative"
    }
    return [pscustomobject]@{
        Type = $match.Groups[1].Value
        Relative = $relative
        Sddl = $match.Groups[3].Value
        Descriptor = $descriptor
    }
}

function Get-AclManifestEntries {
    param([string[]]$Lines, [string]$Context)
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $Lines) {
        $entry = ConvertFrom-AclManifestLine -Line $line -Context $Context
        if (-not $seen.Add($entry.Relative)) { throw "Duplicate case-insensitive ACL manifest path in ${Context}: $($entry.Relative)" }
        $entries.Add($entry)
    }
    return $entries.ToArray()
}

function Add-AclSemanticToken {
    param(
        [hashtable]$Aggregates,
        [hashtable]$ScopeRecords,
        [hashtable]$SidSet,
        [string]$Scope,
        [string]$Qualifier,
        [string]$Sid,
        [uint32]$Mask
    )
    if ($Mask -eq 0) { throw "An ACE for SID '$Sid' has a zero effective access mask." }
    $SidSet[$Sid] = $true
    $key = "$Scope|$Qualifier|$Sid"
    if ($Aggregates.ContainsKey($key)) {
        $Aggregates[$key] = [uint32]([uint32]$Aggregates[$key] -bor $Mask)
    }
    else {
        $Aggregates[$key] = $Mask
    }
    if (-not $ScopeRecords.ContainsKey($Scope)) {
        $ScopeRecords[$Scope] = New-Object System.Collections.ArrayList
    }
    [void]$ScopeRecords[$Scope].Add([pscustomobject]@{ Qualifier = $Qualifier; Sid = $Sid; Mask = $Mask })
}

function Get-AclSemanticModel {
    param(
        [AllowNull()][Security.AccessControl.GenericAcl]$Acl,
        [bool]$IsDirectory,
        [ValidateSet('DACL', 'SACL')][string]$Kind,
        [string]$Context
    )
    if ($null -eq $Acl) {
        return [pscustomobject]@{ Present = $false; Entries = @(); OrderBlocks = @(); Sids = @() }
    }
    $aggregates = @{}
    $scopeRecords = @{}
    $sidSet = @{}
    $knownInheritanceFlags = 1 -bor 2 -bor 4 -bor 8 -bor 16
    $knownAuditFlags = 64 -bor 128
    for ($aceIndex = 0; $aceIndex -lt $Acl.Count; $aceIndex++) {
        $ace = $Acl[$aceIndex]
        if (-not ($ace -is [Security.AccessControl.CommonAce])) {
            throw "Unsupported ACE type '$($ace.GetType().FullName)' in $Kind for $Context."
        }
        if ($null -eq $ace.SecurityIdentifier) { throw "An ACE has no SID in $Kind for $Context." }
        $sid = $ace.SecurityIdentifier.Value
        $flagValue = [int]$ace.AceFlags
        $allowedFlags = if ($Kind -eq 'SACL') { $knownInheritanceFlags -bor $knownAuditFlags } else { $knownInheritanceFlags }
        if (($flagValue -band (-bnot $allowedFlags)) -ne 0) {
            throw "Unsupported ACE flags '$($ace.AceFlags)' in $Kind for $Context."
        }
        $qualifiers = @()
        if ($Kind -eq 'DACL') {
            if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed) { $qualifiers = @('Allow') }
            elseif ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied) { $qualifiers = @('Deny') }
            else { throw "Unsupported DACL ACE qualifier '$($ace.AceQualifier)' for $Context." }
        }
        else {
            if ($ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::SystemAudit) {
                throw "Unsupported SACL ACE qualifier '$($ace.AceQualifier)' for $Context."
            }
            $auditSuccess = ($flagValue -band 64) -ne 0
            $auditFailure = ($flagValue -band 128) -ne 0
            if (-not $auditSuccess -and -not $auditFailure) { throw "A SACL ACE has no audit outcome for $Context." }
            if ($auditSuccess -and $auditFailure) { $qualifiers = @('AuditSuccessFailure') }
            elseif ($auditSuccess) { $qualifiers = @('AuditSuccess') }
            else { $qualifiers = @('AuditFailure') }
        }
        $objectInherit = ($flagValue -band 1) -ne 0
        $containerInherit = ($flagValue -band 2) -ne 0
        $noPropagate = ($flagValue -band 4) -ne 0
        $inheritOnly = ($flagValue -band 8) -ne 0
        if (-not $IsDirectory -and ($objectInherit -or $containerInherit -or $noPropagate -or $inheritOnly)) {
            throw "A file ACE has unresolved inheritance flags in $Kind for $Context."
        }
        if ($IsDirectory -and ($noPropagate -or $inheritOnly) -and -not ($objectInherit -or $containerInherit)) {
            throw "An ACE has inheritance-control flags without OI or CI in $Kind for $Context."
        }
        $scopes = New-Object System.Collections.Generic.List[string]
        if (-not $inheritOnly) { $scopes.Add('Self') }
        if ($IsDirectory -and $objectInherit) { $scopes.Add($(if ($noPropagate) { 'File:Direct' } else { 'File:AllDescendants' })) }
        if ($IsDirectory -and $containerInherit) { $scopes.Add($(if ($noPropagate) { 'Directory:Direct' } else { 'Directory:AllDescendants' })) }
        if ($scopes.Count -eq 0) { throw "An ACE has no resolved semantic scope in $Kind for $Context." }
        $mask = Resolve-FileSystemAccessMask -AccessMask $ace.AccessMask
        foreach ($qualifier in $qualifiers) {
            foreach ($scope in $scopes) {
                Add-AclSemanticToken -Aggregates $aggregates -ScopeRecords $scopeRecords -SidSet $sidSet -Scope $scope -Qualifier $qualifier -Sid $sid -Mask $mask
            }
        }
    }
    $entries = @($aggregates.Keys | Sort-Object | ForEach-Object { "$_|{0:X8}" -f [uint32]$aggregates[$_] })
    $orderBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($scope in @($scopeRecords.Keys | Sort-Object)) {
        $currentQualifier = $null
        $blockIndex = -1
        $block = @{}
        foreach ($record in @($scopeRecords[$scope])) {
            if ($null -ne $currentQualifier -and $record.Qualifier -cne $currentQualifier) {
                foreach ($key in @($block.Keys | Sort-Object)) {
                    $orderBlocks.Add("$scope|$blockIndex|$currentQualifier|$key|{0:X8}" -f [uint32]$block[$key])
                }
                $block = @{}
            }
            if ($null -eq $currentQualifier -or $record.Qualifier -cne $currentQualifier) {
                $blockIndex++
                $currentQualifier = $record.Qualifier
            }
            if ($block.ContainsKey($record.Sid)) { $block[$record.Sid] = [uint32]([uint32]$block[$record.Sid] -bor [uint32]$record.Mask) }
            else { $block[$record.Sid] = [uint32]$record.Mask }
        }
        if ($null -ne $currentQualifier) {
            foreach ($key in @($block.Keys | Sort-Object)) {
                $orderBlocks.Add("$scope|$blockIndex|$currentQualifier|$key|{0:X8}" -f [uint32]$block[$key])
            }
        }
    }
    return [pscustomobject]@{
        Present = $true
        Entries = $entries
        OrderBlocks = $orderBlocks.ToArray()
        Sids = @($sidSet.Keys | Sort-Object)
    }
}

function Assert-StringArrayEqual {
    param([string[]]$Expected, [string[]]$Actual, [string]$Description)
    if ($Expected.Count -ne $Actual.Count) { throw "$Description count differs. Expected=$($Expected.Count), actual=$($Actual.Count)." }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($Expected[$i] -cne $Actual[$i]) { throw "$Description differs at index $i. Expected='$($Expected[$i])', actual='$($Actual[$i])'." }
    }
}

function Assert-SecurityDescriptorSemanticallyEquivalent {
    param(
        [Security.AccessControl.RawSecurityDescriptor]$Expected,
        [Security.AccessControl.RawSecurityDescriptor]$Actual,
        [bool]$IsDirectory,
        [string]$Context
    )
    if ($Expected.Owner.Value -cne $Actual.Owner.Value) { throw "Owner SID differs for ${Context}. Expected=$($Expected.Owner.Value), actual=$($Actual.Owner.Value)." }
    if ($Expected.Group.Value -cne $Actual.Group.Value) { throw "Group SID differs for ${Context}. Expected=$($Expected.Group.Value), actual=$($Actual.Group.Value)." }
    $expectedDaclProtected = ($Expected.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
    $actualDaclProtected = ($Actual.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
    if ($expectedDaclProtected -ne $actualDaclProtected) { throw "DACL protection differs for $Context." }
    $expectedSaclPresent = $null -ne $Expected.SystemAcl
    $actualSaclPresent = $null -ne $Actual.SystemAcl
    if ($expectedSaclPresent -ne $actualSaclPresent) { throw "SACL presence differs for $Context." }
    $ignoredFlags = [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited
    $expectedControl = ([int]$Expected.ControlFlags) -band (-bnot $ignoredFlags)
    $actualControl = ([int]$Actual.ControlFlags) -band (-bnot $ignoredFlags)
    if ($expectedControl -ne $actualControl) { throw "Security descriptor control flags differ for $Context after the permitted AutoInherited normalization." }
    if (($Expected.ControlFlags -band [Security.AccessControl.ControlFlags]::RMControlValid) -ne 0 -and $Expected.ResourceManagerControl -ne $Actual.ResourceManagerControl) {
        throw "Resource manager control differs for $Context."
    }
    $expectedDacl = Get-AclSemanticModel -Acl $Expected.DiscretionaryAcl -IsDirectory $IsDirectory -Kind DACL -Context $Context
    $actualDacl = Get-AclSemanticModel -Acl $Actual.DiscretionaryAcl -IsDirectory $IsDirectory -Kind DACL -Context $Context
    if ($expectedDacl.Present -ne $actualDacl.Present) { throw "DACL presence differs for $Context." }
    Assert-StringArrayEqual -Expected $expectedDacl.Sids -Actual $actualDacl.Sids -Description "DACL SID set for $Context"
    Assert-StringArrayEqual -Expected $expectedDacl.Entries -Actual $actualDacl.Entries -Description "DACL permissions and inheritance semantics for $Context"
    Assert-StringArrayEqual -Expected $expectedDacl.OrderBlocks -Actual $actualDacl.OrderBlocks -Description "DACL security-relevant ACE ordering for $Context"
    if ($expectedSaclPresent) {
        $expectedSacl = Get-AclSemanticModel -Acl $Expected.SystemAcl -IsDirectory $IsDirectory -Kind SACL -Context $Context
        $actualSacl = Get-AclSemanticModel -Acl $Actual.SystemAcl -IsDirectory $IsDirectory -Kind SACL -Context $Context
        Assert-StringArrayEqual -Expected $expectedSacl.Sids -Actual $actualSacl.Sids -Description "SACL SID set for $Context"
        Assert-StringArrayEqual -Expected $expectedSacl.Entries -Actual $actualSacl.Entries -Description "SACL semantics for $Context"
        Assert-StringArrayEqual -Expected $expectedSacl.OrderBlocks -Actual $actualSacl.OrderBlocks -Description "SACL ordering for $Context"
    }
}

function Assert-SemanticAclLinesEquivalent {
    param([string[]]$ExpectedLines, [string[]]$ActualLines, [string]$Context)
    $expected = @(Get-AclManifestEntries -Lines $ExpectedLines -Context "$Context expected ACL manifest")
    $actual = @(Get-AclManifestEntries -Lines $ActualLines -Context "$Context actual ACL manifest")
    if ($expected.Count -ne $actual.Count) { throw "Semantic ACL object count differs for $Context. Expected=$($expected.Count), actual=$($actual.Count)." }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($expected[$i].Relative -cne $actual[$i].Relative) { throw "Relative ACL path differs for $Context at index $i." }
        if ($expected[$i].Type -cne $actual[$i].Type) { throw "ACL object type differs for $Context at '$($expected[$i].Relative)'." }
        Assert-SecurityDescriptorSemanticallyEquivalent -Expected $expected[$i].Descriptor -Actual $actual[$i].Descriptor -IsDirectory ($expected[$i].Type -eq 'D') -Context "$Context path '$($expected[$i].Relative)'"
    }
}

function Assert-SemanticAclManifestMatchesDirectory {
    param([string]$ManifestPath, [string]$Directory)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "ACL manifest is missing: $ManifestPath" }
    Assert-SemanticAclLinesEquivalent -ExpectedLines @(Get-Content -LiteralPath $ManifestPath) -ActualLines @(Get-AclManifestLines -Directory $Directory) -Context $Directory
}

function Resolve-AclManifestPath {
    param([string]$Root, [object]$Entry)
    $rootPath = Get-NormalizedPath -Path $Root
    $relative = ConvertTo-NormalizedAclRelativePath -Relative ([string]$Entry.Relative) -Context "ACL path resolution below '$rootPath'"
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "ACL restore root is a reparse point: $rootPath" }
    if ($relative -eq '.') { return $rootPath }
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $relative.Replace('/', '\')))
    if (-not $candidate.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "ACL manifest path escapes the restore root: $relative"
    }
    $current = $rootPath
    foreach ($segment in @($relative -split '/')) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "ACL manifest path traverses a reparse point: $current"
        }
    }
    return $candidate
}

function Assert-AclManifestCoverage {
    param([string]$ManifestPath, [string]$Directory)
    Assert-NoReparsePoints -Directory $Directory
    $entries = @(Get-AclManifestEntries -Lines @(Get-Content -LiteralPath $ManifestPath) -Context $ManifestPath)
    $rootPath = Get-NormalizedPath -Path $Directory
    $items = @((Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop)) + @(Get-ChildItem -LiteralPath $rootPath -Force -Recurse -ErrorAction Stop)
    $tree = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $relative = if ($item.FullName -eq $rootPath) { '.' } else { $item.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/') }
        $relative = ConvertTo-NormalizedAclRelativePath -Relative $relative -Context "target tree '$Directory'"
        $type = if ($item.PSIsContainer) { 'D' } else { 'F' }
        if ($tree.ContainsKey($relative)) { throw "Duplicate case-insensitive target path before ACL application: $relative" }
        $tree.Add($relative, $type)
    }
    if ($entries.Count -ne $tree.Count) {
        throw "ACL manifest coverage count differs before ACL application. Manifest=$($entries.Count), target=$($tree.Count)."
    }
    $manifestPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        [void]$manifestPaths.Add($entry.Relative)
        if (-not $tree.ContainsKey($entry.Relative)) { throw "ACL manifest path is missing from the target before ACL application: $($entry.Relative)" }
        if ($tree[$entry.Relative] -cne $entry.Type) { throw "ACL manifest object type differs before ACL application at '$($entry.Relative)'." }
    }
    foreach ($relative in $tree.Keys) {
        if (-not $manifestPaths.Contains($relative)) { throw "Additional target path exists before ACL application: $relative" }
    }
    return $entries
}

function Set-AclManifestOnDirectory {
    param([string]$ManifestPath, [string]$Directory)
    $entries = @(Assert-AclManifestCoverage -ManifestPath $ManifestPath -Directory $Directory)
    $ordered = @($entries | Sort-Object @{ Expression = { if ($_.Relative -eq '.') { -1 } else { ($_.Relative -split '/').Count } } }, @{ Expression = { if ($_.Type -eq 'D') { 0 } else { 1 } } }, Relative)
    foreach ($entry in $ordered) {
        $path = Resolve-AclManifestPath -Root $Directory -Entry $entry
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($entry.Type -eq 'D') -ne $item.PSIsContainer) { throw "ACL manifest object type mismatch while applying '$($entry.Relative)'." }
        $security = if ($entry.Type -eq 'D') { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $security.SetSecurityDescriptorSddlForm($entry.Sddl, [Security.AccessControl.AccessControlSections]::All)
        Set-Acl -LiteralPath $path -AclObject $security -ErrorAction Stop
    }
}

function Assert-NoReparsePoints {
    param([string]$Directory)
    $root = Get-Item -LiteralPath $Directory -Force -ErrorAction Stop
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point found at protected tree root: $($root.FullName)" }
    $queue = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point found below protected tree: $($item.FullName)" }
            if ($item.PSIsContainer) { $queue.Enqueue($item) }
        }
    }
}

function Invoke-RobocopyVerified {
    param([string]$Source, [string]$Destination)
    & robocopy.exe $Source $Destination /MIR /COPYALL /DCOPY:DAT /R:1 /W:1 /XJ /NP /NFL /NDL
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed with exit code $LASTEXITCODE." }
}

function Copy-RootAcl {
    param([string]$Source, [string]$Destination)
    $sourceAcl = Get-Acl -LiteralPath $Source -Audit -ErrorAction Stop
    Set-Acl -LiteralPath $Destination -AclObject $sourceAcl -ErrorAction Stop
    $sourceRoot = ConvertFrom-AclManifestLine -Line ((Get-AclManifestLines -Directory $Source) | Select-Object -First 1) -Context $Source
    $destinationRoot = ConvertFrom-AclManifestLine -Line ((Get-AclManifestLines -Directory $Destination) | Select-Object -First 1) -Context $Destination
    Assert-SecurityDescriptorSemanticallyEquivalent -Expected $sourceRoot.Descriptor -Actual $destinationRoot.Descriptor -IsDirectory $true -Context "root ACL between '$Source' and '$Destination'"
}

function Get-ExistingStoragePath {
    param([string]$Path)
    $current = [System.IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "No existing storage ancestor was found for $Path."
        }
        $current = $parent
    }
    return $current
}

function Get-PhysicalDiskIdentity {
    param([string]$Path)
    $existing = Get-ExistingStoragePath -Path $Path
    $root = [System.IO.Path]::GetPathRoot((Get-NormalizedPath -Path $existing))
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "Storage mapping requires a local drive-letter path: $Path"
    }
    $driveLetter = $root.Substring(0, 1)
    $partition = @(Get-Partition -DriveLetter $driveLetter -ErrorAction Stop)
    if ($partition.Count -ne 1) {
        throw "Drive $driveLetter has an ambiguous partition mapping."
    }
    $disk = Get-Disk -Number $partition[0].DiskNumber -ErrorAction Stop
    $uniqueId = if ($null -eq $disk.UniqueId) { '' } else { ([string]$disk.UniqueId).Trim() }
    return [pscustomobject]@{
        Path = Get-NormalizedPath -Path $existing
        DriveLetter = $driveLetter
        DiskNumber = [int]$disk.Number
        UniqueId = $uniqueId
        SerialNumber = if ($null -eq $disk.SerialNumber) { '' } else { ([string]$disk.SerialNumber).Trim() }
        FriendlyName = [string]$disk.FriendlyName
    }
}

function Assert-DifferentPhysicalDisks {
    param([string]$ActivePath, [string]$BackupPath)
    $active = Get-PhysicalDiskIdentity -Path $ActivePath
    $backup = Get-PhysicalDiskIdentity -Path $BackupPath
    Write-Output ("Active storage: DiskNumber={0}, UniqueId={1}, Path={2}" -f $active.DiskNumber, $active.UniqueId, $active.Path)
    Write-Output ("Backup storage: DiskNumber={0}, UniqueId={1}, Path={2}" -f $backup.DiskNumber, $backup.UniqueId, $backup.Path)
    if ($active.DiskNumber -eq $backup.DiskNumber) {
        throw "Active data and backup are on the same physical disk number $($active.DiskNumber)."
    }
    if (-not [string]::IsNullOrWhiteSpace($active.UniqueId) -and
        -not [string]::IsNullOrWhiteSpace($backup.UniqueId) -and
        $active.UniqueId -eq $backup.UniqueId) {
        throw "Active data and backup report the same physical disk UniqueId $($active.UniqueId)."
    }
}

function Get-VolumeCapacity {
    param([string]$Path)
    $identity = Get-PhysicalDiskIdentity -Path $Path
    $volume = Get-Volume -DriveLetter $identity.DriveLetter -ErrorAction Stop
    return [pscustomobject]@{
        DiskIdentity = $identity
        Size = [long]$volume.Size
        Free = [long]$volume.SizeRemaining
    }
}

function Get-DirectorySize {
    param([string]$Directory)
    $measure = Get-ChildItem -LiteralPath $Directory -Recurse -Force -File | Measure-Object Length -Sum
    if ($null -eq $measure.Sum) { return [long]0 }
    return [long]$measure.Sum
}

function Get-MigrationSourceSize {
    $total = [long]0
    foreach ($migration in $Migrations) {
        $total += [long](Get-Item -LiteralPath $migration.Source).Length
    }
    return $total
}

function Assert-ExecuteCapacity {
    $sourceBytes = Get-DirectorySize -Directory $DataDir
    $migrationBytes = Get-MigrationSourceSize
    $dumpAllowance = [long][Math]::Max(1GB, [Math]::Ceiling($sourceBytes * 1.5))
    $evidenceAllowance = [long][Math]::Max(512MB, [Math]::Ceiling($sourceBytes * 0.10)) + $migrationBytes
    $beforeReserve = $sourceBytes + $dumpAllowance + $evidenceAllowance
    $reserve = [long][Math]::Max(5GB, [Math]::Ceiling($beforeReserve * 0.20))
    $requiredFree = $beforeReserve + $reserve
    $capacity = Get-VolumeCapacity -Path $BackupParent
    if ($capacity.Free -lt $requiredFree) {
        throw "Insufficient Execute backup space. Required free bytes=$requiredFree; available=$($capacity.Free); cold-copy=$sourceBytes; dump-allowance=$dumpAllowance; evidence-and-migrations=$evidenceAllowance; reserve=$reserve."
    }
}

function Assert-RollbackCapacity {
    param([string]$ColdBackupPath)
    $coldBytes = Get-DirectorySize -Directory $ColdBackupPath
    $retainedBytes = if (Test-Path -LiteralPath $DataDir -PathType Container) { Get-DirectorySize -Directory $DataDir } else { [long]0 }
    $rollbackLogAllowance = [long]512MB
    $reserve = [long][Math]::Max(5GB, [Math]::Ceiling(($coldBytes + $rollbackLogAllowance) * 0.20))
    $additionalFreeRequired = $coldBytes + $rollbackLogAllowance + $reserve
    $capacity = Get-VolumeCapacity -Path (Split-Path -Parent $DataDir)
    $projectedUsed = ($capacity.Size - $capacity.Free) + $additionalFreeRequired
    if ($capacity.Free -lt $additionalFreeRequired -or $projectedUsed -gt $capacity.Size) {
        throw "Insufficient Rollback space. Existing retained DataDir bytes=$retainedBytes; restore-staging=$coldBytes; rollback-logs=$rollbackLogAllowance; reserve=$reserve; required additional free=$additionalFreeRequired; available=$($capacity.Free)."
    }
}

function Get-FileTailFromOffset {
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        [void]$stream.Seek($Offset, 'Begin')
        $reader = New-Object System.IO.StreamReader($stream, $Utf8NoBom, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-EvidenceText {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Get-FileLineCount {
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).Length -eq 0) { return 0 }
    return @([System.IO.File]::ReadLines($Path)).Count
}

function Assert-DatabasePortOwnership {
    $owned = Get-VerifiedOwnedProcess -Kind Database
    if ($null -eq $owned) { throw 'The database process is not owned by this run.' }
    $owners = @(Get-PortOwnerPids)
    if ($owners.Count -ne 1 -or [int]$owners[0] -ne $owned.Id) {
        throw "Port 3307 is not uniquely owned by this run's database PID $($owned.Id)."
    }
}

function Wait-ForDatabaseReady {
    param(
        [ValidateRange(1, 300000)][int]$TimeoutMilliseconds = 45000,
        [ValidateRange(1, 10000)][int]$PollMilliseconds = 500
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $lastSqlProbeError = 'No SQL identity probe was attempted because the verified MariaDB listener was not available.'
    do {
        $owned = Get-VerifiedOwnedProcess -Kind Database
        if ($null -eq $owned) { throw 'The owned database process exited during startup.' }

        $owners = @(Get-PortOwnerPids)
        if ($owners.Count -gt 0) {
            if ($owners.Count -ne 1 -or [int]$owners[0] -ne $owned.Id) {
                throw "Port 3307 is not uniquely owned by this run's database PID $($owned.Id)."
            }
            try {
                Assert-DatabaseIdentity
                return
            }
            catch {
                $lastSqlProbeError = $_.Exception.Message
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    } while ([DateTime]::UtcNow -lt $deadline)

    $timeoutSeconds = $TimeoutMilliseconds / 1000.0
    throw "MariaDB did not become ready on the verified port within $timeoutSeconds seconds. Last SQL probe error: $lastSqlProbeError"
}

function Assert-ReviewedDatabaseConfiguration {
    Assert-DatabasePortOwnership
    $expectedData = (Get-NormalizedPath -Path $DataDir).Replace('\', '/').TrimEnd('/') + '/'
    $sql = "SELECT CONCAT(REPLACE(@@datadir,'\\','/'),'|',@@port,'|',@@bind_address)"
    $actual = Invoke-MariaDb -Sql $sql
    $expected = "$expectedData|3307|127.0.0.1"
    if ($actual -ine $expected) {
        throw "MariaDB runtime configuration mismatch. Expected '$expected', found '$actual'."
    }
}

function Stop-OwnedWorld {
    $owned = Get-VerifiedOwnedProcess -Kind World
    if ($null -eq $owned) { return $false }
    $worldProcesses = @(Get-ProcessCandidates -Kind World)
    if ($worldProcesses.Count -ne 1 -or $worldProcesses[0].Id -ne $owned.Id) {
        throw 'Controlled Worldserver shutdown was refused because another mangosd process is present.'
    }
    Assert-Hash -Path $ShutdownHelper -ExpectedSha256 $ApprovedFiles.ShutdownHelper.Sha256
    $powerShell51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $powerShell51 -PathType Leaf)) {
        throw "Windows PowerShell 5.1 is missing: $powerShell51"
    }
    & $powerShell51 -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ShutdownHelper -Action World -ServerDirectory $ServerDir -WorldWindowTitle 'mangosd' -SaveDelaySeconds 5 -WorldExitTimeoutSeconds 180
    if ($LASTEXITCODE -ne 0) {
        throw "Controlled Worldserver shutdown failed with exit code $LASTEXITCODE."
    }
    Wait-ForProcessExit -ProcessId $owned.Id -StartTimeUtcTicks $script:RunState.World.OwnedStartTimeUtcTicks -TimeoutSeconds 190
    return $true
}

function Stop-OwnedDatabase {
    $owned = Get-VerifiedOwnedProcess -Kind Database
    if ($null -eq $owned) { return $false }
    if (@(Get-ProcessCandidates -Kind World).Count -gt 0) {
        throw 'MariaDB shutdown was refused because a mangosd process is still running.'
    }
    Assert-Hash -Path $MariaDbAdmin -ExpectedSha256 $ApprovedFiles.MariaDbAdmin.Sha256
    Assert-DatabasePortOwnership
    & $MariaDbAdmin --protocol=TCP "--host=$DatabaseHost" "--port=$DatabasePort" "--user=$DatabaseUser" shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "Controlled MariaDB shutdown failed with exit code $LASTEXITCODE."
    }
    Wait-ForProcessExit -ProcessId $owned.Id -StartTimeUtcTicks $script:RunState.Database.OwnedStartTimeUtcTicks -TimeoutSeconds 60
    return $true
}

function Start-ReviewedDatabase {
    param([switch]$RequireDump)
    Assert-DatabaseProgramFiles
    Assert-RestoredDatabaseConfiguration
    if ($RequireDump) {
        Assert-Hash -Path $MariaDbDump -ExpectedSha256 $ApprovedFiles.MariaDbDump.Sha256
    }

    try {
        Set-LaunchAttempt -Kind Database
        $launcher = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'title MariaDB 3307 & call start-database.bat') -WorkingDirectory $DatabaseRoot -PassThru
        Set-LauncherPid -Kind Database -ProcessId $launcher.Id
        [void](Wait-ForOwnedProcess -Kind Database -TimeoutSeconds 30)
        Wait-ForDatabaseReady
        Assert-ReviewedDatabaseConfiguration
        return Get-VerifiedOwnedProcess -Kind Database
    }
    catch {
        $startError = $_
        try {
            $owned = Get-VerifiedOwnedProcess -Kind Database
            if ($null -ne $owned) {
                if (Test-PortOpen) {
                    [void](Stop-OwnedDatabase)
                }
                else {
                    Start-Sleep -Seconds 2
                    $owned = Get-VerifiedOwnedProcess -Kind Database
                    if ($null -ne $owned) {
                        throw 'Owned MariaDB remained active without a verified control port.'
                    }
                }
            }
        }
        catch {
            [Console]::Error.WriteLine("[DATABASE START CLEANUP] $($_.Exception.Message)")
        }
        throw $startError
    }
}

function Start-ReviewedWorld {
    Assert-WorldRuntimeFiles
    try {
        Set-LaunchAttempt -Kind World
        $launcher = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'title mangosd & call start-mangosd.bat') -WorkingDirectory $ServerDir -PassThru
        Set-LauncherPid -Kind World -ProcessId $launcher.Id
        $owned = Wait-ForOwnedProcess -Kind World -TimeoutSeconds 30
        $worldProcesses = @(Get-ProcessCandidates -Kind World)
        if ($worldProcesses.Count -ne 1 -or $worldProcesses[0].Id -ne $owned.Id) {
            throw 'Worldserver launch validation found an unexpected mangosd process.'
        }
        Assert-Hash -Path $ProductionExe -ExpectedSha256 $ExpectedProductionExeSha256
        return $owned
    }
    catch {
        $startError = $_
        try {
            if ($null -ne (Get-VerifiedOwnedProcess -Kind World)) {
                [void](Stop-OwnedWorld)
            }
        }
        catch {
            [Console]::Error.WriteLine("[WORLD START CLEANUP] $($_.Exception.Message)")
        }
        throw $startError
    }
}

function Invoke-LogicalDump {
    param([string]$DumpPath, [string]$StderrPath)
    Assert-Hash -Path $MariaDbDump -ExpectedSha256 $ApprovedFiles.MariaDbDump.Sha256
    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--default-character-set=utf8mb4', '--hex-blob', '--routines', '--events', '--triggers',
        '--lock-all-tables', '--databases', $DatabaseName
    )
    $process = Start-Process -FilePath $MariaDbDump -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $DumpPath -RedirectStandardError $StderrPath
    if ($process.ExitCode -ne 0) { throw "Logical dump failed with exit code $($process.ExitCode)." }
    if (-not (Test-Path -LiteralPath $DumpPath -PathType Leaf)) {
        throw 'Logical dump is missing.'
    }
    $dumpBytes = [long](Get-Item -LiteralPath $DumpPath).Length
    $dataBytes = Get-DirectorySize -Directory $DataDir
    $minimumReasonableBytes = [long][Math]::Max(1MB, [Math]::Ceiling($dataBytes * 0.01))
    if ($dumpBytes -lt $minimumReasonableBytes) {
        throw "Logical dump is unreasonably small. Minimum=$minimumReasonableBytes bytes; actual=$dumpBytes bytes."
    }
    $tick = [char]96
    $requiredCreate = 'CREATE TABLE ' + $tick + 'character_inventory' + $tick
    if (-not (Select-String -LiteralPath $DumpPath -SimpleMatch -Pattern $requiredCreate -Quiet)) {
        throw 'Logical dump does not contain the expected character_inventory CREATE TABLE statement.'
    }
}

function Stage-Migrations {
    param([string]$MigrationDirectory)
    Assert-SourceMigrationFiles
    New-Item -ItemType Directory -Path $MigrationDirectory -ErrorAction Stop | Out-Null
    foreach ($migration in $Migrations) {
        $destination = Join-Path $MigrationDirectory $migration.FileName
        Copy-Item -LiteralPath $migration.Source -Destination $destination -ErrorAction Stop
        Assert-DualHash -Path $destination -ExpectedSha1 $migration.Sha1 -ExpectedSha256 $migration.Sha256
    }
}

function Invoke-ReviewedMigrations {
    param([string]$MigrationDirectory, [string]$EvidenceDirectory)
    Enable-MigrationsModuleColumn

    $guildBefore = Join-Path $EvidenceDirectory 'guild-bank-money.before.tsv'
    $guildAfter = Join-Path $EvidenceDirectory 'guild-bank-money.after.tsv'
    Invoke-MariaDbExport -Sql 'SELECT * FROM guild_bank_money ORDER BY guildid, isInferno' -OutputPath $guildBefore
    $guildBeforeCount = Get-FileLineCount -Path $guildBefore
    $guildBeforeHash = Get-Sha256 -Path $guildBefore

    for ($i = 0; $i -lt 3; $i++) {
        $migration = $Migrations[$i]
        $staged = Join-Path $MigrationDirectory $migration.FileName
        Assert-DualHash -Path $staged -ExpectedSha1 $migration.Sha1 -ExpectedSha256 $migration.Sha256
        $stdout = Join-Path $EvidenceDirectory ("{0}.stdout.log" -f $migration.Name)
        $stderr = Join-Path $EvidenceDirectory ("{0}.stderr.log" -f $migration.Name)
        Invoke-SqlFile -SqlPath $staged -StdoutPath $stdout -StderrPath $stderr

        if ($i -eq 0) {
            Assert-IndexMigrationEffect
        }
        elseif ($i -eq 1) {
            Assert-GuildMoneySchema
            Invoke-MariaDbExport -Sql 'SELECT * FROM guild_bank_money ORDER BY guildid, isInferno' -OutputPath $guildAfter
            $guildAfterCount = Get-FileLineCount -Path $guildAfter
            $guildAfterHash = Get-Sha256 -Path $guildAfter
            if ($guildAfterCount -ne $guildBeforeCount -or $guildAfterHash -ne $guildBeforeHash) {
                throw 'guild_bank_money rows changed unexpectedly during the type migration.'
            }
        }
        elseif ($i -eq 2) {
            Assert-InventoryCopySchema
        }

        Register-Migration -Migration $migration
    }

    $pvp = $Migrations[3]
    $pvpStaged = Join-Path $MigrationDirectory $pvp.FileName
    Assert-DualHash -Path $pvpStaged -ExpectedSha1 $pvp.Sha1 -ExpectedSha256 $pvp.Sha256
    Assert-PvpCurrencyMaterialized -StagedMigrationPath $pvpStaged
    $pvpStdout = Join-Path $EvidenceDirectory ("{0}.stdout.log" -f $pvp.Name)
    $pvpStderr = Join-Path $EvidenceDirectory ("{0}.stderr.log" -f $pvp.Name)
    Write-Utf8Lines -Path $pvpStdout -Lines @(
        'Verified the staged migration against the materialized baseline schema.',
        'The CREATE TABLE statement was intentionally not executed.',
        "SHA-1=$($pvp.Sha1)",
        "SHA-256=$($pvp.Sha256)"
    )
    Write-EvidenceText -Path $pvpStderr -Text ''
    Register-Migration -Migration $pvp
    Assert-FinalMigrationTracking
}

function Export-InventoryEvidence {
    param([string]$Table, [string]$OutputPath)
    if ($Table -notin @('character_inventory', 'character_inventory_copy')) {
        throw "Inventory export table is not approved: $Table"
    }
    $sql = "SELECT guid,bag,slot,item,item_template FROM $Table ORDER BY item"
    Invoke-MariaDbExport -Sql $sql -OutputPath $OutputPath
    return [pscustomobject]@{
        RowCount = Get-FileLineCount -Path $OutputPath
        Sha256 = Get-Sha256 -Path $OutputPath
    }
}

function Write-SchemaEvidence {
    param([string]$Path)
    $tables = @('character_inventory', 'character_inventory_copy', 'character_pvp_currency', 'guild_bank_money', 'migrations')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($table in $tables) {
        $lines.Add("===== $table =====")
        $lines.Add((Get-ShowCreateDefinition -Table $table))
    }
    Write-Utf8Lines -Path $Path -Lines @($lines)
}

function Wait-ForHonorMaintenance {
    param([long]$HonorOffset)
    $deadline = [DateTime]::UtcNow.AddSeconds($HonorTimeoutSeconds)
    do {
        if ($null -eq (Get-VerifiedOwnedProcess -Kind World)) {
            throw 'Worldserver exited before Honor maintenance completed.'
        }
        $appended = Get-FileTailFromOffset -Path $HonorLog -Offset $HonorOffset
        $marker = Invoke-MariaDb -Sql 'SELECT COUNT(*) FROM saved_variables sv WHERE sv.key=0 AND sv.honorMaintenanceMarker=0'
        if ($appended.Contains('[MAINTENANCE] Honor maintenance finished.') -and $marker -eq '1') {
            return $appended
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Honor maintenance did not reach its success marker and reset state before the timeout.'
}

function Assert-NewErrorLogSafe {
    param([AllowEmptyString()][string]$Text)
    $blockedPatterns = @(
        '(?is)character_inventory_copy.{0,160}(missing|does not exist|doesn''t exist|unknown table|1146)',
        '(?i)(\[1146\]|\berror\s*1146\b)',
        '(?i)database structure is not up to date',
        '(?im)(\[crash\]|crash_[0-9]{8}|fatal signal|unhandled exception|access violation|stack trace)'
    )
    foreach ($pattern in $blockedPatterns) {
        if ([regex]::IsMatch($Text, $pattern)) {
            throw "The newly appended error-log section contains a blocked failure marker matching: $pattern"
        }
    }
}

function Copy-ExecutedScriptEvidence {
    param([string]$Destination)
    Assert-CanonicalScriptFile -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Copy-Item -LiteralPath $PSCommandPath -Destination $Destination -ErrorAction Stop
    Assert-CanonicalScriptFile -Path $Destination -ExpectedSha256 $ApprovedScriptSha256
}

function Get-BackupEvidenceAnchorLines {
    param(
        [string]$RunDirectory,
        [string]$EvidenceDirectory,
        [string]$MigrationDirectory
    )
    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add((Join-Path $EvidenceDirectory 'physical-source.sha256'))
    $targets.Add((Join-Path $EvidenceDirectory 'physical-source.acl.txt'))
    $targets.Add((Join-Path $EvidenceDirectory 'physical-backup.sha256'))
    $targets.Add((Join-Path $EvidenceDirectory 'physical-backup.acl.txt'))
    $targets.Add((Join-Path $EvidenceDirectory 'executed-runbook.ps1'))
    foreach ($migration in $Migrations) {
        $targets.Add((Join-Path $MigrationDirectory $migration.FileName))
    }
    $rootPath = Get-NormalizedPath -Path $RunDirectory
    foreach ($target in $targets) {
        $fullPath = Get-NormalizedPath -Path $target
        if (-not $fullPath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Backup evidence target escapes the run directory: $fullPath"
        }
        $relative = $fullPath.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
        "{0} *{1}" -f (Get-Sha256 -Path $fullPath), $relative
    }
}

function New-BackupEvidenceAnchor {
    param(
        [string]$RunDirectory,
        [string]$EvidenceDirectory,
        [string]$MigrationDirectory,
        [string]$AnchorPath
    )
    Write-Utf8Lines -Path $AnchorPath -Lines @(Get-BackupEvidenceAnchorLines -RunDirectory $RunDirectory -EvidenceDirectory $EvidenceDirectory -MigrationDirectory $MigrationDirectory)
}

function Assert-BackupEvidenceAnchor {
    param(
        [string]$RunDirectory,
        [string]$EvidenceDirectory,
        [string]$MigrationDirectory,
        [string]$AnchorPath,
        [string]$ExpectedAnchorSha256
    )
    Assert-Hash -Path $AnchorPath -ExpectedSha256 $ExpectedAnchorSha256
    $recorded = @(Get-Content -LiteralPath $AnchorPath)
    $actual = @(Get-BackupEvidenceAnchorLines -RunDirectory $RunDirectory -EvidenceDirectory $EvidenceDirectory -MigrationDirectory $MigrationDirectory)
    if ($recorded.Count -ne $actual.Count) {
        throw 'Backup evidence anchor entry count mismatch.'
    }
    for ($i = 0; $i -lt $recorded.Count; $i++) {
        if ($recorded[$i] -cne $actual[$i]) {
            throw "Backup evidence anchor mismatch at line $($i + 1)."
        }
    }
}

function New-FinalArtifactManifest {
    param([string]$RunDirectory, [string]$ManifestPath)
    $rootPath = Get-NormalizedPath -Path $RunDirectory
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force -File | Sort-Object FullName)) {
        if ($file.FullName -ieq (Get-NormalizedPath -Path $ManifestPath)) { continue }
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        $lines.Add(("{0} *{1}" -f $hash, $relative))
    }
    Write-Utf8Lines -Path $ManifestPath -Lines @($lines)
}

function Invoke-FailureCleanup {
    $cleanupErrors = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -ne (Get-VerifiedOwnedProcess -Kind World)) {
            [void](Stop-OwnedWorld)
        }
    }
    catch {
        $cleanupErrors.Add("World cleanup: $($_.Exception.Message)")
    }

    try {
        if ($null -ne (Get-VerifiedOwnedProcess -Kind Database)) {
            if (@(Get-ProcessCandidates -Kind World).Count -gt 0) {
                $cleanupErrors.Add('Database cleanup skipped because a mangosd process remains.')
            }
            else {
                [void](Stop-OwnedDatabase)
            }
        }
    }
    catch {
        $cleanupErrors.Add("Database cleanup: $($_.Exception.Message)")
    }

    foreach ($message in $cleanupErrors) {
        [Console]::Error.WriteLine("[CLEANUP ERROR] $message")
    }
    Write-ServerStatus -Prefix 'FINAL FAILURE STATE'
}

function Invoke-ExecuteMode {
    if ([string]::IsNullOrWhiteSpace($BackupParent)) {
        throw 'Execute requires -BackupParent.'
    }
    if (-not (Test-Path -LiteralPath $BackupParent -PathType Container)) {
        throw "BackupParent must already exist: $BackupParent"
    }
    Assert-DifferentPhysicalDisks -ActivePath $DataDir -BackupPath $BackupParent
    Assert-ExecuteCapacity
    Assert-DatabaseRuntimeFiles
    Assert-WorldRuntimeFiles
    Assert-SourceMigrationFiles
    Assert-Hash -Path $ProductionExe -ExpectedSha256 $ExpectedProductionExeSha256

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $runDirectory = Join-Path $BackupParent "tw-char-migration-$stamp"
    if (Test-Path -LiteralPath $runDirectory) { throw "Backup run directory already exists: $runDirectory" }

    $coldBackup = Join-Path $runDirectory 'cold-backup'
    $migrationDirectory = Join-Path $runDirectory 'migration-files'
    $evidenceDirectory = Join-Path $runDirectory 'evidence'
    New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $evidenceDirectory -ErrorAction Stop | Out-Null

    Copy-ExecutedScriptEvidence -Destination (Join-Path $evidenceDirectory 'executed-runbook.ps1')
    Stage-Migrations -MigrationDirectory $migrationDirectory
    Assert-StagedMigrationFiles -MigrationDirectory $migrationDirectory

    $sourceManifest = Join-Path $evidenceDirectory 'physical-source.sha256'
    $sourceAclManifest = Join-Path $evidenceDirectory 'physical-source.acl.txt'
    $backupManifest = Join-Path $evidenceDirectory 'physical-backup.sha256'
    $backupAclManifest = Join-Path $evidenceDirectory 'physical-backup.acl.txt'
    $backupEvidenceAnchor = Join-Path $evidenceDirectory 'backup-evidence-anchor.sha256'

    Assert-NoReparsePoints -Directory $DataDir
    Assert-NoServerServices
    New-TreeManifest -Directory $DataDir -ManifestPath $sourceManifest
    New-AclManifest -Directory $DataDir -ManifestPath $sourceAclManifest

    Assert-NoServerServices
    Invoke-RobocopyVerified -Source $DataDir -Destination $coldBackup
    Assert-NoReparsePoints -Directory $coldBackup
    Copy-RootAcl -Source $DataDir -Destination $coldBackup
    New-TreeManifest -Directory $coldBackup -ManifestPath $backupManifest
    New-AclManifest -Directory $coldBackup -ManifestPath $backupAclManifest
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $coldBackup
    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $coldBackup
    Assert-AclManifestMatchesDirectory -ManifestPath $backupAclManifest -Directory $coldBackup
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $coldBackup
    Assert-Hash -Path (Join-Path $coldBackup 'my.ini') -ExpectedSha256 $ApprovedFiles.MyIni.Sha256
    $backupManifestHash = Get-Sha256 -Path $backupManifest
    New-BackupEvidenceAnchor -RunDirectory $runDirectory -EvidenceDirectory $evidenceDirectory -MigrationDirectory $migrationDirectory -AnchorPath $backupEvidenceAnchor
    $backupEvidenceAnchorHash = Get-Sha256 -Path $backupEvidenceAnchor
    Assert-BackupEvidenceAnchor -RunDirectory $runDirectory -EvidenceDirectory $evidenceDirectory -MigrationDirectory $migrationDirectory -AnchorPath $backupEvidenceAnchor -ExpectedAnchorSha256 $backupEvidenceAnchorHash
    Write-Output "EXTERNAL RECORD REQUIRED - backup evidence anchor SHA-256: $backupEvidenceAnchorHash"

    [void](Start-ReviewedDatabase -RequireDump)
    Assert-RecordedOfflineSchema

    $dumpPath = Join-Path $evidenceDirectory 'tw_char.pre-migration.sql'
    $dumpErrorPath = Join-Path $evidenceDirectory 'tw_char.pre-migration.stderr.log'
    Invoke-LogicalDump -DumpPath $dumpPath -StderrPath $dumpErrorPath

    Invoke-ReviewedMigrations -MigrationDirectory $migrationDirectory -EvidenceDirectory $evidenceDirectory
    Write-SchemaEvidence -Path (Join-Path $evidenceDirectory 'schema-definitions.after-migrations.txt')

    $inventoryBeforePath = Join-Path $evidenceDirectory 'character_inventory.before-honor.tsv'
    $inventoryBefore = Export-InventoryEvidence -Table 'character_inventory' -OutputPath $inventoryBeforePath
    Write-Utf8Lines -Path (Join-Path $evidenceDirectory 'character_inventory.before-honor.metadata.txt') -Lines @(
        "rows=$($inventoryBefore.RowCount)",
        "sha256=$($inventoryBefore.Sha256)"
    )

    $honorOffset = if (Test-Path -LiteralPath $HonorLog) { (Get-Item -LiteralPath $HonorLog).Length } else { 0 }
    $errorOffset = if (Test-Path -LiteralPath $ErrorLog) { (Get-Item -LiteralPath $ErrorLog).Length } else { 0 }

    Assert-WorldRuntimeFiles
    [void](Start-ReviewedWorld)
    [void](Wait-ForHonorMaintenance -HonorOffset $honorOffset)
    Assert-SingleValue -Sql 'SELECT COUNT(*) FROM saved_variables sv WHERE sv.key=0 AND sv.honorMaintenanceMarker=0' -Expected '1' -Description 'Honor maintenance marker reset'

    $inventoryAfterPath = Join-Path $evidenceDirectory 'character_inventory_copy.after-honor.tsv'
    $inventoryAfter = Export-InventoryEvidence -Table 'character_inventory_copy' -OutputPath $inventoryAfterPath
    Write-Utf8Lines -Path (Join-Path $evidenceDirectory 'character_inventory_copy.after-honor.metadata.txt') -Lines @(
        "rows=$($inventoryAfter.RowCount)",
        "sha256=$($inventoryAfter.Sha256)"
    )
    if ($inventoryAfter.RowCount -ne $inventoryBefore.RowCount) {
        throw "Honor inventory backup row-count mismatch. Source=$($inventoryBefore.RowCount), copy=$($inventoryAfter.RowCount)."
    }
    if ($inventoryAfter.Sha256 -ne $inventoryBefore.Sha256) {
        throw 'Honor inventory backup SHA-256 mismatch against the pre-start source export.'
    }

    [void](Stop-OwnedWorld)
    Assert-Hash -Path $ProductionExe -ExpectedSha256 $ExpectedProductionExeSha256
    $honorAppended = Get-FileTailFromOffset -Path $HonorLog -Offset $honorOffset
    $errorAppended = Get-FileTailFromOffset -Path $ErrorLog -Offset $errorOffset
    Write-EvidenceText -Path (Join-Path $evidenceDirectory 'honor-log.appended.txt') -Text $honorAppended
    Write-EvidenceText -Path (Join-Path $evidenceDirectory 'error-log.appended.txt') -Text $errorAppended
    Assert-NewErrorLogSafe -Text $errorAppended
    [void](Stop-OwnedDatabase)
    Assert-NoServerServices

    $result = [ordered]@{
        status = 'success'
        mode = 'Execute'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        canonicalScriptBytes = $ExpectedCanonicalScriptByteCount
        canonicalScriptSha256 = $ApprovedScriptSha256.ToUpperInvariant()
        productionExeSha256 = Get-Sha256 -Path $ProductionExe
        physicalBackupManifestSha256 = $backupManifestHash
        backupEvidenceAnchorSha256 = $backupEvidenceAnchorHash
        inventorySourceRows = $inventoryBefore.RowCount
        inventorySourceSha256 = $inventoryBefore.Sha256
        inventoryCopyRows = $inventoryAfter.RowCount
        inventoryCopySha256 = $inventoryAfter.Sha256
        migrations = @($Migrations | ForEach-Object { [ordered]@{ Name = $_.Name; Hash = $_.Sha1; Module = '' } })
    }
    Write-EvidenceText -Path (Join-Path $evidenceDirectory 'execution-result.json') -Text ($result | ConvertTo-Json -Depth 5)
    $finalArtifactManifest = Join-Path $runDirectory 'final-artifacts.sha256'
    New-FinalArtifactManifest -RunDirectory $runDirectory -ManifestPath $finalArtifactManifest
    $finalArtifactManifestHash = Get-Sha256 -Path $finalArtifactManifest
    Write-Output "Execution completed. Backup run: $runDirectory"
    Write-Output "EXTERNAL RECORD REQUIRED - backup evidence anchor SHA-256: $backupEvidenceAnchorHash"
    Write-Output "EXTERNAL RECORD REQUIRED - final-artifacts.sha256 SHA-256: $finalArtifactManifestHash"
}

function Invoke-RollbackMode {
    if ([string]::IsNullOrWhiteSpace($BackupRunDirectory)) {
        throw 'Rollback requires -BackupRunDirectory.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedBackupEvidenceAnchorSha256)) {
        throw 'Rollback requires -ExpectedBackupEvidenceAnchorSha256 from the external approval record.'
    }

    Assert-DatabaseProgramFiles

    $runDirectory = Get-NormalizedPath -Path $BackupRunDirectory
    $coldBackup = Join-Path $runDirectory 'cold-backup'
    $migrationDirectory = Join-Path $runDirectory 'migration-files'
    $evidenceDirectory = Join-Path $runDirectory 'evidence'
    $backupManifest = Join-Path $evidenceDirectory 'physical-backup.sha256'
    $backupAclManifest = Join-Path $evidenceDirectory 'physical-backup.acl.txt'
    $sourceManifest = Join-Path $evidenceDirectory 'physical-source.sha256'
    $sourceAclManifest = Join-Path $evidenceDirectory 'physical-source.acl.txt'
    $backupEvidenceAnchor = Join-Path $evidenceDirectory 'backup-evidence-anchor.sha256'
    $executedRunbook = Join-Path $evidenceDirectory 'executed-runbook.ps1'

    Assert-NoReparsePoints -Directory $coldBackup
    Assert-BackupEvidenceAnchor -RunDirectory $runDirectory -EvidenceDirectory $evidenceDirectory -MigrationDirectory $migrationDirectory -AnchorPath $backupEvidenceAnchor -ExpectedAnchorSha256 $ExpectedBackupEvidenceAnchorSha256
    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $coldBackup
    Assert-AclManifestMatchesDirectory -ManifestPath $backupAclManifest -Directory $coldBackup
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $coldBackup
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $coldBackup
    Assert-Hash -Path (Join-Path $coldBackup 'my.ini') -ExpectedSha256 $ApprovedFiles.MyIni.Sha256
    Assert-StagedMigrationFiles -MigrationDirectory $migrationDirectory
    Assert-CanonicalScriptFile -Path $executedRunbook -ExpectedSha256 $ApprovedScriptSha256
    Assert-DatabaseProgramFiles
    Assert-DifferentPhysicalDisks -ActivePath (Split-Path -Parent $DataDir) -BackupPath $coldBackup
    Assert-RollbackCapacity -ColdBackupPath $coldBackup

    $databaseParent = Split-Path -Parent $DataDir
    $staging = Join-Path $databaseParent ("data.restore-staging-{0}" -f [Guid]::NewGuid().ToString('N'))
    $failed = Join-Path $databaseParent ("data.failed-{0}" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $staging) { throw "Restore staging already exists: $staging" }
    if (Test-Path -LiteralPath $failed) { throw "Failed-data retention path already exists: $failed" }

    Invoke-RobocopyVerified -Source $coldBackup -Destination $staging
    Assert-NoReparsePoints -Directory $staging
    Set-AclManifestOnDirectory -ManifestPath $sourceAclManifest -Directory $staging
    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $staging
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $staging
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $staging
    Assert-NoReparsePoints -Directory $staging

    $activeExisted = Test-Path -LiteralPath $DataDir -PathType Container
    $activeMoved = $false
    try {
        if ($activeExisted) {
            Move-Item -LiteralPath $DataDir -Destination $failed -ErrorAction Stop
            $activeMoved = $true
        }
        Move-Item -LiteralPath $staging -Destination $DataDir -ErrorAction Stop
    }
    catch {
        $promotionError = $_
        if ($activeMoved -and -not (Test-Path -LiteralPath $DataDir) -and (Test-Path -LiteralPath $failed)) {
            try {
                Move-Item -LiteralPath $failed -Destination $DataDir -ErrorAction Stop
                $activeMoved = $false
            }
            catch {
                throw "Restore promotion failed, and deterministic recovery of the original DataDir also failed. Original error: $($promotionError.Exception.Message). Recovery error: $($_.Exception.Message). Verified staging remains at $staging; retained original remains at $failed."
            }
        }
        if (-not $activeExisted -and -not (Test-Path -LiteralPath $DataDir)) {
            throw "Restore promotion failed with no original DataDir. The active path remains absent and verified staging remains at $staging. Error: $($promotionError.Exception.Message)"
        }
        throw $promotionError
    }

    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $DataDir
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $DataDir
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $DataDir
    Assert-RestoredDatabaseConfiguration
    Assert-DatabaseProgramFiles

    [void](Start-ReviewedDatabase)
    Assert-RecordedOfflineSchema
    $pvp = $Migrations[3]
    $pvpStaged = Join-Path $migrationDirectory $pvp.FileName
    Assert-DualHash -Path $pvpStaged -ExpectedSha1 $pvp.Sha1 -ExpectedSha256 $pvp.Sha256
    Assert-PvpCurrencyMaterialized -StagedMigrationPath $pvpStaged
    [void](Stop-OwnedDatabase)
    Assert-NoServerServices

    if ($activeExisted) {
        Write-Output "Rollback completed. The failed active data directory is retained at: $failed"
    }
    else {
        Write-Output 'Rollback completed. No prior active DataDir existed, so no data.failed directory was created.'
    }
}

try {
    Assert-CanonicalScriptFile -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Assert-Administrator
    $script:RunState.AdministratorPassed = $true
    Assert-NoServerServices
    $script:RunState.InitialCleanStatePassed = $true

    if ($Mode -eq 'Execute') {
        Invoke-ExecuteMode
    }
    else {
        Invoke-RollbackMode
    }

    Write-ServerStatus -Prefix 'FINAL SUCCESS STATE'
    exit 0
}
catch {
    $originalError = $_
    [Console]::Error.WriteLine("[EXECUTION ERROR] $($originalError.Exception.Message)")
    if ($script:RunState.AdministratorPassed -and $script:RunState.InitialCleanStatePassed) {
        Invoke-FailureCleanup
    }
    else {
        [Console]::Error.WriteLine('[CLEANUP] Reporting only. This run did not pass the administrator and clean-initial-state ownership gates.')
        Write-ServerStatus -Prefix 'READ-ONLY ABORT STATE'
    }
    Write-ServerStatus -Prefix 'FINAL REPORTED STATE'
    exit 1
}
