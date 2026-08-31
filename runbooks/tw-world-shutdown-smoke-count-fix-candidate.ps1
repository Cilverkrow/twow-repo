#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ApprovedHarnessSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HarnessPath = $PSCommandPath
$PinnedRunbook = 'C:\TW\ComTW\runbooks\tw-char-migration-89C6C934.ps1'
$ExpectedPinnedRunbookBytes = 93173
$ExpectedPinnedRunbookSha256 = '89C6C934B3CAAB861570BE54092A768ACEDACDD6D58DA731884EBDE06669314A'
$CandidateHelper = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully-candidate.ps1'
$ExpectedCandidateHelperBytes = 16925
$ExpectedCandidateHelperSha256 = '35C08FAF05FB88285F91413D67189BADC8A8FA1938E317124789BB0F95B34EB7'
$CandidateLauncher = 'C:\TW\ComTW\server\start-mangosd-candidate.bat'
$ExpectedCandidateLauncherBytes = 54
$ExpectedCandidateLauncherSha256 = '0C9A97A7E528F0A4451AA9CD0637C3246271CBAACD09DFB8895AFCB3C57B82AF'
$ExpectedProductionExeSha256ForSmoke = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$PowerShell51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$ExpectedWorldTitle = 'mangosd'
$ServerDirectoryForSmoke = 'C:\TW\ComTW\server'
$WorldPidFile = Join-Path $ServerDirectoryForSmoke 'twlive.pid'
$LogsDirectoryForSmoke = 'C:\TW\ComTW\logs'
$FixedErrorLog = Join-Path $LogsDirectoryForSmoke 'errors.log'
$FixedHonorLog = Join-Path $LogsDirectoryForSmoke 'honor.log'
$AttemptMarkerPath = "$HarnessPath.attempted"
$EvidenceParent = 'C:\TW\ComTW\runbooks'
$EvidencePrefix = 'world-shutdown-smoke-evidence-'
$EvidenceEncoding = New-Object System.Text.UTF8Encoding($false)

$script:EvidenceDirectory = $null
$script:SmokeOutputPath = $null
$script:SmokeErrorPath = $null
$script:StaticAuditPath = $null
$script:ResultPath = $null
$script:PrimaryError = $null
$script:CleanupErrors = New-Object System.Collections.Generic.List[string]
$script:DatabasePid = $null
$script:DatabaseLauncherPid = $null
$script:DatabaseLauncherPath = $null
$script:DatabaseLauncherStartTicks = $null
$script:DatabaseLauncherExitObserved = $false
$script:WorldPid = $null
$script:WorldPidStartTicks = $null
$script:DatabaseStartMilliseconds = $null
$script:WorldPidAcquisitionMilliseconds = $null
$script:WorldReadyMilliseconds = $null
$script:WorldShutdownMilliseconds = $null
$script:DatabaseShutdownMilliseconds = $null
$script:DatabaseStopOutput = ''
$script:WorldLauncher = $null
$script:WorldLauncherHandle = [IntPtr]::Zero
$script:WorldLauncherThreadHandle = [IntPtr]::Zero
$script:WorldLauncherPid = $null
$script:WorldLauncherPath = $null
$script:WorldLauncherStartTicks = $null
$script:WorldLauncherExitCode = $null
$script:WorldLauncherExitObserved = $false
$script:WorldVerifiedForHelper = $false
$script:HelperAttempted = $false
$script:HelperAttemptReason = $null
$script:HelperProcess = $null
$script:HelperProcessPid = $null
$script:HelperProcessPath = $null
$script:HelperProcessStartTicks = $null
$script:HelperProcessHandle = [IntPtr]::Zero
$script:HelperExitCode = $null
$script:HelperConsoleText = ''
$script:HelperStdout = ''
$script:HelperStderr = ''
$script:ValidatedWorldTitle = $null
$script:NewServerLog = $null
$script:InitialLogState = $null
$script:PreWorldPidFileState = $null
$script:ServerLogShutdownOffset = $null
$script:ShutdownLogValidated = $false
$script:FunctionalSequencePassed = $false
$script:DatabaseStopSucceeded = $false
$script:FinalStatePassed = $false
$script:AttemptMarkerCreated = $false
$script:SubsetLoaded = $false
$script:RunStartUtc = [DateTime]::UtcNow

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class WorldSmokeNative
{
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint STILL_ACTIVE = 259;
    private const uint CREATE_NEW_CONSOLE = 0x00000010;
    private const int STD_OUTPUT_HANDLE = -11;

    public sealed class CreatedConsoleProcess
    {
        internal CreatedConsoleProcess() { }
        public IntPtr ProcessHandle { get; internal set; }
        public IntPtr ThreadHandle { get; internal set; }
        public uint ProcessId { get; internal set; }
        public uint ThreadId { get; internal set; }
        public bool ThreadHandleClosed { get; internal set; }
        public int ThreadHandleCloseError { get; internal set; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

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

    public static IntPtr OpenProcessForWaitAndQuery(uint processId)
    {
        IntPtr handle = OpenProcess(
            SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            processId);
        if (handle == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
        return handle;
    }

    public static CreatedConsoleProcess StartWorldLauncherInNewConsole(
        string commandInterpreter,
        string launcherPath,
        string serverDirectory)
    {
        if (String.IsNullOrWhiteSpace(commandInterpreter))
            throw new ArgumentException("The command interpreter path is required.", "commandInterpreter");
        if (String.IsNullOrWhiteSpace(launcherPath))
            throw new ArgumentException("The launcher path is required.", "launcherPath");
        if (String.IsNullOrWhiteSpace(serverDirectory))
            throw new ArgumentException("The server directory is required.", "serverDirectory");

        CreatedConsoleProcess result = new CreatedConsoleProcess();
        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION processInfo;
        StringBuilder commandLine = new StringBuilder(
            "\"" + commandInterpreter + "\" /d /c call \"" + launcherPath + "\"");

        if (!CreateProcessW(
            commandInterpreter,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            CREATE_NEW_CONSOLE,
            IntPtr.Zero,
            serverDirectory,
            ref startup,
            out processInfo))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed");
        }

        result.ProcessHandle = processInfo.hProcess;
        result.ThreadHandle = processInfo.hThread;
        result.ProcessId = processInfo.dwProcessId;
        result.ThreadId = processInfo.dwThreadId;
        if (CloseHandle(processInfo.hThread))
        {
            result.ThreadHandle = IntPtr.Zero;
            result.ThreadHandleClosed = true;
            result.ThreadHandleCloseError = 0;
        }
        else
        {
            result.ThreadHandleClosed = false;
            result.ThreadHandleCloseError = Marshal.GetLastWin32Error();
        }
        return result;
    }

    public static bool WaitForExit(IntPtr processHandle, uint milliseconds)
    {
        uint result = WaitForSingleObject(processHandle, milliseconds);
        if (result == WAIT_OBJECT_0)
            return true;
        if (result == WAIT_TIMEOUT)
            return false;
        if (result == WAIT_FAILED)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        throw new InvalidOperationException(
            String.Format("WaitForSingleObject returned unexpected status 0x{0:X8}.", result));
    }

    public static uint GetExitCode(IntPtr processHandle)
    {
        uint exitCode;
        if (!GetExitCodeProcess(processHandle, out exitCode))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
        if (exitCode == STILL_ACTIVE)
            throw new InvalidOperationException("The process handle is signaled but the process is still active.");
        return exitCode;
    }

    public static void CloseProcessHandle(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero || processHandle == new IntPtr(-1))
            return;
        if (!CloseHandle(processHandle))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle failed");
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
            throw new InvalidOperationException("The console buffer width changed during helper output capture.");

        long start = ((long)marker.Y * marker.Width) + marker.X;
        long end = ((long)info.CursorPosition.Y * info.Size.X) + info.CursorPosition.X;
        if (end < start)
            throw new InvalidOperationException("The console buffer scrolled during helper output capture.");
        long count = end - start;
        if (count == 0)
            return String.Empty;
        if (count > 1048576)
            throw new InvalidOperationException("The helper console output exceeded one MiB.");

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

function Get-LocalSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-LocalFileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -ne $ExpectedBytes) {
        throw "Byte-count mismatch for '$Path'. Expected $ExpectedBytes, found $($item.Length)."
    }
    $actual = Get-LocalSha256 -Path $Path
    if ($actual -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, found $actual."
    }
}

function Write-SmokeLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $line = '{0}|{1}' -f [DateTime]::UtcNow.ToString('o'), $Text
    [Console]::Out.WriteLine($line)
    if (-not [string]::IsNullOrWhiteSpace($script:SmokeOutputPath)) {
        [IO.File]::AppendAllText($script:SmokeOutputPath, $line + "`r`n", $EvidenceEncoding)
    }
}

function Write-SmokeError {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $line = '{0}|{1}' -f [DateTime]::UtcNow.ToString('o'), $Text
    [Console]::Error.WriteLine($line)
    if (-not [string]::IsNullOrWhiteSpace($script:SmokeErrorPath)) {
        [IO.File]::AppendAllText($script:SmokeErrorPath, $line + "`r`n", $EvidenceEncoding)
    }
}

function New-SmokeEvidenceDirectory {
    $name = $EvidencePrefix + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $path = Join-Path $EvidenceParent $name
    if (Test-Path -LiteralPath $path) {
        throw "Smoke evidence directory already exists: $path"
    }
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    $script:EvidenceDirectory = $path
    $script:SmokeOutputPath = Join-Path $path 'smoke.stdout.log'
    $script:SmokeErrorPath = Join-Path $path 'smoke.stderr.log'
    $script:StaticAuditPath = Join-Path $path 'static-call-audit.txt'
    $script:ResultPath = Join-Path $path 'smoke-result.json'
    [IO.File]::WriteAllText($script:SmokeOutputPath, '', $EvidenceEncoding)
    [IO.File]::WriteAllText($script:SmokeErrorPath, '', $EvidenceEncoding)
    return $path
}

function Get-StrictPortOwnerPids {
    param([Parameter(Mandatory = $true)][int]$Port)
    $connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -eq $Port })
    return @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
}

function Get-MatchingRunningServices {
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        $_.State -eq 'Running' -and (
            $_.Name -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
            $_.DisplayName -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
            $_.PathName -match '(?i)mariadb|mysqld|mangosd|realmd|ComTW'
        )
    })
    return $services
}

function Get-SmokeServerProcesses {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $process.Path } catch { }
            $items.Add([pscustomobject]@{
                Name = $process.ProcessName
                Id = $process.Id
                Path = $path
            })
        }
    }
    return @($items | ForEach-Object { $_ })
}

function Get-StrictServerProcessRecords {
    param(
        [ValidateSet('All', 'Database', 'World', 'Realm')]
        [string]$Kind = 'All'
    )
    $names = switch ($Kind) {
        'Database' { @('mysqld.exe', 'mariadbd.exe') }
        'World' { @('mangosd.exe') }
        'Realm' { @('realmd.exe') }
        default { @('mysqld.exe', 'mariadbd.exe', 'mangosd.exe', 'realmd.exe') }
    }
    $records = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $names -icontains $_.Name
    })
    return $records
}

function Assert-StrictProcessAgreement {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Database', 'World')]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Candidates
    )
    $strictRecords = @(Get-StrictServerProcessRecords -Kind $Kind)
    $candidateIds = @($Candidates | ForEach-Object { [int]$_.Id } | Sort-Object)
    $strictIds = @($strictRecords | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    if (($candidateIds -join ',') -cne ($strictIds -join ',')) {
        throw "$Kind process enumerations disagree. Get-Process=[$($candidateIds -join ',')], CIM=[$($strictIds -join ',')]."
    }
    return $strictRecords
}

function Assert-NoRealmdProcessStrict {
    $softProcesses = @(Get-Process -Name realmd -ErrorAction SilentlyContinue)
    $strictProcesses = @(Get-StrictServerProcessRecords -Kind Realm)
    $softIds = @($softProcesses | ForEach-Object { [int]$_.Id } | Sort-Object)
    $strictIds = @($strictProcesses | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    if (($softIds -join ',') -cne ($strictIds -join ',')) {
        throw "Realmd process enumerations disagree. Get-Process=[$($softIds -join ',')], CIM=[$($strictIds -join ',')]."
    }
    if ($strictProcesses.Count -ne 0) {
        throw "A realmd process is active. PIDs: $($strictIds -join ',')."
    }
}

function Get-TrackedProcessStateLine {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][object]$ProcessId,
        [AllowNull()][string]$ExpectedPath,
        [AllowNull()][object]$ExpectedStartTicks
    )
    if ($null -eq $ProcessId) {
        return "TRACKED_PROCESS label=$Label recorded=false"
    }
    $pidValue = [int]$ProcessId
    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return "TRACKED_PROCESS label=$Label pid=$pidValue active=false"
    }
    $actualPath = $null
    $actualStartTicks = $null
    try { $actualPath = $process.Path } catch { $actualPath = "<unavailable:$($_.Exception.Message)>" }
    try { $actualStartTicks = $process.StartTime.ToUniversalTime().Ticks } catch { }
    $pathMatches = $false
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPath) -and
        -not [string]::IsNullOrWhiteSpace($actualPath) -and
        -not $actualPath.StartsWith('<unavailable:', [StringComparison]::Ordinal)) {
        $pathMatches = [string]::Equals(
            [IO.Path]::GetFullPath($actualPath),
            [IO.Path]::GetFullPath($ExpectedPath),
            [StringComparison]::OrdinalIgnoreCase)
    }
    $startMatches = ($null -ne $ExpectedStartTicks -and
        $null -ne $actualStartTicks -and
        $actualStartTicks -eq [long]$ExpectedStartTicks)
    return "TRACKED_PROCESS label=$Label pid=$pidValue active=true path=$actualPath startTicks=$actualStartTicks pathMatches=$pathMatches startMatches=$startMatches"
}

function Get-StateLines {
    $lines = New-Object System.Collections.Generic.List[string]
    $processes = @(Get-SmokeServerProcesses)
    if ($processes.Count -eq 0) {
        $lines.Add('PROCESS none')
    }
    else {
        foreach ($process in $processes) {
            $lines.Add(('PROCESS name={0} pid={1} path={2}' -f $process.Name, $process.Id, $process.Path))
        }
    }

    $services = @(Get-MatchingRunningServices)
    if ($services.Count -eq 0) {
        $lines.Add('RUNNING_SERVICE none')
    }
    else {
        foreach ($service in $services) {
            $lines.Add(('RUNNING_SERVICE name={0} display={1} path={2}' -f
                $service.Name, $service.DisplayName, $service.PathName))
        }
    }

    foreach ($port in @(3307, 8090)) {
        $owners = @(Get-StrictPortOwnerPids -Port $port)
        $ownerText = if ($owners.Count -eq 0) { 'none' } else { $owners -join ',' }
        $lines.Add(('PORT {0} ownerPids={1}' -f $port, $ownerText))
    }
    $lines.Add((Get-TrackedProcessStateLine `
        -Label 'database-launcher' `
        -ProcessId $script:DatabaseLauncherPid `
        -ExpectedPath $script:DatabaseLauncherPath `
        -ExpectedStartTicks $script:DatabaseLauncherStartTicks))
    $lines.Add((Get-TrackedProcessStateLine `
        -Label 'world-launcher' `
        -ProcessId $script:WorldLauncherPid `
        -ExpectedPath $script:WorldLauncherPath `
        -ExpectedStartTicks $script:WorldLauncherStartTicks))
    $lines.Add((Get-TrackedProcessStateLine `
        -Label 'world-helper' `
        -ProcessId $script:HelperProcessPid `
        -ExpectedPath $script:HelperProcessPath `
        -ExpectedStartTicks $script:HelperProcessStartTicks))
    return @($lines | ForEach-Object { $_ })
}

function Write-State {
    param([Parameter(Mandatory = $true)][string]$Prefix)
    foreach ($line in @(Get-StateLines)) {
        Write-SmokeLine -Text ("$Prefix|$line")
    }
}

function Assert-InitialSmokeState {
    $processes = @(Get-SmokeServerProcesses)
    $strictProcesses = @(Get-StrictServerProcessRecords -Kind All)
    $softIds = @($processes | ForEach-Object { [int]$_.Id } | Sort-Object)
    $strictIds = @($strictProcesses | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    if (($softIds -join ',') -cne ($strictIds -join ',')) {
        throw "Initial server-process enumerations disagree. Get-Process=[$($softIds -join ',')], CIM=[$($strictIds -join ',')]."
    }
    if ($processes.Count -ne 0) {
        throw "Initial process gate failed: $($processes | ConvertTo-Json -Compress)"
    }
    $services = @(Get-MatchingRunningServices)
    if ($services.Count -ne 0) {
        throw "Initial service gate failed: $($services | Select-Object Name, DisplayName, PathName | ConvertTo-Json -Compress)"
    }
    foreach ($port in @(3307, 8090)) {
        $owners = @(Get-StrictPortOwnerPids -Port $port)
        if ($owners.Count -ne 0) {
            throw "Initial port gate failed for port $port. Owners: $($owners -join ',')."
        }
    }
    if (-not (Test-Path -LiteralPath 'C:\TW\ComTW\DB\data' -PathType Container)) {
        throw 'The active database directory is missing: C:\TW\ComTW\DB\data'
    }
    if (Test-Path -LiteralPath $WorldPidFile -PathType Leaf) {
        $staleText = [IO.File]::ReadAllText($WorldPidFile).Trim()
        $stalePid = 0
        if (-not [int]::TryParse($staleText, [ref]$stalePid) -or $stalePid -le 0) {
            throw "The pre-existing twlive.pid is malformed: '$staleText'."
        }
        if ($null -ne (Get-Process -Id $stalePid -ErrorAction SilentlyContinue)) {
            throw "The pre-existing twlive.pid references an active unverified PID: $stalePid."
        }
        Write-SmokeLine -Text "PREFLIGHT_STALE_WORLD_PID|PID=$stalePid|ACTIVE=false"
    }
}

function Assert-ReviewedCommandInterpreter {
    $commandInterpreter = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\cmd.exe'))
    if (-not (Test-Path -LiteralPath $commandInterpreter -PathType Leaf)) {
        throw "The reviewed command interpreter is missing: $commandInterpreter"
    }
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($env:ComSpec),
        $commandInterpreter,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "ComSpec does not resolve to the reviewed System32 command interpreter. Found '$env:ComSpec'."
    }
    return $commandInterpreter
}

function Update-DatabaseLauncherRecord {
    param([switch]$RequireActive)
    if (-not $script:SubsetLoaded -or $null -eq $script:RunState.Database.LauncherPid) {
        if ($RequireActive) { throw 'The reviewed database launcher PID was not recorded.' }
        return
    }
    $recordedPid = [int]$script:RunState.Database.LauncherPid
    $recordedPath = Assert-ReviewedCommandInterpreter
    if ($null -eq $script:DatabaseLauncherPid) {
        $script:DatabaseLauncherPid = $recordedPid
        $script:DatabaseLauncherPath = $recordedPath
    }
    elseif ($script:DatabaseLauncherPid -ne $recordedPid -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath($script:DatabaseLauncherPath),
            $recordedPath,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The reviewed database launcher identity changed after its initial capture.'
    }
    $launcher = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
    if ($null -eq $launcher) {
        if ($RequireActive) {
            throw "The reviewed database launcher PID $($script:DatabaseLauncherPid) is not active."
        }
        return
    }
    $actualPath = $launcher.Path
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($actualPath),
        $script:DatabaseLauncherPath,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "The database launcher PID $($launcher.Id) has unexpected path '$actualPath'."
    }
    $actualStartTicks = $launcher.StartTime.ToUniversalTime().Ticks
    if ($null -eq $script:DatabaseLauncherStartTicks) {
        $script:DatabaseLauncherStartTicks = $actualStartTicks
    }
    elseif ($script:DatabaseLauncherStartTicks -ne $actualStartTicks) {
        throw 'The reviewed database launcher PID was reused by a different process.'
    }
}

function Get-ReviewedSubset {
    $bytes = [IO.File]::ReadAllBytes($PinnedRunbook)
    if ($bytes.Length -ne $ExpectedPinnedRunbookBytes) {
        throw "Pinned runbook byte-count mismatch. Expected $ExpectedPinnedRunbookBytes, found $($bytes.Length)."
    }
    if ((Get-LocalSha256 -Path $PinnedRunbook) -cne $ExpectedPinnedRunbookSha256) {
        throw 'Pinned runbook SHA-256 mismatch.'
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Pinned runbook unexpectedly contains a UTF-8 BOM.'
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $PinnedRunbook,
        [ref]$tokens,
        [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "Pinned runbook parser errors: $($errors.Count)."
    }

    $initializerNames = @(
        'Root', 'DatabaseRoot', 'DataDir', 'DatabaseLauncher', 'MariaDbServer',
        'MariaDbClient', 'MariaDbDump', 'MariaDbAdmin', 'MyIni', 'ServerDir',
        'ProductionExe', 'MangosConfig', 'PlayerbotConfig', 'StartWorld',
        'ShutdownHelper', 'LogDir', 'HonorLog', 'ErrorLog', 'DatabaseName',
        'DatabaseHost', 'DatabasePort', 'DatabaseUser',
        'MariaDbPasswordlessTlsWarning', 'ExpectedProductionExeSha256',
        'ApprovedFiles', 'script:RunState', 'Utf8NoBom'
    )
    $functionNames = @(
        'Get-Sha256', 'Assert-Hash', 'Assert-Administrator', 'Get-NormalizedPath',
        'Get-ProcessPath', 'Get-ProcessCandidates', 'Test-PortOpen',
        'Get-PortOwnerPids', 'Get-ServerStatusLines', 'Write-ServerStatus',
        'Assert-NoServerServices', 'Set-LaunchAttempt', 'Set-LauncherPid',
        'Get-VerifiedOwnedProcess', 'Try-AdoptLaunchedProcess',
        'Wait-ForOwnedProcess', 'Wait-ForProcessExit',
        'Assert-DatabaseProgramFiles', 'Assert-RestoredDatabaseConfiguration',
        'Assert-PlayerbotLlmDisabled', 'Assert-WorldRuntimeFiles',
        'Resolve-MariaDbClientResult', 'ConvertTo-WindowsCommandLineArgument',
        'Invoke-ProcessWithCapturedOutput', 'Invoke-MariaDb',
        'Assert-SingleValue', 'Assert-DatabaseIdentity',
        'Assert-DatabasePortOwnership', 'Wait-ForDatabaseReady',
        'Assert-ReviewedDatabaseConfiguration', 'Stop-OwnedDatabase',
        'Start-ReviewedDatabase'
    )

    $topStatements = @($ast.EndBlock.Statements)
    $selected = New-Object System.Collections.Generic.List[object]
    $initializers = New-Object System.Collections.Generic.List[object]
    $functions = New-Object System.Collections.Generic.List[object]
    foreach ($name in $initializerNames) {
        $matches = @($topStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -ieq $name
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one top-level initializer '$name'; found $($matches.Count)."
        }
        $selected.Add($matches[0])
        $initializers.Add([pscustomobject]@{
            Name = $name
            RightText = $matches[0].Right.Extent.Text
            StartOffset = $matches[0].Extent.StartOffset
        })
    }
    foreach ($name in $functionNames) {
        $matches = @($topStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Name -ieq $name
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one top-level function '$name'; found $($matches.Count)."
        }
        $selected.Add($matches[0])
        $functions.Add([pscustomobject]@{
            Name = $name
            BodyText = $matches[0].Body.Extent.Text
            StartOffset = $matches[0].Extent.StartOffset
        })
    }

    $entrypoints = @($topStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    })
    if ($entrypoints.Count -ne 1) {
        throw "Expected one excluded top-level try/catch entry point; found $($entrypoints.Count)."
    }

    $ordered = @($selected | Sort-Object { $_.Extent.StartOffset })
    $code = (@($ordered | ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n") + "`r`n"
    $selectedBytes = $EvidenceEncoding.GetBytes($code)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $selectedHash = ([BitConverter]::ToString($algorithm.ComputeHash($selectedBytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }

    $subsetTokens = $null
    $subsetErrors = $null
    $subsetAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $code,
        [ref]$subsetTokens,
        [ref]$subsetErrors)
    if ($subsetErrors.Count -ne 0) {
        throw "Extracted subset parser errors: $($subsetErrors.Count)."
    }

    $forbiddenNames = @(
        'Invoke-ExecuteMode', 'Invoke-RollbackMode', 'Invoke-ReviewedMigrations',
        'Invoke-LogicalDump', 'Invoke-MariaDbExport', 'Invoke-SqlFile',
        'Start-ReviewedWorld', 'Stop-OwnedWorld', 'Invoke-FailureCleanup',
        'Wait-ForHonorMaintenance', 'Register-Migration', 'Enable-MigrationsModuleColumn'
    )
    $selectedDefinitionNames = @($subsetAst.EndBlock.Statements |
        Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
        ForEach-Object { $_.Name })
    $forbiddenSelected = @($selectedDefinitionNames | Where-Object { $forbiddenNames -icontains $_ })
    if ($forbiddenSelected.Count -ne 0) {
        throw "Forbidden functions entered the extracted subset: $($forbiddenSelected -join ', ')."
    }

    $commandInventory = @($subsetAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object {
        $name = $_.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { '<dynamic>' } else { $name }
    } | Group-Object | Sort-Object Name | ForEach-Object {
        '{0}|COUNT={1}' -f $_.Name, $_.Count
    })

    return [pscustomobject]@{
        Code = $code
        Sha256 = $selectedHash
        InitializerNames = $initializerNames
        FunctionNames = $functionNames
        Initializers = @($initializers | ForEach-Object { $_ })
        Functions = @($functions | ForEach-Object { $_ })
        CommandInventory = $commandInventory
        ExcludedEntrypointCount = $entrypoints.Count
    }
}

function Import-ReviewedSubset {
    param([Parameter(Mandatory = $true)]$Subset)

    foreach ($initializer in @($Subset.Initializers | Sort-Object StartOffset)) {
        $valueScript = [scriptblock]::Create($initializer.RightText)
        $value = & $valueScript
        $variableName = $initializer.Name
        if ($variableName.StartsWith('script:', [StringComparison]::OrdinalIgnoreCase)) {
            $variableName = $variableName.Substring(7)
        }
        Set-Variable -Name $variableName -Value $value -Scope Script
    }

    foreach ($function in @($Subset.Functions | Sort-Object StartOffset)) {
        $bodyText = $function.BodyText
        if ($bodyText.Length -lt 2 -or $bodyText[0] -ne '{' -or $bodyText[$bodyText.Length - 1] -ne '}') {
            throw "Extracted function body is malformed: $($function.Name)"
        }
        $bodyScript = [scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2))
        Set-Item -Path ("Function:\script:{0}" -f $function.Name) -Value $bodyScript
    }
}

function Write-StaticAudit {
    param([Parameter(Mandatory = $true)]$Subset)
    $harnessTokens = $null
    $harnessErrors = $null
    $harnessAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $HarnessPath,
        [ref]$harnessTokens,
        [ref]$harnessErrors)
    if ($harnessErrors.Count -ne 0) {
        throw "Smoke harness parser errors: $($harnessErrors.Count)."
    }

    $actualCommands = @($harnessAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    $forbiddenCalls = @('Invoke-ExecuteMode', 'Invoke-RollbackMode', 'Invoke-ReviewedMigrations',
        'Invoke-LogicalDump', 'Invoke-MariaDbExport', 'Invoke-SqlFile', 'Start-ReviewedWorld',
        'Stop-OwnedWorld', 'Invoke-FailureCleanup', 'Wait-ForHonorMaintenance',
        'Register-Migration', 'Enable-MigrationsModuleColumn', 'taskkill', 'Stop-Process',
        'Invoke-Expression', 'Get-Command')
    $reachedForbidden = @($actualCommands | Where-Object {
        $name = $_.GetCommandName()
        -not [string]::IsNullOrWhiteSpace($name) -and $forbiddenCalls -icontains $name
    })
    if ($reachedForbidden.Count -ne 0) {
        throw "The smoke harness contains forbidden command calls: $(@($reachedForbidden | ForEach-Object { $_.GetCommandName() }) -join ', ')."
    }

    $harnessCommandInventory = @($actualCommands | ForEach-Object {
        $name = $_.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { '<dynamic>' } else { $name }
    } | Group-Object | Sort-Object Name | ForEach-Object {
        '{0}|COUNT={1}' -f $_.Name, $_.Count
    })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("HARNESS_PATH=$HarnessPath")
    $lines.Add("HARNESS_BYTES=$((Get-Item -LiteralPath $HarnessPath).Length)")
    $lines.Add("HARNESS_SHA256=$(Get-LocalSha256 -Path $HarnessPath)")
    $lines.Add("HARNESS_PARSER_ERRORS=$($harnessErrors.Count)")
    $lines.Add("PINNED_RUNBOOK_PATH=$PinnedRunbook")
    $lines.Add("PINNED_RUNBOOK_BYTES=$ExpectedPinnedRunbookBytes")
    $lines.Add("PINNED_RUNBOOK_SHA256=$ExpectedPinnedRunbookSha256")
    $lines.Add("EXTRACTED_SUBSET_SHA256=$($Subset.Sha256)")
    $lines.Add("EXCLUDED_TOP_LEVEL_ENTRYPOINT_COUNT=$($Subset.ExcludedEntrypointCount)")
    $lines.Add("FORBIDDEN_HARNESS_CALL_COUNT=$($reachedForbidden.Count)")
    foreach ($auditedCall in @(
        'Start-ReviewedDatabase',
        'Start-SmokeWorld',
        'Invoke-SmokeWorldHelper',
        'Stop-OwnedDatabase')) {
        $callCount = @($actualCommands | Where-Object {
            $_.GetCommandName() -ieq $auditedCall
        }).Count
        $lines.Add("HARNESS_CALL_SITE_COUNT|NAME=$auditedCall|COUNT=$callCount")
    }
    $lines.Add('HELPER_RUNTIME_ATTEMPT_LIMIT=1')
    $lines.Add('HELPER_ATTEMPT_GATE_SET_BEFORE_PROCESS_CREATION=true')
    $lines.Add('WORLD_CONSOLE_CREATION=CREATE_NEW_CONSOLE')
    $lines.Add('WORLD_CONSOLE_EVIDENCE=CREATION_FLAG_PLUS_PARENT_LINEAGE_PLUS_HELPER_VALIDATED_EXACT_TITLE')
    $lines.Add('EXTRACTED_INITIALIZERS_BEGIN')
    foreach ($name in $Subset.InitializerNames) { $lines.Add($name) }
    $lines.Add('EXTRACTED_INITIALIZERS_END')
    $lines.Add('EXTRACTED_FUNCTIONS_BEGIN')
    foreach ($name in $Subset.FunctionNames) { $lines.Add($name) }
    $lines.Add('EXTRACTED_FUNCTIONS_END')
    $lines.Add('EXTRACTED_COMMAND_INVENTORY_BEGIN')
    foreach ($line in $Subset.CommandInventory) { $lines.Add($line) }
    $lines.Add('EXTRACTED_COMMAND_INVENTORY_END')
    $lines.Add('HARNESS_COMMAND_INVENTORY_BEGIN')
    foreach ($line in $harnessCommandInventory) { $lines.Add($line) }
    $lines.Add('HARNESS_COMMAND_INVENTORY_END')
    [IO.File]::WriteAllLines(
        $script:StaticAuditPath,
        @($lines | ForEach-Object { $_ }),
        $EvidenceEncoding)
}

function Assert-AllRuntimeIdentities {
    Assert-LocalFileIdentity -Path $PinnedRunbook -ExpectedBytes $ExpectedPinnedRunbookBytes -ExpectedSha256 $ExpectedPinnedRunbookSha256
    Assert-LocalFileIdentity -Path $CandidateHelper -ExpectedBytes $ExpectedCandidateHelperBytes -ExpectedSha256 $ExpectedCandidateHelperSha256
    Assert-LocalFileIdentity -Path $CandidateLauncher -ExpectedBytes $ExpectedCandidateLauncherBytes -ExpectedSha256 $ExpectedCandidateLauncherSha256
    foreach ($key in @('DatabaseLauncher', 'MyIni', 'MariaDbServer', 'MariaDbClient',
        'MariaDbDump', 'MariaDbAdmin', 'ProductionExe', 'MangosConfig',
        'PlayerbotConfig', 'StartWorld', 'ShutdownHelper')) {
        Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256
    }
    if ((Get-Sha256 -Path $ProductionExe) -cne $ExpectedProductionExeSha256ForSmoke) {
        throw 'The production mangosd.exe hash differs from the smoke-test approval.'
    }
    Assert-PlayerbotLlmDisabled
}

function Get-InitialLogState {
    $serverFiles = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $LogsDirectoryForSmoke -Filter 'server*.log' -File -ErrorAction Stop)) {
        $serverFiles[$file.FullName.ToUpperInvariant()] = [long]$file.Length
    }
    return [pscustomobject]@{
        ServerFiles = $serverFiles
        ErrorLength = if (Test-Path -LiteralPath $FixedErrorLog -PathType Leaf) { (Get-Item -LiteralPath $FixedErrorLog).Length } else { [long]0 }
        HonorLength = if (Test-Path -LiteralPath $FixedHonorLog -PathType Leaf) { (Get-Item -LiteralPath $FixedHonorLog).Length } else { [long]0 }
    }
}

function Read-FileFromOffset {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Offset
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $Offset) {
            throw "Log file shrank during the smoke test: $Path"
        }
        [void]$stream.Seek($Offset, 'Begin')
        $reader = New-Object IO.StreamReader($stream, $EvidenceEncoding, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-NewServerLog {
    $newFiles = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $LogsDirectoryForSmoke -Filter 'server*.log' -File -ErrorAction Stop)) {
        if (-not $script:InitialLogState.ServerFiles.ContainsKey($file.FullName.ToUpperInvariant())) {
            $newFiles += $file
        }
    }
    if ($newFiles.Count -gt 1) {
        throw "More than one new server log appeared: $($newFiles.FullName -join ', ')."
    }
    if ($newFiles.Count -eq 0) { return $null }
    return $newFiles[0]
}

function Assert-WorldOwnershipTuple {
    $owned = Get-VerifiedOwnedProcess -Kind World
    if ($null -eq $owned) {
        throw 'The owned Worldserver process is no longer verifiable.'
    }
    $worldProcesses = @(Get-ProcessCandidates -Kind World)
    [void](Assert-StrictProcessAgreement -Kind World -Candidates $worldProcesses)
    if ($worldProcesses.Count -ne 1 -or $worldProcesses[0].Id -ne $owned.Id) {
        throw 'Worldserver uniqueness changed during the smoke test.'
    }
    if (@(Get-Process -Name realmd -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'A realmd process appeared during the Worldserver smoke test.'
    }
    if (-not (Test-Path -LiteralPath $WorldPidFile -PathType Leaf)) {
        throw 'twlive.pid disappeared while the Worldserver was active.'
    }
    $pidText = [IO.File]::ReadAllText($WorldPidFile).Trim()
    $pidValue = 0
    if (-not [int]::TryParse($pidText, [ref]$pidValue) -or $pidValue -ne $owned.Id) {
        throw "twlive.pid no longer matches the owned Worldserver PID $($owned.Id). Found '$pidText'."
    }
    if ((Get-Sha256 -Path $ProductionExe) -cne $ExpectedProductionExeSha256ForSmoke) {
        throw 'mangosd.exe changed while running.'
    }
    return $owned
}

function Get-WorldPidFileState {
    if (-not (Test-Path -LiteralPath $WorldPidFile -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Length = [long]0
            LastWriteTimeUtcTicks = [long]0
            Content = ''
            Sha256 = ''
        }
    }
    $item = Get-Item -LiteralPath $WorldPidFile -ErrorAction Stop
    return [pscustomobject]@{
        Exists = $true
        Length = [long]$item.Length
        LastWriteTimeUtcTicks = [long]$item.LastWriteTimeUtc.Ticks
        Content = [IO.File]::ReadAllText($WorldPidFile)
        Sha256 = Get-LocalSha256 -Path $WorldPidFile
    }
}

function Start-SmokeWorld {
    Assert-LocalFileIdentity -Path $CandidateLauncher -ExpectedBytes $ExpectedCandidateLauncherBytes -ExpectedSha256 $ExpectedCandidateLauncherSha256
    Assert-LocalFileIdentity -Path $CandidateHelper -ExpectedBytes $ExpectedCandidateHelperBytes -ExpectedSha256 $ExpectedCandidateHelperSha256
    Assert-Hash -Path $ProductionExe -ExpectedSha256 $ExpectedProductionExeSha256ForSmoke

    $commandInterpreter = Assert-ReviewedCommandInterpreter

    $script:PreWorldPidFileState = Get-WorldPidFileState
    Write-SmokeLine -Text ("WORLD_PID_FILE_PRELAUNCH|EXISTS={0}|LENGTH={1}|LAST_WRITE_TICKS={2}|SHA256={3}|CONTENT={4}" -f
        $script:PreWorldPidFileState.Exists,
        $script:PreWorldPidFileState.Length,
        $script:PreWorldPidFileState.LastWriteTimeUtcTicks,
        $script:PreWorldPidFileState.Sha256,
        $script:PreWorldPidFileState.Content.Trim())

    $timer = [Diagnostics.Stopwatch]::StartNew()
    Set-LaunchAttempt -Kind World
    $script:WorldLauncherPath = $commandInterpreter
    $launch = [WorldSmokeNative]::StartWorldLauncherInNewConsole(
        $commandInterpreter,
        $CandidateLauncher,
        $ServerDirectoryForSmoke)
    $script:WorldLauncherPid = [int]$launch.ProcessId
    $script:WorldLauncherHandle = $launch.ProcessHandle
    $script:WorldLauncherThreadHandle = $launch.ThreadHandle
    Set-LauncherPid -Kind World -ProcessId $script:WorldLauncherPid
    Write-SmokeLine -Text "WORLD_LAUNCHER_CREATED|PID=$($script:WorldLauncherPid)|PATH=$commandInterpreter|CREATE_NEW_CONSOLE=true|THREAD_HANDLE_CLOSED=$($launch.ThreadHandleClosed)|THREAD_CLOSE_WIN32=$($launch.ThreadHandleCloseError)"
    if (-not $launch.ThreadHandleClosed) {
        throw "The launcher thread handle could not be closed after process creation. Win32=$($launch.ThreadHandleCloseError)."
    }

    $launcher = Get-Process -Id $script:WorldLauncherPid -ErrorAction Stop
    $launcherPath = $launcher.Path
    $launcherStartTicks = $launcher.StartTime.ToUniversalTime().Ticks
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($launcherPath),
        $commandInterpreter,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "The candidate launcher PID $($launcher.Id) has unexpected path '$launcherPath'."
    }
    $script:WorldLauncher = $launcher
    $script:WorldLauncherStartTicks = $launcherStartTicks
    Write-SmokeLine -Text "WORLD_LAUNCHER_OWNERSHIP_RECORDED|PID=$($launcher.Id)|PATH=$launcherPath|START_TICKS=$launcherStartTicks|CONSOLE_ISOLATION=CREATE_NEW_CONSOLE"

    $owned = Wait-ForOwnedProcess -Kind World -TimeoutSeconds 60
    $worldProcesses = @(Get-ProcessCandidates -Kind World)
    if ($worldProcesses.Count -ne 1 -or $worldProcesses[0].Id -ne $owned.Id) {
        throw 'Worldserver launch validation found an unexpected mangosd process.'
    }
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $owned.Id) -ErrorAction Stop
    if ([int]$cim.ParentProcessId -ne [int]$launcher.Id) {
        throw "Worldserver parent PID $($cim.ParentProcessId) does not match launcher PID $($launcher.Id)."
    }

    $pidDeadline = [DateTime]::UtcNow.AddSeconds(60)
    $pidValue = 0
    $pidRewriteProven = $false
    $pidValidated = $false
    do {
        if (Test-Path -LiteralPath $WorldPidFile -PathType Leaf) {
            try {
                $pidItem = Get-Item -LiteralPath $WorldPidFile -ErrorAction Stop
                $pidText = [IO.File]::ReadAllText($WorldPidFile).Trim()
                $pidRewriteProven = (
                    -not $script:PreWorldPidFileState.Exists -or
                    $pidItem.LastWriteTimeUtc.Ticks -gt $script:PreWorldPidFileState.LastWriteTimeUtcTicks)
                if ([int]::TryParse($pidText, [ref]$pidValue) -and
                    $pidValue -eq $owned.Id -and
                    $pidRewriteProven -and
                    $pidItem.LastWriteTimeUtc -ge $script:RunState.World.LaunchUtc.AddSeconds(-2)) {
                    $pidValidated = $true
                    break
                }
            }
            catch { }
        }
        if ($null -eq (Get-VerifiedOwnedProcess -Kind World)) {
            throw 'Worldserver exited before twlive.pid was validated.'
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $pidDeadline)
    if (-not $pidValidated) {
        throw "twlive.pid did not prove a fresh rewrite to the owned PID $($owned.Id)."
    }

    $script:WorldPid = $owned.Id
    $script:WorldPidStartTicks = $script:RunState.World.OwnedStartTimeUtcTicks
    [void](Assert-WorldOwnershipTuple)
    $script:WorldVerifiedForHelper = $true
    $timer.Stop()
    $script:WorldPidAcquisitionMilliseconds = $timer.ElapsedMilliseconds
    Write-SmokeLine -Text "WORLD_PID_VALIDATED|PID=$($owned.Id)|LAUNCHER_PID=$($launcher.Id)|PID_ACQUISITION_MS=$($timer.ElapsedMilliseconds)|PID_FILE_REWRITE_PROVEN=true|TITLE_EXPECTED=$ExpectedWorldTitle"
    return $owned
}

function Wait-ForWorldStabilityAndReadiness {
    $stabilityDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        [void](Assert-WorldOwnershipTuple)
        if ([WorldSmokeNative]::WaitForExit($script:WorldLauncherHandle, [uint32]0)) {
            throw 'The candidate launcher exited while mangosd was expected to remain active.'
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $stabilityDeadline)
    Write-SmokeLine -Text 'WORLD_STABILITY_DWELL_COMPLETE|SECONDS=30'

    $readyTimer = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddMinutes(90)
    $nextProgress = [DateTime]::UtcNow
    do {
        [void](Assert-WorldOwnershipTuple)
        if ($null -eq $script:NewServerLog) {
            $newLog = Get-NewServerLog
            if ($null -ne $newLog) {
                if ($newLog.LastWriteTimeUtc -lt $script:RunState.World.LaunchUtc.AddSeconds(-2)) {
                    throw "The new server log predates the World launch: $($newLog.FullName)"
                }
                $script:NewServerLog = $newLog.FullName
                Write-SmokeLine -Text "WORLD_SERVER_LOG_IDENTIFIED|PATH=$($newLog.FullName)"
            }
        }
        if ($null -ne $script:NewServerLog) {
            $content = Read-FileFromOffset -Path $script:NewServerLog -Offset 0
            if ($content.Contains('World server is up and running! Loading time:')) {
                $readyTimer.Stop()
                $script:WorldReadyMilliseconds = [long]([DateTime]::UtcNow - $script:RunState.World.LaunchUtc).TotalMilliseconds
                Write-SmokeLine -Text "WORLD_READY_MARKER_FOUND|TOTAL_LAUNCH_ELAPSED_MS=$($script:WorldReadyMilliseconds)|POST_STABILITY_WAIT_MS=$($readyTimer.ElapsedMilliseconds)|PATH=$($script:NewServerLog)"
                return
            }
        }
        if ([DateTime]::UtcNow -ge $nextProgress) {
            Write-SmokeLine -Text "WORLD_READINESS_WAIT|ELAPSED_SECONDS=$([int]$readyTimer.Elapsed.TotalSeconds)"
            $nextProgress = [DateTime]::UtcNow.AddSeconds(30)
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The Worldserver did not reach its authoritative readiness marker within 90 minutes.'
}

function Invoke-SmokeWorldHelper {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('normal', 'failure_cleanup')]
        [string]$Reason
    )
    if ($script:HelperAttempted) {
        throw 'The candidate helper attempt has already been consumed.'
    }
    if (-not $script:WorldVerifiedForHelper) {
        throw 'The Worldserver was not fully verified for a controlled helper invocation.'
    }
    Assert-LocalFileIdentity -Path $CandidateHelper -ExpectedBytes $ExpectedCandidateHelperBytes -ExpectedSha256 $ExpectedCandidateHelperSha256
    Assert-LocalFileIdentity -Path $CandidateLauncher -ExpectedBytes $ExpectedCandidateLauncherBytes -ExpectedSha256 $ExpectedCandidateLauncherSha256
    Assert-Hash -Path $ProductionExe -ExpectedSha256 $ExpectedProductionExeSha256ForSmoke
    [void](Assert-WorldOwnershipTuple)
    Assert-NoRealmdProcessStrict

    if ($null -ne $script:NewServerLog -and (Test-Path -LiteralPath $script:NewServerLog -PathType Leaf)) {
        $script:ServerLogShutdownOffset = [long](Get-Item -LiteralPath $script:NewServerLog -ErrorAction Stop).Length
        Write-SmokeLine -Text "WORLD_SHUTDOWN_LOG_OFFSET|PATH=$($script:NewServerLog)|BYTES=$($script:ServerLogShutdownOffset)"
    }

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $CandidateHelper,
        '-Action', 'World',
        '-ServerDirectory', $ServerDirectoryForSmoke,
        '-WorldWindowTitle', $ExpectedWorldTitle,
        '-SaveDelaySeconds', '5',
        '-WorldExitTimeoutSeconds', '180'
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShell51
    $startInfo.Arguments = (@($arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Argument $_
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.WorkingDirectory = $ServerDirectoryForSmoke

    $marker = [WorldSmokeNative]::MarkConsole()
    $script:HelperAttempted = $true
    $script:HelperAttemptReason = $Reason
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'The candidate helper process could not be created.'
    }
    $script:HelperProcess = $process
    $script:HelperProcessPid = $process.Id
    try {
        $script:HelperProcessPath = $process.Path
        $script:HelperProcessStartTicks = $process.StartTime.ToUniversalTime().Ticks
        if (-not [string]::Equals(
            [IO.Path]::GetFullPath($script:HelperProcessPath),
            [IO.Path]::GetFullPath($PowerShell51),
            [StringComparison]::OrdinalIgnoreCase)) {
            throw "The helper PID $($process.Id) has unexpected path '$($script:HelperProcessPath)'."
        }
        $script:HelperProcessHandle = [WorldSmokeNative]::OpenProcessForWaitAndQuery([uint32]$process.Id)
        if (-not [WorldSmokeNative]::WaitForExit($script:HelperProcessHandle, [uint32]240000)) {
            throw 'The candidate helper process exceeded the 240-second smoke boundary.'
        }
        $script:HelperExitCode = [int][WorldSmokeNative]::GetExitCode($script:HelperProcessHandle)
        $process.WaitForExit()
        $raw = [WorldSmokeNative]::ReadConsoleSince($marker)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'The scoped helper console capture is empty; unscoped console history is not accepted.'
        }
        $script:HelperConsoleText = $raw
    }
    finally {
        $timer.Stop()
        $script:WorldShutdownMilliseconds = $timer.ElapsedMilliseconds
    }
    Write-SmokeLine -Text "HELPER_STARTED|REASON=$Reason|PID=$($script:HelperProcessPid)|PATH=$($script:HelperProcessPath)|START_TICKS=$($script:HelperProcessStartTicks)|REDIRECTION=false"
    [IO.File]::WriteAllText(
        (Join-Path $script:EvidenceDirectory 'helper.console.raw.txt'),
        $script:HelperConsoleText,
        $EvidenceEncoding)

    $expected = "[OK] Worldserver PID $($script:WorldPid), Pfad '$ServerDirectoryForSmoke\mangosd.exe', Konsole '$ExpectedWorldTitle': kontrolliert beendet."
    $matches = [regex]::Matches($script:HelperConsoleText, [regex]::Escape($expected))
    if ($script:HelperExitCode -eq 0) {
        if ($matches.Count -ne 1 -or $script:HelperConsoleText.Contains('[FEHLER]')) {
            throw "The helper returned zero without one exact visible OK result. Console capture: $($script:HelperConsoleText)"
        }
        $script:HelperStdout = $expected + "`r`n"
        $script:HelperStderr = ''
        $script:ValidatedWorldTitle = $ExpectedWorldTitle
    }
    else {
        $script:HelperStdout = ''
        $errorMatches = [regex]::Matches($script:HelperConsoleText, '\[FEHLER\][^\r\n]*')
        $script:HelperStderr = if ($errorMatches.Count -eq 0) { $script:HelperConsoleText.Trim() + "`r`n" } else { $errorMatches[$errorMatches.Count - 1].Value.TrimEnd() + "`r`n" }
    }
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'helper.stdout.txt'), $script:HelperStdout, $EvidenceEncoding)
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'helper.stderr.txt'), $script:HelperStderr, $EvidenceEncoding)
    Write-SmokeLine -Text "HELPER_COMPLETED|REASON=$Reason|EXIT_CODE=$($script:HelperExitCode)|ELAPSED_MS=$($timer.ElapsedMilliseconds)|CAPTURE_MODE=SCOPED_UNREDIRECTED_CONSOLE|STREAM_EVIDENCE=CLASSIFIED_BY_EXIT_BRANCH"
    if ($script:HelperExitCode -ne 0) {
        throw "The candidate helper failed with exit code $($script:HelperExitCode)."
    }
    Write-SmokeLine -Text "HELPER_STDOUT_EXACT=$($expected)"
}

function Complete-WorldLauncherExit {
    if ($script:WorldLauncherExitObserved) {
        return
    }
    if ($script:WorldLauncherHandle -eq [IntPtr]::Zero) {
        throw 'The retained candidate-launcher handle is unavailable.'
    }
    if (-not [WorldSmokeNative]::WaitForExit($script:WorldLauncherHandle, [uint32]30000)) {
        throw 'The candidate launcher did not exit within 30 seconds after mangosd stopped.'
    }
    $script:WorldLauncherExitCode = [int][WorldSmokeNative]::GetExitCode($script:WorldLauncherHandle)
    $script:WorldLauncherExitObserved = $true
    if ($script:WorldLauncherExitCode -ne 0) {
        throw "The candidate launcher returned exit code $($script:WorldLauncherExitCode)."
    }
    Write-SmokeLine -Text "WORLD_LAUNCHER_EXITED|PID=$($script:WorldLauncherPid)|EXIT_CODE=$($script:WorldLauncherExitCode)"
}

function Assert-NewLogSectionSafe {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $blockedPatterns = @(
        '(?is)character_inventory_copy.{0,160}(missing|does not exist|doesn''t exist|unknown table|1146)',
        '(?i)(\[1146\]|\berror\s*1146\b)',
        '(?i)database structure is not up to date',
        '(?im)(\[crash\]|crash_[0-9]{8}|fatal signal|unhandled exception|access violation|stack trace)'
    )
    foreach ($pattern in $blockedPatterns) {
        if ([regex]::IsMatch($Text, $pattern)) {
            throw "The $Label contains a blocked failure marker matching: $pattern"
        }
    }
}

function Assert-CleanWorldShutdownLog {
    if ($null -eq $script:NewServerLog -or
        -not (Test-Path -LiteralPath $script:NewServerLog -PathType Leaf)) {
        throw 'The unique current-run Worldserver log is unavailable for shutdown verification.'
    }
    if ($null -eq $script:ServerLogShutdownOffset) {
        throw 'The pre-helper Worldserver log offset was not recorded.'
    }

    $shutdownText = Read-FileFromOffset `
        -Path $script:NewServerLog `
        -Offset $script:ServerLogShutdownOffset
    $completeServerText = Read-FileFromOffset -Path $script:NewServerLog -Offset 0
    $markers = @(
        'Shutting down world...',
        'Stopping network threads...',
        'Unloading all maps...',
        'Unloading all transports...',
        'Cleaning character database...',
        'Sending queued mail...',
        'Closing database connections...',
        'Halting process...'
    )
    $cursor = 0
    foreach ($shutdownMarker in $markers) {
        $count = [regex]::Matches(
            $shutdownText,
            [regex]::Escape($shutdownMarker)).Count
        if ($count -ne 1) {
            throw "Shutdown marker '$shutdownMarker' occurs $count times in the post-helper server-log section; expected exactly once."
        }
        $index = $shutdownText.IndexOf(
            $shutdownMarker,
            $cursor,
            [StringComparison]::Ordinal)
        if ($index -lt 0) {
            throw "Shutdown marker '$shutdownMarker' is missing or out of order."
        }
        $cursor = $index + $shutdownMarker.Length
    }

    $errorText = Read-FileFromOffset `
        -Path $FixedErrorLog `
        -Offset $script:InitialLogState.ErrorLength
    Assert-NewLogSectionSafe -Text $completeServerText -Label 'complete current-run server log'
    Assert-NewLogSectionSafe -Text $errorText -Label 'newly appended error-log section'
    $script:ShutdownLogValidated = $true
    Write-SmokeLine -Text "WORLD_SHUTDOWN_LOG_VALIDATED|MARKER_COUNT=$($markers.Count)|ORDERED=true|UNSAFE_MARKERS=false|OFFSET=$($script:ServerLogShutdownOffset)"
}

function Write-LogEvidence {
    $serverText = ''
    $shutdownText = ''
    if ($null -ne $script:NewServerLog -and (Test-Path -LiteralPath $script:NewServerLog -PathType Leaf)) {
        $serverText = Read-FileFromOffset -Path $script:NewServerLog -Offset 0
        if ($null -ne $script:ServerLogShutdownOffset) {
            $shutdownText = Read-FileFromOffset -Path $script:NewServerLog -Offset $script:ServerLogShutdownOffset
        }
    }
    $errorText = Read-FileFromOffset -Path $FixedErrorLog -Offset $script:InitialLogState.ErrorLength
    $honorText = Read-FileFromOffset -Path $FixedHonorLog -Offset $script:InitialLogState.HonorLength
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'server.log.appended.txt'), $serverText, $EvidenceEncoding)
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'server.shutdown.appended.txt'), $shutdownText, $EvidenceEncoding)
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'errors.log.appended.txt'), $errorText, $EvidenceEncoding)
    [IO.File]::WriteAllText((Join-Path $script:EvidenceDirectory 'honor.log.appended.txt'), $honorText, $EvidenceEncoding)
    Write-SmokeLine -Text "LOG_EVIDENCE|SERVER_PATH=$($script:NewServerLog)|SERVER_CHARS=$($serverText.Length)|SHUTDOWN_CHARS=$($shutdownText.Length)|ERROR_CHARS=$($errorText.Length)|HONOR_CHARS=$($honorText.Length)"
}

function Write-SmokeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][object[]]$FinalState
    )
    $result = [ordered]@{
        Status = $Status
        HarnessPath = $HarnessPath
        HarnessBytes = (Get-Item -LiteralPath $HarnessPath).Length
        HarnessSha256 = Get-LocalSha256 -Path $HarnessPath
        PinnedRunbookSha256 = Get-LocalSha256 -Path $PinnedRunbook
        CandidateHelperSha256 = Get-LocalSha256 -Path $CandidateHelper
        CandidateLauncherSha256 = Get-LocalSha256 -Path $CandidateLauncher
        ProductionExeSha256 = Get-LocalSha256 -Path 'C:\TW\ComTW\server\mangosd.exe'
        StartedUtc = $script:RunStartUtc.ToString('o')
        FinishedUtc = [DateTime]::UtcNow.ToString('o')
        DatabasePid = $script:DatabasePid
        DatabaseLauncherPid = $script:DatabaseLauncherPid
        DatabaseLauncherPath = $script:DatabaseLauncherPath
        DatabaseLauncherStartTicks = $script:DatabaseLauncherStartTicks
        DatabaseLauncherExitObserved = $script:DatabaseLauncherExitObserved
        WorldPid = $script:WorldPid
        WorldLauncherPid = $script:WorldLauncherPid
        WorldLauncherPath = $script:WorldLauncherPath
        WorldLauncherStartTicks = $script:WorldLauncherStartTicks
        WorldLauncherExitCode = $script:WorldLauncherExitCode
        WorldLauncherExitObserved = $script:WorldLauncherExitObserved
        WorldConsoleCreation = 'CREATE_NEW_CONSOLE'
        WorldVerifiedForHelper = $script:WorldVerifiedForHelper
        HelperAttempted = $script:HelperAttempted
        HelperAttemptReason = $script:HelperAttemptReason
        HelperProcessPid = $script:HelperProcessPid
        HelperProcessPath = $script:HelperProcessPath
        HelperProcessStartTicks = $script:HelperProcessStartTicks
        HelperExitCode = $script:HelperExitCode
        ValidatedWorldTitle = $script:ValidatedWorldTitle
        ShutdownLogValidated = $script:ShutdownLogValidated
        DatabaseStartMilliseconds = $script:DatabaseStartMilliseconds
        WorldPidAcquisitionMilliseconds = $script:WorldPidAcquisitionMilliseconds
        WorldReadyMilliseconds = $script:WorldReadyMilliseconds
        WorldShutdownMilliseconds = $script:WorldShutdownMilliseconds
        DatabaseShutdownMilliseconds = $script:DatabaseShutdownMilliseconds
        DatabaseStopOutput = $script:DatabaseStopOutput
        ServerLogPath = $script:NewServerLog
        PrimaryError = $script:PrimaryError
        CleanupErrors = @($script:CleanupErrors | ForEach-Object { $_ })
        FinalState = @($FinalState)
        MigrationInvoked = $false
        RollbackInvoked = $false
        DumpInvoked = $false
        BackupInvoked = $false
        HonorMaintenanceExplicitlyInvoked = $false
        RealmdStarted = $false
        ForcedTerminationUsed = $false
    }
    [IO.File]::WriteAllText(
        $script:ResultPath,
        ($result | ConvertTo-Json -Depth 6),
        $EvidenceEncoding)
}

$overallExitCode = 1
$subset = $null
$finalState = @()
try {
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or
        $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "Windows PowerShell 5.1 is required. Found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator=True is required before any server start.'
    }
    if ((Get-LocalSha256 -Path $HarnessPath) -cne $ApprovedHarnessSha256.ToUpperInvariant()) {
        throw 'The smoke harness does not match the externally supplied approved SHA-256.'
    }

    [void](New-SmokeEvidenceDirectory)
    Write-SmokeLine -Text "SMOKE_HARNESS_STARTED|PATH=$HarnessPath|SHA256=$(Get-LocalSha256 -Path $HarnessPath)|POWERSHELL=$($PSVersionTable.PSVersion)|ADMINISTRATOR=True"

    $subset = Get-ReviewedSubset
    Write-StaticAudit -Subset $subset
    Import-ReviewedSubset -Subset $subset
    $script:SubsetLoaded = $true
    Write-SmokeLine -Text "PINNED_SUBSET_LOADED|SHA256=$($subset.Sha256)|ENTRYPOINT_EXCLUDED=true"

    [void](Assert-ReviewedCommandInterpreter)
    Assert-AllRuntimeIdentities
    Assert-InitialSmokeState
    Write-State -Prefix 'INITIAL_STATE'
    Write-SmokeLine -Text 'MANDATORY_PREFLIGHT_PASSED=true'

    if (Test-Path -LiteralPath $AttemptMarkerPath) {
        throw "The one-attempt marker already exists: $AttemptMarkerPath"
    }
    $markerStream = [IO.File]::Open($AttemptMarkerPath, 'CreateNew', 'Write', 'Read')
    try {
        $markerText = "ATTEMPT_UTC=$([DateTime]::UtcNow.ToString('o'))`r`nHARNESS_SHA256=$(Get-LocalSha256 -Path $HarnessPath)`r`n"
        $markerBytes = $EvidenceEncoding.GetBytes($markerText)
        $markerStream.Write($markerBytes, 0, $markerBytes.Length)
        $markerStream.Flush()
    }
    finally {
        $markerStream.Dispose()
    }
    $script:AttemptMarkerCreated = $true
    Write-SmokeLine -Text "ONE_ATTEMPT_MARKER_CREATED|PATH=$AttemptMarkerPath"

    $script:InitialLogState = Get-InitialLogState
    Write-SmokeLine -Text "LOG_OFFSETS_RECORDED|ERRORS=$($script:InitialLogState.ErrorLength)|HONOR=$($script:InitialLogState.HonorLength)|SERVER_FILE_COUNT=$($script:InitialLogState.ServerFiles.Count)"

    Assert-AllRuntimeIdentities
    Assert-InitialSmokeState
    [void](Assert-ReviewedCommandInterpreter)
    Write-SmokeLine -Text 'IMMEDIATE_PRESTART_GATE_PASSED=true'

    $databaseTimer = [Diagnostics.Stopwatch]::StartNew()
    $database = Start-ReviewedDatabase
    $databaseTimer.Stop()
    if ($null -eq $database) { throw 'Start-ReviewedDatabase returned no owned process.' }
    $script:DatabasePid = $database.Id
    Update-DatabaseLauncherRecord -RequireActive
    $script:DatabaseStartMilliseconds = $databaseTimer.ElapsedMilliseconds
    $databaseProcesses = @(Get-ProcessCandidates -Kind Database)
    [void](Assert-StrictProcessAgreement -Kind Database -Candidates $databaseProcesses)
    if ($databaseProcesses.Count -ne 1 -or $databaseProcesses[0].Id -ne $database.Id) {
        throw 'The reviewed database start did not produce exactly one owned process.'
    }
    Assert-DatabasePortOwnership
    $databaseIdentity = Invoke-MariaDb -Sql 'SELECT DATABASE()'
    if ($databaseIdentity -cne 'tw_char') {
        throw "Database identity mismatch. Expected exact 'tw_char', found '$databaseIdentity'."
    }
    Assert-ReviewedDatabaseConfiguration
    Write-SmokeLine -Text "DATABASE_VALIDATED|PID=$($database.Id)|IDENTITY=$databaseIdentity|STARTUP_MS=$($databaseTimer.ElapsedMilliseconds)|PORT_OWNER_EXACT=true|CONFIGURATION_REVIEWED=true"

    Assert-AllRuntimeIdentities
    $world = Start-SmokeWorld
    Wait-ForWorldStabilityAndReadiness
    Invoke-SmokeWorldHelper -Reason 'normal'

    Wait-ForProcessExit -ProcessId $script:WorldPid -StartTimeUtcTicks $script:WorldPidStartTicks -TimeoutSeconds 190
    if (@(Get-ProcessCandidates -Kind World).Count -ne 0) {
        throw 'A mangosd process remains after the helper returned success.'
    }
    Complete-WorldLauncherExit
    Assert-CleanWorldShutdownLog
    Assert-AllRuntimeIdentities
    $script:FunctionalSequencePassed = $true
    Write-SmokeLine -Text 'WORLD_SHUTDOWN_SEQUENCE_PASSED=true'
}
catch {
    $script:PrimaryError = $_.Exception.Message
    try { Write-SmokeError -Text "SMOKE_FAILURE|MESSAGE=$($script:PrimaryError)" } catch {
        try { [Console]::Error.WriteLine("SMOKE_FAILURE|MESSAGE=$($script:PrimaryError)") } catch { }
    }
}
finally {
    if ($script:SubsetLoaded) {
        try { Update-DatabaseLauncherRecord } catch {
            $script:CleanupErrors.Add("Database launcher identity capture: $($_.Exception.Message)")
        }
    }
    if ($null -ne $script:EvidenceDirectory) {
        try { Write-State -Prefix 'PRE_CLEANUP_STATE' } catch {
            $script:CleanupErrors.Add("Pre-cleanup state inspection: $($_.Exception.Message)")
        }
    }

    if ($null -ne $script:PrimaryError -and $script:SubsetLoaded) {
        try {
            $cleanupWorldProcesses = @(Get-ProcessCandidates -Kind World)
            [void](Assert-StrictProcessAgreement -Kind World -Candidates $cleanupWorldProcesses)
            if ($cleanupWorldProcesses.Count -eq 1 -and
                $script:WorldVerifiedForHelper -and
                -not $script:HelperAttempted) {
                $cleanupOwnedWorld = Assert-WorldOwnershipTuple
                if ($cleanupOwnedWorld.Id -ne $script:WorldPid -or
                    $script:RunState.World.OwnedStartTimeUtcTicks -ne $script:WorldPidStartTicks) {
                    throw 'The surviving Worldserver does not match the previously verified ownership tuple.'
                }
                Write-SmokeLine -Text "FAILURE_CLEANUP_WORLD_REVERIFIED|PID=$($cleanupOwnedWorld.Id)|HELPER_ATTEMPT_AVAILABLE=true"
                try {
                    Invoke-SmokeWorldHelper -Reason 'failure_cleanup'
                }
                catch {
                    $script:CleanupErrors.Add("Controlled Worldserver helper cleanup: $($_.Exception.Message)")
                }
            }
            elseif ($cleanupWorldProcesses.Count -gt 0) {
                $reason = if ($script:HelperAttempted) {
                    'the single helper attempt was already consumed'
                }
                elseif (-not $script:WorldVerifiedForHelper) {
                    'the Worldserver never reached the complete verified ownership state'
                }
                else {
                    "the Worldserver process count is $($cleanupWorldProcesses.Count)"
                }
                $script:CleanupErrors.Add("Controlled Worldserver cleanup was not authorized because $reason. No forced action was attempted.")
            }
        }
        catch {
            $script:CleanupErrors.Add("Worldserver cleanup authorization: $($_.Exception.Message)")
        }
    }

    if ($script:HelperProcessHandle -ne [IntPtr]::Zero) {
        try {
            if ([WorldSmokeNative]::WaitForExit($script:HelperProcessHandle, [uint32]0)) {
                if ($null -eq $script:HelperExitCode) {
                    $script:HelperExitCode = [int][WorldSmokeNative]::GetExitCode($script:HelperProcessHandle)
                }
                Write-SmokeLine -Text "HELPER_FINAL_OBSERVATION|PID=$($script:HelperProcessPid)|ACTIVE=false|EXIT_CODE=$($script:HelperExitCode)"
            }
            else {
                Write-SmokeLine -Text "HELPER_FINAL_OBSERVATION|PID=$($script:HelperProcessPid)|ACTIVE=true|ACTION=none"
            }
        }
        catch {
            $script:CleanupErrors.Add("Helper final observation: $($_.Exception.Message)")
        }
    }

    $worldStateKnown = $false
    $worldRemains = $true
    try {
        $remainingWorldProcesses = @(if ($script:SubsetLoaded) {
            @(Get-ProcessCandidates -Kind World)
        }
        else {
            @(Get-Process -Name mangosd -ErrorAction SilentlyContinue)
        })
        if ($script:SubsetLoaded) {
            [void](Assert-StrictProcessAgreement -Kind World -Candidates $remainingWorldProcesses)
        }
        else {
            $strictWorldIds = @(Get-StrictServerProcessRecords -Kind World | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
            $softWorldIds = @($remainingWorldProcesses | ForEach-Object { [int]$_.Id } | Sort-Object)
            if (($strictWorldIds -join ',') -cne ($softWorldIds -join ',')) {
                throw 'Worldserver process enumerations disagree before cleanup.'
            }
        }
        $worldStateKnown = $true
        $worldRemains = ($remainingWorldProcesses.Count -ne 0)
        Write-SmokeLine -Text "WORLD_POST_CLEANUP_OBSERVATION|COUNT=$($remainingWorldProcesses.Count)|PIDS=$(@($remainingWorldProcesses | ForEach-Object { $_.Id }) -join ',')"
    }
    catch {
        $script:CleanupErrors.Add("Worldserver post-cleanup inspection: $($_.Exception.Message)")
    }

    if ($worldStateKnown -and -not $worldRemains -and
        $script:WorldLauncherHandle -ne [IntPtr]::Zero -and
        -not $script:WorldLauncherExitObserved) {
        try { Complete-WorldLauncherExit } catch {
            $script:CleanupErrors.Add("Launcher controlled-exit observation: $($_.Exception.Message)")
        }
    }

    $worldLauncherStateKnown = $true
    $worldLauncherActive = $false
    if ($script:WorldLauncherHandle -ne [IntPtr]::Zero) {
        try {
            if ([WorldSmokeNative]::WaitForExit($script:WorldLauncherHandle, [uint32]0)) {
                if (-not $script:WorldLauncherExitObserved) {
                    $script:WorldLauncherExitCode = [int][WorldSmokeNative]::GetExitCode($script:WorldLauncherHandle)
                    $script:WorldLauncherExitObserved = $true
                    if ($script:WorldLauncherExitCode -ne 0) {
                        $script:CleanupErrors.Add("The candidate launcher returned exit code $($script:WorldLauncherExitCode).")
                    }
                }
            }
            else {
                $worldLauncherActive = $true
            }
        }
        catch {
            $worldLauncherStateKnown = $false
            $script:CleanupErrors.Add("World launcher liveness inspection: $($_.Exception.Message)")
        }
    }
    elseif ($null -ne $script:WorldLauncherPid) {
        $launcherProcess = Get-Process -Id $script:WorldLauncherPid -ErrorAction SilentlyContinue
        if ($null -ne $launcherProcess) {
            try {
                $launcherPathMatches = [string]::Equals(
                    [IO.Path]::GetFullPath($launcherProcess.Path),
                    [IO.Path]::GetFullPath($script:WorldLauncherPath),
                    [StringComparison]::OrdinalIgnoreCase)
                $launcherStartMatches = (
                    $null -ne $script:WorldLauncherStartTicks -and
                    $launcherProcess.StartTime.ToUniversalTime().Ticks -eq $script:WorldLauncherStartTicks)
                if (-not $launcherPathMatches -or -not $launcherStartMatches) {
                    $worldLauncherStateKnown = $false
                    $script:CleanupErrors.Add('The recorded World launcher PID is active with a foreign identity and was not touched.')
                }
                else {
                    $worldLauncherActive = $true
                }
            }
            catch {
                $worldLauncherStateKnown = $false
                $script:CleanupErrors.Add("World launcher fallback inspection: $($_.Exception.Message)")
            }
        }
    }
    try {
        Write-SmokeLine -Text "WORLD_LAUNCHER_FINAL_OBSERVATION|KNOWN=$worldLauncherStateKnown|ACTIVE=$worldLauncherActive|PID=$($script:WorldLauncherPid)|EXIT_OBSERVED=$($script:WorldLauncherExitObserved)|EXIT_CODE=$($script:WorldLauncherExitCode)"
    }
    catch {
        $script:CleanupErrors.Add("World launcher observation evidence: $($_.Exception.Message)")
    }

    try {
        $remainingRealmProcesses = @(Get-Process -Name realmd -ErrorAction SilentlyContinue)
        $strictRealmProcesses = @(Get-StrictServerProcessRecords -Kind Realm)
        $softRealmIds = @($remainingRealmProcesses | ForEach-Object { [int]$_.Id } | Sort-Object)
        $strictRealmIds = @($strictRealmProcesses | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
        if (($softRealmIds -join ',') -cne ($strictRealmIds -join ',')) {
            throw "Realmd process enumerations disagree. Get-Process=[$($softRealmIds -join ',')], CIM=[$($strictRealmIds -join ',')]."
        }
        $remainingMatchingServices = @(Get-MatchingRunningServices)
        if (-not $worldStateKnown -or $worldRemains) {
            $script:CleanupErrors.Add('MariaDB shutdown skipped because Worldserver absence was not proven. No forced Worldserver action was attempted.')
        }
        elseif (-not $worldLauncherStateKnown -or $worldLauncherActive) {
            $script:CleanupErrors.Add('MariaDB shutdown skipped because the owned World launcher is active or its absence is not proven.')
        }
        elseif ($remainingRealmProcesses.Count -ne 0) {
            $script:CleanupErrors.Add('MariaDB shutdown skipped because a realmd process is active.')
        }
        elseif ($remainingMatchingServices.Count -ne 0) {
            $script:CleanupErrors.Add('MariaDB shutdown skipped because a matching Windows service is active.')
        }
        elseif ($script:SubsetLoaded) {
            $ownedDatabase = Get-VerifiedOwnedProcess -Kind Database
            $databaseCandidates = @(Get-ProcessCandidates -Kind Database)
            [void](Assert-StrictProcessAgreement -Kind Database -Candidates $databaseCandidates)
            if ($null -ne $ownedDatabase -and
                $databaseCandidates.Count -eq 1 -and
                $databaseCandidates[0].Id -eq $ownedDatabase.Id) {
                $freshWorldCandidates = @(Get-ProcessCandidates -Kind World)
                [void](Assert-StrictProcessAgreement -Kind World -Candidates $freshWorldCandidates)
                if ($freshWorldCandidates.Count -ne 0) {
                    throw 'A Worldserver process appeared immediately before the controlled database stop.'
                }
                Assert-NoRealmdProcessStrict
                if (@(Get-MatchingRunningServices).Count -ne 0) {
                    throw 'A matching Windows service appeared immediately before the controlled database stop.'
                }
                Assert-DatabasePortOwnership
                $stopTimer = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $databaseStopPipeline = @(Stop-OwnedDatabase)
                    if ($databaseStopPipeline.Count -lt 1 -or
                        -not ($databaseStopPipeline[$databaseStopPipeline.Count - 1] -is [bool]) -or
                        $databaseStopPipeline[$databaseStopPipeline.Count - 1] -ne $true) {
                        throw 'Stop-OwnedDatabase did not end with the required Boolean success value.'
                    }
                    if ($databaseStopPipeline.Count -gt 1) {
                        $script:DatabaseStopOutput = @(
                            $databaseStopPipeline[0..($databaseStopPipeline.Count - 2)] |
                                ForEach-Object { [string]$_ }) -join "`r`n"
                    }
                    if ($null -ne (Get-VerifiedOwnedProcess -Kind Database)) {
                        throw 'The owned MariaDB process remains after Stop-OwnedDatabase returned.'
                    }
                    $postStopDatabaseCandidates = @(Get-ProcessCandidates -Kind Database)
                    [void](Assert-StrictProcessAgreement -Kind Database -Candidates $postStopDatabaseCandidates)
                    if ($postStopDatabaseCandidates.Count -ne 0) {
                        throw 'A MariaDB server process remains after the controlled database stop.'
                    }
                    $postStopPortOwners = @(Get-StrictPortOwnerPids -Port 3307)
                    if ($postStopPortOwners.Count -ne 0) {
                        throw "Port 3307 remains open after the controlled database stop. Owners: $($postStopPortOwners -join ',')."
                    }
                    $stopTimer.Stop()
                    $script:DatabaseShutdownMilliseconds = $stopTimer.ElapsedMilliseconds
                    if ($null -ne $script:DatabaseLauncherPid -and
                        $null -ne $script:DatabaseLauncherStartTicks) {
                        Wait-ForProcessExit `
                            -ProcessId $script:DatabaseLauncherPid `
                            -StartTimeUtcTicks $script:DatabaseLauncherStartTicks `
                            -TimeoutSeconds 30
                        $script:DatabaseLauncherExitObserved = $true
                        Write-SmokeLine -Text "DATABASE_LAUNCHER_EXITED|PID=$($script:DatabaseLauncherPid)"
                    }
                    elseif ($null -ne $script:DatabaseLauncherPid -and
                        $null -ne (Get-Process -Id $script:DatabaseLauncherPid -ErrorAction SilentlyContinue)) {
                        throw 'The database launcher remains active without an immutable start-time identity.'
                    }
                    $script:DatabaseStopSucceeded = $true
                    Write-SmokeLine -Text "DATABASE_STOPPED|PID=$($ownedDatabase.Id)|SHUTDOWN_MS=$($stopTimer.ElapsedMilliseconds)|PROCESS_ABSENT=true|PORT3307_CLOSED=true|LAUNCHER_EXITED=$($script:DatabaseLauncherExitObserved)"
                }
                finally {
                    if ($stopTimer.IsRunning) { $stopTimer.Stop() }
                }
            }
            elseif ($databaseCandidates.Count -ne 0) {
                $script:CleanupErrors.Add('MariaDB shutdown skipped because the active database process is not uniquely verified as owned by this run.')
            }
            elseif ($null -ne $script:DatabasePid) {
                $script:CleanupErrors.Add("The owned MariaDB PID $($script:DatabasePid) was absent before the controlled database-stop step.")
            }
        }
    }
    catch {
        $script:CleanupErrors.Add("Database controlled stop: $($_.Exception.Message)")
    }

    if ($null -ne $script:EvidenceDirectory -and $null -ne $script:InitialLogState) {
        try { Write-LogEvidence } catch {
            $script:CleanupErrors.Add("Log evidence: $($_.Exception.Message)")
        }
    }

    if ($null -ne $script:EvidenceDirectory) {
        try { Write-State -Prefix 'POST_CLEANUP_PRE_HANDLE_CLOSE_STATE' } catch {
            $script:CleanupErrors.Add("Post-cleanup state inspection: $($_.Exception.Message)")
        }
    }

    if ($script:WorldLauncherThreadHandle -ne [IntPtr]::Zero) {
        try {
            [WorldSmokeNative]::CloseProcessHandle($script:WorldLauncherThreadHandle)
            $script:WorldLauncherThreadHandle = [IntPtr]::Zero
            Write-SmokeLine -Text 'WORLD_LAUNCHER_THREAD_HANDLE_CLOSED=true'
        }
        catch {
            $script:CleanupErrors.Add("Launcher thread-handle close: $($_.Exception.Message)")
        }
    }
    if ($script:HelperProcessHandle -ne [IntPtr]::Zero) {
        try {
            [WorldSmokeNative]::CloseProcessHandle($script:HelperProcessHandle)
            $script:HelperProcessHandle = [IntPtr]::Zero
            Write-SmokeLine -Text 'HELPER_NATIVE_HANDLE_CLOSED=true'
        }
        catch {
            $script:CleanupErrors.Add("Helper native-handle close: $($_.Exception.Message)")
        }
    }
    if ($script:WorldLauncherHandle -ne [IntPtr]::Zero) {
        try {
            [WorldSmokeNative]::CloseProcessHandle($script:WorldLauncherHandle)
            $script:WorldLauncherHandle = [IntPtr]::Zero
            Write-SmokeLine -Text 'WORLD_LAUNCHER_NATIVE_HANDLE_CLOSED=true'
        }
        catch {
            $script:CleanupErrors.Add("Launcher process-handle close: $($_.Exception.Message)")
        }
    }
    if ($null -ne $script:HelperProcess) {
        try {
            $script:HelperProcess.Dispose()
            Write-SmokeLine -Text 'HELPER_PROCESS_WRAPPER_DISPOSED=true'
        }
        catch {
            $script:CleanupErrors.Add("Helper Process disposal: $($_.Exception.Message)")
        }
    }
    if ($null -ne $script:WorldLauncher) {
        try {
            $script:WorldLauncher.Dispose()
            Write-SmokeLine -Text 'WORLD_LAUNCHER_PROCESS_WRAPPER_DISPOSED=true'
        }
        catch {
            $script:CleanupErrors.Add("Launcher Process disposal: $($_.Exception.Message)")
        }
    }

    try {
        $finalState = @(Get-StateLines)
        foreach ($line in $finalState) { Write-SmokeLine -Text "FINAL_STATE|$line" }
        $finalProcesses = @(Get-SmokeServerProcesses)
        $strictFinalProcesses = @(Get-StrictServerProcessRecords -Kind All)
        $finalSoftIds = @($finalProcesses | ForEach-Object { [int]$_.Id } | Sort-Object)
        $finalStrictIds = @($strictFinalProcesses | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
        if (($finalSoftIds -join ',') -cne ($finalStrictIds -join ',')) {
            throw "Final server-process enumerations disagree. Get-Process=[$($finalSoftIds -join ',')], CIM=[$($finalStrictIds -join ',')]."
        }
        $finalServices = @(Get-MatchingRunningServices)
        $port3307 = @(Get-StrictPortOwnerPids -Port 3307)
        $port8090 = @(Get-StrictPortOwnerPids -Port 8090)
        $trackedDatabaseLauncherActive = (
            $null -ne $script:DatabaseLauncherPid -and
            $null -ne (Get-Process -Id $script:DatabaseLauncherPid -ErrorAction SilentlyContinue))
        $trackedLauncherActive = (
            $null -ne $script:WorldLauncherPid -and
            $null -ne (Get-Process -Id $script:WorldLauncherPid -ErrorAction SilentlyContinue))
        $trackedHelperActive = (
            $null -ne $script:HelperProcessPid -and
            $null -ne (Get-Process -Id $script:HelperProcessPid -ErrorAction SilentlyContinue))
        $script:FinalStatePassed = (
            $finalProcesses.Count -eq 0 -and
            $strictFinalProcesses.Count -eq 0 -and
            $finalServices.Count -eq 0 -and
            $port3307.Count -eq 0 -and
            $port8090.Count -eq 0 -and
            -not $trackedDatabaseLauncherActive -and
            -not $trackedLauncherActive -and
            -not $trackedHelperActive)
    }
    catch {
        $script:CleanupErrors.Add("Final state inspection: $($_.Exception.Message)")
        $script:FinalStatePassed = $false
    }

    foreach ($cleanupError in @($script:CleanupErrors | ForEach-Object { $_ })) {
        try {
            Write-SmokeError -Text "CLEANUP_ERROR|MESSAGE=$cleanupError"
        }
        catch {
            try {
                [Console]::Error.WriteLine("CLEANUP_ERROR|MESSAGE=$cleanupError|REPORTING_FAILURE=$($_.Exception.Message)")
            }
            catch { }
        }
    }

    if ($null -ne $script:EvidenceDirectory) {
        try {
            $status = if (
                $null -eq $script:PrimaryError -and
                $script:CleanupErrors.Count -eq 0 -and
                $script:FunctionalSequencePassed -and
                $script:ShutdownLogValidated -and
                $script:DatabaseStopSucceeded -and
                $script:FinalStatePassed) {
                'passed'
            }
            else {
                'failed'
            }
            Write-SmokeResult -Status $status -FinalState $finalState
            Write-SmokeLine -Text "SMOKE_RESULT|STATUS=$status|EVIDENCE=$($script:EvidenceDirectory)|RESULT=$($script:ResultPath)"
            if ($status -eq 'passed') { $overallExitCode = 0 }
        }
        catch {
            $resultFailure = $_.Exception.Message
            try { Write-SmokeError -Text "RESULT_WRITE_FAILURE|MESSAGE=$resultFailure" } catch {
                try { [Console]::Error.WriteLine("RESULT_WRITE_FAILURE|MESSAGE=$resultFailure") } catch { }
            }
            $overallExitCode = 1
        }
    }
}

exit $overallExitCode
