param(
  [string]$Source='C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source',
  [string]$Build='C:\TW\rndbot-roster-phase-b-r2-20260831-131938\build-clean-final',
  [string]$Evidence='C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938\evidence\clean-build'
)
$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
if(Test-Path -LiteralPath $Build){throw "Clean build directory already exists: $Build"}
[void](New-Item -ItemType Directory -Path $Evidence -Force)
$candidate=Join-Path $Source 'bin\Release\mangosd.exe'
$before=if(Test-Path -LiteralPath $candidate){[ordered]@{exists=$true;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash;length=(Get-Item -LiteralPath $candidate).Length;last_write_utc=(Get-Item -LiteralPath $candidate).LastWriteTimeUtc.ToString('o')}}else{[ordered]@{exists=$false}}
[IO.File]::WriteAllText((Join-Path $Evidence 'candidate-output-before.json'),(($before|ConvertTo-Json)+"`n"),[Text.UTF8Encoding]::new($false))

function Invoke-Clean([string[]]$Arguments,[string]$Name) {
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$cmake;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.Environment.Clear();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){
    if($entry.Key -ieq 'Path' -or $entry.Key -like 'GIT_CONFIG_*' -or $entry.Key -eq 'CL'){continue}
    if($seen.Add([string]$entry.Key)){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
  }
  $psi.Environment['Path']=$env:Path;$psi.Environment['CL']='/MP2';$psi.Environment['CMAKE_BUILD_PARALLEL_LEVEL']='2'
  $psi.Environment['GIT_CONFIG_COUNT']='1';$psi.Environment['GIT_CONFIG_KEY_0']='safe.directory';$psi.Environment['GIT_CONFIG_VALUE_0']=$Source.Replace('\','/')
  foreach($a in $Arguments){[void]$psi.ArgumentList.Add($a)}
  $p=[Diagnostics.Process]::Start($psi);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
  $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$exit=$p.ExitCode;$p.Dispose()
  [IO.File]::WriteAllText((Join-Path $Evidence "$Name.stdout.log"),$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $Evidence "$Name.stderr.log"),$stderr,[Text.UTF8Encoding]::new($false))
  if($stdout){[Console]::Out.Write($stdout)};if($stderr){[Console]::Error.Write($stderr)}
  if($exit-ne0){throw "$Name failed exit=$exit"}
}

$configure=@(
  '-S',$Source,'-B',$Build,'-G','Visual Studio 17 2022','-A','x64',
  '-DCMAKE_INSTALL_PREFIX=C:/TW/rndbot-roster-phase-b-r2-20260831-131938/install-clean-unused',
  '-DACE_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows','-DBOOST_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
  '-DALLOW_TURTLE_ADDONS=ON','-DBUILD_PLAYERBOTS=ON','-DBUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=OFF','-DMODULES=disabled',
  '-DUSE_ADDRESS_SANITIZER=OFF','-DUSE_ANTICHEAT=ON','-DUSE_DISCORD_BOT=OFF','-DUSE_EXTRACTORS=ON',
  '-DUSE_LIBCURL=OFF','-DUSE_PCH=ON','-DUSE_PCH_OLD=ON','-DUSE_REALMMERGE=OFF','-DUSE_SCRIPTS=ON',
  '-DUSE_STD_MALLOC=ON','-DUSE_TRACY=OFF'
)
Invoke-Clean $configure 'configure'
Invoke-Clean @('--build',$Build,'--config','Release','--target','mangosd','--parallel','2') 'build'
if(-not(Test-Path -LiteralPath $candidate)){throw 'Clean candidate mangosd.exe missing.'}
$pdb=Join-Path $Source 'bin\Release\mangosd.pdb'
$cache=Join-Path $Build 'CMakeCache.txt'
$result=[ordered]@{result='PASS';captured_utc=[DateTime]::UtcNow.ToString('o');source=$Source;build=$Build;candidate_exe=$candidate;candidate_exe_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash;candidate_exe_size=(Get-Item -LiteralPath $candidate).Length;candidate_exe_last_write_utc=(Get-Item -LiteralPath $candidate).LastWriteTimeUtc.ToString('o');candidate_pdb=$pdb;candidate_pdb_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $pdb).Hash;candidate_pdb_size=(Get-Item -LiteralPath $pdb).Length;cmake_cache_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $cache).Hash;candidate_started=$false;deployment_performed=$false}
[IO.File]::WriteAllText((Join-Path $Evidence 'clean-build-result.json'),(($result|ConvertTo-Json -Depth 5)+"`n"),[Text.UTF8Encoding]::new($false))
Write-Output 'CLEAN_BUILD_RESULT=PASS'
Write-Output "CANDIDATE_EXE_SHA256=$($result.candidate_exe_sha256)"
Write-Output "CANDIDATE_PDB_SHA256=$($result.candidate_pdb_sha256)"
