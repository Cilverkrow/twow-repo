param(
    [string]$Source = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source',
    [string]$Build = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\build-adapter',
    [string]$Evidence = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938\evidence',
    [switch]$ResumeExisting
)
$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
if((Test-Path -LiteralPath $Build) -and -not $ResumeExisting){throw "Build directory already exists: $Build"}
[void](New-Item -ItemType Directory -Path $Evidence -Force)

function Invoke-Clean([string[]]$Arguments,[string]$Name) {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$cmake;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Environment.Clear()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if($entry.Key -ieq 'Path' -or $entry.Key -eq 'CL'){continue}
        if($seen.Add([string]$entry.Key)){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    }
    $psi.Environment['Path']=$env:Path
    $psi.Environment['CL']='/MP2'
    foreach($argument in $Arguments){[void]$psi.ArgumentList.Add($argument)}
    $p=[Diagnostics.Process]::Start($psi)
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
    $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$exit=$p.ExitCode;$p.Dispose()
    [IO.File]::WriteAllText((Join-Path $Evidence "$Name.stdout.log"),$stdout,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Evidence "$Name.stderr.log"),$stderr,[Text.UTF8Encoding]::new($false))
    if($stdout){[Console]::Out.Write($stdout)};if($stderr){[Console]::Error.Write($stderr)}
    if($exit-ne0){throw "$Name failed exit=$exit"}
}

$configure=@(
    '-S',$Source,'-B',$Build,'-G','Visual Studio 17 2022','-A','x64',
    '-DCMAKE_INSTALL_PREFIX=C:/TW/rndbot-roster-phase-b-r2-20260831-131938/install-unused',
    '-DACE_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
    '-DBOOST_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
    '-DALLOW_TURTLE_ADDONS=ON','-DBUILD_PLAYERBOTS=ON','-DBUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=ON','-DMODULES=disabled',
    '-DUSE_ADDRESS_SANITIZER=OFF','-DUSE_ANTICHEAT=ON','-DUSE_DISCORD_BOT=OFF','-DUSE_EXTRACTORS=ON',
    '-DUSE_LIBCURL=OFF','-DUSE_PCH=ON','-DUSE_PCH_OLD=ON','-DUSE_REALMMERGE=OFF','-DUSE_SCRIPTS=ON',
    '-DUSE_STD_MALLOC=ON','-DUSE_TRACY=OFF'
)
if(-not $ResumeExisting){Invoke-Clean $configure 'adapter-configure'}
Invoke-Clean @('--build',$Build,'--config','Release','--target','persistent_active_roster_database_tests','--parallel','2') 'adapter-build'
$exe=Join-Path $Build 'adapter-bin\Release\persistent_active_roster_database_tests.exe'
if(-not(Test-Path -LiteralPath $exe)){throw "Adapter executable missing: $exe"}
Write-Output "REAL_ADAPTER_BUILD=PASS"
Write-Output "REAL_ADAPTER_EXE=$exe"
