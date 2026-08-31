param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [string]$BuildDirectory = (Join-Path $PSScriptRoot 'build'),
    [string]$Configuration = 'Release'
)

$ErrorActionPreference='Stop'
$cmake='C:\Program Files\CMake\bin\cmake.exe'
if(-not(Test-Path -LiteralPath $cmake)){throw 'CMake 4.4.2 executable not found'}
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
if(-not(Test-Path -LiteralPath (Join-Path $source 'src\shared\json.hpp'))){throw 'Invalid isolated source root'}

& $cmake -S $PSScriptRoot -B $BuildDirectory -G 'Visual Studio 17 2022' -A x64 "-DSSC_SOURCE_ROOT=$($source.Replace('\','/'))"
if($LASTEXITCODE-ne0){throw "Test configure failed: $LASTEXITCODE"}
& $cmake --build $BuildDirectory --config $Configuration --target external_llm_bridge_tests --parallel 2
if($LASTEXITCODE-ne0){throw "Test build failed: $LASTEXITCODE"}
$runner=Join-Path $BuildDirectory "$Configuration\external_llm_bridge_tests.exe"
& $runner
if($LASTEXITCODE-ne0){throw "Fake-child suite failed: $LASTEXITCODE"}

