param(
  [string]$Source='C:\TW\rndbot-roster-phase-b-20260830-230336\source',
  [string]$Build='C:\TW\rndbot-roster-phase-b-20260830-230336\build-clean-1',
  [string]$LogDirectory='C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-20260830-230336\logs'
)
$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
if(Test-Path -LiteralPath $Build){throw "Build directory already exists: $Build"}
[void](New-Item -ItemType Directory -Path $LogDirectory -Force)

function Invoke-CleanCaptured([string]$File,[string[]]$Arguments,[string]$OutPath,[string]$ErrPath) {
  $psi=[Diagnostics.ProcessStartInfo]::new()
  $psi.FileName=$File;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.Environment.Clear()
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
    if($entry.Key -ieq 'Path' -or $entry.Key -like 'GIT_CONFIG_*' -or $entry.Key -eq 'CL'){continue}
    if($seen.Add([string]$entry.Key)){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
  }
  $psi.Environment['Path']=$env:Path
  $psi.Environment['CL']='/MP2'
  $psi.Environment['CMAKE_BUILD_PARALLEL_LEVEL']='2'
  $psi.Environment['GIT_CONFIG_COUNT']='1'
  $psi.Environment['GIT_CONFIG_KEY_0']='safe.directory'
  $psi.Environment['GIT_CONFIG_VALUE_0']=$Source.Replace('\','/')
  foreach($argument in $Arguments){[void]$psi.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($psi)
  $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
  $stdout=$outTask.GetAwaiter().GetResult();$stderr=$errTask.GetAwaiter().GetResult();$exit=$process.ExitCode;$process.Dispose()
  [IO.File]::WriteAllText($OutPath,$stdout,[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($ErrPath,$stderr,[Text.UTF8Encoding]::new($false))
  if($stdout){[Console]::Out.Write($stdout)};if($stderr){[Console]::Error.Write($stderr)}
  if($exit-ne0){throw "Process failed with exit code ${exit}: $File"}
}

$configure=@(
  '-S',$Source,'-B',$Build,'-G','Visual Studio 17 2022','-A','x64',
  '-DCMAKE_INSTALL_PREFIX=C:/TW/rndbot-roster-phase-b-20260830-230336/install-unused',
  '-DCMAKE_BUILD_TYPE=Release',
  '-DACE_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
  '-DBOOST_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
  '-DALLOW_TURTLE_ADDONS=ON','-DBUILD_PLAYERBOTS=ON','-DMODULES=disabled',
  '-DUSE_ADDRESS_SANITIZER=OFF','-DUSE_ANTICHEAT=ON','-DUSE_DISCORD_BOT=OFF',
  '-DUSE_EXTRACTORS=ON','-DUSE_LIBCURL=OFF','-DUSE_PCH=ON','-DUSE_PCH_OLD=ON',
  '-DUSE_REALMMERGE=OFF','-DUSE_SCRIPTS=ON','-DUSE_STD_MALLOC=ON','-DUSE_TRACY=OFF'
)
Invoke-CleanCaptured $cmake $configure (Join-Path $LogDirectory 'configure.stdout.log') (Join-Path $LogDirectory 'configure.stderr.log')
Invoke-CleanCaptured $cmake @('--build',$Build,'--config','Release','--target','mangosd','--parallel','2') (Join-Path $LogDirectory 'build.stdout.log') (Join-Path $LogDirectory 'build.stderr.log')
