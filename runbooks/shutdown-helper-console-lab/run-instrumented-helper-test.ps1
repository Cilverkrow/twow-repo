[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabDirectory = 'C:\TW\ComTW\runbooks\shutdown-helper-console-lab\attempt-2-instrumented-helper'
$EmitterExecutable = Join-Path $LabDirectory 'mangosd.exe'
$EmitterPidFile = Join-Path $LabDirectory 'twlive.pid'
$EmitterReadyFile = Join-Path $LabDirectory 'emitter-ready.txt'
$EmitterCommandLog = Join-Path $LabDirectory 'received-commands.log'
$EmitterResultFile = Join-Path $LabDirectory 'emitter-result.txt'
$HarnessEventLog = Join-Path $LabDirectory 'harness-events.log'
$ProductionHelper = 'C:\TW\ComTW\runbooks\shutdown-helper-console-lab\instrumented-shutdown-helper.ps1'
$ExpectedProductionHelperSha256 = 'C748771EF236C7943B01732DE95784A3B5F7DD46E31346D7E57807C95D5BBBAF'
$ProductionWorldExecutable = 'C:\TW\ComTW\server\mangosd.exe'
$PowerShell51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

$script:EmitterPid = $null
$script:EmitterProcess = $null
$script:LauncherProcess = $null
$script:EmitterExited = $false
$script:CleanupFailure = $null

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )
    return [string]::Equals(
        (Get-NormalizedPath -Path $First),
        (Get-NormalizedPath -Path $Second),
        [StringComparison]::OrdinalIgnoreCase)
}

function Write-HarnessEvent {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '{0}|{1}' -f [DateTime]::UtcNow.ToString('o'), $Message
    [IO.File]::AppendAllText($HarnessEventLog, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    Write-Output $line
}

function Get-ProcessPathSafe {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    try {
        return $Process.Path
    }
    catch {
        return $null
    }
}

function Assert-InitialServerState {
    $serverProcesses = @(Get-Process -ErrorAction Stop | Where-Object {
        $_.ProcessName -in @('mariadb', 'mysqld', 'mangosd', 'realmd')
    })
    if ($serverProcesses.Count -ne 0) {
        $description = @($serverProcesses | ForEach-Object {
            '{0}:{1}:{2}' -f $_.ProcessName, $_.Id, (Get-ProcessPathSafe -Process $_)
        }) -join '; '
        throw "A server process already exists: $description"
    }

    $netstat = @(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "netstat failed with exit code $LASTEXITCODE."
    }
    $listeners = @($netstat | Where-Object {
        $_ -match '^\s*TCP\s+\S+:3307\s+\S+\s+LISTENING\s+\d+\s*$'
    })
    if ($listeners.Count -ne 0) {
        throw "Port 3307 already has a listener: $($listeners -join '; ')"
    }
}

function Wait-ForEmitterReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $EmitterReadyFile -PathType Leaf) {
            return
        }
        if ($null -ne $script:LauncherProcess) {
            $script:LauncherProcess.Refresh()
            if ($script:LauncherProcess.HasExited) {
                throw "The emitter launcher exited before readiness with code $($script:LauncherProcess.ExitCode)."
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Timed out waiting for emitter-ready.txt.'
}

function Get-ValidatedEmitterProcess {
    if (-not (Test-Path -LiteralPath $EmitterPidFile -PathType Leaf)) {
        throw "Emitter PID file is missing: $EmitterPidFile"
    }

    $pidText = [IO.File]::ReadAllText($EmitterPidFile).Trim()
    $pidValue = 0
    if (-not [int]::TryParse($pidText, [ref]$pidValue) -or $pidValue -le 0) {
        throw "Emitter PID is invalid: '$pidText'"
    }

    $process = Get-Process -Id $pidValue -ErrorAction Stop
    $actualPath = Get-ProcessPathSafe -Process $process
    if ([string]::IsNullOrWhiteSpace($actualPath)) {
        throw "Emitter process path is unavailable for PID $pidValue."
    }
    if (-not (Test-SamePath -First $actualPath -Second $EmitterExecutable)) {
        throw "Emitter PID $pidValue has an unexpected executable path: $actualPath"
    }
    if (Test-SamePath -First $actualPath -Second $ProductionWorldExecutable) {
        throw 'Emitter safety validation resolved to the production mangosd.exe.'
    }

    $readyLines = [IO.File]::ReadAllLines($EmitterReadyFile)
    if (-not ($readyLines -ccontains "PID=$pidValue")) {
        throw 'Emitter readiness PID does not match twlive.pid.'
    }
    if (-not ($readyLines -ccontains "EXE=$actualPath")) {
        throw 'Emitter readiness executable path does not match the live process.'
    }
    if (-not ($readyLines -ccontains 'TITLE=mangosd')) {
        throw 'Emitter console title is not exactly mangosd.'
    }

    $script:EmitterPid = $pidValue
    $script:EmitterProcess = $process
    return $process
}

function Stop-ValidatedDisposableEmitterIfNeeded {
    if ($null -eq $script:EmitterPid) {
        return
    }

    $process = Get-Process -Id $script:EmitterPid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return
    }

    $actualPath = Get-ProcessPathSafe -Process $process
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not (Test-SamePath -First $actualPath -Second $EmitterExecutable) -or
        (Test-SamePath -First $actualPath -Second $ProductionWorldExecutable)) {
        throw "Cleanup refused PID $($script:EmitterPid) because its executable identity is not the disposable emitter."
    }

    Write-HarnessEvent "CLEANUP_KILL_AUTHORIZED|PID=$($script:EmitterPid)|PATH=$actualPath"
    $process.Kill()
    if (-not $process.WaitForExit(5000)) {
        throw "The validated disposable emitter PID $($script:EmitterPid) did not exit after cleanup."
    }
    Write-HarnessEvent "CLEANUP_KILL_COMPLETE|PID=$($script:EmitterPid)|EXIT_CODE=$($process.ExitCode)"
}

$exitCode = 1
try {
    if (-not (Test-Path -LiteralPath $LabDirectory -PathType Container)) {
        throw "Lab directory is missing: $LabDirectory"
    }
    if (-not (Test-Path -LiteralPath $EmitterExecutable -PathType Leaf)) {
        throw "Disposable emitter is missing: $EmitterExecutable"
    }
    if (-not (Test-Path -LiteralPath $ProductionHelper -PathType Leaf)) {
        throw "Production shutdown helper is missing: $ProductionHelper"
    }
    if ((Get-Sha256 -Path $ProductionHelper) -cne $ExpectedProductionHelperSha256) {
        throw 'Production shutdown helper hash mismatch.'
    }
    if (-not (Test-Path -LiteralPath $PowerShell51 -PathType Leaf)) {
        throw "Windows PowerShell 5.1 is missing: $PowerShell51"
    }
    foreach ($evidencePath in @($EmitterPidFile, $EmitterReadyFile, $EmitterCommandLog, $EmitterResultFile, $HarnessEventLog)) {
        if (Test-Path -LiteralPath $evidencePath) {
            throw "A test evidence path already exists: $evidencePath"
        }
    }

    Assert-InitialServerState
    Write-HarnessEvent "PRECHECK_PASS|HELPER_SHA256=$ExpectedProductionHelperSha256|EMITTER_SHA256=$(Get-Sha256 -Path $EmitterExecutable)"

    $script:LauncherProcess = Start-Process -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/c', 'title mangosd & mangosd.exe') `
        -WorkingDirectory $LabDirectory `
        -WindowStyle Normal `
        -PassThru
    Write-HarnessEvent "EMITTER_LAUNCHER_STARTED|PID=$($script:LauncherProcess.Id)|PATH=$($script:LauncherProcess.Path)"

    Wait-ForEmitterReady
    $emitter = Get-ValidatedEmitterProcess
    Write-HarnessEvent "EMITTER_VALIDATED|PID=$($emitter.Id)|PATH=$($emitter.Path)|TITLE=mangosd"

    Write-HarnessEvent 'HELPER_INVOKE_BEGIN|ACTION=World|SAVE_DELAY_SECONDS=1|EXIT_TIMEOUT_SECONDS=20'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    & $PowerShell51 `
        -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $ProductionHelper `
        -Action World `
        -ServerDirectory $LabDirectory `
        -WorldWindowTitle 'mangosd' `
        -SaveDelaySeconds 1 `
        -WorldExitTimeoutSeconds 20
    $helperExitCode = $LASTEXITCODE
    $stopwatch.Stop()
    Write-HarnessEvent "HELPER_INVOKE_END|EXIT_CODE=$helperExitCode|ELAPSED_MILLISECONDS=$($stopwatch.ElapsedMilliseconds)"

    if (-not $emitter.WaitForExit(5000)) {
        throw "Disposable emitter PID $($emitter.Id) remained active after the helper returned."
    }
    $script:EmitterExited = $true
    $emitterExitCode = $emitter.ExitCode
    Write-HarnessEvent "EMITTER_EXITED|PID=$($emitter.Id)|EXIT_CODE=$emitterExitCode"

    if (-not $script:LauncherProcess.WaitForExit(5000)) {
        throw "Emitter launcher PID $($script:LauncherProcess.Id) did not exit."
    }
    Write-HarnessEvent "EMITTER_LAUNCHER_EXITED|PID=$($script:LauncherProcess.Id)|EXIT_CODE=$($script:LauncherProcess.ExitCode)"

    if (-not (Test-Path -LiteralPath $EmitterCommandLog -PathType Leaf)) {
        throw 'received-commands.log was not created.'
    }
    if (-not (Test-Path -LiteralPath $EmitterResultFile -PathType Leaf)) {
        throw 'emitter-result.txt was not created.'
    }

    $receivedLines = [IO.File]::ReadAllLines($EmitterCommandLog)
    $resultLines = [IO.File]::ReadAllLines($EmitterResultFile)
    Write-HarnessEvent "RECEIVED_LINE_COUNT=$($receivedLines.Count)"
    foreach ($line in $receivedLines) {
        Write-HarnessEvent "RECEIVED_COMMAND_RECORD|$line"
    }
    foreach ($line in $resultLines) {
        Write-HarnessEvent "EMITTER_RESULT|$line"
    }

    $saveHex = [BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes('saveall')).Replace('-', '')
    $shutdownHex = [BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes('server shutdown 0')).Replace('-', '')
    if ($receivedLines.Count -ne 2 -or
        $receivedLines[0] -notmatch "\|SEQUENCE=1\|HEX=$saveHex\|TEXT=saveall$" -or
        $receivedLines[1] -notmatch "\|SEQUENCE=2\|HEX=$shutdownHex\|TEXT=server shutdown 0$") {
        throw 'The received command sequence or spelling is incorrect.'
    }
    if ($helperExitCode -ne 0) {
        throw "Production helper returned exit code $helperExitCode."
    }
    if ($emitterExitCode -ne 0) {
        throw "Disposable emitter returned exit code $emitterExitCode."
    }
    if (-not ($resultLines -ccontains 'SAVEALL_SEEN=true') -or
        -not ($resultLines -ccontains 'RECEIVED_LINE_COUNT=2') -or
        -not ($resultLines -ccontains 'REASON=server_shutdown_0_received')) {
        throw 'Emitter result evidence is incomplete or incorrect.'
    }

    Write-HarnessEvent 'TEST_PASS'
    $exitCode = 0
}
catch {
    [Console]::Error.WriteLine("[LAB ERROR] $($_.Exception.Message)")
    if (Test-Path -LiteralPath $LabDirectory -PathType Container) {
        try {
            Write-HarnessEvent "TEST_FAILURE|MESSAGE=$($_.Exception.Message)"
        }
        catch {
            [Console]::Error.WriteLine("[LAB LOG ERROR] $($_.Exception.Message)")
        }
    }
}
finally {
    try {
        Stop-ValidatedDisposableEmitterIfNeeded
    }
    catch {
        $script:CleanupFailure = $_.Exception.Message
        [Console]::Error.WriteLine("[LAB CLEANUP ERROR] $($script:CleanupFailure)")
        $exitCode = 1
    }

    $remaining = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('mariadb', 'mysqld', 'mangosd', 'realmd')
    })
    if ($remaining.Count -eq 0) {
        Write-Output 'FINAL_SERVER_PROCESSES=NONE'
    }
    else {
        foreach ($process in $remaining) {
            Write-Output ("FINAL_SERVER_PROCESS|NAME={0}|PID={1}|PATH={2}" -f `
                $process.ProcessName, $process.Id, (Get-ProcessPathSafe -Process $process))
        }
        $exitCode = 1
    }

    $netstat = @(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1)
    $listeners = @($netstat | Where-Object {
        $_ -match '^\s*TCP\s+\S+:3307\s+\S+\s+LISTENING\s+\d+\s*$'
    })
    if ($LASTEXITCODE -eq 0 -and $listeners.Count -eq 0) {
        Write-Output 'FINAL_PORT_3307=CLOSED'
    }
    else {
        Write-Output "FINAL_PORT_3307_CHECK_FAILED|NETSTAT_EXIT=$LASTEXITCODE|LISTENERS=$($listeners -join '; ')"
        $exitCode = 1
    }
}

exit $exitCode
