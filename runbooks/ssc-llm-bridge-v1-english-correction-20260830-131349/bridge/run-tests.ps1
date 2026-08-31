$ErrorActionPreference = 'Stop'
$artifactDirectory = $PSScriptRoot
$evidenceDirectory = Join-Path $artifactDirectory 'evidence'
$bundledNode = 'C:\Users\djfav\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -ne $nodeCommand) {
    $nodePath = $nodeCommand.Source
} elseif (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    $nodePath = $bundledNode
} else {
    throw 'Node.js 24 or newer was not found; no package installation is permitted by this runner.'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $artifactDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedUtc = [DateTime]::UtcNow
    [void]$process.Start()
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
    $standardError = $standardErrorTask.GetAwaiter().GetResult()
    $completedUtc = [DateTime]::UtcNow

    return [ordered]@{
        exit_code = $process.ExitCode
        started_utc = $startedUtc.ToString('o')
        completed_utc = $completedUtc.ToString('o')
        duration_ms = [int64]($completedUtc - $startedUtc).TotalMilliseconds
        stdout = $standardOutput
        stderr = $standardError
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$nodeVersionRun = Invoke-CapturedProcess -Executable $nodePath -Arguments @('--version')
if ($nodeVersionRun.exit_code -ne 0 -or $nodeVersionRun.stdout.Trim() -notmatch '^v(2[4-9]|[3-9][0-9])\.') {
    throw "Node.js 24 or newer is required. Observed: $($nodeVersionRun.stdout.Trim())"
}

$validationRun = Invoke-CapturedProcess -Executable $nodePath -Arguments @('src/cli.mjs', '--validate-only')
[System.IO.File]::WriteAllText(
    (Join-Path $evidenceDirectory 'config-validation.jsonl'),
    $validationRun.stdout + $validationRun.stderr,
    $utf8NoBom
)

$testFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $artifactDirectory 'test') -Filter '*.test.mjs' -File |
        Sort-Object Name |
        ForEach-Object { [System.IO.Path]::GetRelativePath($artifactDirectory, $_.FullName).Replace('\', '/') }
)
$testArguments = @('--test', '--test-concurrency=1', '--test-reporter=tap') + $testFiles
$testRun = Invoke-CapturedProcess -Executable $nodePath -Arguments $testArguments
[System.IO.File]::WriteAllText(
    (Join-Path $evidenceDirectory 'automated-tests.tap'),
    $testRun.stdout + $testRun.stderr,
    $utf8NoBom
)

$testCount = if ($testRun.stdout -match '(?m)^# tests (\d+)$') { [int]$Matches[1] } else { $null }
$passCount = if ($testRun.stdout -match '(?m)^# pass (\d+)$') { [int]$Matches[1] } else { $null }
$failCount = if ($testRun.stdout -match '(?m)^# fail (\d+)$') { [int]$Matches[1] } else { $null }
$passed = $validationRun.exit_code -eq 0 -and $testRun.exit_code -eq 0 -and $null -ne $testCount -and $testCount -eq $passCount -and $failCount -eq 0

$result = [ordered]@{
    schema_version = 1
    result = if ($passed) { 'V1_ENGLISH_SERVER_FREE_TESTS=PASS' } else { 'V1_ENGLISH_SERVER_FREE_TESTS=FAIL' }
    node_path = $nodePath
    node_version = $nodeVersionRun.stdout.Trim()
    package_installation_performed = $false
    live_ollama_inference_performed = $false
    external_network_used = $false
    database_access_performed = $false
    game_chat_performed = $false
    game_source_modified_or_compiled = $false
    local_mock_http_only = $true
    wire_utc_preserved_as_evidence = $true
    admission_monotonic_deadline_tested = $true
    forward_and_backward_wall_clock_jumps_tested = $true
    sentence_terminator_runs_tested = @('.', '!', '?', '…')
    english_only_system_and_personality_rules_tested = $true
    output_codepoint_limit = 240
    output_utf8_byte_limit = 240
    multibyte_boundary_without_codepoint_splitting_tested = $true
    actions_emotes_commands_or_channels_added = $false
    config_validation_exit_code = $validationRun.exit_code
    test_exit_code = $testRun.exit_code
    tests = $testCount
    passed = $passCount
    failed = $failCount
    test_duration_ms = $testRun.duration_ms
    test_files = $testFiles
}
$resultJson = $result | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText(
    (Join-Path $evidenceDirectory 'automated-test-result.json'),
    $resultJson + "`n",
    $utf8NoBom
)

Write-Output $result.result
Write-Output "tests=$testCount passed=$passCount failed=$failCount"
Write-Output "node=$($result.node_version)"
if (-not $passed) {
    exit 1
}
