$ErrorActionPreference = 'Stop'

$runbook = Split-Path -Parent $MyInvocation.MyCommand.Path
$evidence = Join-Path $runbook 'evidence'
$source = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source'
$build = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\build-clean-final'
$cmake = 'C:\Program Files\CMake\bin\cmake.exe'
$mariadbd = 'C:\TW\ComTW\DB\bin\mariadbd.exe'
$mysql = 'C:\TW\ComTW\DB\bin\mysql.exe'

function Invoke-Version([string] $Exe, [string[]] $Arguments) {
    $output = @(& $Exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Version command failed: $Exe" }
    return ($output -join "`n")
}

$cacheOptions = @()
Get-Content -LiteralPath (Join-Path $build 'CMakeCache.txt') | ForEach-Object {
    if ($_ -match '^(BUILD_[A-Za-z0-9_]+|CMAKE_BUILD_TYPE|CMAKE_CONFIGURATION_TYPES|CMAKE_GENERATOR|CMAKE_GENERATOR_PLATFORM|CMAKE_PREFIX_PATH|DEBUG|PCH|BUILD_EXTRACTORS|BUILD_PLAYERBOTS):([^=]+)=(.*)$') {
        $cacheOptions += [pscustomobject]@{ name = $Matches[1]; type = $Matches[2]; value = $Matches[3] }
    }
}

$clOutput = @(& cmd.exe /d /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul && cl.exe 2>&1')
$clVersion = ($clOutput | Select-Object -First 3) -join "`n"

$result = [ordered]@{
    captured_utc = [DateTime]::UtcNow.ToString('o')
    cmake = Invoke-Version $cmake @('--version')
    git = Invoke-Version 'git.exe' @('--version')
    mariadbd = Invoke-Version $mariadbd @('--no-defaults','--version')
    mysql_client = Invoke-Version $mysql @('--version')
    msvc = $clVersion
    windows_sdk_selected = '10.0.26100.0'
    windows_target_reported_by_cmake = '10.0.26200'
    generator = 'Visual Studio 17 2022'
    architecture = 'x64'
    cmake_cache = [ordered]@{
        path = (Join-Path $build 'CMakeCache.txt')
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $build 'CMakeCache.txt')).Hash
        options = $cacheOptions
    }
    dependencies = [ordered]@{
        vcpkg_prefix = 'C:/TW/ComTW/vcpkg/installed/x64-windows'
        boost = '1.92.0'
        mysql_library = 'C:/TW/ComTW/DB/lib/libmariadb.lib'
    }
    build_contract = [ordered]@{
        configuration = 'Release'
        target = 'mangosd'
        build_playerbots = 'ON'
        build_persistent_roster_adapter_tests = 'OFF'
        candidate_started = $false
    }
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'toolchain-and-build-options.json') -Encoding utf8
$cacheOptions | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation | Set-Content -LiteralPath (Join-Path $evidence 'cmake-options.tsv') -Encoding utf8
Write-Output 'TOOLCHAIN_EVIDENCE=CAPTURED'
Write-Output "CMAKE_CACHE_SHA256=$($result.cmake_cache.sha256)"
