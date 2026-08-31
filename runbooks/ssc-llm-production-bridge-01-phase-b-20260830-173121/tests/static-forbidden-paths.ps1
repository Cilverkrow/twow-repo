param(
    [string]$SourceRoot = 'C:\TW\ssc-llm-phase-b-20260830-173121\source',
    [string]$ProductionRoot = 'C:\TW\ComTW\source'
)

$ErrorActionPreference = 'Stop'
$expected = @(
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
$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $git)) { $git = 'git.exe' }
$actual = @(& $git -c safe.directory=C:/TW/ssc-llm-phase-b-20260830-173121/source -C $SourceRoot status --porcelain=v1 |
    ForEach-Object { $_.Substring(3).Replace('\','/') } | Where-Object { $_ -notlike 'bin/*' } | Sort-Object -Unique)
$expectedSorted = @($expected | Sort-Object)

$checks = [ordered]@{}
$checks.exact_production_file_set = (@(Compare-Object $expectedSorted $actual).Count -eq 0)
$checks.production_source_status_preserved = ((& $git -c safe.directory=C:/TW/ComTW/source -C $ProductionRoot status --short | Out-String) -match 'PlayerbotLLMInterface.cpp')

$diff = & $git -c safe.directory=C:/TW/ssc-llm-phase-b-20260830-173121/source -C $SourceRoot diff -- .
$added = ($diff | Where-Object { $_ -match '^\+(?!\+\+)' }) -join "`n"
$service = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\ExternalLLMBridgeService.cpp')
$say = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\strategy\actions\SayAction.cpp')
$ai = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAI.cpp')
$config = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\aiplayerbot.conf.dist.in')

$checks.no_added_detached_thread = ($added -notmatch '\.detach\s*\(')
$checks.no_added_std_async = ($added -notmatch 'std::async')
$checks.no_ollama_or_http_in_service = ($service -notmatch '(?i)ollama|11434|https?://')
$checks.no_process_enumeration_or_shell = ($service -notmatch '(?i)CreateToolhelp32Snapshot|Process32First|Process32Next|taskkill|cmd\.exe|powershell\.exe|GenerateConsoleCtrlEvent')
$checks.only_owned_process_termination = (([regex]::Matches($service, 'TerminateProcess\(m_process\.Get\(\)').Count -eq [regex]::Matches($service, 'TerminateProcess\(').Count) -and ([regex]::Matches($service, 'TerminateProcess\(').Count -gt 0))
$checks.cli_path_is_derived = ($service -match 'bridge\s*/\s*"src"\s*/\s*"cli\.mjs"')
$checks.no_cliscript_option = ($added -notmatch '(?i)CliScript')
$checks.only_three_external_config_keys = (([regex]::Matches($config, '(?m)^#?\s*AiPlayerbot\.ExternalLLMBridge\.').Count -eq 3) -and $config -match 'ExternalLLMBridge\.Enabled = 0')
$checks.no_model_language_action_config = ($config -notmatch 'ExternalLLMBridge\.(Model|Language|Action|Url|Endpoint|CliScript)')
$checks.say_external_whisper_only = ($say -match 'chatChannelSource == ChatChannelSource::SRC_WHISPER' -and $say -match 'bot->GetGUIDLow\(\) == ExternalLLMBridgeService::BotGuid')
$checks.ai_world_queue_external_eligibility = ($ai -match 'isExternalBridgeChat' -and $ai -match 'msgtype == CHAT_MSG_WHISPER' -and $ai -match 'isAiChat \|\| isExternalBridgeChat')
$checks.non_llm_fallback_remains = ($say -match 'SubmitResult::Admitted\)\s*\r?\n\s*return;[\s\S]*SendGeneralResponse\(')
$checks.no_external_action_dispatch = ($service -notmatch 'HandleCommand\s*\(|HandleCommands\s*\(|ParseChatCommand|DoSpecificAction|TellPlayerNoFacing|LinesToPackets|TextEmote|HandleEmoteCommand')
$checks.no_legacy_async_callsite = ($say -notmatch 'SendDelayedPacket\s*\(' -and $say -notmatch 'std::async')
$checks.exact_constants = ($service -match 'kRequestTtl\(45000\)' -and (Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\ExternalLLMBridgeService.h')) -match 'ReadyTimeoutMs = 35000')
$diffCheck = & $git -c safe.directory=C:/TW/ssc-llm-phase-b-20260830-173121/source -C $SourceRoot diff --check 2>$null
$checks.diff_whitespace_clean = (($diffCheck | Out-String).Trim().Length -eq 0 -and $LASTEXITCODE -eq 0)

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
$result = [ordered]@{
    test_id = 'SSC-LLM-PRODUCTION-BRIDGE-01-PHASE-B-STATIC-GATE'
    checks = $checks
    planned_files = $expectedSorted
    actual_files = $actual
    pass = ($failed.Count -eq 0)
}
$result | ConvertTo-Json -Depth 6
if ($failed.Count) { exit 1 }
