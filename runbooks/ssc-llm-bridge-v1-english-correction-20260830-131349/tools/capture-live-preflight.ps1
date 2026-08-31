$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bridgeRoot = Join-Path $root 'bridge'
$evidenceRoot = Join-Path $root 'evidence'
$outputPath = Join-Path $evidenceRoot 'live-preflight.json'
$nodePath = 'C:\Users\djfav\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
$cliPath = Join-Path $bridgeRoot 'src\cli.mjs'
$lockPath = Join-Path $bridgeRoot 'evidence\.phase1a-instance.lock'
$guardPath = Join-Path $evidenceRoot 'v1-english-one-shot.guard.json'
$manifestPath = Join-Path $bridgeRoot 'sha256-manifest.txt'
$entryListPath = Join-Path $bridgeRoot 'package-entry-list.txt'
$configPath = Join-Path $bridgeRoot 'config\bridge-config-v1.json'
$contextPath = Join-Path $bridgeRoot 'context\personality-context-profile-v1.json'

if (Test-Path -LiteralPath $outputPath) { throw "Refusing to overwrite: $outputPath" }
if (Test-Path -LiteralPath $lockPath) { throw "Bridge instance lock exists: $lockPath" }
if (Test-Path -LiteralPath $guardPath) { throw "One-shot guard already exists: $guardPath" }

$preservedPackages = @(
    [ordered]@{
        label = 'phase1a'
        path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-20260829-023418\ssc-llm-bridge-phase1a-20260829-023418-deliverables.zip'
        expected_sha256 = '2A39C09AACDC5CDEAD1CAC5EE78143D634A3FE006311DD1C67EC253115C1DE51'
    },
    [ordered]@{
        label = 'phase1a_hardening'
        path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1a-hardening-20260829-035317\ssc-llm-bridge-phase1a-hardening-20260829-035317-deliverables.zip'
        expected_sha256 = 'BADE583E726F5177D2BA9AF753962D6DC74BC3297B6C610A3CB91FF5251DDF11'
    },
    [ordered]@{
        label = 'phase1b'
        path = 'C:\TW\ComTW\runbooks\ssc-llm-bridge-phase1b-live-20260829-163519\ssc-llm-bridge-phase1b-live-20260829-163519-deliverables.zip'
        expected_sha256 = '020BDBA7BDE016FEACD2E484818E02BFAD8BE792AD84735BDEA845C2A2D9A5C8'
    },
    [ordered]@{
        label = 'production_bridge_phase_a'
        path = 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-20260830-012815-deliverables.zip'
        expected_sha256 = 'A4EB4552EF029C41F61D9BF4F247332F0239A5058FC32EE7ECCF1961EAF79A9D'
    }
)
foreach ($package in $preservedPackages) {
    $item = Get-Item -LiteralPath $package.path
    $package.size_bytes = [int64]$item.Length
    $package.last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    $package.actual_sha256 = (Get-FileHash -LiteralPath $package.path -Algorithm SHA256).Hash
    $package.match = $package.actual_sha256 -eq $package.expected_sha256
    if (-not $package.match) { throw "Preserved package mismatch: $($package.label)" }
}

$expectedEntries = @(Get-Content -LiteralPath $entryListPath | Where-Object { $_ }) | Sort-Object
$actualEntries = @(
    Get-ChildItem -LiteralPath $bridgeRoot -Recurse -File |
        ForEach-Object { [System.IO.Path]::GetRelativePath($bridgeRoot, $_.FullName).Replace('\', '/') } |
        Sort-Object
)
if (($expectedEntries -join "`n") -ne ($actualEntries -join "`n")) {
    throw 'Payload entry set does not match package-entry-list.txt.'
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
if ($manifestFailures.Count -ne 0) { throw "Payload manifest failures: $($manifestFailures -join ', ')" }

$manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$configSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
$contextSha256 = (Get-FileHash -LiteralPath $contextPath -Algorithm SHA256).Hash
if ($manifestSha256 -ne '814A8988ACF7F9651735A5AC111BA5A13ECD227C837665C0F8F9BA518B07171B') { throw 'Payload manifest hash mismatch.' }
if ($configSha256 -ne 'D2925AA891F1B9F93454F631E30E1BCDC3557FB5EEBC56CA4F9E1F6A955E3902') { throw 'Config hash mismatch.' }
if ($contextSha256 -ne '386659245CB8298221465FD8B40339C13A01C7C10CBC58E876CDD264DC64D07E') { throw 'Personality hash mismatch.' }

$listeners = @(
    Get-NetTCPConnection -State Listen -LocalPort 11434 -ErrorAction Stop |
        Sort-Object LocalAddress, OwningProcess |
        ForEach-Object {
            [ordered]@{
                local_address = $_.LocalAddress
                local_port = $_.LocalPort
                owning_process = $_.OwningProcess
            }
        }
)
if ($listeners.Count -ne 1 -or $listeners[0].local_address -ne '127.0.0.1') {
    throw "Ollama listener is not exactly 127.0.0.1:11434: $($listeners | ConvertTo-Json -Compress)"
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $nodePath
$startInfo.WorkingDirectory = $bridgeRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
[void]$startInfo.ArgumentList.Add($cliPath)
[void]$startInfo.ArgumentList.Add('--validate-only')
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()
if ($process.ExitCode -ne 0) { throw "Offline config validation failed: $stderr" }

$result = [ordered]@{
    schema_version = 1
    result = 'V1_ENGLISH_LIVE_PREFLIGHT=PASS'
    captured_utc = [DateTime]::UtcNow.ToString('o')
    preserved_packages = $preservedPackages
    bridge_payload = [ordered]@{
        files = $actualEntries.Count
        manifest_entries = (Get-Content -LiteralPath $manifestPath).Count
        entry_list_matches = $true
        manifest_failures = 0
        manifest_sha256 = $manifestSha256
        config_sha256 = $configSha256
        personality_sha256 = $contextSha256
        bot_guid = 18281
        active_limit = 1
        waiting_capacity = 2
        ledger_capacity = 64
        max_output_codepoints = 240
        max_output_utf8_bytes = 240
    }
    node = [ordered]@{
        path = $nodePath
        sha256 = (Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash
        file_version = (Get-Item -LiteralPath $nodePath).VersionInfo.FileVersion
    }
    ollama_listeners = $listeners
    listener_exact_loopback_only = $true
    config_validation_exit_code = $process.ExitCode
    config_validation_stdout = $stdout.Trim()
    config_validation_stderr = $stderr.Trim()
    instance_lock_present = $false
    one_shot_guard_present = $false
    inference_attempts_before_run = 0
    game_chat_performed = $false
    core_source_modified = $false
    phase_b_started = $false
}
[System.IO.File]::WriteAllText(
    $outputPath,
    ($result | ConvertTo-Json -Depth 10) + "`n",
    [System.Text.UTF8Encoding]::new($false)
)
$result.result
