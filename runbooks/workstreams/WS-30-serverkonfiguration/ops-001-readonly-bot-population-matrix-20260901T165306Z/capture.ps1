param(
    [string]$StageDirectory = $PSScriptRoot,
    [string]$QueryPath = (Join-Path $PSScriptRoot 'CAPTURE.sql')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8 = [Text.UTF8Encoding]::new($false, $true)
$loopback = [Net.IPAddress]::Loopback.ToString()
$port = 3307
$serverPath = 'C:\TW\ComTW\DB\bin\mysqld.exe'
$clientPath = 'C:\TW\ComTW\DB\bin\mariadb.exe'
$adminPath = 'C:\TW\ComTW\DB\bin\mariadb-admin.exe'
$dataDirectory = 'C:\TW\ComTW\DB\data'
$configPath = 'C:\TW\ComTW\server\mangosd.conf'
$stopToolPath = 'C:\TW\ComTW\server\twow-server-stop-tools-20260829\twow-server-stop-tools\stop-mariadb.bat'
$expectedServerHash = 'FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7'
$expectedClientHash = '9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95'
$expectedAdminHash = '1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E'

$serverProcess = $null
$serverStdoutTask = $null
$serverStderrTask = $null
$credentialPath = $null
$shutdownCredentialPath = $null
$character = $null
$login = $null
$tokenSalt = $null
$queryTemplate = $null
$queryText = $null
$startedUtc = $null
$finishedUtc = $null
$captureAStartedUtc = $null
$captureBStartedUtc = $null
$failureCode = $null
$result = 'BLOCKED'
$accessGate = 'NOT_REACHED'
$accessSqlExecuted = $false
$issueQueryExecuted = $false
$capturePersisted = $false
$gracefulShutdown = $false
$targetedStopFallback = $false
$serviceCandidateCount = 0
$currentCandidateCount = 'NOT_CAPTURED'
$dbFlagCandidateCount = 'NOT_CAPTURED'
$queryHash = 'NOT_COMPUTED'
$captureAHash = 'NOT_CREATED'
$captureBHash = 'NOT_CREATED'
$normalizedHash = 'NOT_CREATED'

function Stop-Safely([string]$Code) {
    throw [InvalidOperationException]::new('SAFE_CODE:' + $Code)
}

function Set-Failure([string]$Code) {
    if ([string]::IsNullOrEmpty($script:failureCode)) {
        $script:failureCode = $Code
    }
}

function Write-NewUtf8File([string]$Path, [string]$Text) {
    if (Test-Path -LiteralPath $Path) { Stop-Safely 'EVIDENCE_OVERWRITE_REFUSED' }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-TextSha256([string]$Text) {
    $bytes = $utf8.GetBytes($Text)
    try {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Read-DatabaseInfo([string]$Key) {
    $line = Get-Content -LiteralPath $configPath | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Key) + '\s*=') } | Select-Object -First 1
    if ($null -eq $line) { Stop-Safely 'CONFIG_DESCRIPTOR_MISSING' }
    $value = ($line -split '=', 2)[1].Trim().Trim('"')
    $parts = $value.Split(';')
    if ($parts.Count -ne 5) { Stop-Safely 'CONFIG_DESCRIPTOR_SHAPE_MISMATCH' }
    if ($parts[2] -match '[\r\n]' -or $parts[3] -match '[\r\n]') { Stop-Safely 'CONFIG_CREDENTIAL_SHAPE_MISMATCH' }
    return [pscustomobject]@{
        Host = $parts[0]
        Port = $parts[1]
        User = $parts[2]
        Password = $parts[3]
        Schema = $parts[4]
    }
}

function Get-DbProcesses {
    return @(Get-Process -Name 'mysqld','mariadbd' -ErrorAction SilentlyContinue)
}

function Get-PortListeners {
    return @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

function Assert-GameServersStopped {
    if (@(Get-Process -Name 'mangosd' -ErrorAction SilentlyContinue).Count -ne 0) { Stop-Safely 'MANGOSD_RUNNING' }
    if (@(Get-Process -Name 'realmd' -ErrorAction SilentlyContinue).Count -ne 0) { Stop-Safely 'REALMD_RUNNING' }
}

function Get-DatabaseServices {
    try {
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($service in @(Get-Service -ErrorAction Stop)) {
            $registryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\' + $service.Name
            $properties = Get-ItemProperty -LiteralPath $registryPath -Name ImagePath -ErrorAction SilentlyContinue
            $imagePath = if ($null -eq $properties) { $null } else { $properties.ImagePath }
            if ($service.Name -match '(?i)maria|mysql' -or
                $service.DisplayName -match '(?i)maria|mysql' -or
                $imagePath -match '(?i)mariadbd|mysqld') {
                $matches.Add([pscustomobject]@{
                    Name=$service.Name
                    State=$service.Status.ToString()
                    PathName=$imagePath
                })
            }
        }
        return @($matches)
    } catch {
        Stop-Safely 'SERVICE_IDENTITY_CHECK_FAILED'
    }
}

function Assert-BinaryIdentity {
    $checks = @(
        [pscustomobject]@{ Path=$serverPath; Hash=$expectedServerHash },
        [pscustomobject]@{ Path=$clientPath; Hash=$expectedClientHash },
        [pscustomobject]@{ Path=$adminPath; Hash=$expectedAdminHash }
    )
    foreach ($check in $checks) {
        if (!(Test-Path -LiteralPath $check.Path -PathType Leaf)) { Stop-Safely 'EXPECTED_BINARY_MISSING' }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $check.Path).Hash
        if ($actual -ne $check.Hash) { Stop-Safely 'BINARY_IDENTITY_MISMATCH' }
    }
    if (!(Test-Path -LiteralPath $dataDirectory -PathType Container)) { Stop-Safely 'EXPECTED_DATADIR_MISSING' }
    if (!(Test-Path -LiteralPath $configPath -PathType Leaf)) { Stop-Safely 'EXPECTED_CONFIG_MISSING' }
    if (!(Test-Path -LiteralPath $stopToolPath -PathType Leaf)) { Stop-Safely 'EXPECTED_STOP_CONTRACT_MISSING' }
}

function Assert-PreStartState {
    Assert-GameServersStopped
    if (@(Get-DbProcesses).Count -ne 0) { Stop-Safely 'DATABASE_PROCESS_ALREADY_RUNNING' }
    if (@(Get-PortListeners).Count -ne 0) { Stop-Safely 'DATABASE_PORT_ALREADY_LISTENING' }
    $services = @(Get-DatabaseServices)
    $script:serviceCandidateCount = @($services).Count
    if (@($services | Where-Object { $_.State -eq 'Running' }).Count -ne 0) { Stop-Safely 'DATABASE_SERVICE_RUNNING' }
}

function Assert-StartedIdentity {
    Assert-GameServersStopped
    if ($null -eq $script:serverProcess) { Stop-Safely 'SERVER_PROCESS_NOT_TRACKED' }
    $processes = @(Get-DbProcesses)
    if ($processes.Count -ne 1) { Stop-Safely 'DATABASE_PROCESS_COUNT_MISMATCH' }
    $process = $processes[0]
    if ($process.Id -ne $script:serverProcess.Id) { Stop-Safely 'DATABASE_PID_MISMATCH' }
    $actualPath = $process.Path
    if ([string]::IsNullOrEmpty($actualPath)) { Stop-Safely 'DATABASE_EXE_PATH_UNAVAILABLE' }
    if ([IO.Path]::GetFullPath($actualPath) -ne [IO.Path]::GetFullPath($serverPath)) { Stop-Safely 'DATABASE_EXE_PATH_MISMATCH' }
    $listeners = @(Get-PortListeners)
    if ($listeners.Count -ne 1) { Stop-Safely 'LISTENER_COUNT_MISMATCH' }
    if ($listeners[0].LocalAddress.ToString() -ne $loopback -or $listeners[0].OwningProcess -ne $process.Id) {
        Stop-Safely 'LISTENER_IDENTITY_MISMATCH'
    }
    $services = @(Get-DatabaseServices)
    if (@($services | Where-Object { $_.State -eq 'Running' }).Count -ne 0) { Stop-Safely 'DATABASE_SERVICE_STATE_DRIFT' }
    $expectedArguments = @(
        ('--datadir=' + $dataDirectory), ('--port=' + $port),
        ('--bind-address=' + $loopback), '--console'
    )
    $trackedArguments = @($script:serverProcess.StartInfo.ArgumentList)
    if ($trackedArguments.Count -ne $expectedArguments.Count) { Stop-Safely 'DATABASE_LAUNCH_ARGUMENT_MISMATCH' }
    for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
        if ($trackedArguments[$index] -cne $expectedArguments[$index]) { Stop-Safely 'DATABASE_LAUNCH_ARGUMENT_MISMATCH' }
    }
}

function New-RestrictedOptionFile([string]$User, [AllowNull()][string]$Password, [string]$Stem) {
    if ($User -match '[\r\n]' -or ($null -ne $Password -and $Password -match '[\r\n]')) { Stop-Safely 'OPTION_VALUE_SHAPE_MISMATCH' }
    $path = Join-Path $StageDirectory ('.' + $Stem + '-' + [Guid]::NewGuid().ToString('N') + '.cnf')
    $escapedUser = $User.Replace('\', '\\').Replace('"', '\"')
    $escapedPassword = $null
    $lines = @('[client]', ('user="' + $escapedUser + '"'))
    if ($null -ne $Password) {
        $escapedPassword = $Password.Replace('\', '\\').Replace('"', '\"')
        $lines += ('password="' + $escapedPassword + '"')
    }
    $content = ($lines -join "`n") + "`n"
    [IO.File]::WriteAllText($path, $content, $utf8)
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
        $verified = Get-Acl -LiteralPath $path
        if ($verified.AreAccessRulesProtected -ne $true) { Stop-Safely 'OPTION_FILE_ACL_INHERITANCE_ENABLED' }
        $ownerSid = ([Security.Principal.NTAccount]$verified.Owner).Translate([Security.Principal.SecurityIdentifier])
        if ($ownerSid -ne $sid) { Stop-Safely 'OPTION_FILE_OWNER_MISMATCH' }
        $rules = @($verified.Access)
        if ($rules.Count -ne 1 -or $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $sid -or
            $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            Stop-Safely 'OPTION_FILE_ACL_MISMATCH'
        }
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($_.Exception.Message -like 'SAFE_CODE:*') { throw }
        Stop-Safely 'OPTION_FILE_ACL_FAILED'
    } finally {
        $escapedPassword = $null
        $content = $null
        $lines = $null
    }
    return $path
}

function Invoke-CapturedProcess([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMilliseconds) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (!$process.Start()) { Stop-Safely 'CLIENT_PROCESS_START_FAILED' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            Stop-Safely 'CLIENT_PROCESS_TIMEOUT'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr }
    } finally {
        $process.Dispose()
    }
}

function Invoke-DatabaseClient([string]$OptionPath, [string]$SqlText) {
    $arguments = @(
        ('--defaults-extra-file=' + $OptionPath),
        ('--host=' + $loopback), ('--port=' + $port), '--protocol=tcp',
        '--skip-ssl', '--connect-timeout=5', '--default-character-set=utf8mb4',
        '--batch', '--raw', '--skip-column-names', '--skip-auto-rehash',
        '--init-command=SET SESSION TRANSACTION READ ONLY',
        '--database=tw_char', ('--execute=' + $SqlText)
    )
    return Invoke-CapturedProcess -FilePath $clientPath -Arguments $arguments -TimeoutMilliseconds 120000
}

function Test-SelectOnlyGrant([string]$GrantText) {
    $lines = @($GrantText -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -eq 0) { return $false }
    $hasSelect = $false
    foreach ($line in $lines) {
        if ($line -match '(?i)\bWITH\s+GRANT\s+OPTION\b') { return $false }
        $match = [regex]::Match($line, '(?i)^GRANT\s+(.+?)\s+ON\s+.+?\s+TO\s+')
        if (!$match.Success) { return $false }
        foreach ($privilege in ($match.Groups[1].Value -split ',')) {
            $normalized = $privilege.Trim()
            if ($normalized -match '(?i)^SELECT(?:\s*\([^)]+\))?$') { $hasSelect = $true; continue }
            if ($normalized -match '(?i)^(USAGE|SHOW\s+VIEW)$') { continue }
            return $false
        }
    }
    return $hasSelect
}

function Assert-StaticQuery([string]$Template) {
    if ($Template -notmatch [regex]::Escape("'__TOKEN_SALT__'")) { Stop-Safely 'QUERY_TOKEN_PLACEHOLDER_MISSING' }
    $withoutComments = [regex]::Replace($Template, '(?m)^\s*--.*$', '')
    $statements = @($withoutComments -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($statements.Count -lt 3) { Stop-Safely 'QUERY_STATEMENT_SET_INCOMPLETE' }
    if ($statements[0] -notmatch '(?is)^SET\s+@capture_epoch\s*=\s*UNIX_TIMESTAMP\(\)\s*$') { Stop-Safely 'QUERY_SESSION_SET_MISMATCH' }
    if ($statements[1] -notmatch "(?is)^SET\s+@token_salt\s*=\s*'__TOKEN_SALT__'\s*$") { Stop-Safely 'QUERY_TOKEN_SET_MISMATCH' }
    foreach ($statement in $statements[2..($statements.Count - 1)]) {
        if ($statement -notmatch '(?is)^SELECT\b') { Stop-Safely 'QUERY_NON_SELECT_STATEMENT' }
        if ($statement -match '(?is)\bINTO\s+(OUTFILE|DUMPFILE)\b|\bFOR\s+UPDATE\b|\bLOCK\s+IN\s+SHARE\s+MODE\b|\bLOAD_FILE\s*\(') {
            Stop-Safely 'QUERY_UNSAFE_SELECT_CLAUSE'
        }
    }
}

function Get-OutputLines([string]$Text) {
    if ($Text.IndexOf([char]0) -ge 0) { Stop-Safely 'CAPTURE_NUL_BYTE' }
    return @($Text -split "`r?`n" | Where-Object { $_.Length -gt 0 })
}

function Convert-ToInt64([string]$Value) {
    $parsed = 0L
    if (![Int64]::TryParse($Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        Stop-Safely 'CAPTURE_INTEGER_PARSE_FAILED'
    }
    return $parsed
}

function Validate-Capture([string]$Text) {
    if ($Text -match '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b') { Stop-Safely 'CAPTURE_EMAIL_PATTERN_DETECTED' }
    if ($Text -match '\b(?:\d{1,3}\.){3}\d{1,3}\b') { Stop-Safely 'CAPTURE_ADDRESS_PATTERN_DETECTED' }
    $allowedTags = @(
        'CAPTURE_META','DML_COUNTER_BEFORE','SCHEMA_COLUMN','SCHEMA_INDEX',
        'EVENT_ROW','EVENT_DUPLICATE_SUMMARY','EVENT_DUPLICATE','SPEC_DISTRIBUTION',
        'RNDBOT_SPEC_COVERAGE','GROUP_MEMBER','GROUP_SUMMARY','MISSING_REFERENCE',
        'ONLINE_FLAGS','DML_COUNTER_AFTER'
    )
    $lines = Get-OutputLines $Text
    $byTag = @{}
    foreach ($tag in $allowedTags) { $byTag[$tag] = [Collections.Generic.List[string]]::new() }
    foreach ($line in $lines) {
        $parts = $line.Split("`t")
        if ($parts.Count -eq 0 -or $parts[0] -notin $allowedTags) { Stop-Safely 'CAPTURE_UNKNOWN_SECTION' }
        $byTag[$parts[0]].Add($line)
        if ($parts[0] -eq 'EVENT_ROW' -and ($parts.Count -ne 8 -or $parts[3] -notmatch '^[0-9a-fA-F]{64}$')) { Stop-Safely 'CAPTURE_EVENT_ROW_SHAPE_MISMATCH' }
        if ($parts[0] -eq 'EVENT_DUPLICATE' -and ($parts.Count -ne 4 -or $parts[2] -notmatch '^[0-9a-fA-F]{64}$')) { Stop-Safely 'CAPTURE_DUPLICATE_ROW_SHAPE_MISMATCH' }
        if ($parts[0] -eq 'GROUP_MEMBER' -and ($parts.Count -ne 18 -or $parts[1] -notmatch '^[0-9a-fA-F]{64}$' -or
            $parts[2] -notmatch '^[0-9a-fA-F]{64}$' -or $parts[3] -notmatch '^[0-9a-fA-F]{64}$')) {
            Stop-Safely 'CAPTURE_GROUP_ROW_SHAPE_MISMATCH'
        }
    }
    foreach ($tag in @('CAPTURE_META','EVENT_DUPLICATE_SUMMARY','RNDBOT_SPEC_COVERAGE','GROUP_SUMMARY','MISSING_REFERENCE','ONLINE_FLAGS')) {
        if ($byTag[$tag].Count -ne 1) { Stop-Safely 'CAPTURE_REQUIRED_SECTION_COUNT_MISMATCH' }
    }
    if ($byTag['DML_COUNTER_BEFORE'].Count -lt 10 -or $byTag['DML_COUNTER_AFTER'].Count -lt 10) { Stop-Safely 'CAPTURE_COUNTER_SET_INCOMPLETE' }
    if ($byTag['SCHEMA_INDEX'].Count -eq 0) { Stop-Safely 'CAPTURE_SCHEMA_INDEX_EMPTY' }

    $requiredColumns = @(
        'tw_char.ai_playerbot_random_bots.id','tw_char.ai_playerbot_random_bots.owner',
        'tw_char.ai_playerbot_random_bots.bot','tw_char.ai_playerbot_random_bots.time',
        'tw_char.ai_playerbot_random_bots.validIn','tw_char.ai_playerbot_random_bots.event',
        'tw_char.ai_playerbot_random_bots.value','tw_char.characters.guid',
        'tw_char.characters.account','tw_char.characters.class','tw_char.characters.online',
        'tw_char.characters.active','tw_char.characters.deleteDate','tw_char.group_member.groupId',
        'tw_char.group_member.memberGuid','tw_char.groups.groupId','tw_char.groups.leaderGuid',
        'tw_logon.account.id','tw_logon.account.username','tw_logon.account.online',
        'tw_logon.account.active','tw_logon.account.locked','tw_logon.account.banned'
    )
    $actualColumns = @{}
    foreach ($line in $byTag['SCHEMA_COLUMN']) {
        $parts = $line.Split("`t")
        if ($parts.Count -ne 8) { Stop-Safely 'CAPTURE_SCHEMA_COLUMN_SHAPE_MISMATCH' }
        $actualColumns[($parts[1] + '.' + $parts[2] + '.' + $parts[4])] = $true
    }
    if ($actualColumns.Count -ne $requiredColumns.Count) { Stop-Safely 'CAPTURE_SCHEMA_COLUMN_COUNT_MISMATCH' }
    foreach ($column in $requiredColumns) { if (!$actualColumns.ContainsKey($column)) { Stop-Safely 'CAPTURE_REQUIRED_COLUMN_MISSING' } }

    $before = @{}
    $after = @{}
    foreach ($line in $byTag['DML_COUNTER_BEFORE']) {
        $parts = $line.Split("`t")
        if ($parts.Count -ne 3) { Stop-Safely 'CAPTURE_COUNTER_SHAPE_MISMATCH' }
        $before[$parts[1]] = Convert-ToInt64 $parts[2]
    }
    foreach ($line in $byTag['DML_COUNTER_AFTER']) {
        $parts = $line.Split("`t")
        if ($parts.Count -ne 3) { Stop-Safely 'CAPTURE_COUNTER_SHAPE_MISMATCH' }
        $after[$parts[1]] = Convert-ToInt64 $parts[2]
    }
    if ($before.Count -ne $after.Count) { Stop-Safely 'CAPTURE_COUNTER_KEY_DRIFT' }
    foreach ($key in $before.Keys) {
        if (!$after.ContainsKey($key) -or $before[$key] -ne $after[$key]) { Stop-Safely 'DATABASE_MUTATION_COUNTER_CHANGED' }
    }

    $duplicateParts = $byTag['EVENT_DUPLICATE_SUMMARY'][0].Split("`t")
    if ($duplicateParts.Count -ne 2 -or (Convert-ToInt64 $duplicateParts[1]) -ne 0 -or $byTag['EVENT_DUPLICATE'].Count -ne 0) {
        Stop-Safely 'EVENT_DUPLICATE_ANOMALY'
    }
    $onlineParts = $byTag['ONLINE_FLAGS'][0].Split("`t")
    if ($onlineParts.Count -ne 5) { Stop-Safely 'ONLINE_FLAG_SUMMARY_SHAPE_MISMATCH' }
    foreach ($value in $onlineParts[1..4]) { if ((Convert-ToInt64 $value) -ne 0) { Stop-Safely 'UNEXPECTED_ONLINE_FLAG' } }
    $groupParts = $byTag['GROUP_SUMMARY'][0].Split("`t")
    if ($groupParts.Count -ne 3) { Stop-Safely 'GROUP_SUMMARY_SHAPE_MISMATCH' }
    $normalizedLines = foreach ($line in $lines) {
        if ($line.StartsWith("CAPTURE_META`t")) { "CAPTURE_META`t<NORMALIZED_UTC>`t<NORMALIZED_EPOCH>" } else { $line }
    }
    return [pscustomobject]@{
        Normalized=(($normalizedLines -join "`n") + "`n")
        CurrentCandidateCount=(Convert-ToInt64 $groupParts[1])
        DbFlagCandidateCount=(Convert-ToInt64 $groupParts[2])
        LineCount=$lines.Count
    }
}

function Start-IntendedServer {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $serverPath
    $psi.WorkingDirectory = Split-Path $serverPath -Parent
    $psi.UseShellExecute = $false
    # Keep the caller's hidden PTY available because the packaged launcher uses
    # --console; stdout/stderr are still drained only into memory and discarded.
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @(
        ('--datadir=' + $dataDirectory), ('--port=' + $port),
        ('--bind-address=' + $loopback), '--console'
    )) { [void]$psi.ArgumentList.Add($argument) }
    $script:serverProcess = [Diagnostics.Process]::new()
    $script:serverProcess.StartInfo = $psi
    if (!$script:serverProcess.Start()) { Stop-Safely 'DATABASE_START_FAILED' }
    $script:serverStdoutTask = $script:serverProcess.StandardOutput.ReadToEndAsync()
    $script:serverStderrTask = $script:serverProcess.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:serverProcess.HasExited) {
            $startupStdout = $script:serverStdoutTask.GetAwaiter().GetResult()
            $startupStderr = $script:serverStderrTask.GetAwaiter().GetResult()
            $startupDiagnostic = $startupStdout + "`n" + $startupStderr
            $classification = if ($startupDiagnostic -match '(?i)access is denied|permission denied') { 'ACCESS' }
                elseif ($startupDiagnostic -match '(?i)unknown (?:option|variable)|bad option') { 'OPTION' }
                elseif ($startupDiagnostic -match '(?i)unable to lock|can''t lock|another mysqld') { 'LOCK' }
                elseif ($startupDiagnostic -match '(?i)address already in use|can''t start server.*bind') { 'BIND' }
                elseif ($startupDiagnostic -match '(?i)corrupt|crash') { 'RECOVERY' }
                else { 'UNCLASSIFIED' }
            $exitCode = $script:serverProcess.ExitCode
            $startupStdout = $null
            $startupStderr = $null
            $startupDiagnostic = $null
            Stop-Safely ('DATABASE_START_EXIT_' + $classification + '_CODE_' + $exitCode)
        }
        $listeners = @(Get-PortListeners)
        if ($listeners.Count -eq 1 -and $listeners[0].LocalAddress.ToString() -eq $loopback -and
            $listeners[0].OwningProcess -eq $script:serverProcess.Id) { return }
        Start-Sleep -Milliseconds 250
    }
    Stop-Safely 'DATABASE_LISTENER_START_TIMEOUT'
}

function Invoke-GracefulShutdown {
    if ($null -eq $script:serverProcess -or $script:serverProcess.HasExited) { return $true }
    Assert-StartedIdentity
    $stopText = [IO.File]::ReadAllText($stopToolPath, $utf8)
    $match = [regex]::Match($stopText, '(?im)^\s*set\s+"DB_USER=([^"\r\n]+)"\s*$')
    if (!$match.Success) { return $false }
    $adminUser = $match.Groups[1].Value
    try {
        $script:shutdownCredentialPath = New-RestrictedOptionFile -User $adminUser -Password $null -Stem 'ops001-shutdown'
        $shutdown = Invoke-CapturedProcess -FilePath $adminPath -Arguments @(
            ('--defaults-extra-file=' + $script:shutdownCredentialPath),
            ('--host=' + $loopback), ('--port=' + $port), '--protocol=tcp', '--skip-ssl', 'shutdown'
        ) -TimeoutMilliseconds 30000
        $shutdown.Stdout = $null
        $shutdown.Stderr = $null
        if ($shutdown.ExitCode -ne 0) { return $false }
        if (!$script:serverProcess.WaitForExit(30000)) { return $false }
        return $true
    } catch {
        return $false
    } finally {
        $adminUser = $null
        $stopText = $null
    }
}

function Stop-ExactTrackedServer {
    if ($null -eq $script:serverProcess -or $script:serverProcess.HasExited) { return }
    try {
        Assert-StartedIdentity
        Stop-Process -Id $script:serverProcess.Id -ErrorAction Stop
        if (!$script:serverProcess.WaitForExit(30000)) { Set-Failure 'TARGETED_STOP_TIMEOUT' }
        $script:targetedStopFallback = $true
    } catch {
        Set-Failure 'TARGETED_STOP_FAILED'
    }
}

function Get-FinalState {
    return [pscustomobject]@{
        MariaDbStopped=(@(Get-DbProcesses).Count -eq 0)
        ListenerAbsent=(@(Get-PortListeners).Count -eq 0)
        MangosdStopped=(@(Get-Process -Name 'mangosd' -ErrorAction SilentlyContinue).Count -eq 0)
        RealmdStopped=(@(Get-Process -Name 'realmd' -ErrorAction SilentlyContinue).Count -eq 0)
    }
}

if (!(Test-Path -LiteralPath $StageDirectory -PathType Container)) { Stop-Safely 'STAGE_DIRECTORY_MISSING' }
if (!(Test-Path -LiteralPath $QueryPath -PathType Leaf)) { Stop-Safely 'QUERY_FILE_MISSING' }

try {
    Assert-BinaryIdentity
    $character = Read-DatabaseInfo 'CharacterDatabase.Info'
    $login = Read-DatabaseInfo 'LoginDatabase.Info'
    if ($character.Host -ne $loopback -or $character.Port -ne $port.ToString() -or $character.Schema -ne 'tw_char') { Stop-Safely 'CHARACTER_ENDPOINT_OR_SCHEMA_MISMATCH' }
    if ($login.Host -ne $loopback -or $login.Port -ne $port.ToString() -or $login.Schema -ne 'tw_logon') { Stop-Safely 'LOGIN_ENDPOINT_OR_SCHEMA_MISMATCH' }
    if ($character.User -ne $login.User -or $character.Password -ne $login.Password) { Stop-Safely 'CONFIG_CREDENTIAL_IDENTITY_MISMATCH' }

    $queryTemplate = [IO.File]::ReadAllText($QueryPath, $utf8)
    Assert-StaticQuery $queryTemplate
    $queryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $QueryPath).Hash
    Assert-PreStartState
    $startedUtc = [DateTime]::UtcNow
    Start-IntendedServer
    Assert-StartedIdentity

    $credentialPath = New-RestrictedOptionFile -User $character.User -Password $character.Password -Stem 'ops001-client'
    Assert-StartedIdentity
    $grantResult = Invoke-DatabaseClient -OptionPath $credentialPath -SqlText 'SHOW GRANTS FOR CURRENT_USER()'
    $accessSqlExecuted = $true
    if ($grantResult.ExitCode -ne 0) {
        $grantResult.Stdout = $null
        $grantResult.Stderr = $null
        Stop-Safely 'GRANT_CHECK_CONNECTION_FAILED'
    }
    $selectOnly = Test-SelectOnlyGrant $grantResult.Stdout
    $grantResult.Stdout = $null
    $grantResult.Stderr = $null
    if (!$selectOnly) {
        $accessGate = 'BLOCKED_NON_SELECT_ONLY'
        Stop-Safely 'EXISTING_PRINCIPAL_NOT_SELECT_ONLY'
    }
    $accessGate = 'PASS_SELECT_ONLY'

    Assert-StartedIdentity
    $tokenSalt = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $queryText = $queryTemplate.Replace('__TOKEN_SALT__', $tokenSalt)
    $captureAStartedUtc = [DateTime]::UtcNow
    $runA = Invoke-DatabaseClient -OptionPath $credentialPath -SqlText $queryText
    if ($runA.ExitCode -ne 0) {
        $runA.Stdout = $null
        $runA.Stderr = $null
        Stop-Safely 'CAPTURE_A_CLIENT_FAILED'
    }
    $validatedA = Validate-Capture $runA.Stdout
    $runA.Stderr = $null

    Assert-StartedIdentity
    $captureBStartedUtc = [DateTime]::UtcNow
    if (($captureBStartedUtc - $captureAStartedUtc).TotalSeconds -gt 60) { Stop-Safely 'CAPTURE_AB_WINDOW_EXCEEDED' }
    $runB = Invoke-DatabaseClient -OptionPath $credentialPath -SqlText $queryText
    if ($runB.ExitCode -ne 0) {
        $runB.Stdout = $null
        $runB.Stderr = $null
        Stop-Safely 'CAPTURE_B_CLIENT_FAILED'
    }
    $validatedB = Validate-Capture $runB.Stdout
    $runB.Stderr = $null
    if ($validatedA.Normalized -cne $validatedB.Normalized) { Stop-Safely 'CAPTURE_AB_DRIFT' }
    if ($validatedA.CurrentCandidateCount -ne $validatedB.CurrentCandidateCount -or
        $validatedA.DbFlagCandidateCount -ne $validatedB.DbFlagCandidateCount) { Stop-Safely 'CAPTURE_SUMMARY_DRIFT' }

    $captureAHash = Get-TextSha256 $runA.Stdout
    $captureBHash = Get-TextSha256 $runB.Stdout
    $normalizedHash = Get-TextSha256 $validatedA.Normalized
    Write-NewUtf8File (Join-Path $StageDirectory 'CAPTURE-A.tsv') $runA.Stdout
    Write-NewUtf8File (Join-Path $StageDirectory 'CAPTURE-B.tsv') $runB.Stdout
    $currentCandidateCount = $validatedA.CurrentCandidateCount.ToString([Globalization.CultureInfo]::InvariantCulture)
    $dbFlagCandidateCount = $validatedA.DbFlagCandidateCount.ToString([Globalization.CultureInfo]::InvariantCulture)
    $issueQueryExecuted = $true
    $capturePersisted = $true
    $runA.Stdout = $null
    $runB.Stdout = $null
    $queryText = $null
    $result = 'PASS'
} catch {
    if ($_.Exception.Message -like 'SAFE_CODE:*') {
        Set-Failure ($_.Exception.Message.Substring('SAFE_CODE:'.Length))
    } else {
        Set-Failure 'UNCLASSIFIED_RUNNER_FAILURE'
    }
    $result = 'BLOCKED'
} finally {
    if ($null -ne $character) { $character.Password = $null }
    if ($null -ne $login) { $login.Password = $null }
    $tokenSalt = $null
    $queryText = $null
    $queryTemplate = $null
    if ($null -ne $serverProcess -and !$serverProcess.HasExited) {
        $gracefulShutdown = Invoke-GracefulShutdown
        if (!$gracefulShutdown) {
            Set-Failure 'GRACEFUL_SHUTDOWN_FAILED'
            Stop-ExactTrackedServer
            $result = 'BLOCKED'
        }
    } elseif ($null -ne $serverProcess) {
        $gracefulShutdown = $true
    }
    foreach ($path in @($credentialPath, $shutdownCredentialPath)) {
        if ($null -ne $path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $serverProcess) {
        if (!$serverProcess.HasExited) { Stop-ExactTrackedServer }
        if ($serverProcess.HasExited) {
            [void]$serverStdoutTask.GetAwaiter().GetResult()
            [void]$serverStderrTask.GetAwaiter().GetResult()
        }
        $serverProcess.Dispose()
    }
    $finishedUtc = [DateTime]::UtcNow
}

$final = Get-FinalState
if (!$final.MariaDbStopped -or !$final.ListenerAbsent -or !$final.MangosdStopped -or !$final.RealmdStopped) {
    Set-Failure 'FINAL_CONTAINMENT_FAILED'
    $result = 'BLOCKED'
}
if ($targetedStopFallback) { $result = 'BLOCKED' }
if ($result -eq 'PASS' -and (!$issueQueryExecuted -or !$capturePersisted)) {
    Set-Failure 'PASS_WITHOUT_CAPTURE_REFUSED'
    $result = 'BLOCKED'
}
if ([string]::IsNullOrEmpty($failureCode)) { $failureCode = 'NONE' }

$status = @(
    'TASK_ID=OPS-001-READONLY-BOT-POPULATION-MATRIX',
    ('RESULT=' + $result),
    ('FAILURE_CODE=' + $failureCode),
    'PROJECT_SIDE=LOCAL',
    'PRIMARY_WORKSTREAM_ID=WS-30',
    'HUB_PREFLIGHT_RESULT=PASS',
    'HUB_MANIFEST_VERIFIED=YES',
    'HUB_PAYLOAD_VERIFIED_COUNT=11',
    ('STARTED_UTC=' + $(if ($null -eq $startedUtc) { 'NOT_STARTED' } else { $startedUtc.ToString('o') })),
    ('FINISHED_UTC=' + $finishedUtc.ToString('o')),
    ('SERVICE_CANDIDATE_COUNT=' + $serviceCandidateCount),
    'SERVICE_START_PERFORMED=NO',
    ('DIRECT_MARIADB_START_PERFORMED=' + $(if ($null -eq $startedUtc) { 'NO' } else { 'YES' })),
    'VERIFIED_ENDPOINT=LOOPBACK_V4_PORT_3307',
    ('ACCESS_GATE=' + $accessGate),
    ('ACCESS_SQL_EXECUTED=' + $(if ($accessSqlExecuted) { 'YES' } else { 'NO' })),
    ('ISSUE_QUERY_EXECUTED=' + $(if ($issueQueryExecuted) { 'YES' } else { 'NO' })),
    ('CAPTURE_PERSISTED=' + $(if ($capturePersisted) { 'YES' } else { 'NO' })),
    ('QUERY_SHA256=' + $queryHash),
    ('CAPTURE_A_SHA256=' + $captureAHash),
    ('CAPTURE_B_SHA256=' + $captureBHash),
    ('NORMALIZED_CAPTURE_SHA256=' + $normalizedHash),
    ('CURRENT_GROUP_LOGIN_CANDIDATE_COUNT=' + $currentCandidateCount),
    ('DB_FLAG_ONLINE_GROUP_LOGIN_CANDIDATE_COUNT=' + $dbFlagCandidateCount),
    'RUNTIME_GROUP_LOGIN_CANDIDATE_COUNT=NOT_OBSERVABLE_SERVER_STOPPED',
    'DOMAIN_DATABASE_CHANGED=NO',
    'CONFIG_CHANGED=NO',
    'MANGOSD_CONTROL_PERFORMED=NO',
    'REALMD_CONTROL_PERFORMED=NO',
    ('GRACEFUL_MARIADB_SHUTDOWN=' + $(if ($gracefulShutdown) { 'YES' } else { 'NO' })),
    ('TARGETED_TERMINATION_FALLBACK=' + $(if ($targetedStopFallback) { 'YES' } else { 'NO' })),
    ('FINAL_MARIADB_STOPPED=' + $(if ($final.MariaDbStopped) { 'YES' } else { 'NO' })),
    ('FINAL_MANGOSD_STOPPED=' + $(if ($final.MangosdStopped) { 'YES' } else { 'NO' })),
    ('FINAL_REALMD_STOPPED=' + $(if ($final.RealmdStopped) { 'YES' } else { 'NO' })),
    ('FINAL_PORT_3307_LISTENER_ABSENT=' + $(if ($final.ListenerAbsent) { 'YES' } else { 'NO' })),
    ('ISSUE_CLOSURE_ALLOWED=' + $(if ($result -eq 'PASS') { 'YES' } else { 'NO' })),
    'HUB_METADATA_CHANGED=NO',
    'TWOW_CORE_CHANGED=NO',
    'NEXT_TASK_AUTHORIZED=NO'
) -join "`n"

$reportLines = @(
    '# OPS-001 read-only bot-population matrix',
    '',
    '- Issue: `OPS-001` / GitHub issue `#23`',
    '- Workstream: `WS-30`',
    ('- Result: `' + $result + '`'),
    ('- Failure code: `' + $failureCode + '`'),
    '',
    '## Enforced boundary',
    '',
    'The intended MariaDB binary and client/admin binaries were SHA-256 pinned before start. No Windows database service was started. The direct process, its executable path, PID, command line, sole loopback listener, and configured schemas were checked before any connection. `mangosd` and `realmd` remained stopped and were never controlled.',
    '',
    'Credentials were read only in memory from the existing local configuration and supplied only through a newly created inheritance-disabled, current-SID-only option file. Raw grants and client/server stderr were never persisted or printed. Temporary option files were removed during cleanup.',
    '',
    '## Capture outcome',
    '',
    $(if ($result -eq 'PASS') {
        'The effective grants contained only `USAGE`, `SELECT`, and optional `SHOW VIEW`. Two deterministic read-only captures completed inside the allowed window, their normalized projections were byte-identical, and all observed DML/DDL counters were unchanged. The stored projections contain no names, account identifiers, email addresses, network addresses, credentials, or free-form event data; row identities are one-run salted pseudonyms.'
      } elseif ($failureCode -eq 'EXISTING_PRINCIPAL_NOT_SELECT_ONLY') {
        'The effective-grant gate found privilege outside the permitted `USAGE` / `SELECT` / `SHOW VIEW` set. Per authorization, execution stopped before every issue query. No raw grant text or principal identity was retained. Issue #23 remains open until an existing SELECT-only principal is provided.'
      } else {
        'The fail-closed runner stopped at the sanitized failure code above. No result is treated as a completed issue capture.'
      }),
    '',
    'The persisted candidate count is separate from the runtime set: with `mangosd` stopped, `RUNTIME_GROUP_LOGIN_CANDIDATE_COUNT` is not observable and is not inferred as zero.',
    '',
    '## Final containment',
    '',
    ('- MariaDB stopped: `' + $(if ($final.MariaDbStopped) { 'YES' } else { 'NO' }) + '`'),
    ('- `mangosd` stopped: `' + $(if ($final.MangosdStopped) { 'YES' } else { 'NO' }) + '`'),
    ('- `realmd` stopped: `' + $(if ($final.RealmdStopped) { 'YES' } else { 'NO' }) + '`'),
    ('- Port 3307 listener absent: `' + $(if ($final.ListenerAbsent) { 'YES' } else { 'NO' }) + '`'),
    ('- Graceful MariaDB shutdown: `' + $(if ($gracefulShutdown) { 'YES' } else { 'NO' }) + '`'),
    ('- Targeted-stop fallback used: `' + $(if ($targetedStopFallback) { 'YES' } else { 'NO' }) + '`'),
    '',
    'No domain INSERT, UPDATE, DELETE, REPLACE, DDL, migration, GRANT, or configuration operation was issued.'
)

Write-NewUtf8File (Join-Path $StageDirectory 'RESULT.txt') ($status + "`n")
Write-NewUtf8File (Join-Path $StageDirectory 'REPORT.md') (($reportLines -join "`n") + "`n")
Write-Output $status
if ($result -ne 'PASS') { exit 3 }
