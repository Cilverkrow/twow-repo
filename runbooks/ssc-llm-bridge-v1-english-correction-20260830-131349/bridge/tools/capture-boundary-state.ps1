$ErrorActionPreference = 'Stop'
$artifactDirectory = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $artifactDirectory 'evidence\operational-boundary-final.json'
$targetNames = @('mangosd', 'mysqld', 'realmd', 'ollama')

$processes = @(
    foreach ($name in $targetNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object {
                [ordered]@{
                    name = $_.ProcessName
                    pid = $_.Id
                    responding = $_.Responding
                    working_set_bytes = [int64]$_.WorkingSet64
                }
            }
    }
)
$targetPids = @($processes | ForEach-Object { $_.pid })
$listeners = @()
if ($targetPids.Count -gt 0) {
    $listeners = @(
        & netstat.exe -ano -p tcp |
            ForEach-Object {
                if ($_ -match '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') {
                    $localEndpoint = $Matches[1]
                    $connectionState = $Matches[3]
                    $ownerPid = [int]$Matches[4]
                    if ($targetPids -contains $ownerPid -and $connectionState -match 'ABH|LISTEN') {
                        $separator = $localEndpoint.LastIndexOf(':')
                        $localAddress = $localEndpoint.Substring(0, $separator).Trim('[', ']')
                        $localPort = [int]$localEndpoint.Substring($separator + 1)
                        $processName = ($processes | Where-Object { $_.pid -eq $ownerPid } | Select-Object -First 1).name
                        [ordered]@{
                            process = $processName
                            pid = $ownerPid
                            local_address = $localAddress
                            local_port = $localPort
                            state = 'LISTEN'
                        }
                    }
                }
            } |
            Sort-Object pid, local_port |
            ForEach-Object {
                [ordered]@{
                    process = $_.process
                    pid = $_.pid
                    local_address = $_.local_address
                    local_port = $_.local_port
                    state = $_.state
                }
            }
    )
}

$snapshot = [ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    processes = $processes
    listeners = $listeners
    phase1a_boundary = [ordered]@{
        mangosd_modified_or_compiled = $false
        mariadb_accessed = $false
        game_chat_sent = $false
        existing_llm_path_enabled = $false
        live_ollama_inference_performed = $false
        model_management_performed = $false
        temporary_loopback_mock_listeners_closed = $true
    }
}
$json = $snapshot | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($outputPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output $outputPath
