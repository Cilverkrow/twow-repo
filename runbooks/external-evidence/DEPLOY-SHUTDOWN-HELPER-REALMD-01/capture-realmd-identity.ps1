$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedExecutable = 'C:\TW\ComTW\server\realmd.exe'
$pidFile = 'C:\TW\ComTW\server\twrealmd.pid'

$pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
$processIdValue = 0
if (-not [int]::TryParse($pidText, [ref]$processIdValue) -or $processIdValue -le 0) {
    throw "Invalid PID file: $pidFile"
}

$process = Get-Process -Id $processIdValue -ErrorAction Stop
$process.Refresh()
if ($process.HasExited -or $process.ProcessName -ne 'realmd') {
    throw "PID $processIdValue is not a running realmd.exe process."
}

$actualExecutable = [System.IO.Path]::GetFullPath($process.Path)
if (-not [string]::Equals($actualExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected realmd executable path: $actualExecutable"
}

$matchingProcesses = @(
    Get-Process -Name realmd -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals(
                [System.IO.Path]::GetFullPath($_.Path),
                $expectedExecutable,
                [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    }
)
if ($matchingProcesses.Count -ne 1) {
    throw "Expected exactly one matching realmd.exe process; found $($matchingProcesses.Count)."
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class EvidenceConsoleSnapshot
{
    private const uint ATTACH_PARENT_PROCESS = 0xFFFFFFFF;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetConsoleTitleW(StringBuilder title, uint size);

    public static string Read(uint processId)
    {
        FreeConsole();
        try
        {
            if (!AttachConsole(processId))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole failed");

            StringBuilder title = new StringBuilder(1024);
            uint length = GetConsoleTitleW(title, (uint)title.Capacity);
            if (length == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Console title is unreadable");

            return title.ToString();
        }
        finally
        {
            FreeConsole();
            AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }
}
'@

$consoleTitle = [EvidenceConsoleSnapshot]::Read([uint32]$processIdValue)

"CapturedUtc=$([DateTime]::UtcNow.ToString('o'))"
"PID_FILE=$pidFile"
"PID=$processIdValue"
"ProcessName=$($process.ProcessName).exe"
"ExecutablePath=$actualExecutable"
"ConsoleTitle=$consoleTitle"
"MatchingExpectedPathCount=$($matchingProcesses.Count)"
