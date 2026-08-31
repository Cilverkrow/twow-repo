[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestRoot = 'C:\TW\ComTW\runbooks\shutdown-helper-console-lab\realm-candidate-tests'
$SharedDirectory = Join-Path $TestRoot 'shared'
$SharedEmitter = Join-Path $SharedDirectory 'realmd.exe'
$HelperCandidate = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully-candidate.ps1'
$LauncherCandidate = 'C:\TW\ComTW\server\start-mangosd-candidate.bat'
$ProductionHelper = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully.ps1'
$ProductionLauncher = 'C:\TW\ComTW\server\start-mangosd.bat'
$ProductionWorld = 'C:\TW\ComTW\server\mangosd.exe'
$ProductionRealm = 'C:\TW\ComTW\server\realmd.exe'
$ReviewedRunbook = 'C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1'
$PowerShell51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$HarnessEvents = Join-Path $TestRoot 'realm-candidate-test-events.log'
$CriticalManifest = Join-Path $TestRoot 'pretest-critical-files.sha256'

$ExpectedHelperCandidateSha256 = '35C08FAF05FB88285F91413D67189BADC8A8FA1938E317124789BB0F95B34EB7'
$ExpectedLauncherCandidateSha256 = '0C9A97A7E528F0A4451AA9CD0637C3246271CBAACD09DFB8895AFCB3C57B82AF'
$ExpectedProductionHelperSha256 = '6582740F7D452EB74ABA368CB70EB33F1683B5511E0169AA0CB98056A2E79884'
$ExpectedProductionLauncherSha256 = '131A0141358D660BAD04AD540BDC170C7CD1B1A99C8AE6AC308EE165B3E6719E'
$ExpectedProductionWorldSha256 = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$ExpectedProductionRealmSha256 = 'A36A3B611229D2A68FEAA4BD92D4283888CA64CD45FBD7C5E6F28050AB0B676B'
$ExpectedReviewedRunbookSha256 = '89C6C934B3CAAB861570BE54092A768ACEDACDD6D58DA731884EBDE06669314A'
$ExpectedSharedEmitterSha256 = '739BA55A583AD0F24A8F05B309FFDB8F382F33BAFD2BB8B7826215D33A70CAD2'

$script:CurrentChild = $null
$script:CurrentEmitterPid = $null
$script:CurrentEmitterPath = $null
$script:CurrentEmitterStartTimeUtc = $null
$script:CurrentScenarioDirectory = $null
$script:TimeoutCleanupAuthorized = $false
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

public static class RealmLabNative
{
    private const int STD_OUTPUT_HANDLE = -11;
    private const uint CREATE_NEW_CONSOLE = 0x00000010;
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public uint Size;
        public string Reserved;
        public string Desktop;
        public string Title;
        public uint X;
        public uint Y;
        public uint XSize;
        public uint YSize;
        public uint XCountChars;
        public uint YCountChars;
        public uint FillAttribute;
        public uint Flags;
        public ushort ShowWindow;
        public ushort Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    public sealed class ConsoleMarker
    {
        internal ConsoleMarker(short x, short y, short width)
        {
            X = x;
            Y = y;
            Width = width;
        }

        internal short X { get; private set; }
        internal short Y { get; private set; }
        internal short Width { get; private set; }
    }

    public sealed class ChildProcess
    {
        internal ChildProcess(IntPtr processHandle, uint processId)
        {
            ProcessHandle = processHandle;
            ProcessId = processId;
        }

        public IntPtr ProcessHandle { get; internal set; }
        public uint ProcessId { get; private set; }
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static ChildProcess LaunchNewConsole(
        string executable,
        string arguments,
        string workingDirectory)
    {
        STARTUPINFO startupInfo = new STARTUPINFO();
        startupInfo.Size = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION processInformation;
        StringBuilder commandLine = new StringBuilder();
        commandLine.Append('"').Append(executable).Append('"');
        if (!String.IsNullOrWhiteSpace(arguments))
            commandLine.Append(' ').Append(arguments);

        if (!CreateProcessW(
            executable,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            CREATE_NEW_CONSOLE,
            IntPtr.Zero,
            workingDirectory,
            ref startupInfo,
            out processInformation))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed");
        }

        if (!CloseHandle(processInformation.Thread))
        {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(processInformation.Process);
            throw new Win32Exception(error, "CloseHandle failed for the primary thread handle");
        }

        return new ChildProcess(processInformation.Process, processInformation.ProcessId);
    }

    public static bool WaitForExit(ChildProcess child, uint milliseconds)
    {
        ValidateChild(child);
        uint result = WaitForSingleObject(child.ProcessHandle, milliseconds);
        if (result == WAIT_OBJECT_0)
            return true;
        if (result == WAIT_TIMEOUT)
            return false;
        if (result == WAIT_FAILED)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        throw new InvalidOperationException(
            String.Format("WaitForSingleObject returned unexpected status 0x{0:X8}.", result));
    }

    public static uint GetExitCode(ChildProcess child)
    {
        ValidateChild(child);
        uint exitCode;
        if (!GetExitCodeProcess(child.ProcessHandle, out exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
        return exitCode;
    }

    public static void CloseChild(ChildProcess child)
    {
        if (child == null || child.ProcessHandle == IntPtr.Zero)
            return;
        if (!CloseHandle(child.ProcessHandle))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle failed for the process handle");
        child.ProcessHandle = IntPtr.Zero;
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

    public static ConsoleMarker MarkConsole()
    {
        IntPtr output = GetOutputHandle();
        CONSOLE_SCREEN_BUFFER_INFO info = GetInfo(output);
        return new ConsoleMarker(info.CursorPosition.X, info.CursorPosition.Y, info.Size.X);
    }

    public static string ReadConsoleSince(ConsoleMarker marker)
    {
        if (marker == null)
            throw new ArgumentNullException("marker");

        IntPtr output = GetOutputHandle();
        CONSOLE_SCREEN_BUFFER_INFO info = GetInfo(output);
        if (info.Size.X != marker.Width)
            throw new InvalidOperationException("The console buffer width changed during output capture.");

        long start = ((long)marker.Y * marker.Width) + marker.X;
        long end = ((long)info.CursorPosition.Y * info.Size.X) + info.CursorPosition.X;
        if (end < start)
            throw new InvalidOperationException("The console buffer scrolled during output capture.");

        long count = end - start;
        if (count == 0)
            return String.Empty;
        if (count > 1048576)
            throw new InvalidOperationException("The console output capture exceeded one MiB.");

        COORD origin = new COORD();
        origin.X = marker.X;
        origin.Y = marker.Y;
        StringBuilder buffer = new StringBuilder((int)count);
        uint read;
        if (!ReadConsoleOutputCharacterW(output, buffer, (uint)count, origin, out read))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadConsoleOutputCharacterW failed");
        if (read != (uint)count)
            throw new InvalidOperationException("Only part of the console output was captured.");
        return buffer.ToString();
    }

    private static void ValidateChild(ChildProcess child)
    {
        if (child == null || child.ProcessHandle == IntPtr.Zero)
            throw new InvalidOperationException("The native child-process handle is closed.");
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

    try { return $Process.Path } catch { return $null }
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
        [pscustomobject]@{ Path = $ProductionRealm; Hash = $ExpectedProductionRealmSha256 },
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
    Copy-Item -LiteralPath $SharedEmitter -Destination (Join-Path $directory 'realmd.exe') -ErrorAction Stop
    return $directory
}

function Get-ReadyValues {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { throw "Malformed readiness line: $line" }
        $key = $line.Substring(0, $separator)
        if ($values.ContainsKey($key)) { throw "Duplicate readiness key: $key" }
        $values[$key] = $line.Substring($separator + 1)
    }
    return $values
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        if ($null -ne $script:CurrentChild -and
            [RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]0)) {
            $code = [RealmLabNative]::GetExitCode($script:CurrentChild)
            throw "Emitter exited before creating $Path with code $code."
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for file: $Path"
}

function Start-ValidatedEmitter {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioDirectory,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$ExpectedTitle
    )

    $script:CurrentScenarioDirectory = $ScenarioDirectory
    $script:CurrentEmitterPath = Join-Path $ScenarioDirectory 'realmd.exe'
    $script:CurrentEmitterPid = $null
    $script:CurrentEmitterStartTimeUtc = $null
    $script:CurrentChild = $null
    $script:TimeoutCleanupAuthorized = $false

    if ((Get-Sha256 -Path $script:CurrentEmitterPath) -cne $ExpectedSharedEmitterSha256) {
        throw "Scenario emitter hash mismatch: $($script:CurrentEmitterPath)"
    }

    $launchAttemptUtc = [DateTime]::UtcNow
    $script:CurrentChild = [RealmLabNative]::LaunchNewConsole(
        $script:CurrentEmitterPath,
        $Arguments,
        $ScenarioDirectory)
    Write-LabEvent "EMITTER_LAUNCHED|SCENARIO=$([IO.Path]::GetFileName($ScenarioDirectory))|PID=$($script:CurrentChild.ProcessId)|PATH=$($script:CurrentEmitterPath)|ARGS=$Arguments"

    $readyPath = Join-Path $ScenarioDirectory 'emitter-ready.txt'
    Wait-ForFile -Path $readyPath -TimeoutSeconds 15
    $ready = Get-ReadyValues -Path $readyPath
    $pidFile = Join-Path $ScenarioDirectory 'twrealmd.pid'
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        throw "Emitter PID file is missing: $pidFile"
    }

    $readyPid = 0
    $filePid = 0
    if (-not [int]::TryParse($ready['PID'], [ref]$readyPid) -or
        -not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(), [ref]$filePid) -or
        $readyPid -ne $filePid -or
        $readyPid -ne [int]$script:CurrentChild.ProcessId) {
        throw "Emitter PID evidence is inconsistent."
    }

    $process = Get-Process -Id $readyPid -ErrorAction Stop
    $actualPath = Get-ProcessPathSafe -Process $process
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not (Test-SamePath -First $actualPath -Second $script:CurrentEmitterPath) -or
        (Test-SamePath -First $actualPath -Second $ProductionRealm)) {
        throw "Emitter process identity is unsafe for PID ${readyPid}: $actualPath"
    }
    $startTimeUtc = $process.StartTime.ToUniversalTime()
    if ($startTimeUtc -lt $launchAttemptUtc.AddSeconds(-2)) {
        throw "Emitter PID $readyPid predates its launch attempt."
    }
    if (-not [string]::Equals($ready['EXE'], $actualPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Emitter readiness path does not match the live process."
    }
    if (-not [string]::Equals($ready['TITLE'], $ExpectedTitle, [StringComparison]::Ordinal)) {
        throw "Emitter title is '$($ready['TITLE'])' instead of exact '$ExpectedTitle'."
    }

    $script:CurrentEmitterPid = $readyPid
    $script:CurrentEmitterStartTimeUtc = $startTimeUtc
    Write-LabEvent "EMITTER_VALIDATED|PID=$readyPid|PATH=$actualPath|TITLE='$($ready['TITLE'])'|TITLE_LENGTH=$($ready['TITLE'].Length)"
    return $process
}

function Assert-CurrentEmitterStillOwned {
    if ($null -eq $script:CurrentChild -or $null -eq $script:CurrentEmitterPid) {
        throw 'No validated disposable emitter identity is recorded.'
    }
    if ([RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]0)) {
        throw "Disposable emitter PID $($script:CurrentEmitterPid) is no longer active."
    }

    $process = Get-Process -Id $script:CurrentEmitterPid -ErrorAction Stop
    $actualPath = Get-ProcessPathSafe -Process $process
    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not (Test-SamePath -First $actualPath -Second $script:CurrentEmitterPath) -or
        (Test-SamePath -First $actualPath -Second $ProductionRealm) -or
        $process.StartTime.ToUniversalTime() -ne $script:CurrentEmitterStartTimeUtc -or
        (Get-Sha256 -Path $actualPath) -cne $ExpectedSharedEmitterSha256) {
        throw "Disposable emitter ownership validation failed for PID $($script:CurrentEmitterPid)."
    }

    $ready = Get-ReadyValues -Path (Join-Path $script:CurrentScenarioDirectory 'emitter-ready.txt')
    if ([int]$ready['PID'] -ne $script:CurrentEmitterPid) {
        throw 'Disposable emitter readiness PID changed.'
    }
    return $process
}

function Wait-ForCurrentEmitterExit {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    if (-not [RealmLabNative]::WaitForExit(
        $script:CurrentChild,
        [uint32]($TimeoutSeconds * 1000))) {
        throw "Disposable emitter PID $($script:CurrentEmitterPid) did not exit within $TimeoutSeconds seconds."
    }
    $exitCode = [RealmLabNative]::GetExitCode($script:CurrentChild)
    Write-LabEvent "EMITTER_EXITED|PID=$($script:CurrentEmitterPid)|EXIT_CODE=$exitCode"
    $script:CurrentEmitterPid = $null
    return $exitCode
}

function Close-CurrentChildHandle {
    if ($null -ne $script:CurrentChild) {
        [RealmLabNative]::CloseChild($script:CurrentChild)
        $script:CurrentChild = $null
        Write-LabEvent 'LAB_NATIVE_PROCESS_HANDLE_CLOSED=true'
    }
}

function Stop-ValidatedTimeoutEmitter {
    $process = Assert-CurrentEmitterStillOwned
    if (-not $script:TimeoutCleanupAuthorized) {
        throw 'Forced lab cleanup is authorized only after the timeout non-termination proof.'
    }

    Write-LabEvent "TIMEOUT_CLEANUP_AUTHORIZED|PID=$($process.Id)|PATH=$($process.Path)"
    $process.Kill()
    if (-not [RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]5000)) {
        throw "Validated timeout emitter PID $($process.Id) did not stop."
    }
    Write-LabEvent "TIMEOUT_CLEANUP_COMPLETE|PID=$($process.Id)"
    $script:CurrentEmitterPid = $null
}

function Invoke-HelperCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioDirectory,
        [Parameter(Mandatory = $true)][int]$ExitTimeoutSeconds
    )

    $transcriptPath = Join-Path $ScenarioDirectory 'helper-host-transcript.txt'
    $visiblePath = Join-Path $ScenarioDirectory 'helper-visible-console.txt'
    if (Test-Path -LiteralPath $transcriptPath) { throw "Transcript exists: $transcriptPath" }
    if (Test-Path -LiteralPath $visiblePath) { throw "Visible output exists: $visiblePath" }

    $helperArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $HelperCandidate,
        '-Action', 'Realm',
        '-ServerDirectory', $ScenarioDirectory,
        '-RealmWindowTitle', 'realmd',
        '-RealmExitTimeoutSeconds', [string]$ExitTimeoutSeconds
    )

    Start-Transcript -LiteralPath $transcriptPath -NoClobber | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $PowerShell51
        $startInfo.Arguments = $helperArguments -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false
        $startInfo.WorkingDirectory = $ScenarioDirectory

        $marker = [RealmLabNative]::MarkConsole()
        $helperProcess = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $helperProcess) { throw 'The helper process could not be created.' }
        $waitMilliseconds = [uint32](($ExitTimeoutSeconds + 30) * 1000)
        $exitCode = [RealmLabNative]::WaitForExitCode($helperProcess.Handle, $waitMilliseconds)
        $helperProcess.WaitForExit()
        $visible = [RealmLabNative]::ReadConsoleSince($marker)
    }
    finally {
        $timer.Stop()
        Stop-Transcript | Out-Null
    }

    Write-LabFile -Path $visiblePath -Content $visible
    Write-LabEvent "HELPER_COMPLETED|SCENARIO=$([IO.Path]::GetFileName($ScenarioDirectory))|EXIT_CODE=$exitCode|ELAPSED_MS=$($timer.ElapsedMilliseconds)"
    return [pscustomobject]@{
        ExitCode = [uint32]$exitCode
        ElapsedMilliseconds = $timer.ElapsedMilliseconds
        VisiblePath = $visiblePath
    }
}

function Get-ControlEvents {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $path = Join-Path $ScenarioDirectory 'received-control-events.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Control-event log is missing: $path"
    }
    return @([IO.File]::ReadAllLines($path))
}

function Assert-OneCtrlBreak {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $records = @(Get-ControlEvents -ScenarioDirectory $ScenarioDirectory)
    if ($records.Count -ne 1 -or
        $records[0] -notmatch '^CTRL_BREAK_EVENT\|COUNT=1\|UTC=') {
        throw "Expected exactly one CTRL_BREAK event: $($records -join ' || ')"
    }
}

function Assert-NoCtrlBreak {
    param([Parameter(Mandatory = $true)][string]$ScenarioDirectory)

    $records = @(Get-ControlEvents -ScenarioDirectory $ScenarioDirectory)
    if ($records.Count -ne 0) {
        throw "Unexpected CTRL_BREAK event: $($records -join ' || ')"
    }
}

function Complete-NormalEmitterCase {
    param([Parameter(Mandatory = $true)][int]$ExpectedExitCode)

    $actualExitCode = Wait-ForCurrentEmitterExit -TimeoutSeconds 20
    if ($actualExitCode -ne $ExpectedExitCode) {
        throw "Emitter exit code $actualExitCode did not match $ExpectedExitCode."
    }
    Close-CurrentChildHandle
}

function Test-RealmSuccess {
    $scenario = New-ScenarioDirectory -Name '01-success-exit-0'
    $null = Start-ValidatedEmitter `
        -ScenarioDirectory $scenario `
        -Arguments '--title realmd --ctrl-break-exit-code 0 --idle-exit-ms 15000' `
        -ExpectedTitle 'realmd'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 10
    if ($helper.ExitCode -ne 0) { throw "Success helper exit was $($helper.ExitCode)." }
    Complete-NormalEmitterCase -ExpectedExitCode 0
    Assert-OneCtrlBreak -ScenarioDirectory $scenario
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains('[OK] Realmd PID')) { throw "Success diagnostic missing: $visible" }
    Write-LabEvent 'TEST_PASS|REALM_SUCCESS|HELPER_EXIT=0|EMITTER_EXIT=0|CTRL_BREAK_COUNT=1'
}

function Test-RealmExitSeven {
    $scenario = New-ScenarioDirectory -Name '02-target-exit-7'
    $null = Start-ValidatedEmitter `
        -ScenarioDirectory $scenario `
        -Arguments '--title realmd --ctrl-break-exit-code 7 --idle-exit-ms 15000' `
        -ExpectedTitle 'realmd'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 10
    if ($helper.ExitCode -ne 1) { throw "Exit-7 helper exit was $($helper.ExitCode)." }
    Complete-NormalEmitterCase -ExpectedExitCode 7
    Assert-OneCtrlBreak -ScenarioDirectory $scenario
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains('[FEHLER] realmd.exe wurde mit dem unerwarteten Exitcode 7 beendet.')) {
        throw "Exit-7 diagnostic missing: $visible"
    }
    Write-LabEvent 'TEST_PASS|REALM_EXIT_7|HELPER_EXIT=1|EMITTER_EXIT=7|CTRL_BREAK_COUNT=1'
}

function Test-RealmWrongTitle {
    $scenario = New-ScenarioDirectory -Name '03-wrong-title'
    $process = Start-ValidatedEmitter `
        -ScenarioDirectory $scenario `
        -Arguments '--title wrong-title --idle-exit-ms 5000' `
        -ExpectedTitle 'wrong-title'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 10
    if ($helper.ExitCode -ne 1) { throw "Wrong-title helper exit was $($helper.ExitCode)." }
    $process.Refresh()
    if ($process.HasExited) { throw 'Wrong-title emitter was unexpectedly terminated by the helper.' }
    Complete-NormalEmitterCase -ExpectedExitCode 0
    Assert-NoCtrlBreak -ScenarioDirectory $scenario
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains("'wrong-title' statt 'realmd'")) {
        throw "Wrong-title diagnostic missing: $visible"
    }
    Write-LabEvent 'TEST_PASS|REALM_WRONG_TITLE|HELPER_EXIT=1|CTRL_BREAK_COUNT=0|TARGET_SELF_EXITED=true'
}

function Test-RealmPidMismatch {
    $scenario = New-ScenarioDirectory -Name '04-pid-mismatch'
    $process = Start-ValidatedEmitter `
        -ScenarioDirectory $scenario `
        -Arguments '--title realmd --idle-exit-ms 5000' `
        -ExpectedTitle 'realmd'
    $pidPath = Join-Path $scenario 'twrealmd.pid'
    [IO.File]::WriteAllText($pidPath, '2147483647', [Text.Encoding]::ASCII)
    Write-LabEvent "PID_FILE_REPLACED|ACTUAL_PID=$($script:CurrentEmitterPid)|FILE_PID=2147483647"
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 10
    if ($helper.ExitCode -ne 1) { throw "PID-mismatch helper exit was $($helper.ExitCode)." }
    $process.Refresh()
    if ($process.HasExited) { throw 'PID-mismatch emitter was unexpectedly terminated by the helper.' }
    Complete-NormalEmitterCase -ExpectedExitCode 0
    Assert-NoCtrlBreak -ScenarioDirectory $scenario
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains('PID-Datei und laufender realmd-Prozess stimmen nicht ueberein')) {
        throw "PID-mismatch diagnostic missing: $visible"
    }
    Write-LabEvent 'TEST_PASS|REALM_PID_MISMATCH|HELPER_EXIT=1|CTRL_BREAK_COUNT=0|REJECTED_BEFORE_OPEN=true'
}

function Test-RealmTimeout {
    $scenario = New-ScenarioDirectory -Name '05-timeout'
    $process = Start-ValidatedEmitter `
        -ScenarioDirectory $scenario `
        -Arguments '--title realmd --hold-after-break' `
        -ExpectedTitle 'realmd'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 5
    if ($helper.ExitCode -ne 1) { throw "Timeout helper exit was $($helper.ExitCode)." }
    if ($helper.ElapsedMilliseconds -lt 5000) { throw "Timeout returned too early after $($helper.ElapsedMilliseconds) ms." }
    $process.Refresh()
    if ($process.HasExited) { throw 'Timeout emitter was terminated by the helper.' }
    Wait-ForFile -Path (Join-Path $scenario 'emitter-state.txt') -TimeoutSeconds 2
    Assert-OneCtrlBreak -ScenarioDirectory $scenario
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains('Es wird kein erzwungenes Beenden ausgefuehrt.')) {
        throw "Timeout diagnostic missing: $visible"
    }
    $script:TimeoutCleanupAuthorized = $true
    Stop-ValidatedTimeoutEmitter
    Close-CurrentChildHandle
    Write-LabEvent 'TEST_PASS|REALM_TIMEOUT|HELPER_EXIT=1|TARGET_ACTIVE_AFTER_TIMEOUT=true|CTRL_BREAK_COUNT=1'
}

function Test-RealmAlreadyStopped {
    $scenario = New-ScenarioDirectory -Name '06-already-stopped'
    $helper = Invoke-HelperCandidate -ScenarioDirectory $scenario -ExitTimeoutSeconds 5
    if ($helper.ExitCode -ne 0) { throw "Already-stopped helper exit was $($helper.ExitCode)." }
    if (Test-Path -LiteralPath (Join-Path $scenario 'twrealmd.pid')) {
        throw 'Already-stopped case unexpectedly created a PID file.'
    }
    $visible = [IO.File]::ReadAllText($helper.VisiblePath)
    if (-not $visible.Contains('[INFO] Realmd laeuft bereits nicht mehr.')) {
        throw "Already-stopped information missing: $visible"
    }
    Write-LabEvent 'TEST_PASS|REALM_ALREADY_STOPPED|HELPER_EXIT=0|HANDLE_OPENED=false|CTRL_BREAK_SENT=false'
}

$failure = $null
try {
    if (Test-Path -LiteralPath $HarnessEvents) { throw "Event log exists: $HarnessEvents" }
    if (Test-Path -LiteralPath $CriticalManifest) { throw "Critical manifest exists: $CriticalManifest" }
    if (-not (Test-Path -LiteralPath $PowerShell51 -PathType Leaf)) {
        throw "Windows PowerShell 5.1 is missing: $PowerShell51"
    }

    Assert-ReviewedIdentities
    Assert-CleanServerState
    Write-LabEvent 'INITIAL_GATE_PASS|SERVER_PROCESSES=NONE|PORT_3307=CLOSED'

    $critical = @(
        $HelperCandidate,
        $LauncherCandidate,
        $ProductionHelper,
        $ProductionLauncher,
        $ProductionWorld,
        $ProductionRealm,
        $ReviewedRunbook,
        $SharedEmitter
    )
    $criticalLines = @($critical | ForEach-Object { '{0} *{1}' -f (Get-Sha256 -Path $_), $_ })
    Write-LabFile -Path $CriticalManifest -Content (($criticalLines -join "`r`n") + "`r`n")

    Test-RealmSuccess
    Assert-CleanServerState
    Test-RealmExitSeven
    Assert-CleanServerState
    Test-RealmWrongTitle
    Assert-CleanServerState
    Test-RealmPidMismatch
    Assert-CleanServerState
    Test-RealmTimeout
    Assert-CleanServerState
    Test-RealmAlreadyStopped
    Assert-CleanServerState

    Assert-ReviewedIdentities
    foreach ($line in [IO.File]::ReadAllLines($CriticalManifest)) {
        if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') { throw "Malformed manifest line: $line" }
        if ((Get-Sha256 -Path $Matches[2]) -cne $Matches[1]) {
            throw "Critical file changed: $($Matches[2])"
        }
    }

    Write-LabEvent 'ALL_REALM_TESTS_PASS|CRITICAL_FILES_UNCHANGED=true'
    $script:HarnessExitCode = 0
}
catch {
    $failure = $_.Exception.Message
    [Console]::Error.WriteLine("[REALM LAB ERROR] $failure")
    try { Write-LabEvent "TEST_FAILURE|MESSAGE=$failure" } catch {
        [Console]::Error.WriteLine("[REALM LAB LOG ERROR] $($_.Exception.Message)")
    }
}
finally {
    if ($null -ne $script:CurrentChild) {
        try {
            if (-not [RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]0)) {
                if ($script:TimeoutCleanupAuthorized) {
                    Stop-ValidatedTimeoutEmitter
                }
                else {
                    [Console]::Error.WriteLine(
                        "[REALM LAB CLEANUP] Waiting for disposable emitter PID $($script:CurrentEmitterPid) to self-exit.")
                    $null = [RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]20000)
                }
            }
            if ([RealmLabNative]::WaitForExit($script:CurrentChild, [uint32]0)) {
                Close-CurrentChildHandle
            }
            else {
                [Console]::Error.WriteLine('[REALM LAB CLEANUP ERROR] A disposable emitter remains active.')
                $script:HarnessExitCode = 1
            }
        }
        catch {
            [Console]::Error.WriteLine("[REALM LAB CLEANUP ERROR] $($_.Exception.Message)")
            $script:HarnessExitCode = 1
        }
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
        [Console]::Error.WriteLine("[REALM LAB FINAL STATE ERROR] $($_.Exception.Message)")
        $script:HarnessExitCode = 1
    }
}

exit $script:HarnessExitCode
