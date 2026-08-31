$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$preflightPath=Join-Path $runbook 'evidence\phase-a-read-only-preflight.json'
$output=Join-Path $runbook 'evidence\phase-a-listener-netstat-supplement.json'
if(Test-Path -LiteralPath $output){throw "Refusing to overwrite: $output"}
$preflight=Get-Content -Raw -LiteralPath $preflightPath|ConvertFrom-Json
$processMap=@{}
foreach($process in $preflight.relevant_processes){$processMap[[int]$process.process_id]=$process.name}
$ports=@(3307,3724,8090,11434)
$raw=@(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1|ForEach-Object{"$_"})
$listeners=@()
foreach($line in $raw){
    $parts=@($line.Trim() -split '\s+'|Where-Object{$_})
    if($parts.Count -ne 5 -or $parts[0] -ne 'TCP'){continue}
    $local=$parts[1];$remote=$parts[2];$state=$parts[3];$pidText=$parts[4]
    if($local -notmatch ':(\d+)$'){continue}
    $port=[int]$matches[1]
    if($port -notin $ports){continue}
    if($remote -notin @('0.0.0.0:0','[::]:0')){continue}
    $pidValue=[int]$pidText
    $listeners += [pscustomobject]@{
        protocol='TCP'
        local_endpoint=$local
        local_port=$port
        remote_endpoint=$remote
        raw_localized_state=$state
        normalized_state='LISTEN'
        owning_process_id=$pidValue
        owning_process_name=if($processMap.ContainsKey($pidValue)){$processMap[$pidValue]}else{$null}
        raw_line=$line
    }
}
$record=[ordered]@{
    schema_version=1
    task='SSC-SOURCE-BASELINE-02C'
    phase='A_READ_ONLY_PREFLIGHT_LISTENER_SUPPLEMENT'
    captured_utc=(Get-Date).ToUniversalTime().ToString('o')
    reason='Get-NetTCPConnection was access-denied in the sandbox; read-only netstat output is used as the listener evidence.'
    listeners=@($listeners|Sort-Object local_port)
    required_ports=[ordered]@{
        mariadb_127_0_0_1_3307=(@($listeners|Where-Object{$_.local_port -eq 3307 -and $_.local_endpoint -like '127.0.0.1:*'}).Count -eq 1)
        realmd_0_0_0_0_3724=(@($listeners|Where-Object{$_.local_port -eq 3724 -and $_.local_endpoint -like '0.0.0.0:*'}).Count -eq 1)
        mangosd_0_0_0_0_8090=(@($listeners|Where-Object{$_.local_port -eq 8090 -and $_.local_endpoint -like '0.0.0.0:*'}).Count -eq 1)
        ollama_127_0_0_1_11434=(@($listeners|Where-Object{$_.local_port -eq 11434 -and $_.local_endpoint -like '127.0.0.1:*'}).Count -eq 1)
    }
    no_network_request_performed=$true
    no_process_control_performed=$true
}
[IO.File]::WriteAllText($output,($record|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
$record.listeners|Format-Table local_endpoint,normalized_state,owning_process_id,owning_process_name -AutoSize
$record.required_ports|Format-List
