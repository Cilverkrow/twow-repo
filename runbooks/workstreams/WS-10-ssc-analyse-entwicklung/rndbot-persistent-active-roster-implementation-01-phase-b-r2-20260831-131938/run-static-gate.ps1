$ErrorActionPreference = 'Stop'

$taskId = 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2'
$baselineCommit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$baselineTree = 'b2cf4e38fd288a53f61b9f2350f74caa85d606ab'
$source = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source'
$runbook = Split-Path -Parent $MyInvocation.MyCommand.Path
$evidence = Join-Path $runbook 'evidence'

$allowed = @(
    'CMakeLists.txt',
    'src/modules/PlayerBots/CMakeLists.txt',
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
    'src/modules/PlayerBots/tests/persistent_active_roster_database_tests.cpp',
    'src/modules/PlayerBots/tests/persistent_active_roster_tests.cpp',
    'src/modules/PlayerBots/tests/run-tests.ps1',
    'src/modules/PlayerBots/tests/schema_fingerprint.sql'
)

$head = (& git -C $source rev-parse HEAD).Trim()
$tree = (& git -C $source rev-parse 'HEAD^{tree}').Trim()
$statusLines = @(& git -C $source status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }

$sourceChanges = @()
$generated = @()
foreach ($line in $statusLines) {
    $path = $line.Substring(3).Replace('\','/')
    if ($path -like 'bin/*') {
        $generated += $path
        continue
    }
    $sourceChanges += $path
}

$unexpected = @($sourceChanges | Where-Object { $allowed -notcontains $_ })
$missing = @($allowed | Where-Object { $sourceChanges -notcontains $_ })
$forbiddenPaths = @($sourceChanges | Where-Object {
    $_ -match '(^|/)(WorldSession\.cpp|Group\.cpp)$' -or
    $_ -match 'ExternalLLM|LLMBridge|Ollama'
})

$diffCheckLog = Join-Path $evidence 'git-diff-check.log'
$diffCheck = @(& git -C $source diff --check 2>&1)
$diffExit = $LASTEXITCODE
$diffCheck | Set-Content -LiteralPath $diffCheckLog -Encoding utf8

$sourceMatrix = @()
foreach ($path in ($sourceChanges | Sort-Object)) {
    $full = Join-Path $source $path
    $statusLine = $statusLines | Where-Object { $_.Substring(3).Replace('\','/') -eq $path } | Select-Object -First 1
    $blob = (& git -C $source rev-parse "HEAD:$path" 2>$null)
    if ($LASTEXITCODE -ne 0) { $blob = 'NEW' } else { $blob = $blob.Trim() }
    $item = Get-Item -LiteralPath $full
    $sourceMatrix += [pscustomobject]@{
        status = $statusLine.Substring(0,2)
        path = $path
        baseline_blob = $blob
        bytes = $item.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash
    }
}
$sourceMatrix | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation | Set-Content -LiteralPath (Join-Path $runbook 'SOURCE-MATRIX.tsv') -Encoding utf8

$generatedEvidence = @()
$binRoot = Join-Path $source 'bin'
if (Test-Path -LiteralPath $binRoot) {
    $generatedEvidence = @(Get-ChildItem -LiteralPath $binRoot -Recurse -File | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($source.Length + 1).Replace('\','/')
            bytes = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
    })
}
$generatedEvidence | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation | Set-Content -LiteralPath (Join-Path $evidence 'generated-build-files.tsv') -Encoding utf8

$pass = ($head -eq $baselineCommit) -and ($tree -eq $baselineTree) -and
    ($unexpected.Count -eq 0) -and ($missing.Count -eq 0) -and
    ($forbiddenPaths.Count -eq 0) -and ($diffExit -eq 0)

$result = [ordered]@{
    task_id = $taskId
    captured_utc = [DateTime]::UtcNow.ToString('o')
    result = $(if ($pass) { 'PASS' } else { 'FAIL' })
    baseline_commit = $baselineCommit
    actual_commit = $head
    baseline_tree = $baselineTree
    actual_tree = $tree
    source_changes = $sourceChanges
    generated_build_paths_from_git_status = $generated
    unexpected_paths = $unexpected
    missing_expected_paths = $missing
    forbidden_paths = $forbiddenPaths
    worldsession_changed = ($sourceChanges -contains 'src/game/WorldSession.cpp')
    group_changed = ($sourceChanges -contains 'src/game/Group.cpp')
    production_config_path_changed = $false
    llm_work_resumed = $false
    git_diff_check_exit_code = $diffExit
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'static-scope-gate.json') -Encoding utf8

if (-not $pass) {
    $result | ConvertTo-Json -Depth 10 | Write-Output
    throw 'Static scope gate failed.'
}
Write-Output 'STATIC_SCOPE_GATE=PASS'
Write-Output "SOURCE_CHANGE_COUNT=$($sourceChanges.Count)"
Write-Output "GENERATED_FILE_COUNT=$($generatedEvidence.Count)"
Write-Output 'GIT_DIFF_CHECK=PASS'
