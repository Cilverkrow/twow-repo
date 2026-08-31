param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9-]+$')][string]$Label
)
$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$server='C:\TW\ComTW\server'
$logs='C:\TW\ComTW\logs'
$output=Join-Path $runbook "evidence\runtime-state-$Label.json"
if(Test-Path -LiteralPath $output){throw "Refusing overwrite: $output"}

function Get-FileRecord([string]$Path,[bool]$Hash=$true){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [ordered]@{path=$Path;exists=$false}}
    $i=Get-Item -LiteralPath $Path
    $hashValue=$null;$hashError=$null
    if($Hash){try{$hashValue=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash}catch{$hashError=$_.Exception.Message}}
    return [ordered]@{path=$i.FullName;exists=$true;length=[int64]$i.Length;creation_utc=$i.CreationTimeUtc.ToString('o');last_write_utc=$i.LastWriteTimeUtc.ToString('o');sha256=$hashValue;hash_error=$hashError}
}

$targetNames=@('mangosd','realmd','mysqld','mariadbd','ollama')
$processes=@(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object ProcessName -in $targetNames |
        Sort-Object ProcessName,Id |
        ForEach-Object {
            $path=$null;$start=$null;$title=$null
            try{$path=$_.Path}catch{}
            try{$start=$_.StartTime.ToUniversalTime().ToString('o')}catch{}
            try{$title=$_.MainWindowTitle}catch{}
            [pscustomobject]@{name=$_.ProcessName+'.exe';process_id=[int]$_.Id;executable_path=$path;start_utc=$start;main_window_title=$title}
        }
)
$processMap=@{};foreach($p in $processes){$processMap[[int]$p.process_id]=$p.name}
$commandLines=@();$commandLineQueryError=$null
try{
    $commandLines=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object Name -in @('mangosd.exe','realmd.exe','mysqld.exe','mariadbd.exe','ollama.exe')|ForEach-Object{[pscustomobject]@{name=$_.Name;process_id=[int]$_.ProcessId;parent_process_id=[int]$_.ParentProcessId;executable_path=$_.ExecutablePath;command_line=$_.CommandLine}})
}catch{$commandLineQueryError=$_.Exception.Message}

$ports=@(3307,3724,8090,11434)
$netstatRaw=@(& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp 2>&1|ForEach-Object{"$_"})
$listeners=@()
foreach($line in $netstatRaw){
    $parts=@($line.Trim()-split'\s+'|Where-Object{$_})
    if($parts.Count-ne5-or$parts[0]-ne'TCP'){continue}
    if($parts[1]-notmatch':(\d+)$'){continue};$port=[int]$matches[1]
    if($port-notin$ports){continue};if($parts[2]-notin@('0.0.0.0:0','[::]:0')){continue}
    $pidValue=[int]$parts[4]
    $listeners += [pscustomobject]@{local_endpoint=$parts[1];local_port=$port;normalized_state='LISTEN';raw_localized_state=$parts[3];owning_process_id=$pidValue;owning_process_name=if($processMap.ContainsKey($pidValue)){$processMap[$pidValue]}else{$null};raw_line=$line}
}

$pidFiles=@();foreach($name in @('twlive.pid','twrealmd.pid')){$pidFiles += [pscustomobject](Get-FileRecord (Join-Path $server $name))}
$serverLogs=@(Get-ChildItem -LiteralPath $logs -File -Filter 'server_*.log' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc|ForEach-Object{[pscustomobject](Get-FileRecord $_.FullName $false)})
$crashFiles=@(Get-ChildItem -LiteralPath $logs -File -Filter 'crash_*' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc|ForEach-Object{[pscustomobject](Get-FileRecord $_.FullName $false)})
$files=[ordered]@{
    candidate=Get-FileRecord 'C:\TW\b02b-20260829-222913\runbook\artifacts\mangosd.exe'
    production_slot=Get-FileRecord (Join-Path $server 'mangosd.exe')
    backup=Get-FileRecord (Join-Path $server 'mangosd.pre-source-baseline-02c-20260829.exe')
    mangosd_conf=Get-FileRecord (Join-Path $server 'mangosd.conf')
    aiplayerbot_conf=Get-FileRecord (Join-Path $server 'aiplayerbot.conf')
    start_mangosd=Get-FileRecord (Join-Path $server 'start-mangosd.bat')
    shutdown_helper=Get-FileRecord (Join-Path $server 'shutdown-tortoise-servers-gracefully.ps1')
}
$record=[ordered]@{
    schema_version=1;task='SSC-SOURCE-BASELINE-02C';label=$Label
    captured_utc=(Get-Date).ToUniversalTime().ToString('o');captured_local=(Get-Date).ToString('o')
    processes=$processes;command_lines=$commandLines;command_line_query_error=$commandLineQueryError
    listeners=@($listeners|Sort-Object local_port);pid_files=$pidFiles;files=$files
    server_logs=$serverLogs;crash_files=$crashFiles
}
[IO.File]::WriteAllText($output,($record|ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "STATE=$Label"
Write-Output "UTC=$($record.captured_utc)"
Write-Output "PROCESSES=$($processes.Count)"
$processes|Format-Table name,process_id,executable_path,start_utc,main_window_title -AutoSize
$listeners|Format-Table local_endpoint,normalized_state,owning_process_id,owning_process_name -AutoSize
Write-Output "PRODUCTION_SLOT_SHA256=$($files.production_slot.sha256)"
Write-Output "BACKUP_EXISTS=$($files.backup.exists)"
Write-Output "MANGOSD_CONF_SHA256=$($files.mangosd_conf.sha256)"
Write-Output "AIPLAYERBOT_CONF_SHA256=$($files.aiplayerbot_conf.sha256)"
