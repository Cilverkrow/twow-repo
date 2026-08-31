#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedScriptSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReviewedRunbookPath = 'C:\TW\ComTW\runbooks\tw-char-migration-F92F86D6.ps1'
$ExpectedReviewedRunbookByteCount = 92898
$ExpectedReviewedRunbookSha256 = 'F92F86D66FEB4C1743F1E09B1CA14101B8249E858CB5B18DC2894AA27E06F881'
$FailedRunDirectory = 'E:\TWoW-Migration-Backups\tw-char-migration-20260827-191328'
$ExpectedBackupEvidenceAnchorSha256 = 'DC2144A911887599185C4B7D2F5717068E91E21D9EC2A5A62F4D1375E5D40D79'
$FailedRunEvidenceRelativePaths = @(
    'evidence\tw_char.pre-migration.sql',
    'evidence\tw_char.pre-migration.stderr.log',
    'evidence\backup-evidence-anchor.sha256'
)
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
    'Test-PortOpen',
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
    'Assert-DatabasePortOwnership',
    'Wait-ForDatabaseReady',
    'Assert-ReviewedDatabaseConfiguration',
    'Stop-OwnedDatabase',
    'Start-ReviewedDatabase'
)

$ProhibitedCommandNames = @(
    'Invoke-ExecuteMode',
    'Invoke-RollbackMode',
    'Invoke-LogicalDump',
    'Invoke-SqlFile',
    'Invoke-MariaDbExport',
    'Invoke-ReviewedMigrations',
    'Register-Migration',
    'Enable-MigrationsModuleColumn',
    'Start-ReviewedWorld',
    'Stop-OwnedWorld',
    'Wait-ForHonorMaintenance',
    'taskkill',
    'robocopy'
)

$script:StartCallIssued = $false
$script:OwnedDatabasePid = $null
$script:BeforeManifest = $null
$script:AfterManifest = $null
$script:ManifestComparison = $null
$script:ExecutionFailure = $null
$script:CleanupErrors = New-Object System.Collections.Generic.List[string]
$script:AcceptedWarningCount = 0
$script:InspectionQueriesAttempted = 0
$script:InspectionQueriesCompleted = 0
$script:InspectionQueryErrors = New-Object System.Collections.Generic.List[string]
$script:ExitCode = 1

# Start-ReviewedDatabase retains its reviewed read-only identity and runtime-configuration safety probes.
# The five fixed statements below are the only schema-inspection queries.
$InspectionSql = [ordered]@{
    ModuleMetadata = @'
SELECT CONCAT_WS('|',
  COLUMN_NAME,
  DATA_TYPE,
  COLUMN_TYPE,
  CHARACTER_MAXIMUM_LENGTH,
  IS_NULLABLE,
  COALESCE(CONCAT('[',COLUMN_DEFAULT,']'),'<NULL>'),
  COALESCE(HEX(COLUMN_DEFAULT),'<NULL>'),
  CHARACTER_SET_NAME,
  COLLATION_NAME,
  ORDINAL_POSITION
)
FROM information_schema.columns
WHERE table_schema=DATABASE()
  AND table_name='migrations'
  AND column_name='Module';
'@
    TableDefinition = @'
SHOW CREATE TABLE migrations;
'@
    TrackingCount = @'
SELECT COUNT(*) FROM migrations;
'@
    TrackingRows = @'
SELECT
  Name,
  UPPER(Hash),
  Module,
  DATE_FORMAT(AppliedAt,'%Y-%m-%d %H:%i:%s')
FROM migrations
ORDER BY Name;
'@
    MigrationProof = @'
SELECT CONCAT_WS('|',
  (SELECT COUNT(DISTINCT index_name)
   FROM information_schema.statistics
   WHERE table_schema=DATABASE()
     AND table_name='ai_playerbot_random_bots'
     AND index_name='idx_owner_bot_event'),

  (SELECT COUNT(*)
   FROM information_schema.columns
   WHERE table_schema=DATABASE()
     AND table_name='guild_bank_money'
     AND column_name='money'
     AND data_type='int'
     AND column_type NOT LIKE '%unsigned%'
     AND is_nullable='NO'),

  (SELECT COUNT(*)
   FROM information_schema.tables
   WHERE table_schema=DATABASE()
     AND table_name='character_inventory_copy')
);
'@
}

function Get-InspectionSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ByteArraySha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-InspectionHash {
    param([string]$Path, [string]$ExpectedSha256)

    $actual = Get-InspectionSha256 -Path $Path
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, found $actual."
    }
}

function Assert-InspectionHost {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "This harness requires Windows PowerShell 5.1 Desktop. Found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This harness requires Administrator=True before any server start.'
    }
}

function Get-InspectionServerState {
    $processes = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = try { $process.Path } catch { '<unavailable>' }
            $processes.Add([pscustomobject]@{
                Name = $process.ProcessName
                Pid = $process.Id
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
                PathName = $_.PathName
            }
        })
    }
    catch {
        $serviceInspectionError = $_.Exception.Message
        $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Running' -and
            (($_.Name + ' ' + $_.DisplayName) -match '(?i)mariadb|mysql|mysqld|mangosd|realmd|twow|turtle')
        } | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                DisplayName = $_.DisplayName
                Status = $_.Status.ToString()
                PathName = '<unavailable>'
            }
        })
    }

    $portInspectionError = $null
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
            $_.LocalPort -eq 3307
        } | ForEach-Object {
            [pscustomobject]@{
                LocalAddress = $_.LocalAddress
                LocalPort = $_.LocalPort
                OwningProcess = $_.OwningProcess
            }
        })
    }
    catch {
        $portInspectionError = $_.Exception.Message
        $listeners = @()
    }

    return [pscustomobject]@{
        ServerProcesses = @($processes | ForEach-Object { $_ })
        MatchingRunningServices = $services
        Port3307Listeners = $listeners
        ServiceInspectionError = $serviceInspectionError
        PortInspectionError = $portInspectionError
    }
}

function Write-InspectionServerState {
    param([string]$Label, [object]$State)

    Write-Output ("[{0}] {1}" -f $Label, ($State | ConvertTo-Json -Depth 5 -Compress))
}

function Assert-InspectionCleanState {
    param([object]$State, [string]$Description)

    if (-not [string]::IsNullOrWhiteSpace($State.ServiceInspectionError)) {
        throw "$Description failed: Windows service inspection was incomplete: $($State.ServiceInspectionError)"
    }
    if (-not [string]::IsNullOrWhiteSpace($State.PortInspectionError)) {
        throw "$Description failed: port inspection was incomplete: $($State.PortInspectionError)"
    }
    if (@($State.ServerProcesses).Count -ne 0) {
        throw "$Description failed: a MariaDB, mangosd, or realmd process is active."
    }
    if (@($State.MatchingRunningServices).Count -ne 0) {
        throw "$Description failed: a matching Windows service is running."
    }
    if (@($State.Port3307Listeners).Count -ne 0) {
        throw "$Description failed: port 3307 has a listener."
    }
}

function Get-InMemoryActiveDataManifest {
    param([string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        throw "Active data directory is missing: $RootPath"
    }

    $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    $manifest = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Force -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($manifest.ContainsKey($relative)) {
            throw "Duplicate active-data path under case-insensitive comparison: $relative"
        }
        $manifest.Add($relative, [pscustomobject]@{
            Length = [int64]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        })
    }
    return $manifest
}

function Compare-InMemoryActiveDataManifests {
    param([object]$Before, [object]$After)

    $added = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[object]
    $changed = New-Object System.Collections.Generic.List[object]
    $unchanged = 0

    foreach ($path in @($Before.Keys | Sort-Object)) {
        if (-not $After.ContainsKey($path)) {
            $old = $Before[$path]
            $removed.Add([pscustomobject]@{
                Path = $path
                BeforeLength = $old.Length
                BeforeSha256 = $old.Sha256
            })
            continue
        }
        $old = $Before[$path]
        $new = $After[$path]
        if ($old.Length -ne $new.Length -or $old.Sha256 -cne $new.Sha256) {
            $changed.Add([pscustomobject]@{
                Path = $path
                BeforeLength = $old.Length
                AfterLength = $new.Length
                BeforeSha256 = $old.Sha256
                AfterSha256 = $new.Sha256
            })
        }
        else {
            $unchanged++
        }
    }

    foreach ($path in @($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($path)) {
            $new = $After[$path]
            $added.Add([pscustomobject]@{
                Path = $path
                AfterLength = $new.Length
                AfterSha256 = $new.Sha256
            })
        }
    }

    return [pscustomobject]@{
        BeforeCount = $Before.Count
        AfterCount = $After.Count
        Added = @($added | ForEach-Object { $_ })
        Removed = @($removed | ForEach-Object { $_ })
        Changed = @($changed | ForEach-Object { $_ })
        Unchanged = $unchanged
    }
}

function Get-VerifiedReviewedRunbookText {
    $item = Get-Item -LiteralPath $ReviewedRunbookPath -ErrorAction Stop
    if ($item.Length -ne $ExpectedReviewedRunbookByteCount) {
        throw "Reviewed runbook size mismatch. Expected $ExpectedReviewedRunbookByteCount, found $($item.Length)."
    }
    $bytes = [System.IO.File]::ReadAllBytes($ReviewedRunbookPath)
    if ($bytes.Length -ne $ExpectedReviewedRunbookByteCount) {
        throw "Reviewed runbook changed while it was read. Expected $ExpectedReviewedRunbookByteCount bytes, read $($bytes.Length)."
    }
    $actualSha256 = Get-ByteArraySha256 -Bytes $bytes
    if ($actualSha256 -cne $ExpectedReviewedRunbookSha256) {
        throw "Reviewed runbook SHA-256 mismatch. Expected $ExpectedReviewedRunbookSha256, found $actualSha256."
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $strictUtf8.GetString($bytes)
    }
    catch {
        throw "Reviewed runbook is not valid strict UTF-8: $($_.Exception.Message)"
    }
}

function Assert-ReviewedRunbookIdentity {
    [void](Get-VerifiedReviewedRunbookText)
}

function Assert-InspectionRuntimeHashes {
    if ($ApprovedFiles.Count -ne $ExpectedRuntimeKeys.Count) {
        throw "The reviewed runbook ApprovedFiles map contains $($ApprovedFiles.Count) entries; expected $($ExpectedRuntimeKeys.Count)."
    }
    foreach ($key in $ExpectedRuntimeKeys) {
        if (-not $ApprovedFiles.ContainsKey($key)) {
            throw "The reviewed runbook ApprovedFiles map is missing '$key'."
        }
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
        Write-Output ("[RUNTIME HASH] {0}|{1}|{2}" -f $key, $ApprovedFiles[$key].Path, $ApprovedFiles[$key].Sha256)
    }
}

function Get-FailedRunEvidenceState {
    $runRoot = [System.IO.Path]::GetFullPath($FailedRunDirectory).TrimEnd('\')
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $FailedRunEvidenceRelativePaths) {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $runRoot $relativePath))
        if (-not $fullPath.StartsWith($runRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Failed-run evidence path escapes its run directory: $relativePath"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Required failed-run evidence is missing: $fullPath"
        }
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        $items.Add([pscustomobject]@{
            RelativePath = $relativePath.Replace('\', '/')
            FullPath = $fullPath
            Length = [int64]$item.Length
            Sha256 = Get-InspectionSha256 -Path $fullPath
        })
    }
    return @($items | ForEach-Object { $_ })
}

function Assert-FailedRunEvidence {
    $items = @(Get-FailedRunEvidenceState)
    $anchor = @($items | Where-Object {
        $_.RelativePath -ceq 'evidence/backup-evidence-anchor.sha256'
    })
    if ($anchor.Count -ne 1) {
        throw 'The failed-run evidence anchor was not identified uniquely.'
    }
    if ($anchor[0].Sha256 -cne $ExpectedBackupEvidenceAnchorSha256) {
        throw "Failed-run evidence-anchor SHA-256 mismatch. Expected $ExpectedBackupEvidenceAnchorSha256, found $($anchor[0].Sha256)."
    }
    foreach ($item in $items) {
        Write-Output ("[FAILED RUN EVIDENCE] {0}|bytes={1}|sha256={2}" -f $item.FullPath, $item.Length, $item.Sha256)
    }
    Write-Output ("[FAILED RUN ANCHOR] PASS|sha256={0}" -f $anchor[0].Sha256)
}

function Get-Utf8StringSha256 {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $bytes = $Utf8NoBom.GetBytes($Text)
    return Get-ByteArraySha256 -Bytes $bytes
}

function Invoke-InspectionSqlExact {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ModuleMetadata', 'TableDefinition', 'TrackingCount', 'TrackingRows', 'MigrationProof')]
        [string]$Name
    )

    if (-not $InspectionSql.Contains($Name)) {
        throw "Unknown inspection SQL name: $Name"
    }
    $sql = [string]$InspectionSql[$Name]
    if ($sql -match '(?im)^\s*(ALTER|DROP|CREATE|INSERT|UPDATE|DELETE|REPLACE|TRUNCATE|GRANT|REVOKE|LOAD|CALL|DO|SET)\b') {
        throw "Write-capable SQL was rejected for inspection query '$Name'."
    }

    $arguments = @(
        '--protocol=TCP', "--host=$DatabaseHost", "--port=$DatabasePort", "--user=$DatabaseUser",
        '--batch', '--raw', '--skip-column-names', '--default-character-set=utf8mb4',
        "--database=$DatabaseName", "--execute=$sql"
    )
    $result = Invoke-ProcessWithCapturedOutput -FilePath $MariaDbClient -ArgumentList $arguments
    $rawStdout = if ($null -eq $result.Stdout) { '' } else { [string]$result.Stdout }
    $rawStderr = if ($null -eq $result.Stderr) { '' } else { [string]$result.Stderr }
    $stderrForValidation = $rawStderr.Trim()

    if ([int]$result.ExitCode -ne 0) {
        $diagnostic = if ([string]::IsNullOrWhiteSpace($rawStderr)) { '<empty>' } else { $rawStderr }
        throw "Inspection query '$Name' failed with exit code $($result.ExitCode). stderr: $diagnostic"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrForValidation)) {
        if ($stderrForValidation -cne $MariaDbPasswordlessTlsWarning) {
            throw "Inspection query '$Name' returned unexpected stderr on successful exit: $rawStderr"
        }
        $script:AcceptedWarningCount++
        [Console]::Error.WriteLine("[ACCEPTED MARIADB CLIENT WARNING][$Name] $stderrForValidation")
    }

    $script:InspectionQueriesCompleted++
    return [pscustomobject]@{
        Name = $Name
        Stdout = $rawStdout
        Stderr = $rawStderr
        ExitCode = [int]$result.ExitCode
    }
}

function Write-ExactSqlCapture {
    param([Parameter(Mandatory = $true)][object]$Result)

    $stdout = [string]$Result.Stdout
    $bytes = $Utf8NoBom.GetBytes($stdout)
    $base64 = [Convert]::ToBase64String($bytes)
    $sha256 = Get-Utf8StringSha256 -Text $stdout
    [Console]::Out.WriteLine(("[SQL STDOUT BEGIN] {0}|utf8Bytes={1}|sha256={2}" -f $Result.Name, $bytes.Length, $sha256))
    [Console]::Out.Write($stdout)
    if ($stdout.Length -eq 0 -or -not $stdout.EndsWith("`n", [StringComparison]::Ordinal)) {
        [Console]::Out.WriteLine()
    }
    [Console]::Out.WriteLine(("[SQL STDOUT END] {0}" -f $Result.Name))
    [Console]::Out.WriteLine(("[SQL STDOUT BASE64] {0}|{1}" -f $Result.Name, $base64))
}

function Invoke-AndWriteInspectionSql {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ModuleMetadata', 'TableDefinition', 'TrackingCount', 'TrackingRows', 'MigrationProof')]
        [string]$Name
    )

    $script:InspectionQueriesAttempted++
    try {
        Write-ExactSqlCapture -Result (Invoke-InspectionSqlExact -Name $Name)
    }
    catch {
        $message = "Inspection query '$Name' failed: $($_.Exception.Message)"
        $script:InspectionQueryErrors.Add($message)
        [Console]::Error.WriteLine("[INSPECTION QUERY ERROR][$Name] $($_.Exception.Message)")
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'The inspection harness must be executed from its reviewed script file.'
    }
    Assert-InspectionHash -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Assert-InspectionHost
    Assert-FailedRunEvidence

    $runbookText = Get-VerifiedReviewedRunbookText
    $runbookTokens = $null
    $runbookErrors = $null
    $runbookAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $runbookText,
        [ref]$runbookTokens,
        [ref]$runbookErrors
    )
    if (@($runbookErrors).Count -ne 0) {
        $messages = @($runbookErrors | ForEach-Object { $_.Message }) -join ' | '
        throw "Reviewed runbook parser errors: $messages"
    }

    $topLevelStatements = @($runbookAst.EndBlock.Statements)
    $entryPoints = @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    })
    if ($entryPoints.Count -ne 1 -or $topLevelStatements[-1] -ne $entryPoints[0]) {
        throw 'The reviewed runbook must contain exactly one final top-level try/catch entry point.'
    }
    $entryPointText = $entryPoints[0].Extent.Text
    if ($entryPointText -notmatch '\bInvoke-ExecuteMode\b' -or
        $entryPointText -notmatch '\bInvoke-RollbackMode\b' -or
        $entryPointText -notmatch '\bAssert-CanonicalScriptFile\b') {
        throw 'The reviewed runbook final top-level entry point did not match the approved structure.'
    }

    $otherPipelines = @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.PipelineAst] -and
        $_.Extent.Text -cne 'Set-StrictMode -Version Latest'
    })
    $unexpectedTopLevel = @($topLevelStatements | Where-Object {
        $_ -isnot [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $_ -isnot [System.Management.Automation.Language.TryStatementAst] -and
        $_ -isnot [System.Management.Automation.Language.PipelineAst]
    })
    if ($otherPipelines.Count -ne 0 -or $unexpectedTopLevel.Count -ne 0) {
        throw 'The reviewed runbook contains an unexpected top-level executable statement.'
    }
    Write-Output '[AST] Reviewed runbook parser errors=0; complete top-level entry point rejected and excluded.'

    $initializerMap = @{}
    foreach ($statement in @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst]
    })) {
        if ($statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
            continue
        }
        $name = $statement.Left.VariablePath.UserPath
        if ($ApprovedInitializerNames -contains $name) {
            if ($initializerMap.ContainsKey($name)) {
                throw "Duplicate approved runbook initializer: $name"
            }
            $initializerMap[$name] = $statement
        }
    }
    foreach ($name in $ApprovedInitializerNames) {
        if (-not $initializerMap.ContainsKey($name)) {
            throw "Approved runbook initializer is missing: $name"
        }
        Invoke-Expression $initializerMap[$name].Extent.Text
    }

    $functionMap = @{}
    foreach ($definition in @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
    })) {
        if ($functionMap.ContainsKey($definition.Name)) {
            throw "Duplicate runbook function definition: $($definition.Name)"
        }
        $functionMap[$definition.Name] = $definition
    }
    foreach ($name in $ApprovedFunctionNames) {
        if (-not $functionMap.ContainsKey($name)) {
            throw "Approved runbook function is missing: $name"
        }
        $definition = $functionMap[$name]
        foreach ($command in @($definition.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))) {
            $commandName = $command.GetCommandName()
            if ($null -ne $commandName -and $ProhibitedCommandNames -contains $commandName) {
                throw "Approved function '$name' references prohibited command '$commandName'."
            }
        }
        Invoke-Expression $definition.Extent.Text
    }
    Write-Output ("[AST] Loaded initializers={0}; functions={1}; reviewed runbook entry point was not executed." -f $ApprovedInitializerNames.Count, $ApprovedFunctionNames.Count)

    Assert-InspectionRuntimeHashes
    $initialState = Get-InspectionServerState
    Write-InspectionServerState -Label 'INITIAL STATE' -State $initialState
    Assert-InspectionCleanState -State $initialState -Description 'Initial clean-state gate'

    $script:BeforeManifest = Get-InMemoryActiveDataManifest -RootPath $DataDir
    Write-Output ("[ACTIVE DATA BEFORE] files={0}" -f $script:BeforeManifest.Count)

    # Repeat every mutable pre-start gate immediately before the one permitted start call.
    Assert-InspectionHash -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Assert-ReviewedRunbookIdentity
    Assert-FailedRunEvidence
    Assert-InspectionHost
    Assert-InspectionRuntimeHashes
    $preStartState = Get-InspectionServerState
    Write-InspectionServerState -Label 'PRE-START STATE' -State $preStartState
    Assert-InspectionCleanState -State $preStartState -Description 'Immediate pre-start clean-state gate'

    $script:StartCallIssued = $true
    $owned = Start-ReviewedDatabase
    if ($null -eq $owned) {
        throw 'Start-ReviewedDatabase did not return an owned MariaDB process.'
    }
    $script:OwnedDatabasePid = [int]$owned.Id
    Write-Output ("[DATABASE] ownedPid={0}" -f $script:OwnedDatabasePid)

    $verifiedOwned = Get-VerifiedOwnedProcess -Kind Database
    if ($null -eq $verifiedOwned -or [int]$verifiedOwned.Id -ne $script:OwnedDatabasePid) {
        throw 'The returned MariaDB process failed the reviewed ownership verification.'
    }
    Assert-DatabasePortOwnership
    $portOwners = @(Get-PortOwnerPids)
    Write-Output ("[DATABASE PORT] owners={0}; expectedOwnedPid={1}" -f ($portOwners -join ','), $script:OwnedDatabasePid)

    Invoke-AndWriteInspectionSql -Name ModuleMetadata
    Invoke-AndWriteInspectionSql -Name TableDefinition
    Invoke-AndWriteInspectionSql -Name TrackingCount
    Invoke-AndWriteInspectionSql -Name TrackingRows
    Invoke-AndWriteInspectionSql -Name MigrationProof
    Write-Output '[MIGRATION PROOF FIELDS] 1=idx_owner_bot_event distinct-index count; 2=signed NOT NULL INT guild_bank_money.money column count; 3=character_inventory_copy table count.'

    if ($script:InspectionQueriesAttempted -ne 5) {
        throw "Inspection query attempt count mismatch. Expected 5, found $($script:InspectionQueriesAttempted)."
    }
    if ($script:InspectionQueryErrors.Count -ne 0 -or $script:InspectionQueriesCompleted -ne 5) {
        throw ("One or more inspection queries failed. attempted={0}; completed={1}; errors={2}" -f
            $script:InspectionQueriesAttempted,
            $script:InspectionQueriesCompleted,
            ($script:InspectionQueryErrors -join ' | '))
    }
    Write-Output ("[INSPECTION SQL] attempted={0}; completed={1}; acceptedWarningCount={2}" -f
        $script:InspectionQueriesAttempted,
        $script:InspectionQueriesCompleted,
        $script:AcceptedWarningCount)
    $script:ExitCode = 0
}
catch {
    $script:ExecutionFailure = $_
    $script:ExitCode = 1
    [Console]::Error.WriteLine("[INSPECTION ERROR] $($_.Exception.Message)")
}
finally {
    if ($script:StartCallIssued -and (Get-Command Get-VerifiedOwnedProcess -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $remainingOwned = Get-VerifiedOwnedProcess -Kind Database
            if ($null -ne $remainingOwned) {
                if ($null -ne $script:OwnedDatabasePid -and [int]$remainingOwned.Id -ne [int]$script:OwnedDatabasePid) {
                    throw "Cleanup refused PID $($remainingOwned.Id) because the recorded owned PID is $($script:OwnedDatabasePid)."
                }
                Write-Output ("[CLEANUP] Stopping verified owned MariaDB PID {0}." -f $remainingOwned.Id)
                if (-not (Stop-OwnedDatabase)) {
                    throw 'Stop-OwnedDatabase returned false during deterministic cleanup.'
                }
                Write-Output '[CLEANUP] Verified owned MariaDB process stopped.'
            }
        }
        catch {
            $message = $_.Exception.Message
            $script:CleanupErrors.Add($message)
            [Console]::Error.WriteLine("[CLEANUP ERROR] $message")
        }
    }

    $finalState = $null
    try {
        $finalState = Get-InspectionServerState
        Assert-InspectionCleanState -State $finalState -Description 'Final clean-state gate'
    }
    catch {
        $message = "Final process/service/port state is not proven clean: $($_.Exception.Message)"
        $script:CleanupErrors.Add($message)
        [Console]::Error.WriteLine("[FINAL STATE ERROR] $message")
    }

    if ($null -ne $script:BeforeManifest -and $null -ne $finalState -and $script:CleanupErrors.Count -eq 0) {
        try {
            $script:AfterManifest = Get-InMemoryActiveDataManifest -RootPath $DataDir
            $script:ManifestComparison = Compare-InMemoryActiveDataManifests -Before $script:BeforeManifest -After $script:AfterManifest
            Write-Output ("[ACTIVE DATA COMPARISON] {0}" -f ($script:ManifestComparison | ConvertTo-Json -Depth 8 -Compress))
        }
        catch {
            $message = "Final active-data comparison failed: $($_.Exception.Message)"
            $script:CleanupErrors.Add($message)
            [Console]::Error.WriteLine("[MANIFEST ERROR] $message")
        }
    }

    if ($script:CleanupErrors.Count -ne 0) {
        $script:ExitCode = 1
    }
    if ($script:ExitCode -eq 0) {
        Write-Output '[RESULT] MODULE INSPECTION PASS'
    }
    else {
        Write-Output '[RESULT] MODULE INSPECTION FAILED'
    }
    if ($null -ne $finalState) {
        Write-InspectionServerState -Label 'FINAL STATE' -State $finalState
    }
}

exit $script:ExitCode
