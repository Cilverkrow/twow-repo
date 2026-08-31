$ErrorActionPreference = 'Stop'
$runbook = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$output = Join-Path $runbook 'evidence\phase-a-read-only-preflight.json'
$summaryOutput = Join-Path $runbook 'evidence\phase-a-read-only-preflight.txt'
$candidatePath = 'C:\TW\b02b-20260829-222913\runbook\artifacts\mangosd.exe'
$productionPath = 'C:\TW\ComTW\server\mangosd.exe'
$mangosConfig = 'C:\TW\ComTW\server\mangosd.conf'
$playerbotConfig = 'C:\TW\ComTW\server\aiplayerbot.conf'
$futureBackupPath = 'C:\TW\ComTW\server\mangosd.pre-source-baseline-02c-20260829.exe'
$expectedCandidate = '2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE'
$expectedProduction = 'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'

foreach($path in @($output,$summaryOutput)){if(Test-Path -LiteralPath $path){throw "Refusing to overwrite: $path"}}

function Get-FileRecord([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [ordered]@{path=$Path;exists=$false}}
    $item=Get-Item -LiteralPath $Path
    return [ordered]@{
        path=$item.FullName
        exists=$true
        length=[int64]$item.Length
        creation_utc=$item.CreationTimeUtc.ToString('o')
        last_write_utc=$item.LastWriteTimeUtc.ToString('o')
        sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
        file_version=$item.VersionInfo.FileVersion
        product_version=$item.VersionInfo.ProductVersion
    }
}

$candidate=Get-FileRecord $candidatePath
$production=Get-FileRecord $productionPath
$mangosConf=Get-FileRecord $mangosConfig
$playerbotConf=Get-FileRecord $playerbotConfig
if(-not $candidate.exists -or $candidate.sha256 -ne $expectedCandidate){throw "Candidate hash gate failed: $($candidate.sha256)"}
if(-not $production.exists -or $production.sha256 -ne $expectedProduction){throw "Production hash gate failed: $($production.sha256)"}

$targetNames=@('mangosd.exe','realmd.exe','mariadbd.exe','mysqld.exe','ollama.exe')
$processQueryError=$null
try {
    $processes=@(
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -in $targetNames } |
            Sort-Object Name,ProcessId |
            ForEach-Object {
                [pscustomobject]@{
                    name=$_.Name
                    process_id=[int]$_.ProcessId
                    parent_process_id=[int]$_.ParentProcessId
                    executable_path=$_.ExecutablePath
                    command_line=$_.CommandLine
                    creation_date=if($_.CreationDate){$_.CreationDate.ToUniversalTime().ToString('o')}else{$null}
                }
            }
    )
} catch {
    $processQueryError=$_.Exception.Message
    $processes=@(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { ($_.Name + '.exe') -in $targetNames } |
            Sort-Object ProcessName,Id |
            ForEach-Object {
                $fallbackPath=$null
                $fallbackCreation=$null
                try{$fallbackPath=$_.Path}catch{}
                try{$fallbackCreation=$_.StartTime.ToUniversalTime().ToString('o')}catch{}
                [pscustomobject]@{
                    name=$_.ProcessName+'.exe'
                    process_id=[int]$_.Id
                    parent_process_id=$null
                    executable_path=$fallbackPath
                    command_line=$null
                    creation_date=$fallbackCreation
                }
            }
    )
}

$processMap=@{}
foreach($process in $processes){$processMap[[int]$process.process_id]=$process.name}
$listenerQueryError=$null
try {
    $allListeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Sort-Object LocalPort,LocalAddress,OwningProcess)
    $listeners=@(
        $allListeners |
            Where-Object { $_.LocalPort -in @(3307,3724,8090,11434) -or $processMap.ContainsKey([int]$_.OwningProcess) } |
            ForEach-Object {
                [pscustomobject]@{
                    protocol='TCP'
                    local_address=$_.LocalAddress
                    local_port=[int]$_.LocalPort
                    state=$_.State.ToString()
                    owning_process_id=[int]$_.OwningProcess
                    owning_process_name=if($processMap.ContainsKey([int]$_.OwningProcess)){$processMap[[int]$_.OwningProcess]}else{$null}
                }
            }
    )
} catch {
    $listenerQueryError=$_.Exception.Message
    $listeners=@()
}

$netstatLines=@(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1 | ForEach-Object{"$_"})
$relevantNetstat=@($netstatLines | Where-Object { $_ -match 'LISTENING' -and ($_ -match ':(3307|3724|8090|11434)\s' -or $_ -match '\s('+(@($processMap.Keys)-join '|')+')\s*$') })

$record=[ordered]@{
    schema_version=1
    task='SSC-SOURCE-BASELINE-02C'
    phase='A_READ_ONLY_PREFLIGHT'
    captured_utc=(Get-Date).ToUniversalTime().ToString('o')
    maintenance_window_confirmed=$false
    phase_b_started=$false
    candidate_commit='42b8a7f742548793910fe8880463aeeb71627fb9'
    candidate_executable=$candidate
    production_executable=$production
    configs=[ordered]@{mangosd=$mangosConf;aiplayerbot=$playerbotConf}
    future_backup_path=[ordered]@{path=$futureBackupPath;exists=(Test-Path -LiteralPath $futureBackupPath)}
    relevant_processes=$processes
    process_query_error=$processQueryError
    relevant_tcp_listeners=$listeners
    listener_query_error=$listenerQueryError
    relevant_netstat_lines=$relevantNetstat
    gates=[ordered]@{
        candidate_hash_match=($candidate.sha256 -eq $expectedCandidate)
        production_hash_match=($production.sha256 -eq $expectedProduction)
        configs_exist=($mangosConf.exists -and $playerbotConf.exists)
        future_backup_name_unused=(-not(Test-Path -LiteralPath $futureBackupPath))
        no_file_replacement_performed=$true
        no_process_control_performed=$true
        wait_for_explicit_maintenance_window=$true
    }
}
[IO.File]::WriteAllText($output,($record|ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))

$summary=@(
    'SSC-SOURCE-BASELINE-02C Phase A read-only preflight',
    "CAPTURED_UTC=$($record.captured_utc)",
    "CANDIDATE_SHA256=$($candidate.sha256)",
    "PRODUCTION_SHA256=$($production.sha256)",
    "MANGOSD_CONF_SHA256=$($mangosConf.sha256)",
    "AIPLAYERBOT_CONF_SHA256=$($playerbotConf.sha256)",
    "FUTURE_BACKUP_NAME_UNUSED=$($record.gates.future_backup_name_unused)",
    "RELEVANT_PROCESS_COUNT=$($processes.Count)",
    "RELEVANT_LISTENER_COUNT=$($listeners.Count)",
    "MAINTENANCE_WINDOW_CONFIRMED=False",
    "PHASE_B_STARTED=False",
    "NO_FILE_REPLACEMENT_PERFORMED=True",
    "NO_PROCESS_CONTROL_PERFORMED=True"
)
[IO.File]::WriteAllText($summaryOutput,($summary-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
$summary
$processes|Format-Table name,process_id,parent_process_id,executable_path,creation_date -AutoSize
$listeners|Format-Table protocol,local_address,local_port,state,owning_process_id,owning_process_name -AutoSize
