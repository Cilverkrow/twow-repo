param(
    [string]$Runbook = 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-r1-20260830-194919',
    [string]$Source = 'C:\TW\ssc-llm-phase-b-20260830-173121\source',
    [string]$Build = 'C:\TW\ssc-llm-phase-b-20260830-173121\build-r1-clean-final2',
    [string]$Tests = 'C:\TW\ssc-llm-phase-b-20260830-173121\r1-tests'
)

$ErrorActionPreference = 'Stop'
$candidate = '42b8a7f742548793910fe8880463aeeb71627fb9'
$tree = 'b2cf4e38fd288a53f61b9f2350f74caa85d606ab'
$candidateHash = '1231B38B3EA8C241742B3735C13515DA0A0A98158F3ADE96FDBB7EA0AFB3718C'
$productionExeHash = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$mangosdConfigHash = 'C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D'
$playerbotConfigHash = '490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF'
$previousZipHash = '510C3E365C959DAD8ACCE30A5DA29D5C6F0B6D268D9AD5DCC8E7A82FF99BE365'
$exe = Join-Path $Source 'bin\Release\mangosd.exe'
$pdb = Join-Path $Source 'bin\Release\mangosd.pdb'
$cache = Join-Path $Build 'CMakeCache.txt'
$evidence = Join-Path $Runbook 'evidence'
$artifacts = Join-Path $Runbook 'artifacts'
$copies = Join-Path $Runbook 'source-copies'
$testCopies = Join-Path $Runbook 'tests'

$plannedFiles = @(
    'src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp',
    'src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h',
    'src/modules/PlayerBots/playerbot/PlayerbotAI.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotAI.h',
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h',
    'src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp',
    'src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in',
    'src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp'
)

function Invoke-Captured([string]$File, [string[]]$Arguments, [string]$WorkingDirectory) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $File
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $record = [ordered]@{
        exit_code = $process.ExitCode
        stdout = $outTask.GetAwaiter().GetResult().TrimEnd()
        stderr = $errTask.GetAwaiter().GetResult().TrimEnd()
    }
    $process.Dispose()
    return $record
}

function Git([string]$Root, [string[]]$Arguments, [switch]$AllowDiffExitOne) {
    $safe = $Root.Replace('\','/')
    $result = Invoke-Captured 'git.exe' (@('-c', "safe.directory=$safe", '-C', $Root) + $Arguments) $Root
    if ($result.exit_code -ne 0 -and -not ($AllowDiffExitOne -and $result.exit_code -eq 1)) {
        throw "git failed: $($Arguments -join ' ')`n$($result.stderr)"
    }
    return $result
}

function FileRecord([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        size = [int64]$item.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        created_utc = $item.CreationTimeUtc.ToString('o')
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        file_version = $item.VersionInfo.FileVersion
        product_version = $item.VersionInfo.ProductVersion
    }
}

function Read-U16($reader, [int64]$offset) { $reader.BaseStream.Position = $offset; $reader.ReadUInt16() }
function Read-U32($reader, [int64]$offset) { $reader.BaseStream.Position = $offset; $reader.ReadUInt32() }
function Read-U64($reader, [int64]$offset) { $reader.BaseStream.Position = $offset; $reader.ReadUInt64() }

function PeRecord([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ((Read-U16 $reader 0) -ne 0x5A4D) { throw 'Missing MZ signature' }
        $pe = Read-U32 $reader 0x3c
        if ((Read-U32 $reader $pe) -ne 0x4550) { throw 'Missing PE signature' }
        $coff = $pe + 4
        $sectionsCount = Read-U16 $reader ($coff + 2)
        $stamp = Read-U32 $reader ($coff + 4)
        $optionalSize = Read-U16 $reader ($coff + 16)
        $optional = $coff + 20
        $magic = Read-U16 $reader $optional
        $is64 = $magic -eq 0x20b
        $directory = $optional + $(if ($is64) { 112 } else { 96 })
        $debugRva = Read-U32 $reader ($directory + 48)
        $debugSize = Read-U32 $reader ($directory + 52)
        $sectionTable = $optional + $optionalSize
        $sections = @()
        for ($i = 0; $i -lt $sectionsCount; $i++) {
            $offset = $sectionTable + 40 * $i
            $reader.BaseStream.Position = $offset
            $sections += [pscustomobject]@{
                name = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)).Trim([char]0)
                virtual_size = Read-U32 $reader ($offset + 8)
                virtual_address = Read-U32 $reader ($offset + 12)
                raw_size = Read-U32 $reader ($offset + 16)
                raw_pointer = Read-U32 $reader ($offset + 20)
            }
        }
        $debugOffset = $null
        foreach ($section in $sections) {
            $extent = [math]::Max([uint64]$section.virtual_size, [uint64]$section.raw_size)
            if ($debugRva -ge $section.virtual_address -and $debugRva -lt ([uint64]$section.virtual_address + $extent)) {
                $debugOffset = [uint64]$section.raw_pointer + ([uint64]$debugRva - [uint64]$section.virtual_address)
                break
            }
        }
        $codeView = @()
        if ($null -ne $debugOffset) {
            for ($i = 0; $i -lt [math]::Floor($debugSize / 28); $i++) {
                $entry = $debugOffset + 28 * $i
                if ((Read-U32 $reader ($entry + 12)) -ne 2) { continue }
                $size = Read-U32 $reader ($entry + 16)
                $raw = Read-U32 $reader ($entry + 24)
                $reader.BaseStream.Position = $raw
                $signature = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
                if ($signature -ne 'RSDS') { continue }
                $guid = [Guid]::new($reader.ReadBytes(16))
                $age = $reader.ReadUInt32()
                $bytes = [Collections.Generic.List[byte]]::new()
                while ($reader.BaseStream.Position -lt $reader.BaseStream.Length) {
                    $byte = $reader.ReadByte()
                    if ($byte -eq 0) { break }
                    $bytes.Add($byte)
                }
                $codeView += [pscustomobject]@{
                    signature = $signature
                    guid = $guid.ToString('D').ToUpperInvariant()
                    age = $age
                    pdb_path = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
                    size = $size
                }
            }
        }
        return [ordered]@{
            machine = ('0x{0:X4}' -f (Read-U16 $reader $coff))
            linker_timestamp_unix = $stamp
            linker_timestamp_utc = [DateTimeOffset]::FromUnixTimeSeconds($stamp).UtcDateTime.ToString('o')
            pe32_plus = $is64
            image_base = ('0x{0:X16}' -f (Read-U64 $reader ($optional + 24)))
            size_of_image = Read-U32 $reader ($optional + 56)
            codeview = $codeView
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-Equal([object]$Left, [object]$Right, [string]$Name) {
    if ($Left -ne $Right) { throw "$Name mismatch: '$Left' != '$Right'" }
}

foreach ($required in @($exe, $pdb, $cache, (Join-Path $evidence 'production-before.json'),
        (Join-Path $evidence 'production-after.json'), (Join-Path $Runbook 'logs\fake-child-tests.tap'),
        (Join-Path $Runbook 'logs\fake-child-tests-reproducibility.tap'), (Join-Path $Runbook 'logs\static-gate.log'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing evidence input: $required" }
}

$head = (Git $Source @('rev-parse','HEAD')).stdout.Trim()
$actualTree = (Git $Source @('rev-parse','HEAD^{tree}')).stdout.Trim()
Assert-Equal $head $candidate 'candidate commit'
Assert-Equal $actualTree $tree 'candidate tree'
$symbolic = Git $Source @('symbolic-ref','-q','HEAD') -AllowDiffExitOne
$status = (Git $Source @('status','--short','--untracked-files=all')).stdout
$changed = @($status -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Substring(3).Replace('\','/') } |
    Where-Object { $_ -notlike 'bin/*' } | Sort-Object -Unique)
if (@(Compare-Object ($plannedFiles | Sort-Object) $changed).Count -ne 0) {
    throw "Unexpected isolated production file set: $($changed -join ', ')"
}

$before = Get-Content -Raw -LiteralPath (Join-Path $evidence 'production-before.json') | ConvertFrom-Json -Depth 20
$after = Get-Content -Raw -LiteralPath (Join-Path $evidence 'production-after.json') | ConvertFrom-Json -Depth 20
$statusIdentical = (($before.repository.status_lines -join "`n") -ceq ($after.repository.status_lines -join "`n"))
$beforeMap = @{}
foreach ($entry in $before.repository.dirty_files) { $beforeMap[$entry.relative_path] = $entry }
$dirtyComparisons = @()
foreach ($entry in $after.repository.dirty_files) {
    $prior = $beforeMap[$entry.relative_path]
    $same = $null -ne $prior -and $prior.status -ceq $entry.status -and
        [int64]$prior.file.size -eq [int64]$entry.file.size -and $prior.file.sha256 -ceq $entry.file.sha256
    $dirtyComparisons += [pscustomobject]@{
        relative_path = $entry.relative_path
        before_status = $prior.status
        after_status = $entry.status
        before_size = $prior.file.size
        after_size = $entry.file.size
        before_sha256 = $prior.file.sha256
        after_sha256 = $entry.file.sha256
        byte_identical = $same
    }
}
$dirtySetIdentical = $statusIdentical -and $before.repository.dirty_files.Count -eq $after.repository.dirty_files.Count -and
    @($dirtyComparisons | Where-Object { -not $_.byte_identical }).Count -eq 0
$protectedComparisons = [ordered]@{}
foreach ($name in @('production_exe','mangosd_config','playerbot_config','previous_phase_b_zip')) {
    $old = $before.protected_artifacts.$name
    $new = $after.protected_artifacts.$name
    $protectedComparisons[$name] = [ordered]@{
        before_size = $old.size
        after_size = $new.size
        before_sha256 = $old.sha256
        after_sha256 = $new.sha256
        byte_identical = ([int64]$old.size -eq [int64]$new.size -and $old.sha256 -ceq $new.sha256)
    }
}
$productionIdentical = $dirtySetIdentical -and @($protectedComparisons.Values | Where-Object { -not $_.byte_identical }).Count -eq 0
if (-not $productionIdentical) { throw 'Production before/after byte comparison failed' }
Assert-Equal $after.protected_artifacts.production_exe.sha256 $productionExeHash 'production EXE hash'
Assert-Equal $after.protected_artifacts.mangosd_config.sha256 $mangosdConfigHash 'mangosd.conf hash'
Assert-Equal $after.protected_artifacts.playerbot_config.sha256 $playerbotConfigHash 'aiplayerbot.conf hash'
Assert-Equal $after.protected_artifacts.previous_phase_b_zip.sha256 $previousZipHash 'previous Phase-B ZIP hash'

$comparison = [ordered]@{
    schema_version = 1
    before_captured_utc = $before.captured_utc
    after_captured_utc = $after.captured_utc
    live_inventories_used = $true
    status_identical = $statusIdentical
    dirty_file_set_and_bytes_identical = $dirtySetIdentical
    dirty_files = $dirtyComparisons
    protected_artifacts = $protectedComparisons
    production_source_byte_identical = $productionIdentical
}
[IO.File]::WriteAllText((Join-Path $evidence 'production-byte-comparison.json'), ($comparison | ConvertTo-Json -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))

$trackedDiff = (Git $Source @('diff','--binary','HEAD','--')).stdout
$fullDiff = $trackedDiff + $(if ($trackedDiff) { "`n" } else { '' })
foreach ($newFile in @('src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp','src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h')) {
    $entry = Git $Source @('diff','--no-index','--binary','--','NUL',$newFile) -AllowDiffExitOne
    if ($entry.exit_code -ne 1) { throw "Unable to create new-file diff: $newFile" }
    $fullDiff += $entry.stdout + "`n"
}
[IO.File]::WriteAllText((Join-Path $evidence 'full-git-diff.patch'), $fullDiff, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $evidence 'isolated-status-after.txt'), $status + "`n", [Text.UTF8Encoding]::new($false))

foreach ($relative in $plannedFiles) {
    $destination = Join-Path $copies $relative
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination))
    Copy-Item -LiteralPath (Join-Path $Source $relative) -Destination $destination -Force
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Source $relative)).Hash `
        (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash "source copy $relative"
}
foreach ($name in @('CMakeLists.txt','external_llm_bridge_tests.cpp','run-tests.ps1','static-forbidden-paths.ps1')) {
    Copy-Item -LiteralPath (Join-Path $Tests $name) -Destination (Join-Path $testCopies $name) -Force
}
Copy-Item -LiteralPath $cache -Destination (Join-Path $evidence 'CMakeCache.txt') -Force
Copy-Item -LiteralPath $exe -Destination (Join-Path $artifacts 'mangosd.exe') -Force
Copy-Item -LiteralPath 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r2-20260830-170407\bridge-contract-v1.json' `
    -Destination (Join-Path $Runbook 'bridge-contract-v1.json') -Force
Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash $candidateHash 'candidate EXE hash'
Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $artifacts 'mangosd.exe')).Hash $candidateHash 'packaged candidate EXE hash'

$buildLog = Join-Path $Runbook 'logs\build.stdout.log'
$diagnostics = @(Select-String -LiteralPath $buildLog -Pattern '(?i)warning (C|LNK)[0-9]+|CMake Warning|error (C|LNK)[0-9]+|fatal error|: error ' | ForEach-Object { $_.Line })
$finalErrors = @($diagnostics | Where-Object { $_ -match '(?i)error (C|LNK)[0-9]+|fatal error|: error ' })
[IO.File]::WriteAllLines((Join-Path $evidence 'final-build-diagnostics.txt'), $diagnostics, [Text.UTF8Encoding]::new($false))
if ($finalErrors.Count -ne 0) { throw 'Final build log contains an error diagnostic' }

$tap = Get-Content -Raw -LiteralPath (Join-Path $Runbook 'logs\fake-child-tests.tap')
$tapRepro = Get-Content -Raw -LiteralPath (Join-Path $Runbook 'logs\fake-child-tests-reproducibility.tap')
$testsPass = $tap -match '(?m)^1\.\.683\r?$' -and $tap -match '(?m)^# failures=0\r?$' -and $tap -notmatch '(?m)^not ok '
$testsReproPass = $tapRepro -match '(?m)^1\.\.683\r?$' -and $tapRepro -match '(?m)^# failures=0\r?$' -and $tapRepro -notmatch '(?m)^not ok '
if (-not $testsPass -or -not $testsReproPass) { throw 'Final or reproducibility test evidence failed' }
$staticGate = Get-Content -Raw -LiteralPath (Join-Path $Runbook 'logs\static-gate.log') | ConvertFrom-Json -Depth 10
if (-not $staticGate.pass) { throw 'Static gate failed' }

$bytes = [IO.File]::ReadAllBytes($exe)
$latin = [Text.Encoding]::Latin1.GetString($bytes)
$unicode = [Text.Encoding]::Unicode.GetString($bytes)
$revisionPresent = $latin.Contains('42b8a7f742548793910f') -or $unicode.Contains('42b8a7f742548793910f')
$noopPresent = $latin.Contains('LLM generation disabled in this build') -or $unicode.Contains('LLM generation disabled in this build')
if (-not $revisionPresent -or -not $noopPresent) { throw 'Embedded revision or Release no-op marker missing' }

$options = [ordered]@{
    generator = 'Visual Studio 17 2022'
    architecture = 'x64'
    configuration = 'Release'
    target = 'mangosd only'
    cmake = '4.4.2'
    msvc = '19.44.35228; tools 14.44.35207'
    windows_sdk = '10.0.26100.0'
    parallel_projects = 2
    cl_mp_count = 2
    cache_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $cache).Hash
    configure_definitions = @(
        'CMAKE_INSTALL_PREFIX=C:/TW/ssc-llm-phase-b-20260830-173121/install-r1-clean-final2',
        'CMAKE_BUILD_TYPE=Release','ACE_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows',
        'BOOST_ROOT=C:/TW/ComTW/vcpkg/installed/x64-windows','ALLOW_TURTLE_ADDONS=ON','BUILD_PLAYERBOTS=ON',
        'MODULES=disabled','USE_ADDRESS_SANITIZER=OFF','USE_ANTICHEAT=ON','USE_DISCORD_BOT=OFF',
        'USE_EXTRACTORS=ON','USE_LIBCURL=OFF','USE_PCH=ON','USE_PCH_OLD=ON','USE_REALMMERGE=OFF',
        'USE_SCRIPTS=ON','USE_STD_MALLOC=ON','USE_TRACY=OFF'
    )
}
[IO.File]::WriteAllText((Join-Path $evidence 'build-options.json'), ($options | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))

$record = [ordered]@{
    schema_version = 1
    task = 'SSC-LLM-PRODUCTION-BRIDGE-01-PHASE-B-R1'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    baseline = [ordered]@{
        commit = $head
        tree = $actualTree
        detached = ($symbolic.exit_code -ne 0)
        gitmodules_present = (Test-Path -LiteralPath (Join-Path $Source '.gitmodules') -PathType Leaf)
        submodules = @()
    }
    scope = [ordered]@{
        isolated_source = $Source
        planned_production_files = $plannedFiles
        unplanned_production_files = @()
        isolated_status = @($status -split "`r?`n" | Where-Object { $_ })
    }
    tests = [ordered]@{
        final = [ordered]@{ passed = $testsPass; count = 683; log = FileRecord (Join-Path $Runbook 'logs\fake-child-tests.tap') }
        reproducibility = [ordered]@{ passed = $testsReproPass; count = 683; log = FileRecord (Join-Path $Runbook 'logs\fake-child-tests-reproducibility.tap') }
        static_gate = [ordered]@{ passed = [bool]$staticGate.pass; log = FileRecord (Join-Path $Runbook 'logs\static-gate.log'); checks = $staticGate.checks }
    }
    build = [ordered]@{
        result = 'PASS'
        final_directory = $Build
        first_configure_attempt = [ordered]@{ result = 'FAIL'; build_started = $false; reason = 'Legacy PREFIX definition collided with CMake 4.4 compiler-ID macro template; no candidate was produced'; stdout = FileRecord (Join-Path $Runbook 'logs\configure-attempt1.stdout.log'); stderr = FileRecord (Join-Path $Runbook 'logs\configure-attempt1.stderr.log') }
        successful_configure = [ordered]@{ stdout = FileRecord (Join-Path $Runbook 'logs\configure.stdout.log'); stderr = FileRecord (Join-Path $Runbook 'logs\configure.stderr.log') }
        successful_build = [ordered]@{ stdout = FileRecord (Join-Path $Runbook 'logs\build.stdout.log'); stderr = FileRecord (Join-Path $Runbook 'logs\build.stderr.log'); warning_diagnostic_count = $diagnostics.Count; error_diagnostic_count = $finalErrors.Count }
        options = $options
    }
    artifacts = [ordered]@{
        executable = FileRecord $exe
        packaged_executable = FileRecord (Join-Path $artifacts 'mangosd.exe')
        pdb = FileRecord $pdb
        pe = PeRecord $exe
        embedded_revision_present = $revisionPresent
        embedded_release_noop_present = $noopPresent
    }
    production = [ordered]@{
        before = FileRecord (Join-Path $evidence 'production-before.json')
        after = FileRecord (Join-Path $evidence 'production-after.json')
        comparison = $comparison
    }
    review_inputs = $before.review_inputs
    previous_phase_b_zip = $after.protected_artifacts.previous_phase_b_zip
    prohibitions = [ordered]@{
        real_bridge_started = $false
        ollama_accessed = $false
        inference_performed = $false
        game_chat_sent = $false
        database_accessed = $false
        deployment_performed = $false
        phase_c_started = $false
        active_config_changed = $false
        production_exe_changed = $false
        candidate_exe_started = $false
    }
}
[IO.File]::WriteAllText((Join-Path $evidence 'final-evidence.json'), ($record | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
$record | ConvertTo-Json -Depth 5
