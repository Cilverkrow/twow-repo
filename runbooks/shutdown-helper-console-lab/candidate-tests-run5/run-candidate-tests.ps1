[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestRoot = 'C:\TW\ComTW\runbooks\shutdown-helper-console-lab\candidate-tests-run5'
$SharedDirectory = Join-Path $TestRoot 'shared'
$SharedEmitter = Join-Path $SharedDirectory 'mangosd.exe'
$HelperCandidate = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully-candidate.ps1'
$LauncherCandidate = 'C:\TW\ComTW\server\start-mangosd-candidate.bat'
$ProductionHelper = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully.ps1'
$ProductionLauncher = 'C:\TW\ComTW\server\start-mangosd.bat'
$ProductionWorld = 'C:\TW\ComTW\server\mangosd.exe'
$ReviewedRunbook = 'C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1'
$PowerShell51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$HarnessEvents = Join-Path $TestRoot 'candidate-test-events.log'
$CriticalManifest = Join-Path $TestRoot 'pretest-critical-files.sha256'

$ExpectedHelperCandidateSha256 = '7741C9D16BD703A2ED069A3FDD87E6FFC39D304547CD65F8A417A84012B360AB'
$ExpectedLauncherCandidateSha256 = '0C9A97A7E528F0A4451AA9CD0637C3246271CBAACD09DFB8895AFCB3C57B82AF'
$ExpectedProductionHelperSha256 = '6582740F7D452EB74ABA368CB70EB33F1683B5511E0169AA0CB98056A2E79884'
$ExpectedProductionLauncherSha256 = '131A0141358D660BAD04AD540BDC170C7CD1B1A99C8AE6AC308EE165B3E6719E'
$ExpectedProductionWorldSha256 = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$ExpectedReviewedRunbookSha256 = '89C6C934B3CAAB861570BE54092A768ACEDACDD6D58DA731884EBDE06669314A'
$ExpectedSharedEmitterSha256 = '1B29F6CA0777A8D0906522AF70A23F4CF0250142E677F58B508212FD51119F20'

$script:CurrentEmitterPid = $null
$script:CurrentEmitterPath = $null
$script:CurrentEmitterStartTimeUtc = $null
$script:CurrentLauncherProcess = $null
$script:CurrentScenarioDirectory = $null
$script:HarnessExitCode = 1
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LabTemp = Join-Path $SharedDirectory 'temp'
if (-not (Test-Path -LiteralPath $LabTemp -PathType Container)) {
    New-Item -ItemType Directory -Path $LabTemp -ErrorAction Stop | Out-Null
}
$env:TEMP = $LabTemp
$env:TMP = $LabTemp

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class LabConsoleCapture
{
    private const int STD_OUTPUT_HANDLE = -11;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SMALL_RECT
    {
        public short Left;
        public short Top;
        public short Right;
        public short Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CONSOLE_SCREEN_BUFFER_INFO
    {
        public COORD Size;
        public COORD CursorPosition;
        public short Attributes;
        public SMALL_RECT Window;
        public COORD MaximumWindowSize;
    }

    public sealed class Marker
    {
        internal Marker(short x, short y, short width)
        {
            X = x;
            Y = y;
            Width = width;
        }

        internal short X { get; private set; }
        internal short Y { get; private set; }
        internal short Width { get; private set; }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleScreenBufferInfo(
        IntPtr consoleOutput,
        out CONSOLE_SCREEN_BUFFER_INFO info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ReadConsoleOutputCharacterW(
        IntPtr consoleOutput,
        StringBuilder characters,
        uint length,
        COORD readCoordinate,
        out uint charactersRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

    public static Marker Mark()
    {
        IntPtr output = GetOutputHandle();
        CONSOLE_SCREEN_BUFFER_INFO info = GetInfo(output);
        return new Marker(info.CursorPosition.X, info.CursorPosition.Y, info.Size.X);
    }

    public static string ReadSince(Marker marker)
    {
        if (marker == null)
            throw new ArgumentNullException("marker");

        IntPtr output = GetOutputHandle();
        CONSOLE_SCREEN_BUFFER_INFO info = GetInfo(output);
        if (info.Size.X != marker.Width)
            throw new InvalidOperationException("The console buffer width changed during helper output capture.");

        long start = ((long)marker.Y * marker.Width) + marker.X;
        long end = ((long)info.CursorPosition.Y * info.Size.X) + info.CursorPosition.X;
        if (end < start)
            throw new InvalidOperationException("The console buffer scrolled during helper output capture.");

        long count = end - start;
        if (count == 0)
            return String.Empty;
        if (count > 1048576)
            throw new InvalidOperationException("The helper console capture exceeded one MiB.");

        COORD origin = new COORD();
        origin.X = marker.X;
        origin.Y = marker.Y;
        StringBuilder buffer = new StringBuilder((int)count);
        uint read;
        if (!ReadConsoleOutputCharacterW(output, buffer, (uint)count, origin, out read))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadConsoleOutputCharacterW failed");
        if (read != (uint)count)
            throw new InvalidOperationException("Only part of the helper console output was captured.");

        return buffer.ToString();
    }

    public static uint WaitForExitCode(IntPtr processHandle, uint milliseconds)
    {
        uint waitResult = WaitForSingleObject(processHandle, milliseconds);
        if (waitResult == WAIT_TIMEOUT)
            throw new TimeoutException("The helper process exceeded its test wait boundary.");
        if (waitResult == WAIT_FAILED)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        if (waitResult != WAIT_OBJECT_0)
            throw new InvalidOperationException(
                String.Format("WaitForSingleObject returned unexpected status 0x{0:X8}.", waitResult));

        uint exitCode;
        if (!GetExitCodeProcess(processHandle, out exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
        return exitCode;
    }

    private static IntPtr GetOutputHandle()
    {
        IntPtr output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (output == IntPtr.Zero || output == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The console output handle is invalid");
        return output;
    }

    private static CONSOLE_SCREEN_BUFFER_INFO GetInfo(IntPtr output)
    {
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(output, out info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetConsoleScreenBufferInfo failed");
        return info;
    }
}
'@

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    return [string]::Equals(
        [IO.Path]::GetFullPath($First).TrimEnd('\'),
        [IO.Path]::GetFullPath($Second).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Write-LabFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite lab evidence: $Path"
    }

    [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Write-LabEvent {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '{0}|{1}' -f [DateTime]::UtcNow.ToString('o'), $Message
    [IO.File]::AppendAllText($HarnessEvents, $line + "`r`n", $Utf8NoBom)
    [Console]::Out.WriteLine($line)
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

function Get-ServerProcesses {
    return @(Get-Process -ErrorAction Stop | Where-Object {
        $_.ProcessName -in @('mariadb', 'mariadbd', 'mysqld', 'mangosd', 'realmd')
    })
}

function Get-Port3307Listeners {
    $netstat = @(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "netstat failed with exit code $LASTEXITCODE."
    }

    return @($netstat | Where-Object {
        $_ -match '^\s*TCP\s+\S+:3307\s+\S+\s+LISTENING\s+\d+\s*$'
    })
}

function Assert-CleanServerState {
    $processes = @(Get-ServerProcesses)
    if ($processes.Count -ne 0) {
        $description = @($processes | ForEach-Object {
            '{0}:{1}:{2}' -f $_.ProcessName, $_.Id, (Get-ProcessPathSafe -Process $_)
        }) -join '; '
        throw "A server-named process is active: $description"
    }

    $listeners = @(Get-Port3307Listeners)
    if ($listeners.Count -ne 0) {
        throw "Port 3307 has a listener: $($listeners -join '; ')"
    }
}

function Assert-ReviewedIdentities {
    $expectations = @(
        [pscustomobject]@{ Path = $HelperCandidate; Hash = $ExpectedHelperCandidateSha256 },
        [pscustomobject]@{ Path = $LauncherCandidate; Hash = $ExpectedLauncherCandidateSha256 },
        [pscustomobject]@{ Path = $ProductionHelper; Hash = $ExpectedProductionHelperSha256 },
        [pscustomobject]@{ Path = $ProductionLauncher; Hash = $ExpectedProductionLauncherSha256 },
        [pscustomobject]@{ Path = $ProductionWorld; Hash = $ExpectedProductionWorldSha256 },
        [pscustomobject]@{ Path = $ReviewedRunbook; Hash = $ExpectedReviewedRunbookSha256 },
        [pscustomobject]@{ Path = $SharedEmitter; Hash = $ExpectedSharedEmitterSha256 }
    )

    foreach ($expectation in $expectations) {
        if (-not (Test-Path -LiteralPath $expectation.Path -PathType Leaf)) {
            throw "Required file is missing: $($expectation.Path)"
        }

        $actual = Get-Sha256 -Path $expectation.Path
        if ($actual -cne $expectation.Hash) {
            throw "SHA-256 mismatch for $($expectation.Path): $actual"
        }
    }
}

function New-ScenarioDirectory {
    param([Parameter(Mandatory = $true)][string]$Name)

    $directory = Join-Path $TestRoot $Name
    if (Test-Path -LiteralPath $directory) {
        throw "Scenario directory already exists: $directory"
    }

    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $SharedEmitter -Destination (Join-Path $directory 'mangosd.exe') -ErrorAction Stop
    return $directory
}

function New-LabLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    Write-LabFile -Path $Path -Content (($Lines -join "`r`n") + "`r`n")
}

function Get-ReadyValues {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            throw "Malformed readiness line: $line"
        }

        $key = $line.Substring(0, $separator)
        if ($values.ContainsKey($key)) {
            throw "Duplicate readiness key: $key"
        }

        $values[$key] = $line.Substring($separator + 1)
    }

    return $values
}

function Wait-ForEmitterReady {
    param(
        [Parameter(Mandatory = $true)][string]$ReadyPath,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$LauncherProcess
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ReadyPath -PathType Leaf) {
            return
        }

        $LauncherProcess.Refresh()
        if ($LauncherProcess.HasExited) {
            throw "Emitter launcher exited before readiness with code $($LauncherProcess.ExitCode)."
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Timed out waiting for emitter readiness: $ReadyPath"
}

function Start-ValidatedEmitter {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioDirectory,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$ExpectedTitle
    )

    $script:CurrentScenarioDirectory = $ScenarioDirectory
    $script:CurrentEmitterPath = Join-Path $ScenarioDirectory 'mangosd.exe'
    $script:CurrentEmitterPid = $null
    $script:CurrentEmitterStartTimeUtc = $null
    $script:CurrentLauncherProcess = $null

    if ((Get-Sha256 -Path $script:CurrentEmitterPath) -cne $ExpectedSharedEmitterSha256) {
        throw "Scenario emitter hash mismatch: $($script:CurrentEmitterPath)"
    }

    $launchAttemptUtc = [DateTime]::UtcNow
    $script:CurrentLauncherProcess = Start-Process -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/c', $LauncherPath) `
        -WorkingDirectory $ScenarioDirectory `
        -WindowStyle Normal `
        -PassThru

    Write-LabEvent "EMITTER_LAUNCH_ATTEMPT|SCENARIO=$([IO.Path]::GetFileName($ScenarioDirectory))|LAUNCHER_PID=$($script:CurrentLauncherProcess.Id)|LAUNCHER=$LauncherPath"

    $readyPath = Join-Path $ScenarioDirectory 'emitter-ready.txt'
    Wait-ForEmitterReady -ReadyPath $readyPath -LauncherProcess $script:CurrentLauncherProcess
    $ready = Get-ReadyValues -Path $readyPath

    $emitterPid = 0
    if (-not [int]::TryParse($ready['PID'], [ref]$emitterPid) -or $emitterPid -le 0) {
        throw "Invalid emitter PID in readiness evidence: $($ready['PID'])"
    }

    $emitter = Get-Process -Id $emitterPid -ErrorAction Stop
    $actualPath = Get-ProcessPathSafe -Process $emitter
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not (Test-SamePath -First $actualPath -Second $script:CurrentEmitterPath) -or
        (Test-SamePath -First $actualPath -Second $ProductionWorld)) {
        throw "Emitter process identity is unsafe for PID ${emitterPid}: $actualPath"
    }

    $startTimeUtc = $emitter.StartTime.ToUniversalTime()
    if ($startTimeUtc -lt $launchAttemptUtc.AddSeconds(-2)) {
        throw "Emitter PID $emitterPid predates its launch attempt."
    }

    if (-not [string]::Equals($ready['EXE'], $actualPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Emitter readiness path does not match the live process: $($ready['EXE'])"
    }

    if (-not [string]::Equals($ready['TITLE'], $ExpectedTitle, [StringComparison]::Ordinal)) {
        throw "Emitter title is '$($ready['TITLE'])' instead of exact '$ExpectedTitle'."
    }

    $script:CurrentEmitterPid = $emitterPid
    $script:CurrentEmitterStartTimeUtc = $startTimeUtc
    Write-LabEvent "EMITTER_VALIDATED|PID=$emitterPid|PATH=$actualPath|TITLE='$($ready['TITLE'])'|TITLE_LENGTH=$($ready['TITLE'].Length)"
    return $emitter
}

function Stop-ValidatedDisposableEmitter {
    param([Parameter(Mandatory = $true)][string]$Reason)

    if ($null -eq $script:CurrentEmitterPid) {
        return
    }

    $process = Get-Process -Id $script:CurrentEmitterPid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        $script:CurrentEmitterPid = $null
        return
    }

    $actualPath = Get-ProcessPathSafe -Process $process
    $actualStartTimeUtc = $process.StartTime.ToUniversalTime()
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not (Test-SamePath -First $actualPath -Second $script:CurrentEmitterPath) -or
        (Test-SamePath -First $actualPath -Second $ProductionWorld) -or
        $actualStartTimeUtc -ne $script:CurrentEmitterStartTimeUtc) {
        throw "Cleanup refused PID $($script:CurrentEmitterPid) because its disposable identity changed."
    }

    Write-LabEvent "DISPOSABLE_CLEANUP_AUTHORIZED|PID=$($process.Id)|PATH=$actualPath|REASON=$Reason"
    $process.Kill()
    if (-not $process.WaitForExit(5000)) {
        throw "Validated disposable emitter PID $($process.Id) did not stop after lab cleanup."
    }

    Write-LabEvent "DISPOSABLE_CLEANUP_COMPLETE|PID=$($process.Id)"
    $script:CurrentEmitterPid = $null
}

function Complete-LauncherWait {
    if ($null -eq $script:CurrentLauncherProcess) {
        return
    }

    if (-not $script:CurrentLauncherProcess.WaitForExit(5000)) {
        throw "Emitter launcher PID $($script:CurrentLauncherProcess.Id) did not exit."
    }

    Write-LabEvent "EMITTER_LAUNCHER_EXITED|PID=$($script:CurrentLauncherProcess.Id)|EXIT_CODE=$($script:CurrentLauncherProcess.ExitCode)"
    $script:CurrentLauncherProcess = $null
}

function Invoke-HelperCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedTitle,
        [Parameter(Mandatory = $true)][int]$ExitTimeoutSeconds
    )

    $transcriptPath = Join-Path $ScenarioDirectory 'helper-console-transcript.txt'
    if (Test-Path -LiteralPath $transcriptPath) {
        throw "Helper transcript already exists: $transcriptPath"
    }

    $visibleConsolePath = Join-Path $ScenarioDirectory 'helper-visible-console.txt'
    if (Test-Path -LiteralPath $visibleConsolePath) {
        throw "Visible console evidence already exists: $visibleConsolePath"
    }

    Start-Transcript -LiteralPath $transcriptPath -NoClobber | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $helperArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $HelperCandidate,
            '-Action',
            'World',
            '-ServerDirectory',
            $ScenarioDirectory,
            '-WorldWindowTitle',
            $ExpectedTitle,
            '-SaveDelaySeconds',
            '1',
            '-WorldExitTimeoutSeconds',
            [string]$ExitTimeoutSeconds
        )

        $consoleMarker = [LabConsoleCapture]::Mark()
        $helperProcess = Start-Process -FilePath $PowerShell51 `
            -ArgumentList $helperArguments `
            -NoNewWindow `
            -PassThru
        $helperWaitMilliseconds = [uint32](($ExitTimeoutSeconds + 30) * 1000)
        $exitCode = [LabConsoleCapture]::WaitForExitCode($helperProcess.Handle, $helperWaitMilliseconds)
        $helperProcess.WaitForExit()
        $visibleConsole = [LabConsoleCapture]::ReadSince($consoleMarker)
    }
    finally {
        $timer.Stop()
        Stop-Transcript | Out-Null
    }

    Write-LabFile -Path $visibleConsolePath -Content $visibleConsole
    Write-LabEvent "HELPER_COMPLETED|SCENARIO=$([IO.Path]::GetFileName($ScenarioDirectory))|EXIT_CODE=$exitCode|ELAPSED_MS=$($timer.ElapsedMilliseconds)"
    return [pscustomobject]@{
        ExitCode = $exitCode
        ElapsedMilliseconds = $timer.ElapsedMilliseconds
        TranscriptPath = $transcriptPath
        VisibleConsolePath = $visibleConsolePath
    }
}

function Get-CommandRecords {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $path = Join-Path $ScenarioDirectory 'received-commands.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Command log is missing: $path"
    }

    return @([IO.File]::ReadAllLines($path))
}

function Assert-ExactShutdownCommands {
    param([Parameter(Mandatory = $true)][string[]]$Records)

    $saveHex = '73617665616C6C'
    $shutdownHex = '7365727665722073687574646F776E2030'
    if ($Records.Count -ne 2 -or
        $Records[0] -notmatch "\|SEQUENCE=1\|HEX=$saveHex\|TEXT=saveall$" -or
        $Records[1] -notmatch "\|SEQUENCE=2\|HEX=$shutdownHex\|TEXT=server shutdown 0$") {
        throw "Unexpected command sequence: $($Records -join ' || ')"
    }
}

function Assert-NoCommands {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $records = @(Get-CommandRecords -ScenarioDirectory $ScenarioDirectory)
    if ($records.Count -ne 0) {
        throw "A rejected scenario received console input: $($records -join ' || ')"
    }
}

function Read-EmitterResult {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $path = Join-Path $ScenarioDirectory 'emitter-result.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Emitter result is missing: $path"
    }

    return @([IO.File]::ReadAllLines($path))
}

function Test-PositiveShutdown {
    $scenario = New-ScenarioDirectory -Name '01-positive-launcher-and-shutdown'
    $candidateCopy = Join-Path $scenario 'start-mangosd-candidate.bat'
    Copy-Item -LiteralPath $LauncherCandidate -Destination $candidateCopy -ErrorAction Stop
    if ((Get-Sha256 -Path $candidateCopy) -cne $ExpectedLauncherCandidateSha256) {
        throw 'The disposable launcher copy differs from the candidate.'
    }

    $outerLauncher = Join-Path $scenario 'outer-launcher-with-trailing-title.bat'
    New-LabLauncher -Path $outerLauncher -Lines @(
        '@echo off',
        'title mangosd ',
        'call start-mangosd-candidate.bat'
    )

    $emitter = Start-ValidatedEmitter -ScenarioDirectory $scenario -LauncherPath $outerLauncher -ExpectedTitle 'mangosd'
    $ready = Get-ReadyValues -Path (Join-Path $scenario 'emitter-ready.txt')
    if ($ready['TITLE'].Length -ne 7) {
        throw "Candidate launcher title length is $($ready['TITLE'].Length), expected 7."
    }

    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExpectedTitle 'mangosd' -ExitTimeoutSeconds 20
    if ($helper.ExitCode -ne 0) {
        throw "Positive helper test returned $($helper.ExitCode)."
    }
    $visible = [IO.File]::ReadAllText($helper.VisibleConsolePath)
    Write-LabEvent "POSITIVE_VISIBLE_CONSOLE_LENGTH=$($visible.Length)"

    if (-not $emitter.WaitForExit(5000)) {
        throw 'Positive emitter remained active after helper success.'
    }
    $script:CurrentEmitterPid = $null
    Complete-LauncherWait

    $records = @(Get-CommandRecords -ScenarioDirectory $scenario)
    Assert-ExactShutdownCommands -Records $records
    $result = @(Read-EmitterResult -ScenarioDirectory $scenario)
    if (-not ($result -ccontains 'EXIT_CODE=0') -or
        -not ($result -ccontains 'SAVEALL_SEEN=true') -or
        -not ($result -ccontains 'RECEIVED_LINE_COUNT=2')) {
        throw "Positive emitter result is incomplete: $($result -join ' | ')"
    }

    Write-LabEvent "TEST_PASS|POSITIVE|HELPER_EXIT=0|EMITTER_EXIT=0|TITLE=mangosd|COMMANDS=saveall,server shutdown 0"
}

function Test-NonzeroExit {
    $scenario = New-ScenarioDirectory -Name '02-nonzero-target-exit'
    $launcher = Join-Path $scenario 'launch-exit-7.bat'
    New-LabLauncher -Path $launcher -Lines @(
        '@echo off',
        'title mangosd',
        'cd /d "%~dp0"',
        'mangosd.exe --shutdown-exit-code 7'
    )

    $emitter = Start-ValidatedEmitter -ScenarioDirectory $scenario -LauncherPath $launcher -ExpectedTitle 'mangosd'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExpectedTitle 'mangosd' -ExitTimeoutSeconds 20
    if ($helper.ExitCode -ne 1) {
        throw "Nonzero-exit helper test returned $($helper.ExitCode), expected 1."
    }

    if (-not $emitter.WaitForExit(5000)) {
        throw 'Exit-7 emitter remained active.'
    }
    $script:CurrentEmitterPid = $null
    Complete-LauncherWait

    $records = @(Get-CommandRecords -ScenarioDirectory $scenario)
    Assert-ExactShutdownCommands -Records $records
    $result = @(Read-EmitterResult -ScenarioDirectory $scenario)
    if (-not ($result -ccontains 'EXIT_CODE=7')) {
        throw "Emitter did not record exit code 7: $($result -join ' | ')"
    }

    $visible = [IO.File]::ReadAllText($helper.VisibleConsolePath)
    if (-not $visible.Contains('[FEHLER] mangosd.exe wurde mit dem unerwarteten Exitcode 7 beendet.')) {
        throw "The exit-code-7 diagnostic was not captured exactly: $visible"
    }
    Write-LabEvent 'TEST_PASS|NONZERO_EXIT|HELPER_EXIT=1|EMITTER_EXIT=7|DIAGNOSTIC_CAPTURED=true|COMMANDS=saveall,server shutdown 0'
}

function Test-WrongTitle {
    $scenario = New-ScenarioDirectory -Name '03-wrong-title'
    $launcher = Join-Path $scenario 'launch-wrong-title.bat'
    New-LabLauncher -Path $launcher -Lines @(
        '@echo off',
        'title wrong-title',
        'cd /d "%~dp0"',
        'mangosd.exe'
    )

    $null = Start-ValidatedEmitter -ScenarioDirectory $scenario -LauncherPath $launcher -ExpectedTitle 'wrong-title'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExpectedTitle 'mangosd' -ExitTimeoutSeconds 20
    if ($helper.ExitCode -ne 1) {
        throw "Wrong-title helper test returned $($helper.ExitCode), expected 1."
    }
    $visible = [IO.File]::ReadAllText($helper.VisibleConsolePath)
    if (-not $visible.Contains("Unerwarteter Konsolentitel") -or
        -not $visible.Contains("'wrong-title' statt 'mangosd'")) {
        throw "The wrong-title diagnostic is incomplete: $visible"
    }

    Assert-NoCommands -ScenarioDirectory $scenario
    Stop-ValidatedDisposableEmitter -Reason 'wrong-title negative test completed'
    Complete-LauncherWait
    Write-LabEvent 'TEST_PASS|WRONG_TITLE|HELPER_EXIT=1|COMMAND_COUNT=0|REJECTED_BEFORE_OPERATION=true'
}

function Test-PidMismatch {
    $scenario = New-ScenarioDirectory -Name '04-pid-mismatch'
    $launcher = Join-Path $scenario 'launch-pid-mismatch.bat'
    New-LabLauncher -Path $launcher -Lines @(
        '@echo off',
        'title mangosd',
        'cd /d "%~dp0"',
        'mangosd.exe'
    )

    $null = Start-ValidatedEmitter -ScenarioDirectory $scenario -LauncherPath $launcher -ExpectedTitle 'mangosd'
    $pidPath = Join-Path $scenario 'twlive.pid'
    [IO.File]::WriteAllText($pidPath, '2147483647', [Text.Encoding]::ASCII)
    Write-LabEvent "PID_FILE_REPLACED_FOR_NEGATIVE_TEST|ACTUAL_PID=$($script:CurrentEmitterPid)|FILE_PID=2147483647"

    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExpectedTitle 'mangosd' -ExitTimeoutSeconds 20
    if ($helper.ExitCode -ne 1) {
        throw "PID-mismatch helper test returned $($helper.ExitCode), expected 1."
    }
    $visible = [IO.File]::ReadAllText($helper.VisibleConsolePath)
    if (-not $visible.Contains('PID-Datei und laufender mangosd-Prozess stimmen nicht ueberein')) {
        throw "The PID-mismatch diagnostic is incomplete: $visible"
    }

    Assert-NoCommands -ScenarioDirectory $scenario
    Stop-ValidatedDisposableEmitter -Reason 'PID-mismatch negative test completed'
    Complete-LauncherWait
    Write-LabEvent 'TEST_PASS|PID_MISMATCH|HELPER_EXIT=1|COMMAND_COUNT=0|REJECTED_BEFORE_ATTACH=true'
}

function Test-Timeout {
    $scenario = New-ScenarioDirectory -Name '05-timeout'
    $launcher = Join-Path $scenario 'launch-timeout.bat'
    New-LabLauncher -Path $launcher -Lines @(
        '@echo off',
        'title mangosd',
        'cd /d "%~dp0"',
        'mangosd.exe --ignore-shutdown'
    )

    $emitter = Start-ValidatedEmitter -ScenarioDirectory $scenario -LauncherPath $launcher -ExpectedTitle 'mangosd'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExpectedTitle 'mangosd' -ExitTimeoutSeconds 10
    if ($helper.ExitCode -ne 1) {
        throw "Timeout helper test returned $($helper.ExitCode), expected 1."
    }
    $visible = [IO.File]::ReadAllText($helper.VisibleConsolePath)
    if (-not $visible.Contains('Es wird kein erzwungener Shutdown ausgefuehrt.')) {
        throw "The timeout diagnostic is incomplete: $visible"
    }

    $records = @(Get-CommandRecords -ScenarioDirectory $scenario)
    Assert-ExactShutdownCommands -Records $records
    $emitter.Refresh()
    if ($emitter.HasExited) {
        throw 'The helper terminated the timeout emitter.'
    }

    Write-LabEvent "TIMEOUT_TARGET_CONFIRMED_ACTIVE|PID=$($emitter.Id)"
    Stop-ValidatedDisposableEmitter -Reason 'timeout test completed after non-termination proof'
    Complete-LauncherWait
    Write-LabEvent 'TEST_PASS|TIMEOUT|HELPER_EXIT=1|TARGET_ACTIVE_AFTER_TIMEOUT=true|COMMANDS=saveall,server shutdown 0'
}

$failure = $null
try {
    if (Test-Path -LiteralPath $HarnessEvents) {
        throw "Harness event log already exists: $HarnessEvents"
    }
    if (Test-Path -LiteralPath $CriticalManifest) {
        throw "Critical manifest already exists: $CriticalManifest"
    }
    if (-not (Test-Path -LiteralPath $PowerShell51 -PathType Leaf)) {
        throw "Windows PowerShell 5.1 is missing: $PowerShell51"
    }

    Assert-ReviewedIdentities
    Assert-CleanServerState
    Write-LabEvent 'INITIAL_GATE_PASS|REAL_SERVER_PROCESSES=NONE|PORT_3307=CLOSED'

    $critical = @(
        $ProductionHelper,
        $ProductionLauncher,
        $ProductionWorld,
        $ReviewedRunbook,
        $HelperCandidate,
        $LauncherCandidate
    )
    $criticalLines = @($critical | ForEach-Object { '{0} *{1}' -f (Get-Sha256 -Path $_), $_ })
    Write-LabFile -Path $CriticalManifest -Content (($criticalLines -join "`r`n") + "`r`n")

    Test-PositiveShutdown
    Assert-CleanServerState
    Test-NonzeroExit
    Assert-CleanServerState
    Test-WrongTitle
    Assert-CleanServerState
    Test-PidMismatch
    Assert-CleanServerState
    Test-Timeout
    Assert-CleanServerState

    Assert-ReviewedIdentities
    foreach ($line in [IO.File]::ReadAllLines($CriticalManifest)) {
        if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') {
            throw "Malformed critical manifest line: $line"
        }
        if ((Get-Sha256 -Path $Matches[2]) -cne $Matches[1]) {
            throw "Critical file changed during testing: $($Matches[2])"
        }
    }

    Write-LabEvent 'ALL_TESTS_PASS|CRITICAL_FILES_UNCHANGED=true'
    $script:HarnessExitCode = 0
}
catch {
    $failure = $_.Exception.Message
    [Console]::Error.WriteLine("[LAB ERROR] $failure")
    try {
        Write-LabEvent "TEST_FAILURE|MESSAGE=$failure"
    }
    catch {
        [Console]::Error.WriteLine("[LAB LOG ERROR] $($_.Exception.Message)")
    }
}
finally {
    try {
        Stop-ValidatedDisposableEmitter -Reason 'deterministic harness cleanup'
    }
    catch {
        [Console]::Error.WriteLine("[LAB CLEANUP ERROR] $($_.Exception.Message)")
        $script:HarnessExitCode = 1
    }

    try {
        Complete-LauncherWait
    }
    catch {
        [Console]::Error.WriteLine("[LAB LAUNCHER CLEANUP ERROR] $($_.Exception.Message)")
        $script:HarnessExitCode = 1
    }

    try {
        $remaining = @(Get-ServerProcesses)
        if ($remaining.Count -eq 0) {
            [Console]::Out.WriteLine('FINAL_SERVER_PROCESSES=NONE')
        }
        else {
            foreach ($process in $remaining) {
                [Console]::Out.WriteLine(
                    'FINAL_SERVER_PROCESS|NAME={0}|PID={1}|PATH={2}' -f `
                    $process.ProcessName, $process.Id, (Get-ProcessPathSafe -Process $process))
            }
            $script:HarnessExitCode = 1
        }

        $listeners = @(Get-Port3307Listeners)
        if ($listeners.Count -eq 0) {
            [Console]::Out.WriteLine('FINAL_PORT_3307=CLOSED')
        }
        else {
            [Console]::Out.WriteLine("FINAL_PORT_3307_LISTENERS=$($listeners -join '; ')")
            $script:HarnessExitCode = 1
        }
    }
    catch {
        [Console]::Error.WriteLine("[LAB FINAL STATE ERROR] $($_.Exception.Message)")
        $script:HarnessExitCode = 1
    }
}

exit $script:HarnessExitCode
