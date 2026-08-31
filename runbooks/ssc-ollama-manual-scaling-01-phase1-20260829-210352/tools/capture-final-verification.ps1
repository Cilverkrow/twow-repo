[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352'
$output = Join-Path $root 'evidence\final-readonly-verification.json'
if (Test-Path -LiteralPath $output) { throw 'Refusing overwrite' }
$repo = 'C:\TW\ComTW\source'
$config = 'C:\TW\ComTW\server\aiplayerbot.conf'
$exe = 'C:\TW\ComTW\server\mangosd.exe'
$initial = Get-Content -Raw -LiteralPath (Join-Path $root 'evidence\phase1-readonly-integrity.json') | ConvertFrom-Json
$status = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo status --short --untracked-files=all) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
$configItem = Get-Item -LiteralPath $config
$configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
$result = [ordered]@{
    captured_utc = [DateTime]::UtcNow.ToString('o')
    config = [ordered]@{
        path = $config
        size_bytes = $configItem.Length
        last_write_utc = $configItem.LastWriteTimeUtc.ToString('o')
        sha256 = $configHash
        equals_initial = ($configHash -eq $initial.config_sha256_initial)
    }
    production_exe = [ordered]@{
        path = $exe
        sha256 = $exeHash
        equals_baseline_hash = ($exeHash -eq 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC')
    }
    source = [ordered]@{
        head = (& git -c safe.directory=C:/TW/ComTW/source -C $repo rev-parse HEAD).Trim()
        status_short = $status
    }
    database_statement_class = 'SELECT only'
    database_writes = @()
    bot_login_actions = @()
    process_control_actions = @()
    ollama_inference_actions = @()
    production_config_or_source_writes = @()
    phase2_started = $false
}
[IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 5
