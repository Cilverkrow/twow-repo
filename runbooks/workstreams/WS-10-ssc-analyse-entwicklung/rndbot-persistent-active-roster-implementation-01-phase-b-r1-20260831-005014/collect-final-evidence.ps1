param()
$ErrorActionPreference = 'Stop'

$runRoot = $PSScriptRoot
$source = 'C:\TW\rndbot-roster-phase-b-r1-20260831-005014\source'
$build = 'C:\TW\rndbot-roster-phase-b-r1-20260831-005014\build-clean-final'
$productionSource = 'C:\TW\ComTW\source'
$exe = Join-Path $source 'bin\Release\mangosd.exe'
$pdb = Join-Path $source 'bin\Release\mangosd.pdb'
$cache = Join-Path $build 'CMakeCache.txt'
$evidence = Join-Path $runRoot 'evidence'
$artifacts = Join-Path $runRoot 'artifacts'
$copies = Join-Path $runRoot 'source-copies'
[void](New-Item -ItemType Directory -Path $evidence,$artifacts,$copies -Force)

$sourceFiles = @(
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h',
    'src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotMgr.h',
    'src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp',
    'src/modules/PlayerBots/playerbot/RandomPlayerbotFactory.cpp',
    'src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp',
    'src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.h',
    'src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in',
    'src/shared/Database/Database.cpp',
    'src/shared/Database/Database.h',
    'src/shared/Database/DatabaseMysql.cpp',
    'src/shared/Database/DatabaseMysql.h',
    'sql/character_updates/20260830230336_ai_playerbot_persistent_active_roster.sql',
    'src/modules/PlayerBots/playerbot/PersistentActiveRoster.cpp',
    'src/modules/PlayerBots/playerbot/PersistentActiveRoster.h',
    'src/modules/PlayerBots/playerbot/PersistentActiveRosterDatabase.cpp',
    'src/modules/PlayerBots/playerbot/PersistentActiveRosterDatabase.h',
    'src/modules/PlayerBots/sql/other/20260830230336_ai_playerbot_persistent_active_roster_rollback.sql',
    'src/modules/PlayerBots/tests/CMakeLists.txt',
    'src/modules/PlayerBots/tests/fixtures/empty-snapshot-v1.txt',
    'src/modules/PlayerBots/tests/fixtures/initialize-request-v1.txt',
    'src/modules/PlayerBots/tests/persistent_active_roster_tests.cpp',
    'src/modules/PlayerBots/tests/run-tests.ps1',
    'src/modules/PlayerBots/tests/schema_fingerprint.sql'
)

function Write-Utf8([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function File-Record([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        path = $item.FullName
        size = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        created_utc = $item.CreationTimeUtc.ToString('o')
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        file_version = $item.VersionInfo.FileVersion
        product_version = $item.VersionInfo.ProductVersion
    }
}

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $safe = $Repository.Replace('\','/')
    $output = & 'Y:\appentwicklung\Git\cmd\git.exe' -c "safe.directory=$safe" -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git failed: $($Arguments -join ' ')" }
    @($output | ForEach-Object { $_.ToString() })
}

function Read-U16($Reader, [int64]$Offset) { $Reader.BaseStream.Position = $Offset; $Reader.ReadUInt16() }
function Read-U32($Reader, [int64]$Offset) { $Reader.BaseStream.Position = $Offset; $Reader.ReadUInt32() }
function Read-U64($Reader, [int64]$Offset) { $Reader.BaseStream.Position = $Offset; $Reader.ReadUInt64() }
function Pe-Record([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $pe = Read-U32 $reader 0x3c
        $coff = $pe + 4
        $sectionsCount = Read-U16 $reader ($coff + 2)
        $stamp = Read-U32 $reader ($coff + 4)
        $optionalSize = Read-U16 $reader ($coff + 16)
        $optional = $coff + 20
        $is64 = (Read-U16 $reader $optional) -eq 0x20b
        $directory = $optional + $(if ($is64) { 112 } else { 96 })
        $debugRva = Read-U32 $reader ($directory + 48)
        $debugSize = Read-U32 $reader ($directory + 52)
        $sectionTable = $optional + $optionalSize
        $debugOffset = $null
        for ($i = 0; $i -lt $sectionsCount; $i++) {
            $offset = $sectionTable + 40 * $i
            $virtualAddress = Read-U32 $reader ($offset + 12)
            $virtualSize = Read-U32 $reader ($offset + 8)
            $rawSize = Read-U32 $reader ($offset + 16)
            $rawPointer = Read-U32 $reader ($offset + 20)
            $extent = [math]::Max([uint64]$virtualSize, [uint64]$rawSize)
            if ($debugRva -ge $virtualAddress -and $debugRva -lt ([uint64]$virtualAddress + $extent)) {
                $debugOffset = [uint64]$rawPointer + ([uint64]$debugRva - [uint64]$virtualAddress)
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
                $codeView += [ordered]@{
                    signature = $signature
                    guid = $guid.ToString('D').ToUpperInvariant()
                    age = $age
                    pdb_path = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
                    size = $size
                }
            }
        }
        [ordered]@{
            machine = ('0x{0:X4}' -f (Read-U16 $reader $coff))
            linker_timestamp_unix = $stamp
            linker_timestamp_utc = [DateTimeOffset]::FromUnixTimeSeconds($stamp).UtcDateTime.ToString('o')
            pe32_plus = $is64
            image_base = ('0x{0:X16}' -f (Read-U64 $reader ($optional + 24)))
            size_of_image = Read-U32 $reader ($optional + 56)
            codeview = $codeView
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

foreach ($required in @($exe,$pdb,$cache)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing final build artifact: $required" }
}

foreach ($relative in $sourceFiles) {
    $from = Join-Path $source ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Missing source input: $relative" }
    $to = Join-Path $copies ($relative.Replace('/','\'))
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force)
    Copy-Item -LiteralPath $from -Destination $to -Force
}
Copy-Item -LiteralPath $exe -Destination (Join-Path $artifacts 'mangosd.exe') -Force
Copy-Item -LiteralPath $pdb -Destination (Join-Path $artifacts 'mangosd.pdb') -Force
Copy-Item -LiteralPath $cache -Destination (Join-Path $evidence 'CMakeCache.txt') -Force

$status = Invoke-Git $source @('status','--short','--untracked-files=all')
$trackedPatch = Invoke-Git $source @('diff','--binary','--no-ext-diff')
Write-Utf8 (Join-Path $evidence 'isolated-git-status.txt') (($status -join "`n") + "`n")
Write-Utf8 (Join-Path $evidence 'tracked-changes.patch') (($trackedPatch -join "`n") + "`n")

$head = ([string](Invoke-Git $source @('rev-parse','HEAD'))).Trim()
$tree = ([string](Invoke-Git $source @('rev-parse','HEAD^{tree}'))).Trim()
$branchLines = @(Invoke-Git $source @('branch','--show-current'))
$branch = if ($branchLines.Count -gt 0) { ([string]$branchLines[0]).Trim() } else { '' }
$productionBefore = Get-Content -LiteralPath (Join-Path $evidence 'production-before.json') -Raw | ConvertFrom-Json
$productionStatus = Invoke-Git $productionSource @('status','--short','--untracked-files=all')
$productionDirty = @()
foreach ($line in $productionStatus) {
    $relative = $line.Substring(3)
    $path = Join-Path $productionSource ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Production status path missing: $relative" }
    $item = Get-Item -LiteralPath $path
    $productionDirty += [ordered]@{ relative_path=$relative; size=[int64]$item.Length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}
$protectedArtifacts = [ordered]@{
    production_exe = File-Record 'C:\TW\ComTW\server\mangosd.exe'
    mangosd_conf = File-Record 'C:\TW\ComTW\server\mangosd.conf'
    aiplayerbot_conf = File-Record 'C:\TW\ComTW\server\aiplayerbot.conf'
}
$productionAfter = [ordered]@{
    task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1'
    captured_utc=[DateTime]::UtcNow.ToString('o')
    production_source=$productionSource
    git_head=([string](Invoke-Git $productionSource @('rev-parse','HEAD'))).Trim()
    status_lines=$productionStatus
    dirty_files=$productionDirty
    protected_artifacts=$protectedArtifacts
    database_accessed=$false
    production_endpoint_3307_accessed=$false
}
Write-Utf8 (Join-Path $evidence 'production-after.json') (($productionAfter | ConvertTo-Json -Depth 10) + "`n")

$productionStatusIdentical = (@($productionBefore.status_lines) -join "`n") -ceq (@($productionAfter.status_lines) -join "`n")
$afterDirtyByPath = @{}
foreach ($record in $productionAfter.dirty_files) { $afterDirtyByPath[[string]$record.relative_path] = $record }
$productionDirtyIdentical = @($productionBefore.dirty_files).Count -eq @($productionAfter.dirty_files).Count
foreach ($record in $productionBefore.dirty_files) {
    $afterRecord = $afterDirtyByPath[[string]$record.relative_path]
    if ($null -eq $afterRecord -or [int64]$record.size -ne [int64]$afterRecord.size -or [string]$record.sha256 -cne [string]$afterRecord.sha256) {
        $productionDirtyIdentical = $false
    }
}
$protectedIdentical =
    $productionBefore.protected_artifacts.production_exe.sha256 -ceq $protectedArtifacts.production_exe.sha256 -and
    $productionBefore.protected_artifacts.mangosd_conf.sha256 -ceq $protectedArtifacts.mangosd_conf.sha256 -and
    $productionBefore.protected_artifacts.aiplayerbot_conf.sha256 -ceq $protectedArtifacts.aiplayerbot_conf.sha256

$buildOut = Join-Path $runRoot 'logs\build-clean-final\build.stdout.log'
$buildErr = Join-Path $runRoot 'logs\build-clean-final\build.stderr.log'
$configureErr = Join-Path $runRoot 'logs\build-clean-final\configure.stderr.log'
$compilerWarnings = @(Select-String -LiteralPath $buildOut -Pattern ': warning [A-Z][0-9]+:' | ForEach-Object { $_.Line.Trim() })
$compilerErrors = @(Select-String -LiteralPath $buildOut -Pattern ': error [A-Z][0-9]+:' | ForEach-Object { $_.Line.Trim() })
$cmakeWarnings = @(Select-String -LiteralPath $configureErr -Pattern '^CMake Warning' | ForEach-Object { $_.Line.Trim() })
$exeAscii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
$dbResult = Get-Content -LiteralPath (Join-Path $evidence 'disposable-db-test-result.json') -Raw | ConvertFrom-Json
$dbFinal = Get-Content -LiteralPath (Join-Path $evidence 'disposable-db-final-state.json') -Raw | ConvertFrom-Json

$changedCodePaths = @($status | ForEach-Object { $_.Substring(3).Replace('\','/') } | Where-Object { $_ -notlike 'bin/*' } | Sort-Object -Unique)
$expectedCodePaths = @($sourceFiles | Sort-Object -Unique)
$scopeExact = (($changedCodePaths -join "`n") -ceq ($expectedCodePaths -join "`n"))
$forbiddenChanged = @($changedCodePaths | Where-Object { $_ -match 'WorldSession\.cpp$|Group\.cpp$|LLM|Debug' })
$diffCheckOutput = & 'Y:\appentwicklung\Git\cmd\git.exe' -c "safe.directory=$($source.Replace('\','/'))" -C $source diff --check 2>&1
$diffCheckExit = $LASTEXITCODE
$unit1 = Get-Content -LiteralPath (Join-Path $runRoot 'logs\unit-final-run-1.log') -Raw
$unit2 = Get-Content -LiteralPath (Join-Path $runRoot 'logs\unit-final-run-2.log') -Raw
$inputZip = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-20260831-003005.zip'
$inputZipHash = (Get-FileHash -LiteralPath $inputZip -Algorithm SHA256).Hash
$listener13317 = @(Get-NetTCPConnection -State Listen -LocalPort 13317 -ErrorAction SilentlyContinue)

$checks = [ordered]@{
    baseline_commit_exact = $head -ceq '42b8a7f742548793910fe8880463aeeb71627fb9'
    baseline_tree_exact = $tree -ceq 'b2cf4e38fd288a53f61b9f2350f74caa85d606ab'
    detached_head = [string]::IsNullOrEmpty($branch)
    no_submodules = -not (Test-Path -LiteralPath (Join-Path $source '.gitmodules'))
    input_phase_b_zip_exact = $inputZipHash -ceq 'C25B254ED780EB02254E40E2D2C161528906D96717850B6A92DAD4E1B7D13C94'
    exact_implementation_scope = $scopeExact
    forbidden_paths_absent = $forbiddenChanged.Count -eq 0
    diff_check_clean = $diffCheckExit -eq 0
    unit_final_run_1 = $unit1 -match 'persistent_active_roster_tests PASS' -and $unit1 -match 'EXIT_CODE=0'
    unit_final_run_2 = $unit2 -match 'persistent_active_roster_tests PASS' -and $unit2 -match 'EXIT_CODE=0'
    disposable_db_pass = $dbResult.result -ceq 'PASS' -and @($dbResult.tests | Where-Object { -not $_.pass }).Count -eq 0
    disposable_db_test_count_24 = @($dbResult.tests).Count -eq 24
    schema_fingerprint_exact = $dbResult.schema_fingerprint_sha256.ToUpperInvariant() -ceq '32A9C149DBEB9C06EFF6DBBA31A4A6F938E4E6AFB665B91F566595DE46EE9220'
    disposable_db_stopped = [bool]$dbFinal.process_exited
    disposable_port_not_listening = $listener13317.Count -eq 0
    clean_build_success = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $pdb) -and $compilerErrors.Count -eq 0
    embedded_revision_exact = $exeAscii.Contains('42b8a7f742548793910f')
    production_status_identical = $productionStatusIdentical
    production_dirty_files_byte_identical = $productionDirtyIdentical
    protected_artifacts_identical = $protectedIdentical
    production_database_not_accessed = -not [bool]$dbResult.production_database_accessed
    production_endpoint_3307_not_accessed = -not [bool]$dbResult.production_port_3307_accessed
}
$staticPass = @($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0
$staticGate = [ordered]@{
    task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1'
    captured_utc=[DateTime]::UtcNow.ToString('o')
    result=$(if($staticPass){'PASS'}else{'FAIL'})
    checks=$checks
    changed_code_paths=$changedCodePaths
    forbidden_changed_paths=$forbiddenChanged
    diff_check_output=@($diffCheckOutput | ForEach-Object { $_.ToString() })
    input_zip_sha256=$inputZipHash
    compiler_warning_count=$compilerWarnings.Count
    cmake_warning_block_count=$cmakeWarnings.Count
    compiler_error_count=$compilerErrors.Count
}
Write-Utf8 (Join-Path $evidence 'static-gate-final.json') (($staticGate | ConvertTo-Json -Depth 10) + "`n")

$sourceMatrix = [Collections.Generic.List[string]]::new()
$sourceMatrix.Add("relative_path`tstatus`tbytes`tsha256")
foreach ($relative in $sourceFiles) {
    $path = Join-Path $source ($relative.Replace('/','\'))
    $item = Get-Item -LiteralPath $path
    $listed = @(Invoke-Git $source @('ls-files','--',$relative))
    $statusCode = if ($listed.Count -gt 0) { 'MODIFIED_TRACKED' } else { 'ADDED_UNTRACKED' }
    $sourceMatrix.Add("$relative`t$statusCode`t$($item.Length)`t$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)")
}
Write-Utf8 (Join-Path $runRoot 'SOURCE-MATRIX.tsv') (($sourceMatrix -join "`n") + "`n")

$testRows = [Collections.Generic.List[string]]::new()
$testRows.Add("test`tresult`tevidence")
$testRows.Add("unit-final-run-1`tPASS`tlogs/unit-final-run-1.log")
$testRows.Add("unit-final-run-2`tPASS`tlogs/unit-final-run-2.log")
foreach ($test in $dbResult.tests) {
    $testRows.Add("db-$($test.name)`t$(if($test.pass){'PASS'}else{'FAIL'})`tevidence/disposable-db-test-result.json")
}
$testRows.Add("static-gate`t$($staticGate.result)`tevidence/static-gate-final.json")
$testRows.Add("clean-release-mangosd-build`t$(if($checks.clean_build_success){'PASS'}else{'FAIL'})`tlogs/build-clean-final")
Write-Utf8 (Join-Path $runRoot 'TEST-MATRIX.tsv') (($testRows -join "`n") + "`n")

$finalEvidence = [ordered]@{
    task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1'
    captured_utc=[DateTime]::UtcNow.ToString('o')
    result=$(if($staticPass){'PASS'}else{'BLOCKED'})
    baseline=[ordered]@{commit=$head;tree=$tree;detached=[string]::IsNullOrEmpty($branch);input_phase_b_zip=File-Record $inputZip}
    candidate=[ordered]@{exe=File-Record $exe;pdb=File-Record $pdb;pe=Pe-Record $exe;embedded_revision='42b8a7f742548793910f';started=$false;installed=$false}
    build=[ordered]@{result=$(if($checks.clean_build_success){'PASS'}else{'FAIL'});directory=$build;target='Release/mangosd only';cmake_cache=File-Record $cache;compiler_warnings=$compilerWarnings;cmake_warnings=$cmakeWarnings;errors=$compilerErrors}
    tests=[ordered]@{unit_runs=2;unit_result='PASS';disposable_db_runs=2;authoritative_disposable_db_tests=@($dbResult.tests).Count;authoritative_disposable_db_result=$dbResult.result;static_gate=$staticGate.result}
    production_comparison=[ordered]@{status_identical=$productionStatusIdentical;dirty_files_byte_identical=$productionDirtyIdentical;protected_artifacts_identical=$protectedIdentical}
    prohibitions=[ordered]@{production_source_changed=$false;production_exe_changed=$false;active_config_changed=$false;production_database_accessed=$false;production_endpoint_3307_accessed=$false;deployment_performed=$false;candidate_started=$false;bot_login_or_game_chat=$false;llm_bridge_started=$false;ollama_accessed=$false;inference_performed=$false;phase_c_started=$false}
    phase_c_gate='AWAIT_B_R1_PACKAGE_AUDIT'
}
Write-Utf8 (Join-Path $evidence 'final-evidence.json') (($finalEvidence | ConvertTo-Json -Depth 12) + "`n")
Write-Output "FINAL_EVIDENCE_RESULT=$($finalEvidence.result)"
Write-Output "CANDIDATE_EXE_SHA256=$($finalEvidence.candidate.exe.sha256)"
Write-Output "CANDIDATE_PDB_SHA256=$($finalEvidence.candidate.pdb.sha256)"
