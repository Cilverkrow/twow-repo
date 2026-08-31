param(
    [Parameter(Mandatory=$true)][ValidateSet('run1','run2')][string]$Run,
    [Parameter(Mandatory=$true)][int]$Port,
    [int]$Attempt=1,
    [string]$IsolationRoot='C:\TW\rndbot-roster-phase-b-r2-20260831-131938',
    [string]$Source='C:\TW\rndbot-roster-phase-b-r2-20260831-131938\source',
    [string]$Build='C:\TW\rndbot-roster-phase-b-r2-20260831-131938\build-adapter',
    [string]$Evidence='C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-r2-20260831-131938\evidence'
)
$ErrorActionPreference='Stop'
if($Port-eq3307){throw 'Production endpoint 127.0.0.1:3307 is forbidden.'}
$utf8=[Text.UTF8Encoding]::new($false)
$bin='C:\TW\ComTW\DB\bin'
$install=Join-Path $bin 'mariadb-install-db.exe'
$server=Join-Path $bin 'mariadbd.exe'
$client=Join-Path $bin 'mariadb.exe'
$admin=Join-Path $bin 'mariadb-admin.exe'
$adapter=Join-Path $Build 'adapter-bin\Release\persistent_active_roster_database_tests.exe'
$label="$Run-attempt$Attempt"
$dbRoot=Join-Path $IsolationRoot "db-r2-$label"
$data=Join-Path $dbRoot 'data'
$pidFile=Join-Path $dbRoot 'mariadbd.pid'
$errorLog=Join-Path $dbRoot 'mariadbd-error.log'
$schema="ssc_roster_r2_${Run}_$Attempt"
$user="ssc_r2_${Run}_${Attempt}_user"
$password=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
$process=$null

function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Hash-Text([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{[Convert]::ToHexString($sha.ComputeHash($utf8.GetBytes($Text)))}finally{$sha.Dispose()}}
function Invoke-Captured([string]$File,[string[]]$Arguments,[string]$InputText='',[string]$Password='',[bool]$AllowFailure=$false){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$File;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true
    if($Password){$psi.Environment['MYSQL_PWD']=$Password}
    $psi.Environment['Path']=(Join-Path $Source 'dep\windows\lib\x64_release')+';C:\TW\ComTW\vcpkg\installed\x64-windows\bin;'+$bin+';'+$env:Path
    foreach($a in $Arguments){[void]$psi.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::Start($psi)
    if($InputText){$p.StandardInput.Write($InputText)};$p.StandardInput.Close()
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
    $result=[pscustomobject]@{exit_code=$p.ExitCode;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()};$p.Dispose()
    if(-not$AllowFailure -and $result.exit_code-ne0){throw "Process failed exit=$($result.exit_code): $File`n$($result.stderr)"}
    return $result
}
function Root-Sql([string]$Sql){Invoke-Captured $client @('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port",'--user=root','--skip-ssl','--batch','--raw','--skip-column-names','--abort-source-on-error') $Sql}
function Test-Sql([string]$Sql){Invoke-Captured $client @('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port","--user=$user","--database=$schema",'--skip-ssl','--batch','--raw','--skip-column-names','--abort-source-on-error') $Sql $password}

try {
    if(Test-Path -LiteralPath $dbRoot){throw "Fresh disposable root already exists: $dbRoot"}
    if(-not(Test-Path -LiteralPath $adapter)){throw "Adapter executable missing: $adapter"}
    [void](New-Item -ItemType Directory -Path $dbRoot -Force);[void](New-Item -ItemType Directory -Path $Evidence -Force)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try{$listener.Start()}finally{$listener.Stop()}
    $serverArgs=@('--no-defaults',"--datadir=$data","--port=$Port",'--bind-address=127.0.0.1','--skip-networking=0','--skip-name-resolve',"--pid-file=$pidFile","--log-error=$errorLog")
    $pre=[ordered]@{task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2';run=$Run;captured_utc=[DateTime]::UtcNow.ToString('o');server_executable=$server;server_arguments=$serverArgs;server_command_line='"'+$server+'" '+($serverArgs-join' ');datadir=$data;bind_address='127.0.0.1';port=$Port;no_defaults=$true;production_endpoint_3307_allowed=$false;production_config_used=$false;windows_service=$false;temporary_user=$user;temporary_password_sha256=(Hash-Text $password)}
    Write-Utf8 (Join-Path $Evidence "$label-db-prestart.json") (($pre|ConvertTo-Json -Depth 6)+"`n")
    $init=Invoke-Captured $install @("--datadir=$data","--port=$Port",'--allow-remote-root-access')
    Write-Utf8 (Join-Path $Evidence "$label-db-init.log") ($init.stdout+$init.stderr)
    if(-not(Test-Path -LiteralPath (Join-Path $data 'mysql'))){throw 'Fresh datadir initialization failed.'}
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$server;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle='Hidden'
    foreach($a in $serverArgs){[void]$psi.ArgumentList.Add($a)};$process=[Diagnostics.Process]::Start($psi)
    $ready=$false
    for($i=0;$i-lt100-and-not$ready;$i++){Start-Sleep -Milliseconds 200;try{$c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',$Port);$c.Dispose();$ready=$true}catch{};if($process.HasExited){break}}
    if(-not$ready){throw 'Disposable MariaDB listener did not become ready.'}
    $netstat=@(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp)
    $owned=@($netstat|Where-Object{$_-match("^\s*TCP\s+127\.0\.0\.1:{0}\s+\S+\s+\S+\s+{1}\s*$"-f$Port,$process.Id)})
    if($owned.Count-ne1){throw 'Disposable listener ownership verification failed.'}
    Write-Utf8 (Join-Path $Evidence "$label-db-runtime.json") (([ordered]@{captured_utc=[DateTime]::UtcNow.ToString('o');pid=$process.Id;executable=$process.MainModule.FileName;listener=$owned;datadir=$data;port=$Port}|ConvertTo-Json -Depth 5)+"`n")
    [void](Root-Sql "CREATE DATABASE ``$schema`` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE USER '$user'@'127.0.0.1' IDENTIFIED BY '$password'; GRANT ALL PRIVILEGES ON ``$schema``.* TO '$user'@'127.0.0.1'; FLUSH PRIVILEGES;")
    $migration=[IO.File]::ReadAllText((Join-Path $Source 'sql\character_updates\20260830230336_ai_playerbot_persistent_active_roster.sql'))
    [void](Test-Sql $migration);[void](Test-Sql $migration)
    $connection="127.0.0.1;$Port;$user;$password;$schema"
    $test=Invoke-Captured $adapter @($connection)
    Write-Utf8 (Join-Path $Evidence "$label-real-adapter.stdout.log") $test.stdout
    Write-Utf8 (Join-Path $Evidence "$label-real-adapter.stderr.log") $test.stderr
    if($test.stdout-notmatch'persistent_active_roster_database_tests PASS'){throw 'Real adapter did not report PASS.'}
    $rollback=[IO.File]::ReadAllText((Join-Path $Source 'src\modules\PlayerBots\sql\other\20260830230336_ai_playerbot_persistent_active_roster_rollback.sql'))
    [void](Test-Sql $rollback)
    $remaining=(Test-Sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'ai_playerbot_roster_%';").stdout.Trim()
    if($remaining-ne'0'){throw "Rollback left $remaining roster tables."}
    Write-Utf8 (Join-Path $Evidence "$label-result.json") (([ordered]@{task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2';run=$Run;attempt=$Attempt;result='PASS';captured_utc=[DateTime]::UtcNow.ToString('o');adapter_exe_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $adapter).Hash;server_pid=$process.Id;port=$Port;datadir=$data;migration_apply_count=2;real_cpp_adapter='PASS';rollback_remaining_tables=0;production_database_accessed=$false;production_endpoint_3307_accessed=$false}|ConvertTo-Json -Depth 5)+"`n")
    Write-Output "REAL_CPP_ADAPTER_${Run}=PASS"
}
finally {
    if($process-and-not$process.HasExited){
        $shutdown=Invoke-Captured $admin @('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port",'--user=root','--skip-ssl','shutdown') '' '' $true
        Write-Utf8 (Join-Path $Evidence "$label-db-shutdown.log") ("exit=$($shutdown.exit_code)`n"+$shutdown.stdout+$shutdown.stderr)
        [void]$process.WaitForExit(30000)
    }
    if($process){$exited=$process.HasExited;$testProcessId=$process.Id;$process.Dispose();Write-Utf8 (Join-Path $Evidence "$label-db-final.json") (([ordered]@{captured_utc=[DateTime]::UtcNow.ToString('o');pid=$testProcessId;exited=$exited;port=$Port;production_endpoint_3307_accessed=$false}|ConvertTo-Json)+"`n");if(-not$exited){throw 'Disposable MariaDB did not stop.'}}
}
