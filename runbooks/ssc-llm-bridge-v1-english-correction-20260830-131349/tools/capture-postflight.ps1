$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bridgeRoot = Join-Path $root 'bridge'
$evidenceRoot = Join-Path $root 'evidence'
$outputPath = Join-Path $evidenceRoot 'postflight.json'
$manifestPath = Join-Path $bridgeRoot 'sha256-manifest.txt'
$lockPath = Join-Path $bridgeRoot 'evidence\.phase1a-instance.lock'
if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite: $outputPath" }
if (Test-Path -LiteralPath $lockPath) { throw 'Bridge instance lock remains after one-shot shutdown.' }

$expectedPackages = [ordered]@{
    phase1a = [ordered]@{ path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-20260829-023418\ssc-llm-bridge-phase1a-20260829-023418-deliverables.zip'; sha256 = '2A39C09AACDC5CDEAD1CAC5EE78143D634A3FE006311DD1C67EC253115C1DE51' }
    phase1a_hardening = [ordered]@{ path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-hardening-20260829-035317\ssc-llm-bridge-phase1a-hardening-20260829-035317-deliverables.zip'; sha256 = 'BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11' }
    phase1b = [ordered]@{ path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1b-live-20260829-163519\ssc-llm-bridge-phase1b-live-20260829-163519-deliverables.zip'; sha256 = '020BDBA7BDE016FEACD2E484818E02BFAD8BE792AD84735BDEA845C2A2D9A5C8' }
    production_phase_a = [ordered]@{ path = 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-20260830-012815-deliverables.zip'; sha256 = 'A4EB4552EF029C41F61D9BF4F247332F0239A5058FC32EE7ECCF1961EAF79A9D' }
}
foreach ($entry in $expectedPackages.GetEnumerator()) {
    $entry.Value.actual_sha256 = (Get-FileHash -LiteralPath $entry.Value.path -Algorithm SHA256).Hash
    $entry.Value.match = $entry.Value.actual_sha256 -eq $entry.Value.sha256
    if (-not $entry.Value.match) { throw "Preserved package mismatch: $($entry.Key)" }
}

$manifestFailures = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9A-F]{64}) \*(.+)$') { $manifestFailures.Add("format:$line"); continue }
    $candidate = Join-Path $bridgeRoot $Matches[2]
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $manifestFailures.Add("missing:$($Matches[2])")
    } elseif ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $Matches[1]) {
        $manifestFailures.Add("hash:$($Matches[2])")
    }
}
$manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
if ($manifestFailures.Count -ne 0 -or $manifestSha256 -ne '814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B') {
    throw "Post-run payload verification failed: $($manifestFailures -join ', ')"
}

$live = Get-Content -Raw -LiteralPath (Join-Path $evidenceRoot 'live-run-result.json') | ConvertFrom-Json
$language = Get-Content -Raw -LiteralPath (Join-Path $evidenceRoot 'english-language-verification.json') | ConvertFrom-Json
$metrics = Get-Content -Raw -LiteralPath (Join-Path $evidenceRoot 'metrics-before-shutdown.json') | ConvertFrom-Json
$shutdown = Get-Content -Raw -LiteralPath (Join-Path $evidenceRoot 'shutdown-response.json') | ConvertFrom-Json
$secondConsume = Get-Content -Raw -LiteralPath (Join-Path $evidenceRoot 'consume-second-response.json') | ConvertFrom-Json
if (
    $live.result -ne 'V1_ENGLISH_LIVE_INFERENCE=PASS' -or
    $live.cli_start_count -ne 1 -or
    $live.submit_command_count -ne 1 -or
    $live.live_inference_count -ne 1 -or
    $live.automatic_retry_performed -ne $false -or
    $live.resubmission_performed -ne $false -or
    $live.english_output_verified -ne $true -or
    $live.sanitized_text_utf8_bytes -gt 240 -or
    $metrics.metrics.inference_attempts -ne 1 -or
    $metrics.metrics.max_active_observed -ne 1 -or
    $metrics.metrics.active -ne 0 -or
    $secondConsume.code -ne 'already_consumed' -or
    $null -ne $secondConsume.completion -or
    $shutdown.metrics.lifecycle -ne 'stopped' -or
    $shutdown.metrics.worker_settled -ne $true
) { throw 'Live evidence invariant failed.' }

$stdinCommands = @(
    Get-Content -LiteralPath (Join-Path $evidenceRoot 'bridge-stdin.ndjson') |
        Where-Object { $_ } |
        ForEach-Object { $_ | ConvertFrom-Json }
)
$commandCounts = [ordered]@{}
foreach ($command in $stdinCommands) {
    $name = [string]$command.command
    if (-not $commandCounts.Contains($name)) { $commandCounts[$name] = 0 }
    $commandCounts[$name] += 1
}
if ($commandCounts.submit -ne 1 -or $commandCounts.consume -ne 2 -or $commandCounts.metrics -ne 1 -or $commandCounts.shutdown -ne 1) {
    throw 'Transcript command counts differ from the one-shot contract.'
}

$listeners = @(
    Get-NetTCPConnection -State Listen -LocalPort 11434 -ErrorAction Stop |
        Sort-Object LocalAddress, OwningProcess |
        ForEach-Object { [ordered]@{ local_address = $_.LocalAddress; local_port = $_.LocalPort; owning_process = $_.OwningProcess } }
)
if ($listeners.Count -ne 1 -or $listeners[0].local_address -ne '127.0.0.1') { throw 'Ollama listener changed from exact loopback-only binding.' }

$dirtyRoot = 'C:\TW\ComTW\source'
$dirtyFiles = [ordered]@{
    'src/modules/PlayerBots/CMakeLists.txt' = 'D590DA061544BBF07D43B78264FBC630E8114F0312F12E8E038518E70F4AA6DE'
    'src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp' = '24FB6B7475265436DBC0C191DA0B084E6DE622424556A8ED8751893AD3ABF592'
    'src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h' = '8C21805363EA2D68077810AD56E85C8D74948E4DC18CA322A2847DF38E182D71'
    'src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp' = '9052A1B0D9A8748C2E1D3F46F388A31031E2B43CAFCF665521C9A0B46A19DA0A'
}
$sourceHashes = [ordered]@{}
foreach ($entry in $dirtyFiles.GetEnumerator()) {
    $path = Join-Path $dirtyRoot $entry.Key
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $sourceHashes[$entry.Key] = [ordered]@{ expected_sha256 = $entry.Value; actual_sha256 = $actual; match = $actual -eq $entry.Value }
    if ($actual -ne $entry.Value) { throw "Core source changed: $($entry.Key)" }
}
$sourceStatus = @(git -c safe.directory=C:/TW/ComTW/source -C $dirtyRoot status --short --untracked-files=all)

$productionArtifacts = [ordered]@{
    mangosd_exe = [ordered]@{ path = 'C:\TW\ComTW\server\mangosd.exe'; expected_sha256 = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC' }
    mangosd_conf = [ordered]@{ path = 'C:\TW\ComTW\server\mangosd.conf'; expected_sha256 = 'C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D' }
    aiplayerbot_conf = [ordered]@{ path = 'C:\TW\ComTW\server\aiplayerbot.conf'; expected_sha256 = '490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF' }
}
foreach ($entry in $productionArtifacts.GetEnumerator()) {
    $entry.Value.actual_sha256 = (Get-FileHash -LiteralPath $entry.Value.path -Algorithm SHA256).Hash
    $entry.Value.match = $entry.Value.actual_sha256 -eq $entry.Value.expected_sha256
    if (-not $entry.Value.match) { throw "Production artifact/config mismatch: $($entry.Key)" }
}

$result = [ordered]@{
    schema_version = 1
    result = 'V1_ENGLISH_POSTFLIGHT=PASS'
    captured_utc = [DateTime]::UtcNow.ToString('o')
    preserved_packages = $expectedPackages
    payload_manifest_sha256 = $manifestSha256
    payload_manifest_entries = (Get-Content -LiteralPath $manifestPath).Count
    payload_manifest_failures = 0
    live_result = $live.result
    request_id = $live.request_id
    bot_guid = $live.bot_guid
    model = $live.model
    sanitized_text = $live.sanitized_text
    sanitized_text_codepoints = $live.sanitized_text_codepoints
    sanitized_text_utf8_bytes = $live.sanitized_text_utf8_bytes
    language_verification = $language.result
    command_counts = $commandCounts
    inference_attempts = $metrics.metrics.inference_attempts
    max_active_observed = $metrics.metrics.max_active_observed
    active_after_completion = $metrics.metrics.active
    second_consume = $secondConsume.code
    second_consume_completion_is_null = $null -eq $secondConsume.completion
    worker_joined = $shutdown.metrics.worker_settled
    instance_lock_removed = -not (Test-Path -LiteralPath $lockPath)
    one_shot_guard_sha256 = (Get-FileHash -LiteralPath (Join-Path $evidenceRoot 'v1-english-one-shot.guard.json') -Algorithm SHA256).Hash
    ollama_listeners = $listeners
    core_source_hashes = $sourceHashes
    core_git_status_short_all = $sourceStatus
    production_artifacts = $productionArtifacts
    core_source_modified = $false
    core_config_modified = $false
    build_or_compile_performed = $false
    database_access_performed = $false
    game_chat_performed = $false
    actions_emotes_commands_or_channels_added = $false
    phase_b_started = $false
    ollama_process_control_performed = $false
    game_process_control_performed = $false
}
[System.IO.File]::WriteAllText(
    $outputPath,
    ($result | ConvertTo-Json -Depth 12) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
$result.result
