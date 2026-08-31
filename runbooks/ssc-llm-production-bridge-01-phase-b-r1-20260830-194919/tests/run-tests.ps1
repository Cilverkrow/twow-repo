param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [string]$BuildDirectory = (Join-Path $PSScriptRoot 'build'),
    [string]$Configuration = 'Release'
)

$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
if(-not(Test-Path -LiteralPath $cmake)){throw 'CMake executable not found'}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
if(-not(Test-Path -LiteralPath (Join-Path $source 'src\shared\json.hpp'))){throw 'Invalid isolated source root'}
$buildFull=[IO.Path]::GetFullPath($BuildDirectory)
[void](New-Item -ItemType Directory -Path $buildFull -Force)

function Invoke-CleanProcess([string]$File,[string[]]$Arguments,[hashtable]$Overrides=@{}) {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$File
    $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.Environment.Clear()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if($entry.Key -ieq 'Path'){continue}
        if($seen.Add([string]$entry.Key)){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    }
    $psi.Environment['Path']=$env:Path
    foreach($entry in $Overrides.GetEnumerator()){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    foreach($argument in $Arguments){[void]$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
    if($out){[Console]::Out.Write($out)}
    if($err){[Console]::Error.Write($err)}
    $exit=$process.ExitCode;$process.Dispose()
    if($exit-ne0){throw "Process failed with exit code ${exit}: $File"}
}

$fixture=Join-Path $buildFull 'package-fixtures'
$fixtureFull=[IO.Path]::GetFullPath($fixture)
$expectedPrefix=$buildFull.TrimEnd('\')+'\'
if(-not$fixtureFull.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'}
if(Test-Path -LiteralPath $fixtureFull){Remove-Item -LiteralPath $fixtureFull -Recurse -Force}
$safe=Join-Path $fixtureFull 'safe'
$bridge=Join-Path $safe 'bridge'
foreach($directory in @((Join-Path $bridge 'config'),(Join-Path $bridge 'context'),(Join-Path $bridge 'src'))){[void](New-Item -ItemType Directory -Path $directory -Force)}
[IO.File]::WriteAllText((Join-Path $bridge 'config\bridge-config-v1.json'),"{`"fixture`":1}`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bridge 'context\personality-context-profile-v1.json'),"{`"fixture`":2}`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bridge 'src\cli.mjs'),"// fake child payload`n",[Text.UTF8Encoding]::new($false))
$manifestLines=@()
foreach($relative in @('config/bridge-config-v1.json','context/personality-context-profile-v1.json','src/cli.mjs')) {
    $native=$relative.Replace('/','\')
    $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $bridge $native)).Hash
    $manifestLines += "$hash *$relative"
}
[IO.File]::WriteAllText((Join-Path $bridge 'sha256-manifest.txt'),($manifestLines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
$rootJunction=Join-Path $fixtureFull 'root-junction'
[void](New-Item -ItemType Junction -Path $rootJunction -Target $safe)
$bridgeJunctionRoot=Join-Path $fixtureFull 'bridge-junction-root'
[void](New-Item -ItemType Directory -Path $bridgeJunctionRoot)
[void](New-Item -ItemType Junction -Path (Join-Path $bridgeJunctionRoot 'bridge') -Target $bridge)
$payloadJunctionRoot=Join-Path $fixtureFull 'payload-junction-root'
$payloadBridge=Join-Path $payloadJunctionRoot 'bridge'
foreach($directory in @($payloadBridge,(Join-Path $payloadBridge 'context'),(Join-Path $payloadBridge 'src'))){[void](New-Item -ItemType Directory -Path $directory -Force)}
Copy-Item -LiteralPath (Join-Path $bridge 'sha256-manifest.txt') -Destination (Join-Path $payloadBridge 'sha256-manifest.txt')
Copy-Item -LiteralPath (Join-Path $bridge 'context\personality-context-profile-v1.json') -Destination (Join-Path $payloadBridge 'context\personality-context-profile-v1.json')
Copy-Item -LiteralPath (Join-Path $bridge 'src\cli.mjs') -Destination (Join-Path $payloadBridge 'src\cli.mjs')
[void](New-Item -ItemType Junction -Path (Join-Path $payloadBridge 'config') -Target (Join-Path $bridge 'config'))

Invoke-CleanProcess $cmake @('-S',$PSScriptRoot,'-B',$buildFull,'-G','Visual Studio 17 2022','-A','x64',"-DSSC_SOURCE_ROOT=$($source.Replace('\','/'))")
Invoke-CleanProcess $cmake @('--build',$buildFull,'--config',$Configuration,'--target','external_llm_bridge_tests','--parallel','2')
$runner=Join-Path $buildFull "$Configuration\external_llm_bridge_tests.exe"
Invoke-CleanProcess $runner @() @{
    SSC_R1_SAFE_PACKAGE=$safe
    SSC_R1_ROOT_JUNCTION_PACKAGE=$rootJunction
    SSC_R1_BRIDGE_JUNCTION_PACKAGE=$bridgeJunctionRoot
    SSC_R1_PAYLOAD_JUNCTION_PACKAGE=$payloadJunctionRoot
}
