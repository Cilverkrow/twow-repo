#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedScriptSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CandidatePath = 'C:\TW\ComTW\runbooks\tw-char-migration-db-ready-candidate.ps1'
$ExpectedCandidateByteCount = 92898
$ExpectedCandidateSha256 = 'F92F86D66FEB4C1743F1E09B1CA14101B8249E858CB5B18DC2894AA27E06F881'
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
    'Assert-Administrator',
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
    'Assert-RecordedOfflineSchema',
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
$script:NormalStopCompleted = $false
$script:BeforeManifest = $null
$script:AfterManifest = $null
$script:ManifestComparison = $null
$script:ExecutionFailure = $null
$script:CleanupErrors = New-Object System.Collections.Generic.List[string]
$script:ExitCode = 1

function Get-SmokeSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-SmokeHash {
    param([string]$Path, [string]$ExpectedSha256)

    $actual = Get-SmokeSha256 -Path $Path
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, found $actual."
    }
}

function Assert-SmokeHost {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "This harness requires Windows PowerShell 5.1 Desktop. Found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This harness requires Administrator=True before any server start.'
    }
}

function Get-SmokeServerState {
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

function Write-SmokeServerState {
    param([string]$Label, [object]$State)

    Write-Output ("[{0}] {1}" -f $Label, ($State | ConvertTo-Json -Depth 5 -Compress))
}

function Assert-SmokeCleanState {
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

    $added = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[object]
    $unchanged = 0

    foreach ($path in @($Before.Keys | Sort-Object)) {
        if (-not $After.ContainsKey($path)) {
            $removed.Add($path)
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
            $added.Add($path)
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

function Assert-SmokeCandidateIdentity {
    $item = Get-Item -LiteralPath $CandidatePath -ErrorAction Stop
    if ($item.Length -ne $ExpectedCandidateByteCount) {
        throw "Readiness candidate size mismatch. Expected $ExpectedCandidateByteCount, found $($item.Length)."
    }
    Assert-SmokeHash -Path $CandidatePath -ExpectedSha256 $ExpectedCandidateSha256
}

function Assert-SmokeRuntimeHashes {
    if ($ApprovedFiles.Count -ne $ExpectedRuntimeKeys.Count) {
        throw "The candidate ApprovedFiles map contains $($ApprovedFiles.Count) entries; expected $($ExpectedRuntimeKeys.Count)."
    }
    foreach ($key in $ExpectedRuntimeKeys) {
        if (-not $ApprovedFiles.ContainsKey($key)) {
            throw "The candidate ApprovedFiles map is missing '$key'."
        }
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
        Write-Output ("[RUNTIME HASH] {0}|{1}|{2}" -f $key, $ApprovedFiles[$key].Path, $ApprovedFiles[$key].Sha256)
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'The harness must be executed from its reviewed script file.'
    }
    Assert-SmokeHash -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Assert-SmokeHost
    Assert-SmokeCandidateIdentity

    $candidateTokens = $null
    $candidateErrors = $null
    $candidateAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $CandidatePath,
        [ref]$candidateTokens,
        [ref]$candidateErrors
    )
    if (@($candidateErrors).Count -ne 0) {
        $messages = @($candidateErrors | ForEach-Object { $_.Message }) -join ' | '
        throw "Readiness candidate parser errors: $messages"
    }

    $topLevelStatements = @($candidateAst.EndBlock.Statements)
    $entryPoints = @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    })
    if ($entryPoints.Count -ne 1 -or $topLevelStatements[-1] -ne $entryPoints[0]) {
        throw 'The candidate must contain exactly one final top-level try/catch entry point.'
    }
    $entryPointText = $entryPoints[0].Extent.Text
    if ($entryPointText -notmatch '\bInvoke-ExecuteMode\b' -or
        $entryPointText -notmatch '\bInvoke-RollbackMode\b' -or
        $entryPointText -notmatch '\bAssert-CanonicalScriptFile\b') {
        throw 'The candidate final top-level try/catch entry point did not match the reviewed structure.'
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
        throw 'The candidate contains an unexpected top-level executable statement.'
    }
    Write-Output '[AST] Candidate parser errors=0; final top-level try/catch entry point rejected and excluded.'

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
                throw "Duplicate approved candidate initializer: $name"
            }
            $initializerMap[$name] = $statement
        }
    }
    foreach ($name in $ApprovedInitializerNames) {
        if (-not $initializerMap.ContainsKey($name)) {
            throw "Approved candidate initializer is missing: $name"
        }
        Invoke-Expression $initializerMap[$name].Extent.Text
    }

    $functionMap = @{}
    foreach ($definition in @($topLevelStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
    })) {
        if ($functionMap.ContainsKey($definition.Name)) {
            throw "Duplicate candidate function definition: $($definition.Name)"
        }
        $functionMap[$definition.Name] = $definition
    }
    foreach ($name in $ApprovedFunctionNames) {
        if (-not $functionMap.ContainsKey($name)) {
            throw "Approved candidate function is missing: $name"
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
    Write-Output ("[AST] Loaded initializers={0}; functions={1}; complete candidate was not executed." -f $ApprovedInitializerNames.Count, $ApprovedFunctionNames.Count)

    Assert-Administrator
    Assert-SmokeRuntimeHashes
    $initialState = Get-SmokeServerState
    Write-SmokeServerState -Label 'INITIAL STATE' -State $initialState
    Assert-SmokeCleanState -State $initialState -Description 'Initial clean-state gate'

    $script:BeforeManifest = Get-InMemoryActiveDataManifest -RootPath $DataDir
    Write-Output ("[ACTIVE DATA BEFORE] files={0}" -f $script:BeforeManifest.Count)

    # Repeat every mutable pre-start gate immediately before the single permitted start call.
    Assert-SmokeHash -Path $PSCommandPath -ExpectedSha256 $ApprovedScriptSha256
    Assert-SmokeCandidateIdentity
    Assert-Administrator
    Assert-SmokeRuntimeHashes
    $preStartState = Get-SmokeServerState
    Write-SmokeServerState -Label 'PRE-START STATE' -State $preStartState
    Assert-SmokeCleanState -State $preStartState -Description 'Immediate pre-start clean-state gate'

    $script:StartCallIssued = $true
    $owned = Start-ReviewedDatabase
    if ($null -eq $owned) {
        throw 'Start-ReviewedDatabase did not return an owned MariaDB process.'
    }
    $script:OwnedDatabasePid = [int]$owned.Id
    Write-Output ("[DATABASE] ownedPid={0}" -f $script:OwnedDatabasePid)

    $verifiedOwned = Get-VerifiedOwnedProcess -Kind Database
    if ($null -eq $verifiedOwned -or [int]$verifiedOwned.Id -ne $script:OwnedDatabasePid) {
        throw 'The returned MariaDB process failed the candidate ownership verification.'
    }
    Assert-DatabasePortOwnership
    $portOwners = @(Get-PortOwnerPids)
    Write-Output ("[DATABASE PORT] owners={0}; expectedOwnedPid={1}" -f ($portOwners -join ','), $script:OwnedDatabasePid)

    $identityResult = Invoke-MariaDb -Sql 'SELECT DATABASE()'
    Write-Output ("[SQL IDENTITY] {0}" -f $identityResult)
    if ($identityResult -cne 'tw_char') {
        throw "SQL identity mismatch. Expected 'tw_char', found '$identityResult'."
    }

    Assert-ReviewedDatabaseConfiguration
    Write-Output '[DATABASE CONFIGURATION] PASS'
    Assert-RecordedOfflineSchema
    Write-Output '[RECORDED OFFLINE SCHEMA] PASS'

    $stopped = Stop-OwnedDatabase
    if (-not $stopped) {
        throw 'Stop-OwnedDatabase did not stop the verified owned MariaDB process.'
    }
    $script:NormalStopCompleted = $true
    Write-Output '[DATABASE SHUTDOWN] PASS'

    $postStopState = Get-SmokeServerState
    Write-SmokeServerState -Label 'POST-STOP STATE' -State $postStopState
    Assert-SmokeCleanState -State $postStopState -Description 'Post-stop clean-state gate'

    $script:AfterManifest = Get-InMemoryActiveDataManifest -RootPath $DataDir
    $script:ManifestComparison = Compare-InMemoryActiveDataManifests -Before $script:BeforeManifest -After $script:AfterManifest
    Write-Output ("[ACTIVE DATA COMPARISON] {0}" -f ($script:ManifestComparison | ConvertTo-Json -Depth 6 -Compress))
    $script:ExitCode = 0
}
catch {
    $script:ExecutionFailure = $_
    $script:ExitCode = 1
    [Console]::Error.WriteLine("[SMOKE TEST ERROR] $($_.Exception.Message)")
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
        $finalState = Get-SmokeServerState
        if (-not [string]::IsNullOrWhiteSpace($finalState.ServiceInspectionError) -or
            -not [string]::IsNullOrWhiteSpace($finalState.PortInspectionError) -or
            @($finalState.ServerProcesses).Count -ne 0 -or
            @($finalState.MatchingRunningServices).Count -ne 0 -or
            @($finalState.Port3307Listeners).Count -ne 0) {
            $message = 'Final state is not proven clean; inspection errors or foreign/remaining services were reported but not stopped.'
            $script:CleanupErrors.Add($message)
            [Console]::Error.WriteLine("[FINAL STATE ERROR] $message")
        }
    }
    catch {
        $message = "Final process/service/port inspection failed: $($_.Exception.Message)"
        $script:CleanupErrors.Add($message)
        [Console]::Error.WriteLine("[FINAL STATE ERROR] $message")
    }

    if ($null -ne $script:BeforeManifest -and $null -eq $script:AfterManifest -and
        $null -ne $finalState -and @($finalState.ServerProcesses).Count -eq 0) {
        try {
            $script:AfterManifest = Get-InMemoryActiveDataManifest -RootPath $DataDir
            $script:ManifestComparison = Compare-InMemoryActiveDataManifests -Before $script:BeforeManifest -After $script:AfterManifest
            Write-Output ("[ACTIVE DATA COMPARISON AFTER CLEANUP] {0}" -f ($script:ManifestComparison | ConvertTo-Json -Depth 6 -Compress))
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
        Write-Output '[RESULT] READINESS SMOKE PASS'
    }
    else {
        Write-Output '[RESULT] READINESS SMOKE FAILED'
    }
    if ($null -ne $finalState) {
        Write-SmokeServerState -Label 'FINAL STATE' -State $finalState
    }
}

exit $script:ExitCode
