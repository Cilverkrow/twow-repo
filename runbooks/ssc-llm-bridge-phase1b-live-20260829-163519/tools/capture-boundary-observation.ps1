param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('before', 'after')]
    [string]$Label
)

$ErrorActionPreference = 'Stop'
$phase1bDirectory = Split-Path -Parent $PSScriptRoot
$evidenceDirectory = Join-Path $phase1bDirectory 'evidence'
$outputPath = Join-Path $evidenceDirectory "boundary-observation-$Label.json"
$rawPsPath = Join-Path $evidenceDirectory "ollama-ps-$Label.json"
$observerPath = Join-Path $PSScriptRoot 'observe-ollama-ps.mjs'
$bundledNode = 'C:\Users\djfav\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($mustNotExist in @($outputPath, $rawPsPath)) {
    if (Test-Path -LiteralPath $mustNotExist) {
        throw "Refusing to overwrite one-shot observation evidence: $mustNotExist"
    }
}
if (-not (Test-Path -LiteralPath $bundledNode -PathType Leaf)) {
    throw "Pinned Node runtime is missing: $bundledNode"
}

$capturedUtc = [DateTime]::UtcNow.ToString('o')
$targetNames = @('mangosd', 'realmd', 'mysqld', 'mariadbd')
$targetProcesses = @(
    foreach ($name in $targetNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object {
                [ordered]@{ name = $_.ProcessName; pid = $_.Id }
            }
    }
)

$allListeners = @(
    & netstat.exe -ano -p tcp |
        ForEach-Object {
            if ($_ -match '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') {
                $localEndpoint = $Matches[1]
                $connectionState = $Matches[3]
                $ownerPid = [int]$Matches[4]
                $separator = $localEndpoint.LastIndexOf(':')
                if ($connectionState -match 'ABH|LISTEN' -and $separator -gt 0) {
                    $localAddress = $localEndpoint.Substring(0, $separator).Trim('[', ']')
                    $localPortText = $localEndpoint.Substring($separator + 1)
                    if ($localPortText -match '^\d+$') {
                        [ordered]@{
                            local_address = $localAddress
                            local_port = [int]$localPortText
                            state = 'LISTEN'
                            pid = $ownerPid
                        }
                    }
                }
            }
        }
)

$targetPids = @($targetProcesses | ForEach-Object { $_.pid })
$targetListeners = @(
    $allListeners |
        Where-Object { $targetPids -contains $_.pid } |
        Sort-Object pid, local_port, local_address
)
$ollamaProcesses = @(
    Get-Process -Name 'ollama' -ErrorAction SilentlyContinue |
        ForEach-Object { [ordered]@{ name = $_.ProcessName; pid = $_.Id } }
)
$ollamaPids = @($ollamaProcesses | ForEach-Object { $_.pid })
$ollamaOwnedListeners = @($allListeners | Where-Object { $ollamaPids -contains $_.pid })
$ollamaListeners = @($allListeners | Where-Object { $_.local_port -eq 11434 })
if ($ollamaListeners.Count -lt 1) {
    throw 'No TCP listener exists on Ollama port 11434.'
}
if (@($ollamaListeners | Where-Object { $_.local_address -ne '127.0.0.1' }).Count -ne 0) {
    throw 'Ollama port 11434 is not bound exclusively to 127.0.0.1.'
}
if (
    $ollamaOwnedListeners.Count -ne $ollamaListeners.Count -or
    @($ollamaOwnedListeners | Where-Object {
        $_.local_address -ne '127.0.0.1' -or $_.local_port -ne 11434
    }).Count -ne 0
) {
    throw 'The Ollama process owns a TCP listener other than 127.0.0.1:11434.'
}
$ollamaListenerProcesses = @(
    foreach ($listener in $ollamaListeners) {
        $owner = Get-Process -Id $listener.pid -ErrorAction Stop
        [ordered]@{
            name = $owner.ProcessName
            pid = $owner.Id
            local_address = $listener.local_address
            local_port = $listener.local_port
            state = $listener.state
        }
    }
)
if (@($ollamaListenerProcesses | Where-Object { $_.name -ne 'ollama' }).Count -ne 0) {
    throw 'Port 11434 is not owned exclusively by the Ollama process.'
}

$observerOutput = & $bundledNode $observerPath $Label
if ($LASTEXITCODE -ne 0) {
    throw "The one-shot GET /api/ps $Label observation failed with exit code $LASTEXITCODE."
}
$ollamaModelState = ($observerOutput -join "`n") | ConvertFrom-Json

$observation = [ordered]@{
    schema_version = 1
    result = "PHASE1B_BOUNDARY_$($Label.ToUpperInvariant())=PASS"
    label = $Label
    captured_utc = $capturedUtc
    observation_scope = 'process-name/PID presence and associated TCP listeners only'
    ollama_binding_requirement = '127.0.0.1:11434 only'
    ollama_binding_verified = $true
    ollama_processes = $ollamaProcesses
    ollama_listeners = $ollamaListenerProcesses
    game_database_processes = $targetProcesses
    game_database_listeners = $targetListeners
    ollama_running_model_observation = $ollamaModelState
    actions = [ordered]@{
        process_control_actions = 0
        game_process_start_stop_actions = 0
        database_connections_or_queries = 0
        game_source_reads_or_writes = 0
        game_chat_actions = 0
        model_pull_update_copy_delete_actions = 0
        model_explicit_load_unload_actions = 0
        manual_tags_requests = 0
        live_inference_requests = 0
        ps_observation_requests = 1
    }
}
[System.IO.File]::WriteAllText(
    $outputPath,
    ($observation | ConvertTo-Json -Depth 10) + "`n",
    $utf8NoBom
)

Write-Output $observation.result
Write-Output "ollama_binding_verified=$($observation.ollama_binding_verified)"
Write-Output "pinned_model_state=$($ollamaModelState.pinned_model_state)"
Write-Output "game_database_process_count=$($targetProcesses.Count)"
