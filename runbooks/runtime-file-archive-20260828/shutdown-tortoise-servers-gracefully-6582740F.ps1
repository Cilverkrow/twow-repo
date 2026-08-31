[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('World', 'Realm')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ServerDirectory,

    [string]$WorldWindowTitle = 'mangosd',
    [string]$RealmWindowTitle = 'realmd',

    [ValidateRange(1, 60)]
    [int]$SaveDelaySeconds = 5,

    [ValidateRange(10, 3600)]
    [int]$WorldExitTimeoutSeconds = 180,

    [ValidateRange(5, 300)]
    [int]$RealmExitTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TortoiseConsoleControl
{
    private const int STD_INPUT_HANDLE = -10;
    private const ushort KEY_EVENT = 0x0001;
    private const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;
    private const uint CTRL_BREAK_EVENT = 1;

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    private struct KEY_EVENT_RECORD
    {
        [FieldOffset(0)]  public int KeyDown;
        [FieldOffset(4)]  public ushort RepeatCount;
        [FieldOffset(6)]  public ushort VirtualKeyCode;
        [FieldOffset(8)]  public ushort VirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint ControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    private struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    private delegate bool ConsoleCtrlHandler(uint ctrlType);
    private static readonly ConsoleCtrlHandler ProtectionHandler = IgnoreControlEvent;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int stdHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetConsoleTitleW(StringBuilder title, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WriteConsoleInputW(
        IntPtr consoleInput,
        INPUT_RECORD[] buffer,
        uint length,
        out uint written);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

    public static void Detach()
    {
        FreeConsole();
    }

    public static void AttachTo(uint processId)
    {
        if (!AttachConsole(processId))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole failed");
    }

    public static void TryAttachToParent()
    {
        AttachConsole(ATTACH_PARENT_PROCESS);
    }

    public static string GetTitle()
    {
        StringBuilder title = new StringBuilder(1024);
        uint length = GetConsoleTitleW(title, (uint)title.Capacity);
        if (length == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The attached console has no readable title");

        return title.ToString();
    }

    public static void WriteCommand(string command)
    {
        if (String.IsNullOrWhiteSpace(command) || command.IndexOfAny(new[] { '\r', '\n' }) >= 0)
            throw new ArgumentException("The console command must be one non-empty line.", "command");

        IntPtr input = GetStdHandle(STD_INPUT_HANDLE);
        if (input == IntPtr.Zero || input == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The console input handle is invalid");

        List<INPUT_RECORD> records = new List<INPUT_RECORD>();

        // Remove any text that might already be waiting on the current input line.
        for (int i = 0; i < 256; ++i)
            AddKey(records, '\b', 0x08);

        foreach (char character in command)
            AddKey(records, character, GetVirtualKey(character));

        AddKey(records, '\r', 0x0D);

        INPUT_RECORD[] buffer = records.ToArray();
        uint written;
        if (!WriteConsoleInputW(input, buffer, (uint)buffer.Length, out written))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteConsoleInput failed");

        if (written != buffer.Length)
            throw new InvalidOperationException("Only part of the command reached the server console.");
    }

    public static void EnableControlProtection()
    {
        if (!SetConsoleCtrlHandler(ProtectionHandler, true))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetConsoleCtrlHandler failed");
    }

    public static void DisableControlProtection()
    {
        SetConsoleCtrlHandler(ProtectionHandler, false);
    }

    public static void SendCtrlBreak()
    {
        if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GenerateConsoleCtrlEvent failed");

        // Give every process in the target console time to receive the event
        // before this helper detaches from that console.
        Thread.Sleep(250);
    }

    private static bool IgnoreControlEvent(uint ctrlType)
    {
        return true;
    }

    private static ushort GetVirtualKey(char character)
    {
        if (character >= 'a' && character <= 'z')
            return (ushort)Char.ToUpperInvariant(character);

        return character;
    }

    private static void AddKey(List<INPUT_RECORD> records, char character, ushort virtualKey)
    {
        INPUT_RECORD keyDown = new INPUT_RECORD();
        keyDown.EventType = KEY_EVENT;
        keyDown.KeyEvent.KeyDown = 1;
        keyDown.KeyEvent.RepeatCount = 1;
        keyDown.KeyEvent.VirtualKeyCode = virtualKey;
        keyDown.KeyEvent.UnicodeChar = character;
        records.Add(keyDown);

        INPUT_RECORD keyUp = keyDown;
        keyUp.KeyEvent.KeyDown = 0;
        records.Add(keyUp);
    }
}
'@

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$First,

        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    return [string]::Equals(
        [System.IO.Path]::GetFullPath($First),
        [System.IO.Path]::GetFullPath($Second),
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ValidatedServerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedExecutable,

        [Parameter(Mandatory = $true)]
        [string]$PidFile,

        [switch]$AllowNotRunning
    )

    $namedProcesses = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($namedProcesses.Count -eq 0) {
        if ($AllowNotRunning) {
            return $null
        }

        throw "Es laeuft kein $ProcessName.exe. Der Shutdown wird abgebrochen."
    }

    $matchingProcesses = @(
        foreach ($candidate in $namedProcesses) {
            try {
                if (Test-SamePath -First $candidate.Path -Second $ExpectedExecutable) {
                    $candidate
                }
            }
            catch {
                # Ein Prozess ohne pruefbaren Pfad darf nie automatisch gesteuert werden.
            }
        }
    )

    if ($matchingProcesses.Count -ne 1) {
        throw "Der Prozess $ProcessName.exe ist ueber seinen vollstaendigen EXE-Pfad nicht eindeutig (Treffer: $($matchingProcesses.Count))."
    }

    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
        throw "Die PID-Datei fehlt: $PidFile"
    }

    $pidText = (Get-Content -LiteralPath $PidFile -Raw).Trim()
    $processIdValue = 0
    if (-not [int]::TryParse($pidText, [ref]$processIdValue) -or $processIdValue -le 0) {
        throw "Die PID-Datei enthaelt keine gueltige PID: $PidFile"
    }

    $serverProcess = $matchingProcesses[0]
    if ($serverProcess.Id -ne $processIdValue) {
        throw "PID-Datei und laufender $ProcessName-Prozess stimmen nicht ueberein (Datei: $processIdValue, Prozess: $($serverProcess.Id))."
    }

    $serverProcess.Refresh()
    if ($serverProcess.HasExited) {
        throw "$ProcessName.exe (PID $processIdValue) wurde waehrend der Pruefung beendet."
    }

    return $serverProcess
}

function Invoke-InValidatedConsole {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$ServerProcess,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedWindowTitle,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation
    )

    [TortoiseConsoleControl]::Detach()
    $attached = $false
    try {
        [TortoiseConsoleControl]::AttachTo([uint32]$ServerProcess.Id)
        $attached = $true

        $actualTitle = [TortoiseConsoleControl]::GetTitle()
        if (-not [string]::Equals($actualTitle, $ExpectedWindowTitle, [System.StringComparison]::Ordinal)) {
            throw "Unerwarteter Konsolentitel fuer PID $($ServerProcess.Id): '$actualTitle' statt '$ExpectedWindowTitle'."
        }

        & $Operation
        return $actualTitle
    }
    finally {
        if ($attached) {
            [TortoiseConsoleControl]::Detach()
        }

        [TortoiseConsoleControl]::TryAttachToParent()
    }
}

try {
    $resolvedServerDirectory = [System.IO.Path]::GetFullPath($ServerDirectory)

    if ($Action -eq 'World') {
        $worldExecutable = Join-Path $resolvedServerDirectory 'mangosd.exe'
        $worldPidFile = Join-Path $resolvedServerDirectory 'twlive.pid'

        if (-not (Test-Path -LiteralPath $worldExecutable -PathType Leaf)) {
            throw "Worldserver-EXE nicht gefunden: $worldExecutable"
        }

        $worldProcess = Get-ValidatedServerProcess `
            -ProcessName 'mangosd' `
            -ExpectedExecutable $worldExecutable `
            -PidFile $worldPidFile

        $validatedTitle = Invoke-InValidatedConsole `
            -ServerProcess $worldProcess `
            -ExpectedWindowTitle $WorldWindowTitle `
            -Operation {
                [TortoiseConsoleControl]::WriteCommand('saveall')
                Start-Sleep -Seconds $SaveDelaySeconds

                $worldProcess.Refresh()
                if ($worldProcess.HasExited) {
                    throw 'mangosd.exe wurde nach saveall unerwartet beendet.'
                }

                [TortoiseConsoleControl]::WriteCommand('server shutdown 0')
            }

        if (-not $worldProcess.WaitForExit($WorldExitTimeoutSeconds * 1000)) {
            throw "mangosd.exe laeuft nach $WorldExitTimeoutSeconds Sekunden noch. Es wird kein erzwungener Shutdown ausgefuehrt."
        }

        if ($worldProcess.ExitCode -ne 0) {
            throw "mangosd.exe wurde mit dem unerwarteten Exitcode $($worldProcess.ExitCode) beendet."
        }

        Write-Output "[OK] Worldserver PID $($worldProcess.Id), Pfad '$worldExecutable', Konsole '$validatedTitle': kontrolliert beendet."
        exit 0
    }

    $realmExecutable = Join-Path $resolvedServerDirectory 'realmd.exe'
    $realmPidFile = Join-Path $resolvedServerDirectory 'twrealmd.pid'

    if (-not (Test-Path -LiteralPath $realmExecutable -PathType Leaf)) {
        throw "Realmd-EXE nicht gefunden: $realmExecutable"
    }

    $realmProcess = Get-ValidatedServerProcess `
        -ProcessName 'realmd' `
        -ExpectedExecutable $realmExecutable `
        -PidFile $realmPidFile `
        -AllowNotRunning

    if ($null -eq $realmProcess) {
        Write-Output '[INFO] Realmd laeuft bereits nicht mehr.'
        exit 0
    }

    $validatedTitle = Invoke-InValidatedConsole `
        -ServerProcess $realmProcess `
        -ExpectedWindowTitle $RealmWindowTitle `
        -Operation {
            [TortoiseConsoleControl]::EnableControlProtection()
            try {
                # Der Core behandelt CTRL_BREAK als SIGBREAK und setzt damit
                # sein stopEvent. Das ist der vorgesehene kontrollierte Pfad.
                [TortoiseConsoleControl]::SendCtrlBreak()
            }
            finally {
                [TortoiseConsoleControl]::DisableControlProtection()
            }
        }

    if (-not $realmProcess.WaitForExit($RealmExitTimeoutSeconds * 1000)) {
        throw "realmd.exe laeuft nach $RealmExitTimeoutSeconds Sekunden noch. Es wird kein erzwungenes Beenden ausgefuehrt."
    }

    if ($realmProcess.ExitCode -ne 0) {
        throw "realmd.exe wurde mit dem unerwarteten Exitcode $($realmProcess.ExitCode) beendet."
    }

    Write-Output "[OK] Realmd PID $($realmProcess.Id), Pfad '$realmExecutable', Konsole '$validatedTitle': kontrolliert beendet."
    exit 0
}
catch {
    Write-Error "[FEHLER] $($_.Exception.Message)"
    exit 1
}
