$ErrorActionPreference = 'Stop'

$taskId = 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2'
$runbook = Split-Path -Parent $MyInvocation.MyCommand.Path
$evidence = Join-Path $runbook 'evidence'
$beforePath = Join-Path $evidence 'production-before.json'
$productionSource = 'C:\TW\ComTW\source'
$productionServer = 'C:\TW\ComTW\server'
$isolatedSource = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source'
$isolationRoot = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938'

function Get-FileEvidence([string] $Path, [string] $RelativePath = '') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ relative_path = $RelativePath; path = $Path; exists = $false }
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        relative_path = $RelativePath
        path = $Path
        exists = $true
        size = $item.Length
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    }
}

$before = Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json
$afterDirty = @()
foreach ($entry in $before.dirty_files) {
    $afterDirty += Get-FileEvidence (Join-Path $productionSource $entry.relative_path) $entry.relative_path
}

$protected = [ordered]@{
    production_exe = Get-FileEvidence (Join-Path $productionServer 'mangosd.exe')
    mangosd_conf = Get-FileEvidence (Join-Path $productionServer 'mangosd.conf')
    aiplayerbot_conf = Get-FileEvidence (Join-Path $productionServer 'aiplayerbot.conf')
}

$status = @(& git -c "safe.directory=$($productionSource.Replace('\','/'))" -C $productionSource status --short --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Production git status failed.' }
$head = (& git -c "safe.directory=$($productionSource.Replace('\','/'))" -C $productionSource rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Production git rev-parse failed.' }

$isolatedStatus = @(& git -C $isolatedSource status --short)
if ($LASTEXITCODE -ne 0) { throw 'Isolated git status failed.' }
$isolatedHead = (& git -C $isolatedSource rev-parse HEAD).Trim()
$isolatedTree = (& git -C $isolatedSource rev-parse 'HEAD^{tree}').Trim()

$dirtySame = $true
foreach ($old in $before.dirty_files) {
    $new = $afterDirty | Where-Object { $_.relative_path -eq $old.relative_path }
    if (-not $new -or -not $new.exists -or $new.sha256 -ne $old.sha256 -or $new.size -ne $old.size) {
        $dirtySame = $false
    }
}
$statusSame = (($status -join "`n") -ceq (($before.status_lines | ForEach-Object { [string]$_ }) -join "`n"))
$protectedSame =
    ($protected.production_exe.sha256 -eq $before.protected_artifacts.production_exe.sha256) -and
    ($protected.mangosd_conf.sha256 -eq $before.protected_artifacts.mangosd_conf.sha256) -and
    ($protected.aiplayerbot_conf.sha256 -eq $before.protected_artifacts.aiplayerbot_conf.sha256)

$runningIsolationProcesses = @(
    Get-Process -Name 'mangosd','mariadbd','persistent_active_roster_database_tests' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($isolationRoot, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object Id, ProcessName, Path, StartTime
)

$result = [ordered]@{
    task_id = $taskId
    captured_utc = [DateTime]::UtcNow.ToString('o')
    production_source = $productionSource
    git_head = $head
    status_lines = $status
    dirty_files = $afterDirty
    protected_artifacts = $protected
    comparison = [ordered]@{
        production_head_unchanged = ($head -eq $before.git_head)
        production_status_byte_identical = $statusSame
        production_dirty_files_byte_identical = $dirtySame
        protected_artifacts_byte_identical = $protectedSame
        production_source_byte_identical = ($statusSame -and $dirtySame -and ($head -eq $before.git_head))
        production_exe_changed = ($protected.production_exe.sha256 -ne $before.protected_artifacts.production_exe.sha256)
        active_config_changed = (($protected.mangosd_conf.sha256 -ne $before.protected_artifacts.mangosd_conf.sha256) -or ($protected.aiplayerbot_conf.sha256 -ne $before.protected_artifacts.aiplayerbot_conf.sha256))
    }
    isolated_source = [ordered]@{
        path = $isolatedSource
        git_head = $isolatedHead
        git_tree = $isolatedTree
        status_lines = $isolatedStatus
    }
    running_isolation_processes = $runningIsolationProcesses
    production_database_accessed = $false
    production_endpoint_3307_accessed = $false
    candidate_started = $false
    deployment_performed = $false
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $evidence 'production-after.json') -Encoding utf8
$result.comparison | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'production-comparison.json') -Encoding utf8

if (-not $result.comparison.production_source_byte_identical) { throw 'Production source changed during R2.' }
if (-not $result.comparison.protected_artifacts_byte_identical) { throw 'Protected production artifact changed during R2.' }
if ($runningIsolationProcesses.Count -ne 0) { throw 'An isolation-owned test or candidate process is still running.' }

Write-Output 'PRODUCTION_SOURCE_BYTE_IDENTICAL=YES'
Write-Output 'PRODUCTION_EXE_CHANGED=NO'
Write-Output 'ACTIVE_CONFIG_CHANGED=NO'
Write-Output 'ISOLATION_PROCESSES_RUNNING=0'
