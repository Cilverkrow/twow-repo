param([Parameter(Mandatory=$true)][string]$BuildDirectory,[string]$LogPath='')
$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
$source=$PSScriptRoot
$build=[IO.Path]::GetFullPath($BuildDirectory)
$runtime=(Resolve-Path -LiteralPath (Join-Path $source '..\..\..\..\dep\windows\lib\x64_release')).Path
if(Test-Path -LiteralPath $build){throw "Build directory already exists: $build"}
$transcript=[Text.StringBuilder]::new()

function Invoke-Clean([string]$file,[string[]]$arguments) {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$file;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Environment.Clear()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if($entry.Key -ieq 'Path' -or $entry.Key -eq 'CL'){continue}
        if($seen.Add([string]$entry.Key)){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    }
    $psi.Environment['Path']=$runtime+';'+$env:Path
    foreach($argument in $arguments){[void]$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $stdout=$outTask.GetAwaiter().GetResult();$stderr=$errTask.GetAwaiter().GetResult();$exit=$process.ExitCode;$process.Dispose()
    [void]$transcript.AppendLine("COMMAND=$file $($arguments -join ' ')")
    [void]$transcript.AppendLine("EXIT_CODE=$exit")
    [void]$transcript.Append($stdout);[void]$transcript.Append($stderr)
    if($stdout){[Console]::Out.Write($stdout)};if($stderr){[Console]::Error.Write($stderr)}
    if($exit-ne0){throw "Process failed with exit code ${exit}: $file"}
}

Invoke-Clean $cmake @('-S',$source,'-B',$build,'-G','Visual Studio 17 2022','-A','x64','-DCMAKE_PREFIX_PATH=C:/TW/ComTW/vcpkg/installed/x64-windows')
Invoke-Clean $cmake @('--build',$build,'--config','Release','--target','persistent_active_roster_tests','--parallel','2')
Invoke-Clean (Join-Path $build 'Release\persistent_active_roster_tests.exe') @()
if($LogPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($LogPath),$transcript.ToString(),[Text.UTF8Encoding]::new($false))}
