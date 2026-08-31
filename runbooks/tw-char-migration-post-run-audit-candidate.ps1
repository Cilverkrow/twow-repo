#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedScriptSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReviewedRunbookPath = 'C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1'
$ExpectedReviewedRunbookBytes = 93173
$ExpectedReviewedRunbookSha256 = '89C6C934B3CAAB861570BE54092A768ACEDACDD6D58DA731884EBDE06669314A'
$ReviewedRunDirectory = 'E:\TWoW-Migration-Backups\tw-char-migration-20260827-205920'
$ExpectedBackupEvidenceAnchorSha256 = '0AE6731234148C6ABC067907E963435FC334E1D0C707FD529DB111B24308E648'
$ExpectedOriginalEvidenceFileCount = 31
$ExpectedOriginalEvidenceManifestSha256 = 'DDA21A255B9265B5C807A0394C07BCA9B3591E8E596A8BD5C2D242A4A1F72E5C'
$RecoveryDirectory = Join-Path $ReviewedRunDirectory 'post-run-recovery'
$OriginalRunbookFailure = 'Controlled Worldserver shutdown failed with exit code 1.'
$ExpectedHonorMarker = '[MAINTENANCE] Honor maintenance finished.'
$ExpectedHonorLogBytes = 407
$ExpectedHonorLogSha256 = '1FA8D0C6D4740E06828FDF0F4B9BDF352E382DD4A82EA8A16943569FD97CFE83'
$ExpectedErrorLogBytes = 948759
$ExpectedErrorLogSha256 = '923570252AE730181938F071F5F0EB71C7BE114C48A305DEBB56C65071088294'
$ExpectedHonorMessages = @(
    '[MAINTENANCE] Honor maintenance starting.',
    '[MAINTENANCE] Load weekly players scores.',
    '[MAINTENANCE] Decay rank points.',
    '[MAINTENANCE] Flush rank points.',
    '[MAINTENANCE] Assign city ranks.',
    '[MAINTENANCE] Flush weekly quests.',
    '[MAINTENANCE] Honor maintenance finished.'
)
$SchemaEvidencePath = Join-Path $ReviewedRunDirectory 'evidence\schema-definitions.after-migrations.txt'
$DumpPath = Join-Path $ReviewedRunDirectory 'evidence\tw_char.pre-migration.sql'
$PvpMigrationPath = Join-Path $ReviewedRunDirectory 'migration-files\20260817151028_character.sql'

$ExpectedRuntimeKeys = @(
    'DatabaseLauncher',
    'MyIni',
    'MariaDbServer',
    'MariaDbClient',
    'MariaDbDump',
    'MariaDbAdmin',
    'ProductionExe',
    'MangosConfig',
    'PlayerbotConfig',
    'StartWorld',
    'ShutdownHelper'
)

$ExpectedAnchorRelativePaths = @(
    'evidence/physical-source.sha256',
    'evidence/physical-source.acl.txt',
    'evidence/physical-backup.sha256',
    'evidence/physical-backup.acl.txt',
    'evidence/executed-runbook.ps1',
    'migration-files/20260708055500_ai_playerbot_random_bots_index.sql',
    'migration-files/20260731160000_guild_bank_money_unsigned.sql',
    'migration-files/20260812142512_character_inventory_copy.sql',
    'migration-files/20260817151028_character.sql'
)

$ExpectedTrackingRows = @(
    '20260708055500_ai_playerbot_random_bots_index|61460E23B54A25F909665D7D1AC3DC768A87166C|',
    '20260731160000_guild_bank_money_unsigned|24BD0E3575C54EC1709EE37253D4373677322FCB|',
    '20260812142512_character_inventory_copy|8662106E777C548A1349CB813EE1A47DB7A1785E|',
    '20260817151028_character|557CE92CFE4B6C0B6E54316EA781459ED26F1B07|'
)

$ExpectedRecoveryFiles = @(
    'post-run-sql-state.txt',
    'post-run-honor-log-snapshot.txt',
    'post-run-error-log-snapshot.txt',
    'post-run-pvp-before.tsv',
    'post-run-pvp-after.tsv',
    'post-run-pvp-differences.tsv',
    'post-run-recovery-result.json',
    'post-run-recovery-artifacts.sha256'
)

$ApprovedInitializerNames = @(
    'Root',
    'DatabaseRoot',
    'DataDir',
    'DatabaseLauncher',
    'MariaDbServer',
    'MariaDbClient',
    'MariaDbDump',
    'MariaDbAdmin',
    'MyIni',
    'ServerDir',
    'ProductionExe',
    'MangosConfig',
    'PlayerbotConfig',
    'StartWorld',
    'ShutdownHelper',
    'LogDir',
    'HonorLog',
    'ErrorLog',
    'DatabaseName',
    'DatabaseHost',
    'DatabasePort',
    'DatabaseUser',
    'MariaDbPasswordlessTlsWarning',
    'ExpectedProductionExeSha256',
    'ApprovedFiles',
    'script:RunState',
    'Utf8NoBom'
)

$ApprovedFunctionNames = @(
    'Get-Sha256',
    'Assert-Hash',
    'Get-NormalizedPath',
    'Get-ProcessPath',
    'Get-ProcessCandidates',
    'Get-PortOwnerPids',
    'Set-LaunchAttempt',
    'Set-LauncherPid',
    'Get-VerifiedOwnedProcess',
    'Try-AdoptLaunchedProcess',
    'Wait-ForOwnedProcess',
    'Wait-ForProcessExit',
    'Assert-DatabaseProgramFiles',
    'Assert-RestoredDatabaseConfiguration',
    'Resolve-MariaDbClientResult',
    'ConvertTo-WindowsCommandLineArgument',
    'Invoke-ProcessWithCapturedOutput',
    'Invoke-MariaDb',
    'Assert-SingleValue',
    'Assert-DatabaseIdentity',
    'Normalize-CreateTable',
    'Assert-DatabasePortOwnership',
    'Wait-ForDatabaseReady',
    'Assert-ReviewedDatabaseConfiguration',
    'Stop-OwnedDatabase'
)

$ProhibitedImportedCommandNames = @(
    'Invoke-ExecuteMode',
    'Invoke-RollbackMode',
    'Invoke-LogicalDump',
    'Invoke-SqlFile',
    'Invoke-MariaDbExport',
    'Invoke-ReviewedMigrations',
    'Register-Migration',
    'Enable-MigrationsModuleColumn',
    'Start-ReviewedDatabase',
    'Start-ReviewedWorld',
    'Stop-OwnedWorld',
    'Wait-ForHonorMaintenance',
    'taskkill',
    'Stop-Process',
    'robocopy'
)

$ReadOnlySql = [ordered]@{
    ModuleMetadata = @'
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
    MigrationTracking = @'
SELECT CONCAT(Name,'|',UPPER(Hash),'|',Module)
FROM migrations
ORDER BY Name
'@
    RequiredTables = @'
SELECT CONCAT_WS('|',
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_inventory'),
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_inventory_copy'),
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='character_pvp_currency'),
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='guild_bank_money'),
 (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='migrations')
)
'@
    IndexDefinition = @'
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
    GuildMoneyDefinition = @'
SELECT CONCAT_WS('|',
  DATA_TYPE,
  COLUMN_TYPE,
  IS_NULLABLE,
  COALESCE(CAST(COLUMN_DEFAULT AS CHAR),'<NULL>')
)
FROM information_schema.columns
WHERE table_schema=DATABASE()
  AND table_name='guild_bank_money'
  AND column_name='money'
'@
    HonorState = @'
SELECT CONCAT_WS('|',
  COALESCE(CAST(honorMaintenanceMarker AS CHAR),'<NULL>'),
  COALESCE(CAST(lastHonorMaintenanceDay AS CHAR),'<NULL>'),
  COALESCE(CAST(nextHonorMaintenanceDay AS CHAR),'<NULL>')
)
FROM saved_variables
WHERE `key`=0
'@
    PvpRows = @'
SELECT guid, honor, conquest, weekly_honor, week_begin_day
FROM character_pvp_currency
ORDER BY guid
'@
}

$script:DatabaseStartAttempted = $false
$script:DatabaseStarted = $false
$script:DatabaseStoppedControlled = $false
$script:OwnedDatabasePid = $null
$script:TechnicalFailure = $null
$script:CleanupErrors = New-Object System.Collections.Generic.List[string]
$script:ReviewFindings = New-Object System.Collections.Generic.List[string]
$script:AuditResults = New-Object System.Collections.Generic.List[object]
$script:SqlCalls = New-Object System.Collections.Generic.List[string]
$script:OriginalEvidenceBefore = $null
$script:OriginalEvidenceUnchanged = $false
$script:OriginalEvidenceManifestSha256 = $null
$script:InitialServerState = $null
$script:FinalServerState = $null
$script:AnchorState = $null
$script:RuntimeState = @()
$script:DumpPvp = $null
$script:LivePvp = $null
$script:PvpDifference = $null
$script:HonorLogBytes = [byte[]]@()
$script:ErrorLogBytes = [byte[]]@()
$script:LogState = [ordered]@{}
$script:SqlState = [ordered]@{}
$LocalUtf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Get-LocalSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-TextSha256 {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    return Get-BytesSha256 -Bytes ($LocalUtf8NoBom.GetBytes($Text))
}

function Assert-LocalHash {
    param([string]$Path, [string]$ExpectedSha256)

    $actual = Get-LocalSha256 -Path $Path
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, found $actual."
    }
}

function Assert-SelfIdentity {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'This harness must be executed from its approved script file.'
    }
    Assert-LocalHash -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
}

function Assert-AuditHost {
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "This harness requires Windows PowerShell 5.1 Desktop. Found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This harness requires Administrator=True before the database can be started.'
    }
}

function Get-AuditServerState {
    $processes = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = try { $process.Path } catch { '<unavailable>' }
            $processes.Add([pscustomobject]@{
                Name = $process.ProcessName
                Pid = [int]$process.Id
                Path = $path
            })
        }
    }

    $serviceInspectionError = $null
    try {
        $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.State -eq 'Running' -and
            (($_.Name + ' ' + $_.DisplayName + ' ' + $_.PathName) -match '(?i)mariadb|mysql|mysqld|mangosd|realmd|twow|turtle')
        } | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                DisplayName = $_.DisplayName
                Status = $_.State
                ProcessId = [int]$_.ProcessId
                PathName = $_.PathName
            }
        })
    }
    catch {
        $serviceInspectionError = $_.Exception.Message
        $services = @()
    }

    $portInspectionError = $null
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq 3307 } | ForEach-Object {
            [pscustomobject]@{
                LocalAddress = $_.LocalAddress
                LocalPort = [int]$_.LocalPort
                OwningProcess = [int]$_.OwningProcess
            }
        })
    }
    catch {
        $portInspectionError = $_.Exception.Message
        $listeners = @()
    }

    return [pscustomobject]@{
        ServerProcesses = @($processes | ForEach-Object { $_ })
        MatchingRunningServices = @($services)
        Port3307Listeners = @($listeners)
        ServiceInspectionError = $serviceInspectionError
        PortInspectionError = $portInspectionError
    }
}

function Assert-AuditCleanState {
    param([object]$State, [string]$Description)

    if (-not [string]::IsNullOrWhiteSpace($State.ServiceInspectionError)) {
        throw "$Description failed because Windows service inspection was incomplete: $($State.ServiceInspectionError)"
    }
    if (-not [string]::IsNullOrWhiteSpace($State.PortInspectionError)) {
        throw "$Description failed because port inspection was incomplete: $($State.PortInspectionError)"
    }
    if (@($State.ServerProcesses).Count -ne 0) {
        throw "$Description failed because a MariaDB, mangosd, or realmd process is active."
    }
    if (@($State.MatchingRunningServices).Count -ne 0) {
        throw "$Description failed because a matching Windows service is running."
    }
    if (@($State.Port3307Listeners).Count -ne 0) {
        throw "$Description failed because port 3307 has a listener."
    }
}

function Get-VerifiedReviewedRunbookText {
    $item = Get-Item -LiteralPath $ReviewedRunbookPath -ErrorAction Stop
    if ([int64]$item.Length -ne $ExpectedReviewedRunbookBytes) {
        throw "Reviewed runbook size mismatch. Expected $ExpectedReviewedRunbookBytes, found $($item.Length)."
    }
    $bytes = [IO.File]::ReadAllBytes($ReviewedRunbookPath)
    if ($bytes.Length -ne $ExpectedReviewedRunbookBytes) {
        throw "Reviewed runbook changed while being read. Expected $ExpectedReviewedRunbookBytes bytes, read $($bytes.Length)."
    }
    $actualHash = Get-BytesSha256 -Bytes $bytes
    if ($actualHash -cne $ExpectedReviewedRunbookSha256) {
        throw "Reviewed runbook SHA-256 mismatch. Expected $ExpectedReviewedRunbookSha256, found $actualHash."
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Reviewed runbook unexpectedly contains a UTF-8 BOM.'
    }
    try {
        return $LocalUtf8NoBom.GetString($bytes)
    }
    catch {
        throw "Reviewed runbook is not strict UTF-8: $($_.Exception.Message)"
    }
}

function Import-ReviewedRunbookSubset {
    $text = Get-VerifiedReviewedRunbookText
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "Reviewed runbook parser errors: $(@($errors | ForEach-Object { $_.Message }) -join ' | ')"
    }

    $statements = @($ast.EndBlock.Statements)
    $entryPoints = @($statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($entryPoints.Count -ne 1 -or $statements[-1] -ne $entryPoints[0]) {
        throw 'Reviewed runbook must contain exactly one final top-level try/catch entry point.'
    }
    $entryText = $entryPoints[0].Extent.Text
    if ($entryText -notmatch '\bInvoke-ExecuteMode\b' -or
        $entryText -notmatch '\bInvoke-RollbackMode\b' -or
        $entryText -notmatch '\bAssert-CanonicalScriptFile\b') {
        throw 'Reviewed runbook top-level entry point does not match the approved structure.'
    }

    $unexpected = @($statements | Where-Object {
        $_ -isnot [Management.Automation.Language.AssignmentStatementAst] -and
        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
        $_ -isnot [Management.Automation.Language.TryStatementAst] -and
        -not ($_ -is [Management.Automation.Language.PipelineAst] -and $_.Extent.Text -ceq 'Set-StrictMode -Version Latest')
    })
    if ($unexpected.Count -ne 0) {
        throw 'Reviewed runbook contains an unexpected top-level executable statement.'
    }

    $initializerMap = @{}
    foreach ($statement in @($statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] })) {
        if ($statement.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = $statement.Left.VariablePath.UserPath
        if ($ApprovedInitializerNames -contains $name) {
            if ($initializerMap.ContainsKey($name)) {
                throw "Duplicate approved initializer in reviewed runbook: $name"
            }
            $initializerMap[$name] = $statement
        }
    }
    foreach ($name in $ApprovedInitializerNames) {
        if (-not $initializerMap.ContainsKey($name)) {
            throw "Approved initializer is missing from reviewed runbook: $name"
        }
        $initializerText = $initializerMap[$name].Extent.Text
        if ($name -cne 'script:RunState') {
            $initializerText = [regex]::Replace(
                $initializerText,
                ('^\${0}\s*=' -f [regex]::Escape($name)),
                ('$script:{0} =' -f $name),
                1
            )
        }
        Invoke-Expression $initializerText
    }

    $functionMap = @{}
    foreach ($definition in @($statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
        if ($functionMap.ContainsKey($definition.Name)) {
            throw "Duplicate function in reviewed runbook: $($definition.Name)"
        }
        $functionMap[$definition.Name] = $definition
    }
    foreach ($name in $ApprovedFunctionNames) {
        if (-not $functionMap.ContainsKey($name)) {
            throw "Approved function is missing from reviewed runbook: $name"
        }
        $definition = $functionMap[$name]
        foreach ($command in @($definition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))) {
            $commandName = $command.GetCommandName()
            if ($null -ne $commandName -and $ProhibitedImportedCommandNames -contains $commandName) {
                throw "Approved function '$name' references prohibited command '$commandName'."
            }
        }
        $functionText = [regex]::Replace(
            $definition.Extent.Text,
            ('^function\s+{0}\b' -f [regex]::Escape($name)),
            ('function script:{0}' -f $name),
            1
        )
        Invoke-Expression $functionText
    }

    Write-Output ("[AST] initializers={0}; functions={1}; complete reviewed entry point excluded." -f
        $ApprovedInitializerNames.Count,
        $ApprovedFunctionNames.Count)
}

function Assert-AllRuntimeHashes {
    if ($ApprovedFiles.Count -ne $ExpectedRuntimeKeys.Count) {
        throw "ApprovedFiles count mismatch. Expected $($ExpectedRuntimeKeys.Count), found $($ApprovedFiles.Count)."
    }
    $runtimeState = New-Object System.Collections.Generic.List[object]
    foreach ($key in $ExpectedRuntimeKeys) {
        if (-not $ApprovedFiles.ContainsKey($key)) {
            throw "ApprovedFiles is missing runtime key '$key'."
        }
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
        $item = Get-Item -LiteralPath $ApprovedFiles[$key].Path -ErrorAction Stop
        $runtimeState.Add([pscustomobject]@{
            Key = $key
            Path = $ApprovedFiles[$key].Path
            Bytes = [int64]$item.Length
            Sha256 = $ApprovedFiles[$key].Sha256
        })
    }
    $script:RuntimeState = @($runtimeState | ForEach-Object { $_ })
}

function Resolve-RunRelativePath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $RelativePath -match '^[A-Za-z]:') {
        throw "Unsafe run-relative path: $RelativePath"
    }
    $runRoot = [IO.Path]::GetFullPath($ReviewedRunDirectory).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $runRoot $RelativePath.Replace('/', '\')))
    if (-not $fullPath.StartsWith($runRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Run-relative path escapes the reviewed run: $RelativePath"
    }
    return $fullPath
}

function Assert-BackupEvidenceAnchor {
    $anchorPath = Join-Path $ReviewedRunDirectory 'evidence\backup-evidence-anchor.sha256'
    Assert-LocalHash -Path $anchorPath -ExpectedSha256 $ExpectedBackupEvidenceAnchorSha256
    $lines = @([IO.File]::ReadAllLines($anchorPath, $LocalUtf8NoBom))
    if ($lines.Count -ne 9) {
        throw "Backup evidence anchor must contain exactly nine lines; found $($lines.Count)."
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $lines) {
        if ($line -cnotmatch '^([A-F0-9]{64}) \*(.+)$') {
            throw "Malformed backup evidence anchor line: $line"
        }
        $expectedHash = $Matches[1]
        $relative = $Matches[2].Replace('\', '/')
        if (-not $seen.Add($relative)) {
            throw "Duplicate backup evidence anchor path: $relative"
        }
        $fullPath = Resolve-RunRelativePath -RelativePath $relative
        Assert-LocalHash -Path $fullPath -ExpectedSha256 $expectedHash
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $entries.Add([pscustomobject]@{
            RelativePath = $relative
            FullPath = $fullPath
            Bytes = [int64]$item.Length
            Sha256 = $expectedHash
        })
    }

    $actualPaths = @($entries | ForEach-Object { $_.RelativePath } | Sort-Object)
    $expectedPaths = @($ExpectedAnchorRelativePaths | Sort-Object)
    if (($actualPaths -join "`n") -cne ($expectedPaths -join "`n")) {
        throw 'Backup evidence anchor path set does not match the reviewed nine-file set.'
    }
    $script:AnchorState = @($entries | ForEach-Object { $_ })
}

function Get-OriginalEvidenceManifest {
    $roots = @(
        (Join-Path $ReviewedRunDirectory 'evidence')
        (Join-Path $ReviewedRunDirectory 'migration-files')
    )
    $manifest = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $runRoot = [IO.Path]::GetFullPath($ReviewedRunDirectory).TrimEnd('\')
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Original evidence directory is missing: $root"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($runRoot.Length + 1).Replace('\', '/')
            if ($manifest.ContainsKey($relative)) {
                throw "Duplicate original evidence path: $relative"
            }
            $manifest.Add($relative, [pscustomobject]@{
                Bytes = [int64]$file.Length
                Sha256 = Get-LocalSha256 -Path $file.FullName
            })
        }
    }
    return $manifest
}

function Get-OriginalEvidenceManifestText {
    param([object]$Manifest)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Manifest.Keys | Sort-Object)) {
        $entry = $Manifest[$path]
        $lines.Add(("{0} *{1}|bytes={2}" -f $entry.Sha256, $path, $entry.Bytes))
    }
    return (($lines -join "`r`n") + "`r`n")
}

function Assert-OriginalEvidenceUnchanged {
    param([object]$Before)

    $after = Get-OriginalEvidenceManifest
    $beforePaths = @($Before.Keys | Sort-Object)
    $afterPaths = @($after.Keys | Sort-Object)
    if (($beforePaths -join "`n") -cne ($afterPaths -join "`n")) {
        throw 'Original evidence path set changed during the audit.'
    }
    foreach ($path in $beforePaths) {
        if ($Before[$path].Bytes -ne $after[$path].Bytes -or
            $Before[$path].Sha256 -cne $after[$path].Sha256) {
            throw "Original evidence changed during the audit: $path"
        }
    }
}

function Assert-RecoveryDirectoryAbsent {
    if (Test-Path -LiteralPath $RecoveryDirectory) {
        throw "Recovery evidence directory already exists and will not be overwritten: $RecoveryDirectory"
    }
}

function Assert-ReadOnlySqlText {
    param([string]$Name, [string]$Sql)

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "Read-only SQL '$Name' is empty."
    }
    $trimmed = $Sql.Trim()
    if ($trimmed.Contains(';')) {
        throw "Read-only SQL '$Name' contains a statement separator."
    }
    if ($trimmed -match '(?is)/\*|--|#') {
        throw "Read-only SQL '$Name' contains a comment token."
    }
    if ($trimmed -match '(?i)\b(INTO\s+(OUTFILE|DUMPFILE)|FOR\s+UPDATE|LOCK\s+IN\s+SHARE\s+MODE|GET_LOCK\s*\(|RELEASE_LOCK\s*\(|SLEEP\s*\(|BENCHMARK\s*\()') {
        throw "Read-only SQL '$Name' contains a prohibited side-effect or blocking construct."
    }

    if ($trimmed -match '(?i)^SHOW\s+CREATE\s+TABLE\s+`(character_inventory|character_inventory_copy|character_pvp_currency|guild_bank_money|migrations)`$') {
        return
    }
    if ($trimmed -notmatch '(?i)^SELECT\b') {
        throw "Read-only SQL '$Name' must begin with SELECT or an approved SHOW CREATE TABLE."
    }
    if ($trimmed -match '(?i)\b(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|LOAD|CALL|GRANT|REVOKE|RENAME|ANALYZE|OPTIMIZE|REPAIR|FLUSH|RESET|PURGE|INSTALL|UNINSTALL|SHUTDOWN|KILL|SET|DO|HANDLER)\b') {
        throw "Read-only SQL '$Name' contains a prohibited keyword."
    }
}

function Invoke-ReadOnlySql {
    param([string]$Name, [string]$Sql, [switch]$AllowEmpty)

    Assert-ReadOnlySqlText -Name $Name -Sql $Sql
    Assert-Hash -Path $MariaDbClient -ExpectedSha256 $ApprovedFiles.MariaDbClient.Sha256
    $script:SqlCalls.Add($Name)
    return Invoke-MariaDb -Sql $Sql -AllowEmpty:$AllowEmpty
}

function Add-AuditResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [AllowEmptyString()][string]$Expected,
        [AllowEmptyString()][string]$Actual
    )

    $result = [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Expected = $Expected
        Actual = $Actual
    }
    $script:AuditResults.Add($result)
    if (-not $Passed) {
        $script:ReviewFindings.Add("$Name expected '$Expected' but found '$Actual'.")
    }
    return $result
}

function ConvertTo-ExactOutputLines {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text -split "`r?`n")
}

function Get-AuditShowCreateDefinition {
    param(
        [ValidateSet('character_inventory', 'character_inventory_copy', 'character_pvp_currency', 'guild_bank_money', 'migrations')]
        [string]$Table
    )

    $tick = [char]96
    $sql = "SHOW CREATE TABLE $tick$Table$tick"
    $result = Invoke-ReadOnlySql -Name "ShowCreate:$Table" -Sql $sql
    $parts = $result -split ([string][char]9), 2
    if ($parts.Count -ne 2) {
        throw "Unexpected SHOW CREATE TABLE output for $Table."
    }
    return $parts[1]
}

function Read-SchemaEvidence {
    if (-not (Test-Path -LiteralPath $SchemaEvidencePath -PathType Leaf)) {
        throw "Schema evidence is missing: $SchemaEvidencePath"
    }
    $lines = [IO.File]::ReadAllLines($SchemaEvidencePath, $LocalUtf8NoBom)
    $definitions = @{}
    $current = $null
    $builder = $null
    foreach ($line in $lines) {
        if ($line -cmatch '^===== ([a-z0-9_]+) =====$') {
            if ($null -ne $current) {
                $definitions[$current] = $builder.ToString().TrimEnd([char[]]@([char]13, [char]10))
            }
            $current = $Matches[1]
            if ($definitions.ContainsKey($current)) {
                throw "Duplicate table section in schema evidence: $current"
            }
            $builder = New-Object Text.StringBuilder
            continue
        }
        if ($null -ne $current) {
            [void]$builder.AppendLine($line)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($line)) {
            throw 'Schema evidence contains text before its first table section.'
        }
    }
    if ($null -ne $current) {
        $definitions[$current] = $builder.ToString().TrimEnd([char[]]@([char]13, [char]10))
    }
    $required = @('character_inventory', 'character_inventory_copy', 'character_pvp_currency', 'guild_bank_money', 'migrations')
    if ($definitions.Count -ne $required.Count) {
        throw "Schema evidence section count mismatch. Expected $($required.Count), found $($definitions.Count)."
    }
    foreach ($name in $required) {
        if (-not $definitions.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($definitions[$name])) {
            throw "Schema evidence is missing table definition '$name'."
        }
    }
    return $definitions
}

function Read-InventoryMetadata {
    param([string]$MetadataPath, [string]$DataPath)

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        throw "Inventory metadata is missing: $MetadataPath"
    }
    if (-not (Test-Path -LiteralPath $DataPath -PathType Leaf)) {
        throw "Inventory evidence data is missing: $DataPath"
    }
    $lines = @([IO.File]::ReadAllLines($MetadataPath, $LocalUtf8NoBom))
    if ($lines.Count -ne 2 -or $lines[0] -cnotmatch '^rows=([0-9]+)$' -or $lines[1] -cnotmatch '^sha256=([A-F0-9]{64})$') {
        throw "Inventory metadata has an unexpected format: $MetadataPath"
    }
    [uint64]$rowCount = [uint64]::Parse(([regex]::Match($lines[0], '^rows=([0-9]+)$')).Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $expectedHash = ([regex]::Match($lines[1], '^sha256=([A-F0-9]{64})$')).Groups[1].Value
    $actualHash = Get-LocalSha256 -Path $DataPath
    $actualRows = 0
    $reader = [IO.File]::OpenText($DataPath)
    try {
        while ($null -ne $reader.ReadLine()) { $actualRows++ }
    }
    finally {
        $reader.Dispose()
    }
    if ($actualHash -cne $expectedHash) {
        throw "Inventory evidence hash mismatch for '$DataPath'. Expected $expectedHash, found $actualHash."
    }
    if ([uint64]$actualRows -ne $rowCount) {
        throw "Inventory evidence row-count mismatch for '$DataPath'. Expected $rowCount, found $actualRows."
    }
    return [pscustomobject]@{
        MetadataPath = $MetadataPath
        DataPath = $DataPath
        Rows = $rowCount
        Sha256 = $expectedHash
        Bytes = [int64](Get-Item -LiteralPath $DataPath).Length
    }
}

function ConvertTo-CanonicalPvpSnapshot {
    param([object[]]$Rows, [string]$Source)

    $map = New-Object 'System.Collections.Generic.Dictionary[uint64,object]'
    foreach ($row in $Rows) {
        [uint64]$guid = $row.Guid
        if ($map.ContainsKey($guid)) {
            throw "Duplicate character_pvp_currency GUID $guid in $Source."
        }
        $map.Add($guid, $row)
    }

    $ordered = @($map.Values | Sort-Object Guid)
    $dataBuilder = New-Object Text.StringBuilder
    $tsvBuilder = New-Object Text.StringBuilder
    [void]$tsvBuilder.Append("guid`thonor`tconquest`tweekly_honor`tweek_begin_day`r`n")
    foreach ($row in $ordered) {
        $line = ("{0}`t{1}`t{2}`t{3}`t{4}" -f $row.Guid, $row.Honor, $row.Conquest, $row.WeeklyHonor, $row.WeekBeginDay)
        [void]$dataBuilder.Append($line).Append("`r`n")
        [void]$tsvBuilder.Append($line).Append("`r`n")
    }

    $summary = [ordered]@{}
    foreach ($field in @('Honor', 'Conquest', 'WeeklyHonor', 'WeekBeginDay')) {
        [decimal]$sum = 0
        $nonZero = 0
        foreach ($row in $ordered) {
            [uint64]$value = $row.$field
            $sum += [decimal]$value
            if ($value -ne 0) { $nonZero++ }
        }
        $summary[$field] = [pscustomobject]@{
            Sum = $sum.ToString([Globalization.CultureInfo]::InvariantCulture)
            NonZero = $nonZero
        }
    }

    return [pscustomobject]@{
        Source = $Source
        Rows = $ordered
        Map = $map
        RowCount = $ordered.Count
        CanonicalData = $dataBuilder.ToString()
        CanonicalTsv = $tsvBuilder.ToString()
        NormalizedSha256 = Get-TextSha256 -Text $dataBuilder.ToString()
        Summary = $summary
    }
}

function New-PvpRow {
    param([string[]]$Values, [string]$Source)

    if ($Values.Count -ne 5) {
        throw "Expected five numeric character_pvp_currency values in $Source."
    }
    $parsed = New-Object uint64[] 5
    for ($index = 0; $index -lt 5; $index++) {
        if ($Values[$index] -cnotmatch '^(0|[1-9][0-9]*)$') {
            throw "Non-numeric character_pvp_currency value '$($Values[$index])' in ${Source}."
        }
        try {
            $parsed[$index] = [uint64]::Parse($Values[$index], [Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            throw "Out-of-range character_pvp_currency value '$($Values[$index])' in $Source."
        }
        if ($parsed[$index] -gt [uint32]::MaxValue) {
            throw "character_pvp_currency value exceeds UINT32 in ${Source}: $($Values[$index])"
        }
    }
    return [pscustomobject]@{
        Guid = $parsed[0]
        Honor = $parsed[1]
        Conquest = $parsed[2]
        WeeklyHonor = $parsed[3]
        WeekBeginDay = $parsed[4]
    }
}

function New-DumpPvpParserState {
    return [pscustomobject]@{
        Rows = New-Object System.Collections.Generic.List[object]
        CreateColumns = New-Object System.Collections.Generic.List[string]
        CreateCount = 0
        InsertCount = 0
        EnableCount = 0
        InCreate = $false
        InRows = $false
        RowBlockEnded = $false
    }
}

function Add-DumpPvpParserLine {
    param([object]$State, [string]$Line, [int]$LineNumber)

    if ($Line -cmatch '^CREATE\s+TABLE\b.*`character_pvp_currency`') {
        if ($Line -cne 'CREATE TABLE `character_pvp_currency` (') {
            throw "Unsupported character_pvp_currency CREATE TABLE form at dump line $LineNumber."
        }
        if ($State.InsertCount -ne 0 -or $State.EnableCount -ne 0 -or $State.RowBlockEnded) {
            throw 'character_pvp_currency CREATE TABLE appears after its data block.'
        }
        $State.CreateCount++
        if ($State.CreateCount -ne 1) {
            throw 'Ambiguous character_pvp_currency CREATE TABLE definition in dump.'
        }
        $State.InCreate = $true
        return
    }
    if ($State.InCreate) {
        if ($Line -cmatch '^  `([^`]+)`\s+') {
            $State.CreateColumns.Add($Matches[1])
        }
        if ($Line.TrimEnd().EndsWith(';')) {
            $expectedTerminator = ') ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC;'
            if ($Line -cne $expectedTerminator) {
                throw "Unexpected character_pvp_currency CREATE TABLE terminator at dump line ${LineNumber}: $Line"
            }
            $State.InCreate = $false
        }
        return
    }
    if ($Line -cmatch '^INSERT\s+INTO\s+`character_pvp_currency`') {
        if ($Line -cne 'INSERT INTO `character_pvp_currency` VALUES') {
            throw "Unsupported character_pvp_currency INSERT form at dump line $LineNumber."
        }
        if ($State.CreateCount -ne 1 -or $State.InCreate) {
            throw 'character_pvp_currency INSERT block appears before its completed CREATE TABLE definition.'
        }
        $State.InsertCount++
        if ($State.InsertCount -ne 1 -or $State.InRows -or $State.RowBlockEnded) {
            throw 'Ambiguous character_pvp_currency INSERT block in dump.'
        }
        $State.InRows = $true
        return
    }
    if ($State.InRows) {
        if ($Line -cnotmatch '^\(([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)\)([,;])$') {
            throw "Malformed character_pvp_currency tuple at dump line ${LineNumber}: $Line"
        }
        $values = @($Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5])
        $State.Rows.Add((New-PvpRow -Values $values -Source "dump line $LineNumber"))
        if ($Matches[6] -ceq ';') {
            $State.InRows = $false
            $State.RowBlockEnded = $true
        }
        return
    }
    if ($State.RowBlockEnded -and $State.EnableCount -eq 0) {
        if ($Line -cne '/*!40000 ALTER TABLE `character_pvp_currency` ENABLE KEYS */;') {
            throw "Unexpected content between the character_pvp_currency data terminator and ENABLE KEYS marker at dump line ${LineNumber}: $Line"
        }
        $State.EnableCount = 1
        return
    }
    if ($Line -ceq '/*!40000 ALTER TABLE `character_pvp_currency` ENABLE KEYS */;') {
        throw 'Ambiguous or misplaced character_pvp_currency ENABLE KEYS marker in dump.'
    }
}

function Complete-DumpPvpParser {
    param([object]$State, [string]$Source)

    if ($State.InCreate -or $State.InRows -or -not $State.RowBlockEnded) {
        throw 'Pre-migration dump contains an incomplete character_pvp_currency definition or data block.'
    }
    if ($State.CreateCount -ne 1 -or $State.InsertCount -ne 1 -or $State.EnableCount -ne 1) {
        throw ("Expected one character_pvp_currency CREATE, INSERT, and ENABLE block; found CREATE={0} INSERT={1} ENABLE={2}." -f
            $State.CreateCount,
            $State.InsertCount,
            $State.EnableCount)
    }
    $expectedColumns = @('guid', 'honor', 'conquest', 'weekly_honor', 'week_begin_day')
    if (($State.CreateColumns -join ',') -cne ($expectedColumns -join ',')) {
        throw "character_pvp_currency dump column order mismatch. Expected '$($expectedColumns -join ',')', found '$($State.CreateColumns -join ',')'."
    }
    return ConvertTo-CanonicalPvpSnapshot -Rows @($State.Rows | ForEach-Object { $_ }) -Source $Source
}

function Get-DumpPvpSnapshot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pre-migration dump is missing: $Path"
    }
    $state = New-DumpPvpParserState
    $lineNumber = 0
    $reader = New-Object IO.StreamReader($Path, $LocalUtf8NoBom, $true)
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            if ($state.InCreate -or
                $state.InRows -or
                ($state.RowBlockEnded -and $state.EnableCount -eq 0) -or
                $line.Contains('character_pvp_currency')) {
                Add-DumpPvpParserLine -State $state -Line $line -LineNumber $lineNumber
            }
        }
    }
    finally {
        $reader.Dispose()
    }
    return Complete-DumpPvpParser -State $state -Source $Path
}

function Get-LivePvpSnapshot {
    $raw = Invoke-ReadOnlySql -Name 'PvpRows' -Sql $ReadOnlySql.PvpRows -AllowEmpty
    $rows = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in @(ConvertTo-ExactOutputLines -Text $raw)) {
        $lineNumber++
        if ($line -cnotmatch '^([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-9]+)$') {
            throw "Malformed live character_pvp_currency row ${lineNumber}: $line"
        }
        $rows.Add((New-PvpRow -Values @($Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5]) -Source "live row $lineNumber"))
    }
    return ConvertTo-CanonicalPvpSnapshot -Rows @($rows | ForEach-Object { $_ }) -Source 'live tw_char.character_pvp_currency'
}

function Compare-PvpSnapshots {
    param([object]$Before, [object]$After)

    $missing = New-Object System.Collections.Generic.List[uint64]
    $additional = New-Object System.Collections.Generic.List[uint64]
    $changed = New-Object System.Collections.Generic.List[uint64]
    $differenceBuilder = New-Object Text.StringBuilder
    [void]$differenceBuilder.Append("status`tguid`tbefore_honor`tbefore_conquest`tbefore_weekly_honor`tbefore_week_begin_day`tafter_honor`tafter_conquest`tafter_weekly_honor`tafter_week_begin_day`r`n")

    foreach ($guid in @($Before.Map.Keys | Sort-Object)) {
        if (-not $After.Map.ContainsKey($guid)) {
            $missing.Add($guid)
            $row = $Before.Map[$guid]
            [void]$differenceBuilder.Append(("missing_after`t{0}`t{1}`t{2}`t{3}`t{4}`t`t`t`t" -f
                $guid, $row.Honor, $row.Conquest, $row.WeeklyHonor, $row.WeekBeginDay)).Append("`r`n")
            continue
        }
        $old = $Before.Map[$guid]
        $new = $After.Map[$guid]
        if ($old.Honor -ne $new.Honor -or
            $old.Conquest -ne $new.Conquest -or
            $old.WeeklyHonor -ne $new.WeeklyHonor -or
            $old.WeekBeginDay -ne $new.WeekBeginDay) {
            $changed.Add($guid)
            [void]$differenceBuilder.Append(("changed`t{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f
                $guid,
                $old.Honor,
                $old.Conquest,
                $old.WeeklyHonor,
                $old.WeekBeginDay,
                $new.Honor,
                $new.Conquest,
                $new.WeeklyHonor,
                $new.WeekBeginDay)).Append("`r`n")
        }
    }
    foreach ($guid in @($After.Map.Keys | Sort-Object)) {
        if (-not $Before.Map.ContainsKey($guid)) {
            $additional.Add($guid)
            $row = $After.Map[$guid]
            [void]$differenceBuilder.Append(("additional_after`t{0}`t`t`t`t`t{1}`t{2}`t{3}`t{4}" -f
                $guid, $row.Honor, $row.Conquest, $row.WeeklyHonor, $row.WeekBeginDay)).Append("`r`n")
        }
    }

    return [pscustomobject]@{
        MissingGuids = @($missing | ForEach-Object { $_ })
        AdditionalGuids = @($additional | ForEach-Object { $_ })
        ChangedGuids = @($changed | ForEach-Object { $_ })
        DifferenceTsv = $differenceBuilder.ToString()
    }
}

function Read-SharedFileBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required log file is missing: $Path"
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] $stream.Length
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -eq 0) { throw "Unexpected end of file while reading $Path" }
            $offset += $read
        }
        return $buffer
    }
    finally {
        $stream.Dispose()
    }
}

function Start-AuditDatabase {
    Assert-DatabaseProgramFiles
    Assert-RestoredDatabaseConfiguration
    Set-LaunchAttempt -Kind Database
    $script:DatabaseStartAttempted = $true
    $launcher = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', 'title MariaDB 3307 & call start-database.bat') -WorkingDirectory $DatabaseRoot -PassThru -WindowStyle Hidden
    Set-LauncherPid -Kind Database -ProcessId $launcher.Id
    $owned = Wait-ForOwnedProcess -Kind Database -TimeoutSeconds 30
    $script:OwnedDatabasePid = [int]$owned.Id
    Wait-ForDatabaseReady
    Assert-ReviewedDatabaseConfiguration
    $verified = Get-VerifiedOwnedProcess -Kind Database
    if ($null -eq $verified -or $verified.Id -ne $owned.Id) {
        throw 'The database failed final owned-process verification after startup.'
    }
    $script:DatabaseStarted = $true
    return $verified
}

function Invoke-SchemaAndTrackingAudit {
    $module = Invoke-ReadOnlySql -Name 'ModuleMetadata' -Sql $ReadOnlySql.ModuleMetadata
    $expectedModule = 'Module|varchar|varchar(255)|255|NO|2727|utf8mb3|utf8mb3_general_ci|3'
    [void](Add-AuditResult -Name 'migrations.Module exact definition' -Passed ($module -ceq $expectedModule) -Expected $expectedModule -Actual $module)
    $script:SqlState.ModuleMetadata = $module

    $tracking = @(ConvertTo-ExactOutputLines -Text (Invoke-ReadOnlySql -Name 'MigrationTracking' -Sql $ReadOnlySql.MigrationTracking -AllowEmpty))
    $trackingMatches = $tracking.Count -eq $ExpectedTrackingRows.Count -and (($tracking -join "`n") -ceq ($ExpectedTrackingRows -join "`n"))
    [void](Add-AuditResult -Name 'migration tracking rows' -Passed $trackingMatches -Expected ($ExpectedTrackingRows -join '; ') -Actual ($tracking -join '; '))
    $script:SqlState.MigrationTrackingRows = $tracking

    $requiredTables = Invoke-ReadOnlySql -Name 'RequiredTables' -Sql $ReadOnlySql.RequiredTables
    [void](Add-AuditResult -Name 'required live table existence' -Passed ($requiredTables -ceq '1|1|1|1|1') -Expected '1|1|1|1|1' -Actual $requiredTables)
    $script:SqlState.RequiredTables = $requiredTables

    $index = Invoke-ReadOnlySql -Name 'IndexDefinition' -Sql $ReadOnlySql.IndexDefinition
    $expectedIndex = '1|3|1|1|1|BTREE|owner,bot,event'
    [void](Add-AuditResult -Name 'idx_owner_bot_event definition' -Passed ($index -ceq $expectedIndex) -Expected $expectedIndex -Actual $index)
    $script:SqlState.IndexDefinition = $index

    $guild = Invoke-ReadOnlySql -Name 'GuildMoneyDefinition' -Sql $ReadOnlySql.GuildMoneyDefinition
    $expectedGuild = 'int|int(10) unsigned|NO|0'
    [void](Add-AuditResult -Name 'guild_bank_money.money definition' -Passed ($guild -ceq $expectedGuild) -Expected $expectedGuild -Actual $guild)
    $script:SqlState.GuildMoneyDefinition = $guild

    $evidenceDefinitions = Read-SchemaEvidence
    $liveDefinitions = @{}
    foreach ($table in @('character_inventory', 'character_inventory_copy', 'character_pvp_currency', 'guild_bank_money', 'migrations')) {
        $live = Get-AuditShowCreateDefinition -Table $table
        $liveDefinitions[$table] = $live
        $expectedNormalized = Normalize-CreateTable -Definition $evidenceDefinitions[$table] -TableNames @($table)
        $actualNormalized = Normalize-CreateTable -Definition $live -TableNames @($table)
        [void](Add-AuditResult -Name "schema evidence match: $table" -Passed ($actualNormalized -ceq $expectedNormalized) -Expected $expectedNormalized -Actual $actualNormalized)
    }

    $inventory = Normalize-CreateTable -Definition $liveDefinitions.character_inventory -TableNames @('character_inventory')
    $inventoryCopy = Normalize-CreateTable -Definition $liveDefinitions.character_inventory_copy -TableNames @('character_inventory_copy')
    [void](Add-AuditResult -Name 'character inventory schema equivalence' -Passed ($inventory -ceq $inventoryCopy) -Expected $inventory -Actual $inventoryCopy)

    $migrationText = $LocalUtf8NoBom.GetString([IO.File]::ReadAllBytes($PvpMigrationPath))
    $migrationMatch = [regex]::Match($migrationText, '(?is)^\s*(CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+.+?;)\s*$')
    if (-not $migrationMatch.Success) {
        throw 'Anchored character_pvp_currency migration has an unexpected structure.'
    }
    $expectedPvp = Normalize-CreateTable -Definition $migrationMatch.Groups[1].Value -TableNames @('character_pvp_currency')
    $actualPvp = Normalize-CreateTable -Definition $liveDefinitions.character_pvp_currency -TableNames @('character_pvp_currency')
    [void](Add-AuditResult -Name 'character_pvp_currency staged migration match' -Passed ($actualPvp -ceq $expectedPvp) -Expected $expectedPvp -Actual $actualPvp)

    $script:SqlState.LiveSchemaDefinitions = $liveDefinitions
}

function Invoke-HonorAudit {
    $honorState = Invoke-ReadOnlySql -Name 'HonorState' -Sql $ReadOnlySql.HonorState
    $parts = @($honorState -split '\|', -1)
    if ($parts.Count -ne 3) {
        throw "Unexpected saved_variables key=0 honor-state output: $honorState"
    }
    [void](Add-AuditResult -Name 'honorMaintenanceMarker' -Passed ($parts[0] -ceq '0') -Expected '0' -Actual $parts[0])
    $script:SqlState.HonorState = [ordered]@{
        honorMaintenanceMarker = $parts[0]
        lastHonorMaintenanceDay = $parts[1]
        nextHonorMaintenanceDay = $parts[2]
    }

    $script:HonorLogBytes = Read-SharedFileBytes -Path $HonorLog
    $script:ErrorLogBytes = Read-SharedFileBytes -Path $ErrorLog
    $honorHash = Get-BytesSha256 -Bytes $script:HonorLogBytes
    $errorHash = Get-BytesSha256 -Bytes $script:ErrorLogBytes
    if ($script:HonorLogBytes.Length -ne $ExpectedHonorLogBytes -or $honorHash -cne $ExpectedHonorLogSha256) {
        throw "Honor log identity differs from the reviewed post-run snapshot. Expected $ExpectedHonorLogBytes bytes / $ExpectedHonorLogSha256, found $($script:HonorLogBytes.Length) bytes / $honorHash."
    }
    if ($script:ErrorLogBytes.Length -ne $ExpectedErrorLogBytes -or $errorHash -cne $ExpectedErrorLogSha256) {
        throw "Error log identity differs from the reviewed post-run snapshot. Expected $ExpectedErrorLogBytes bytes / $ExpectedErrorLogSha256, found $($script:ErrorLogBytes.Length) bytes / $errorHash."
    }

    $honorText = $LocalUtf8NoBom.GetString($script:HonorLogBytes)
    $honorLines = @(($honorText.TrimEnd([char[]]@([char]13, [char]10))) -split "`r?`n")
    $honorMessages = New-Object System.Collections.Generic.List[string]
    $honorTimestamps = New-Object System.Collections.Generic.List[string]
    $honorFormatValid = $honorLines.Count -eq $ExpectedHonorMessages.Count
    foreach ($line in $honorLines) {
        if ($line -cnotmatch '^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) (\[MAINTENANCE\] .+)$') {
            $honorFormatValid = $false
            continue
        }
        $honorTimestamps.Add($Matches[1])
        $honorMessages.Add($Matches[2])
    }
    $honorSequenceValid = $honorFormatValid -and
        (($honorMessages -join "`n") -ceq ($ExpectedHonorMessages -join "`n")) -and
        (@($honorTimestamps | Select-Object -Unique).Count -eq 1)
    [void](Add-AuditResult -Name 'Honor maintenance exact reviewed sequence' -Passed $honorSequenceValid -Expected ($ExpectedHonorMessages -join '; ') -Actual ($honorMessages -join '; '))
    $markerCount = @($honorMessages | Where-Object { $_ -ceq $ExpectedHonorMarker }).Count
    [void](Add-AuditResult -Name 'Honor maintenance log marker count' -Passed ($markerCount -eq 1) -Expected '1' -Actual ([string]$markerCount))

    $errorText = $LocalUtf8NoBom.GetString($script:ErrorLogBytes)
    $unsafePattern = '(?im)^.*(?:error\s*1146|database structure (?:is )?not up to date|character_inventory_copy|\bcrash(?:ed|ing)?\b|\bfatal\b|assertion failed|unhandled exception|access violation).*$'
    $unsafeMatches = @([regex]::Matches($errorText, $unsafePattern) | ForEach-Object { $_.Value.TrimEnd([char]13) })
    $script:LogState = [ordered]@{
        HonorLog = [ordered]@{
            Path = $HonorLog
            Bytes = $script:HonorLogBytes.Length
            Sha256 = $honorHash
            SequenceTimestamp = if ($honorTimestamps.Count -eq 0) { $null } else { $honorTimestamps[0] }
            MarkerCount = $markerCount
        }
        ErrorLog = [ordered]@{
            Path = $ErrorLog
            Bytes = $script:ErrorLogBytes.Length
            Sha256 = $errorHash
            FullSnapshotUnsafePatternMatchCount = $unsafeMatches.Count
            FullSnapshotUnsafePatternMatches = $unsafeMatches
            ReviewedRunAppendRange = 'not recoverable from the reviewed run artifacts'
        }
    }
    [void](Add-AuditResult -Name 'reviewed-run error-log append-range attribution' -Passed $false -Expected 'externally anchored pre-run byte offset or hash' -Actual 'not recoverable from the reviewed run artifacts; full reviewed snapshot retained')
}

function Invoke-InventoryEvidenceAudit {
    $evidenceRoot = Join-Path $ReviewedRunDirectory 'evidence'
    $before = Read-InventoryMetadata -MetadataPath (Join-Path $evidenceRoot 'character_inventory.before-honor.metadata.txt') -DataPath (Join-Path $evidenceRoot 'character_inventory.before-honor.tsv')
    $after = Read-InventoryMetadata -MetadataPath (Join-Path $evidenceRoot 'character_inventory_copy.after-honor.metadata.txt') -DataPath (Join-Path $evidenceRoot 'character_inventory_copy.after-honor.tsv')
    [void](Add-AuditResult -Name 'stored inventory row-count equality' -Passed ($before.Rows -eq $after.Rows) -Expected ([string]$before.Rows) -Actual ([string]$after.Rows))
    [void](Add-AuditResult -Name 'stored inventory SHA-256 equality' -Passed ($before.Sha256 -ceq $after.Sha256) -Expected $before.Sha256 -Actual $after.Sha256)
    $script:SqlState.InventoryEvidence = [ordered]@{
        Before = $before
        After = $after
    }
}

function Write-NewBytes {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes)

    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-CrlfText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
}

function Write-NewUtf8Text {
    param([string]$Path, [AllowEmptyString()][string]$Text)

    $normalized = ConvertTo-CrlfText -Text $Text
    Write-NewBytes -Path $Path -Bytes ($LocalUtf8NoBom.GetBytes($normalized))
}

function Get-SqlStateText {
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('POST-RUN RECOVERY SQL STATE')
    [void]$builder.AppendLine("reviewedRun=$ReviewedRunDirectory")
    [void]$builder.AppendLine("reviewedRunbook=$ReviewedRunbookPath")
    [void]$builder.AppendLine("reviewedRunbookSha256=$ExpectedReviewedRunbookSha256")
    [void]$builder.AppendLine("sqlCallCount=$($script:SqlCalls.Count)")
    foreach ($name in $script:SqlCalls) { [void]$builder.AppendLine("sqlCall=$name") }
    foreach ($result in $script:AuditResults) {
        [void]$builder.AppendLine(("audit|{0}|passed={1}|expected={2}|actual={3}" -f
            $result.Name,
            $result.Passed,
            ([string]$result.Expected).Replace("`r", ' ').Replace("`n", ' '),
            ([string]$result.Actual).Replace("`r", ' ').Replace("`n", ' ')))
    }
    [void]$builder.AppendLine('migrationTrackingRows:')
    foreach ($row in @($script:SqlState.MigrationTrackingRows)) { [void]$builder.AppendLine($row) }
    [void]$builder.AppendLine('liveSchemaDefinitions:')
    foreach ($table in @('character_inventory', 'character_inventory_copy', 'character_pvp_currency', 'guild_bank_money', 'migrations')) {
        [void]$builder.AppendLine("===== $table =====")
        [void]$builder.AppendLine([string]$script:SqlState.LiveSchemaDefinitions[$table])
    }
    return $builder.ToString()
}

function New-RecoveryEvidence {
    param([ValidateSet('verified_recovery_after_shutdown_helper_failure', 'review_required', 'failed')][string]$Status)

    Assert-RecoveryDirectoryAbsent
    $created = New-Item -ItemType Directory -Path $RecoveryDirectory -ErrorAction Stop
    if ($created.FullName -ine ([IO.Path]::GetFullPath($RecoveryDirectory))) {
        throw "Recovery directory resolved unexpectedly: $($created.FullName)"
    }

    $paths = @{}
    foreach ($name in $ExpectedRecoveryFiles) { $paths[$name] = Join-Path $RecoveryDirectory $name }

    $sqlText = if ($script:SqlState.Count -gt 0 -and $script:SqlState.Contains('MigrationTrackingRows') -and $script:SqlState.Contains('LiveSchemaDefinitions')) {
        Get-SqlStateText
    }
    else {
        "POST-RUN RECOVERY SQL STATE`r`ntechnicalFailure=$($script:TechnicalFailure.Exception.Message)`r`n"
    }
    Write-NewUtf8Text -Path $paths['post-run-sql-state.txt'] -Text $sqlText
    Write-NewBytes -Path $paths['post-run-honor-log-snapshot.txt'] -Bytes $script:HonorLogBytes
    Write-NewBytes -Path $paths['post-run-error-log-snapshot.txt'] -Bytes $script:ErrorLogBytes
    $beforeTsv = if ($null -ne $script:DumpPvp) { $script:DumpPvp.CanonicalTsv } else { "guid`thonor`tconquest`tweekly_honor`tweek_begin_day`r`n" }
    $afterTsv = if ($null -ne $script:LivePvp) { $script:LivePvp.CanonicalTsv } else { "guid`thonor`tconquest`tweekly_honor`tweek_begin_day`r`n" }
    $differenceTsv = if ($null -ne $script:PvpDifference) { $script:PvpDifference.DifferenceTsv } else { "status`tguid`tbefore_honor`tbefore_conquest`tbefore_weekly_honor`tbefore_week_begin_day`tafter_honor`tafter_conquest`tafter_weekly_honor`tafter_week_begin_day`r`n" }
    Write-NewUtf8Text -Path $paths['post-run-pvp-before.tsv'] -Text $beforeTsv
    Write-NewUtf8Text -Path $paths['post-run-pvp-after.tsv'] -Text $afterTsv
    Write-NewUtf8Text -Path $paths['post-run-pvp-differences.tsv'] -Text $differenceTsv

    $artifactHashes = [ordered]@{}
    foreach ($name in @(
        'post-run-sql-state.txt',
        'post-run-honor-log-snapshot.txt',
        'post-run-error-log-snapshot.txt',
        'post-run-pvp-before.tsv',
        'post-run-pvp-after.tsv',
        'post-run-pvp-differences.tsv'
    )) {
        $artifactHashes[$name] = Get-LocalSha256 -Path $paths[$name]
    }

    $harnessBytes = [IO.File]::ReadAllBytes($PSCommandPath)
    $harnessHash = Get-BytesSha256 -Bytes $harnessBytes
    if ($harnessHash -cne $ApprovedScriptSha256.ToUpperInvariant()) {
        throw "Audit harness changed immediately before evidence creation. Expected $ApprovedScriptSha256, found $harnessHash."
    }
    $originalEvidenceEntries = @($script:OriginalEvidenceBefore.Keys | Sort-Object | ForEach-Object {
        $entry = $script:OriginalEvidenceBefore[$_]
        [ordered]@{
            relativePath = $_
            bytes = $entry.Bytes
            sha256 = $entry.Sha256
        }
    })

    $result = [ordered]@{
        status = $Status
        originalRunbookExitStatus = 'error'
        originalRunbookFailure = $OriginalRunbookFailure
        migrationReexecuted = $false
        worldserverShutdownRecovery = 'manual'
        originalMariaDbShutdownExitCode = 0
        acceptedOriginalRunFactsEvidenceBasis = 'binding facts supplied by the user; not independently re-derived by this harness'
        auditMariaDbOwnedPid = $script:OwnedDatabasePid
        auditMariaDbShutdownExitCode = 0
        originalEvidenceUnchanged = $script:OriginalEvidenceUnchanged
        originalEvidenceUnchangedDuringAudit = $script:OriginalEvidenceUnchanged
        originalEvidenceExternalAnchorScope = 'nine files listed in backup-evidence-anchor.sha256'
        originalEvidenceCandidateBoundScope = '31 evidence and migration-files entries bound by the reviewed audit-harness identity'
        originalEvidenceExpectedFileCount = $ExpectedOriginalEvidenceFileCount
        originalEvidenceExpectedManifestSha256 = $ExpectedOriginalEvidenceManifestSha256
        originalEvidenceManifestSha256 = $script:OriginalEvidenceManifestSha256
        originalEvidenceManifestEntries = $originalEvidenceEntries
        reviewedRunDirectory = $ReviewedRunDirectory
        backupEvidenceAnchorSha256 = $ExpectedBackupEvidenceAnchorSha256
        anchoredFiles = @($script:AnchorState)
        runtimeFiles = @($script:RuntimeState)
        auditHarness = [ordered]@{
            path = $PSCommandPath
            bytes = [int64]$harnessBytes.Length
            sha256 = $harnessHash
        }
        reviewedRunbook = [ordered]@{
            path = $ReviewedRunbookPath
            bytes = $ExpectedReviewedRunbookBytes
            sha256 = $ExpectedReviewedRunbookSha256
        }
        auditResults = @($script:AuditResults | ForEach-Object { $_ })
        reviewFindings = @($script:ReviewFindings | ForEach-Object { $_ })
        technicalFailure = if ($null -eq $script:TechnicalFailure) { $null } else { $script:TechnicalFailure.Exception.Message }
        cleanupErrors = @($script:CleanupErrors | ForEach-Object { $_ })
        sqlCalls = @($script:SqlCalls)
        migrationTrackingRows = if ($script:SqlState.Contains('MigrationTrackingRows')) { @($script:SqlState.MigrationTrackingRows) } else { @() }
        honorState = if ($script:SqlState.Contains('HonorState')) { $script:SqlState.HonorState } else { $null }
        inventoryEvidence = if ($script:SqlState.Contains('InventoryEvidence')) { $script:SqlState.InventoryEvidence } else { $null }
        sourceLogHashes = [ordered]@{
            honorLog = Get-BytesSha256 -Bytes $script:HonorLogBytes
            errorLog = Get-BytesSha256 -Bytes $script:ErrorLogBytes
        }
        logEvidence = $script:LogState
        pvpAudit = [ordered]@{
            before = if ($null -eq $script:DumpPvp) { $null } else { [ordered]@{ rowCount=$script:DumpPvp.RowCount; normalizedSha256=$script:DumpPvp.NormalizedSha256; summary=$script:DumpPvp.Summary } }
            after = if ($null -eq $script:LivePvp) { $null } else { [ordered]@{ rowCount=$script:LivePvp.RowCount; normalizedSha256=$script:LivePvp.NormalizedSha256; summary=$script:LivePvp.Summary } }
            missingGuids = if ($null -eq $script:PvpDifference) { @() } else { @($script:PvpDifference.MissingGuids) }
            additionalGuids = if ($null -eq $script:PvpDifference) { @() } else { @($script:PvpDifference.AdditionalGuids) }
            changedGuids = if ($null -eq $script:PvpDifference) { @() } else { @($script:PvpDifference.ChangedGuids) }
        }
        initialServerState = $script:InitialServerState
        finalServerState = $script:FinalServerState
        artifactHashes = $artifactHashes
    }
    $json = $result | ConvertTo-Json -Depth 12
    Write-NewUtf8Text -Path $paths['post-run-recovery-result.json'] -Text ($json + "`r`n")

    $manifestLines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($ExpectedRecoveryFiles | Where-Object { $_ -cne 'post-run-recovery-artifacts.sha256' } | Sort-Object)) {
        $manifestLines.Add(("{0} *{1}" -f (Get-LocalSha256 -Path $paths[$name]), $name))
    }
    Write-NewUtf8Text -Path $paths['post-run-recovery-artifacts.sha256'] -Text (($manifestLines -join "`r`n") + "`r`n")

    $actualFiles = @(Get-ChildItem -LiteralPath $RecoveryDirectory -File -Force | Select-Object -ExpandProperty Name | Sort-Object)
    $expectedFiles = @($ExpectedRecoveryFiles | Sort-Object)
    if (($actualFiles -join "`n") -cne ($expectedFiles -join "`n")) {
        throw 'Recovery evidence directory does not contain exactly the approved eight files.'
    }
    foreach ($line in $manifestLines) {
        if ($line -cnotmatch '^([A-F0-9]{64}) \*(.+)$') { throw "Malformed generated recovery manifest line: $line" }
        Assert-LocalHash -Path (Join-Path $RecoveryDirectory $Matches[2]) -ExpectedSha256 $Matches[1]
    }
    Write-Output "[RECOVERY EVIDENCE] status=$Status; directory=$RecoveryDirectory"
    Write-Output "[RECOVERY MANIFEST SHA-256] $(Get-LocalSha256 -Path $paths['post-run-recovery-artifacts.sha256'])"
}

$exitCode = 1
try {
    Assert-SelfIdentity
    Assert-AuditHost
    if (-not (Test-Path -LiteralPath $ReviewedRunDirectory -PathType Container)) {
        throw "Reviewed run directory is missing: $ReviewedRunDirectory"
    }
    $script:InitialServerState = Get-AuditServerState
    Assert-AuditCleanState -State $script:InitialServerState -Description 'Initial clean-state gate'
    Assert-RecoveryDirectoryAbsent

    Import-ReviewedRunbookSubset
    Assert-AllRuntimeHashes
    Assert-BackupEvidenceAnchor
    $script:OriginalEvidenceBefore = Get-OriginalEvidenceManifest
    $script:OriginalEvidenceManifestSha256 = Get-TextSha256 -Text (Get-OriginalEvidenceManifestText -Manifest $script:OriginalEvidenceBefore)
    if ($script:OriginalEvidenceBefore.Count -ne $ExpectedOriginalEvidenceFileCount -or
        $script:OriginalEvidenceManifestSha256 -cne $ExpectedOriginalEvidenceManifestSha256) {
        throw "Original evidence identity mismatch. Expected $ExpectedOriginalEvidenceFileCount files / $ExpectedOriginalEvidenceManifestSha256, found $($script:OriginalEvidenceBefore.Count) files / $($script:OriginalEvidenceManifestSha256)."
    }
    $script:DumpPvp = Get-DumpPvpSnapshot -Path $DumpPath
    Invoke-InventoryEvidenceAudit

    # Recheck every mutable pre-start gate immediately before the only database launch.
    Assert-SelfIdentity
    [void](Get-VerifiedReviewedRunbookText)
    Assert-AllRuntimeHashes
    Assert-BackupEvidenceAnchor
    Assert-OriginalEvidenceUnchanged -Before $script:OriginalEvidenceBefore
    Assert-RecoveryDirectoryAbsent
    $preStartState = Get-AuditServerState
    Assert-AuditCleanState -State $preStartState -Description 'Immediate pre-start clean-state gate'

    $owned = Start-AuditDatabase
    if ($null -eq $owned) { throw 'Start-AuditDatabase did not return an owned MariaDB process.' }
    Assert-DatabasePortOwnership

    Invoke-SchemaAndTrackingAudit
    Invoke-HonorAudit
    $script:LivePvp = Get-LivePvpSnapshot
    $script:PvpDifference = Compare-PvpSnapshots -Before $script:DumpPvp -After $script:LivePvp
    $pvpExact = $script:PvpDifference.MissingGuids.Count -eq 0 -and
        $script:PvpDifference.AdditionalGuids.Count -eq 0 -and
        $script:PvpDifference.ChangedGuids.Count -eq 0
    [void](Add-AuditResult -Name 'character_pvp_currency before/after equality' -Passed $pvpExact -Expected 'missing=0; additional=0; changed=0' -Actual ("missing={0}; additional={1}; changed={2}" -f
        $script:PvpDifference.MissingGuids.Count,
        $script:PvpDifference.AdditionalGuids.Count,
        $script:PvpDifference.ChangedGuids.Count))
}
catch {
    $script:TechnicalFailure = $_
    [Console]::Error.WriteLine("[AUDIT ERROR] $($_.Exception.Message)")
}
finally {
    if ($script:DatabaseStartAttempted -and (Get-Command Get-VerifiedOwnedProcess -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $remainingOwned = Get-VerifiedOwnedProcess -Kind Database
            if ($null -ne $remainingOwned) {
                if ($null -ne $script:OwnedDatabasePid -and $remainingOwned.Id -ne $script:OwnedDatabasePid) {
                    throw "Cleanup refused owned PID $($remainingOwned.Id); recorded PID is $($script:OwnedDatabasePid)."
                }
                if (-not (Stop-OwnedDatabase)) {
                    throw 'Stop-OwnedDatabase returned false during deterministic cleanup.'
                }
                $script:DatabaseStoppedControlled = $true
            }
            elseif ($script:DatabaseStarted) {
                throw 'The owned MariaDB process disappeared before controlled shutdown.'
            }
        }
        catch {
            $script:CleanupErrors.Add($_.Exception.Message)
            [Console]::Error.WriteLine("[CLEANUP ERROR] $($_.Exception.Message)")
        }
    }

    try {
        $script:FinalServerState = Get-AuditServerState
        Assert-AuditCleanState -State $script:FinalServerState -Description 'Final clean-state gate'
    }
    catch {
        $script:CleanupErrors.Add($_.Exception.Message)
        [Console]::Error.WriteLine("[FINAL STATE ERROR] $($_.Exception.Message)")
    }

    if ($script:DatabaseStoppedControlled -and $script:CleanupErrors.Count -eq 0) {
        try {
            Assert-SelfIdentity
            [void](Get-VerifiedReviewedRunbookText)
            Assert-AllRuntimeHashes
            Assert-BackupEvidenceAnchor
            Assert-OriginalEvidenceUnchanged -Before $script:OriginalEvidenceBefore
            $script:OriginalEvidenceUnchanged = $true

            $status = if ($null -ne $script:TechnicalFailure) {
                'failed'
            }
            elseif ($script:ReviewFindings.Count -gt 0) {
                'review_required'
            }
            else {
                'verified_recovery_after_shutdown_helper_failure'
            }
            New-RecoveryEvidence -Status $status
            $exitCode = if ($status -ceq 'verified_recovery_after_shutdown_helper_failure') { 0 } elseif ($status -ceq 'review_required') { 2 } else { 1 }
        }
        catch {
            $script:CleanupErrors.Add($_.Exception.Message)
            [Console]::Error.WriteLine("[EVIDENCE ERROR] $($_.Exception.Message)")
            $exitCode = 1
        }
    }
    else {
        [Console]::Error.WriteLine('[EVIDENCE SKIPPED] Controlled MariaDB shutdown and final clean-state verification were not both successful.')
        $exitCode = 1
    }

    Write-Output ("[FINAL] exitCode={0}; databaseStarted={1}; databaseStoppedControlled={2}; reviewFindings={3}; cleanupErrors={4}" -f
        $exitCode,
        $script:DatabaseStarted,
        $script:DatabaseStoppedControlled,
        $script:ReviewFindings.Count,
        $script:CleanupErrors.Count)
}

exit $exitCode
