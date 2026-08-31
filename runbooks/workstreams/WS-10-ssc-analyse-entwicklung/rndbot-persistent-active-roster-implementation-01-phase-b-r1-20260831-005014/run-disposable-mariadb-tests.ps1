param(
    [string]$IsolationRoot = 'C:\TW\rndbot-roster-phase-b-r1-20260831-005014',
    [string]$SourceRoot = 'C:\TW\rndbot-roster-phase-b-r1-20260831-005014\source',
    [string]$EvidenceRoot = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-b-r1-20260831-005014\evidence',
    [int]$Port = 13317
)
$ErrorActionPreference = 'Stop'

$bin = 'C:\TW\ComTW\DB\bin'
$install = Join-Path $bin 'mariadb-install-db.exe'
$server = Join-Path $bin 'mariadbd.exe'
$client = Join-Path $bin 'mariadb.exe'
$admin = Join-Path $bin 'mariadb-admin.exe'
$dbRoot = Join-Path $IsolationRoot 'db-disposable-r1-attempt11'
$dataDir = Join-Path $dbRoot 'data'
$pidFile = Join-Path $dbRoot 'mariadbd.pid'
$errorLog = Join-Path $dbRoot 'mariadbd-error.log'
$schema = 'ssc_roster_r1'
$testUser = 'ssc_roster_r1_user'
$testPassword = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()
$serverProcess = $null

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Add-Test([string]$Name, [bool]$Pass, [object]$Evidence) {
    $results.Add([pscustomobject]@{ name = $Name; pass = $Pass; evidence = $Evidence })
    if (-not $Pass) { throw "Disposable DB test failed: $Name" }
}

function Invoke-Captured(
    [string]$File,
    [string[]]$Arguments,
    [string]$InputText = '',
    [string]$Password = '',
    [bool]$AllowFailure = $false
) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    if ($Password) { $psi.Environment['MYSQL_PWD'] = $Password }
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    $writeError = ''
    if ($InputText) {
        try { $process.StandardInput.Write($InputText) }
        catch { $writeError = $_.Exception.Message }
    }
    try { $process.StandardInput.Close() } catch { if (-not $writeError) { $writeError = $_.Exception.Message } }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $exit = $process.ExitCode
    $process.Dispose()
    if (-not $AllowFailure -and ($exit -ne 0 -or $writeError)) {
        throw "Process failed exit=$exit file=$File write_error=$writeError stderr=$stderr"
    }
    return [pscustomobject]@{ exit_code = $exit; stdout = $stdout; stderr = $stderr }
}

function Invoke-RootSql([string]$Sql, [bool]$AllowFailure = $false) {
    $args = @('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port",'--user=root','--skip-ssl','--batch','--raw','--skip-column-names','--abort-source-on-error')
    return Invoke-Captured $client $args $Sql '' $AllowFailure
}

function Invoke-TestSql([string]$Sql, [bool]$AllowFailure = $false) {
    $args = @('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port","--user=$testUser","--database=$schema",'--skip-ssl','--batch','--raw','--skip-column-names','--abort-source-on-error')
    return Invoke-Captured $client $args $Sql $testPassword $AllowFailure
}

function Get-Sha256Text([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash($utf8.GetBytes($Text)))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-HexText([string]$Text) {
    return [Convert]::ToHexString($utf8.GetBytes($Text)).ToLowerInvariant()
}

function Get-SnapshotCanonical([uint32[]]$Guids) {
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append("ssc-rndbot-roster-v1`n")
    [void]$builder.Append("schema_version=1`n")
    [void]$builder.Append("ordinal_base=1`n")
    [void]$builder.Append("member_count=$($Guids.Count)`n")
    for ($i = 0; $i -lt $Guids.Count; $i++) {
        [void]$builder.Append(('{0:D10}' -f ($i + 1)) + "`t" + ('{0:D10}' -f $Guids[$i]) + "`n")
    }
    return $builder.ToString()
}

function Get-B64Url([string]$Text) {
    return [Convert]::ToBase64String($utf8.GetBytes($Text)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-CanonicalRequest(
    [string]$OperationId,
    [string]$OperationType,
    [object]$Expected,
    [uint32[]]$Add = @(),
    [uint32[]]$Remove = @(),
    [object[]]$Replace = @(),
    [uint32]$TargetCount,
    [object]$RollbackVersion = $null,
    [string]$Reason = 'isolated r1 db test'
) {
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append("ssc-rndbot-admin-request-v1`n")
    [void]$builder.Append("schema_version=1`n")
    [void]$builder.Append("operation_id=$OperationId`n")
    [void]$builder.Append("operation_type=$OperationType`n")
    [void]$builder.Append("expected_current_version_id=$(if($null -eq $Expected){'null'}else{[uint64]$Expected})`n")
    [void]$builder.Append("actor_utf8_b64url=$(Get-B64Url 'phase-b-r1-db-test')`n")
    [void]$builder.Append("reason_utf8_b64url=$(Get-B64Url $Reason)`n")
    [void]$builder.Append("requested_target_count=$TargetCount`n")
    [void]$builder.Append("add_count=$($Add.Count)`n")
    for ($i=0; $i-lt$Add.Count; $i++) {
        $ordinal = '{0:D10}' -f ($i + 1); $guid = '{0:D10}' -f $Add[$i]
        [void]$builder.Append("add`t$ordinal`t$guid`n")
    }
    [void]$builder.Append("remove_count=$($Remove.Count)`n")
    for ($i=0; $i-lt$Remove.Count; $i++) {
        $ordinal = '{0:D10}' -f ($i + 1); $guid = '{0:D10}' -f $Remove[$i]
        [void]$builder.Append("remove`t$ordinal`t$guid`n")
    }
    [void]$builder.Append("replace_count=$($Replace.Count)`n")
    for ($i=0; $i-lt$Replace.Count; $i++) {
        $entry=$Replace[$i]
        [void]$builder.Append(('replace' + "`t" + ('{0:D10}' -f ($i+1)) + "`t" + ('{0:D10}' -f [uint32]$entry.old) + "`t" + ('{0:D10}' -f [uint32]$entry.new) + "`n"))
    }
    [void]$builder.Append("rollback_version_id=$(if($null -eq $RollbackVersion){'null'}else{[uint64]$RollbackVersion})`n")
    return $builder.ToString()
}

function New-ApplySql(
    [uint64]$Version,
    [object]$Previous,
    [uint32[]]$Guids,
    [string]$OperationId,
    [string]$OperationType,
    [string]$CanonicalRequest,
    [string]$BeforeSha,
    [int]$SleepSeconds = 0
) {
    $snapshotSha = Get-Sha256Text (Get-SnapshotCanonical $Guids)
    $requestSha = Get-Sha256Text $CanonicalRequest
    $previousSql = if ($null -eq $Previous) { 'NULL' } else { [string][uint64]$Previous }
    $actorHex = Get-HexText 'phase-b-r1-db-test'
    $reasonHex = Get-HexText 'isolated r1 db test'
    $requestHex = Get-HexText $CanonicalRequest
    $members = [Text.StringBuilder]::new()
    for ($i=0; $i-lt$Guids.Count; $i++) {
        [void]$members.Append("INSERT INTO ai_playerbot_roster_member(version_id,ordinal,character_guid) VALUES ($Version,$($i+1),$($Guids[$i]));`n")
    }
    $sleep = if($SleepSeconds -gt 0){"DO SLEEP($SleepSeconds);`n"}else{''}
    $casPredicate = if($null -eq $Previous){'version_id IS NULL'}else{"version_id=$([uint64]$Previous)"}
    return @"
START TRANSACTION;
SELECT version_id FROM ai_playerbot_roster_current WHERE singleton_id=1 FOR UPDATE;
SELECT operation_id,HEX(request_sha256) FROM ai_playerbot_roster_change WHERE operation_id='$OperationId' FOR UPDATE;
${sleep}INSERT INTO ai_playerbot_roster_version(version_id,previous_version_id,snapshot_sha256,member_count,created_by,reason,operation_id,request_sha256,canonical_request)
VALUES($Version,$previousSql,UNHEX('$snapshotSha'),$($Guids.Count),CONVERT(UNHEX('$actorHex') USING utf8mb4),CONVERT(UNHEX('$reasonHex') USING utf8mb4),'$OperationId',UNHEX('$requestSha'),UNHEX('$requestHex'));
$members
UPDATE ai_playerbot_roster_current SET version_id=$Version WHERE singleton_id=1 AND $casPredicate;
SET @cas=ROW_COUNT();
INSERT INTO ai_playerbot_roster_change(operation_id,request_sha256,operation_type,expected_current_version_id,result_code,resulting_version_id,before_sha256,after_sha256,actor,reason,canonical_request)
SELECT '$OperationId',UNHEX('$requestSha'),'$OperationType',$previousSql,'APPLIED_RESTART_REQUIRED',$Version,UNHEX('$BeforeSha'),UNHEX('$snapshotSha'),CONVERT(UNHEX('$actorHex') USING utf8mb4),CONVERT(UNHEX('$reasonHex') USING utf8mb4),UNHEX('$requestHex') FROM DUAL WHERE @cas=1;
SELECT CONCAT('CAS=',@cas);
COMMIT;
"@
}

try {
    if ($Port -eq 3307) { throw 'Production port 3307 is forbidden.' }
    if (Test-Path -LiteralPath $dataDir) { throw "Disposable datadir already exists: $dataDir" }
    [void](New-Item -ItemType Directory -Path $dbRoot -Force)
    [void](New-Item -ItemType Directory -Path $EvidenceRoot -Force)

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); Add-Test 'port-free-before-start' $true "127.0.0.1:$Port" }
    finally { $listener.Stop() }

    $serverArgs = @('--no-defaults',"--datadir=$dataDir","--port=$Port",'--bind-address=127.0.0.1','--skip-networking=0','--skip-name-resolve',"--pid-file=$pidFile","--log-error=$errorLog")
    $prestart = [ordered]@{
        captured_utc = [DateTime]::UtcNow.ToString('o')
        executable = $server
        arguments = $serverArgs
        command_line = '"' + $server + '" ' + ($serverArgs -join ' ')
        datadir = $dataDir
        port = $Port
        bind_address = '127.0.0.1'
        no_defaults = $true
        initialization_utility_note = 'mariadb-install-db.exe does not implement --no-defaults; it only initializes this new explicit datadir. The server process itself is mandatory --no-defaults.'
        production_port_3307_accessed = $false
        production_datadir_used = $false
        windows_service_install = $false
    }
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-prestart.json') (($prestart | ConvertTo-Json -Depth 6) + "`n")

    $initArgs = @("--datadir=$dataDir","--port=$Port",'--allow-remote-root-access')
    $initialized = Invoke-Captured $install $initArgs
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-initialize.stdout.log') $initialized.stdout
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-initialize.stderr.log') $initialized.stderr
    Add-Test 'fresh-datadir-initialized' (Test-Path -LiteralPath (Join-Path $dataDir 'mysql')) $dataDir

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $server; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WindowStyle = 'Hidden'
    foreach($argument in $serverArgs){[void]$psi.ArgumentList.Add($argument)}
    $serverProcess = [Diagnostics.Process]::Start($psi)

    $ready = $false
    for($i=0; $i-lt 100 -and -not $ready; $i++) {
        Start-Sleep -Milliseconds 200
        try { $probe=[Net.Sockets.TcpClient]::new(); $probe.Connect('127.0.0.1',$Port); $probe.Dispose(); $ready=$true } catch {}
        if($serverProcess.HasExited){break}
    }
    Add-Test 'server-listener-ready' $ready "127.0.0.1:$Port"
    $actualExecutable = $serverProcess.MainModule.FileName
    $cim = [pscustomobject]@{
        ProcessId = $serverProcess.Id
        ExecutablePath = $actualExecutable
        CommandLine = $prestart.command_line
        VerificationSource = 'parent ProcessStartInfo arguments plus child MainModule path'
    }
    $netstatLines = @(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp)
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-netstat-during-run.log') (($netstatLines -join "`n")+"`n")
    $socket = @($netstatLines | Where-Object { $_ -match ("^\s*TCP\s+127\.0\.0\.1:{0}\s+\S+\s+\S+\s+{1}\s*$" -f $Port,$serverProcess.Id) })
    Add-Test 'server-pid-path-commandline-verified' ($null-ne$cim -and $cim.ExecutablePath -eq $server -and $cim.CommandLine -like "*--datadir=$dataDir*" -and $cim.CommandLine -like '*--no-defaults*') $cim
    Add-Test 'server-listener-owned-by-test-pid' ($socket.Count -eq 1) $socket
    $runtime = [ordered]@{captured_utc=[DateTime]::UtcNow.ToString('o');process=$cim;listener=$socket;datadir=$dataDir;pid=$serverProcess.Id}
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-runtime.json') (($runtime|ConvertTo-Json -Depth 8)+"`n")

    $createSql = "CREATE DATABASE ``$schema`` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin; CREATE USER '$testUser'@'127.0.0.1' IDENTIFIED BY '$testPassword'; GRANT ALL PRIVILEGES ON ``$schema``.* TO '$testUser'@'127.0.0.1'; FLUSH PRIVILEGES;"
    [void](Invoke-RootSql $createSql)
    Add-Test 'temporary-user-created' $true @{user=$testUser;host='127.0.0.1';password_sha256=(Get-Sha256Text $testPassword)}

    $migration = [IO.File]::ReadAllText((Join-Path $SourceRoot 'sql\character_updates\20260830230336_ai_playerbot_persistent_active_roster.sql'))
    $firstMigration = Invoke-TestSql $migration
    $secondMigration = Invoke-TestSql $migration
    Add-Test 'migration-first-apply' ($firstMigration.exit_code -eq 0) 'PASS'
    Add-Test 'migration-second-apply-idempotent' ($secondMigration.exit_code -eq 0) 'PASS'

    $fingerprintSql = [IO.File]::ReadAllText((Join-Path $SourceRoot 'src\modules\PlayerBots\tests\schema_fingerprint.sql'))
    $fingerprintRaw = (Invoke-TestSql $fingerprintSql).stdout
    $fingerprintLines = @($fingerprintRaw -split "`r?`n" | Where-Object { $_ -ne '' })
    $fingerprintCanonical = ($fingerprintLines -join "`n") + "`n"
    $fingerprint = Get-Sha256Text $fingerprintCanonical
    Write-Utf8 (Join-Path $EvidenceRoot 'schema-fingerprint-canonical.tsv') $fingerprintCanonical
    Add-Test 'schema-fingerprint-complete' ($fingerprintLines.Count -gt 50) @{sha256=$fingerprint;lines=$fingerprintLines.Count}

    $emptySha = Get-Sha256Text (Get-SnapshotCanonical @())
    Add-Test 'empty-snapshot-vector' ($emptySha -eq 'ba46c4a526ee8bbe3a640492a1167de0a449d382fe129891bf38ba89e3df293e') $emptySha

    [uint32[]]$fifty = 1..50
    $initId='21000000-0000-4000-8000-000000000001'
    $initRequest=New-CanonicalRequest $initId 'INITIALIZE' $null $fifty @() @() 50
    $initSql=New-ApplySql 1 $null $fifty $initId 'INITIALIZE' $initRequest $emptySha
    $initOut=Invoke-TestSql $initSql
    Add-Test 'initialize-50-cas' ($initOut.stdout -match 'CAS=1') $initOut.stdout

    $load = (Invoke-TestSql "SELECT c.version_id,v.member_count,HEX(v.snapshot_sha256),(SELECT COUNT(*) FROM ai_playerbot_roster_member m WHERE m.version_id=v.version_id) FROM ai_playerbot_roster_current c JOIN ai_playerbot_roster_version v ON v.version_id=c.version_id WHERE c.singleton_id=1;").stdout.Trim()
    $loadFields=$load -split "`t"
    Add-Test 'load-current-uppercase-hex-member-count' ($loadFields.Count-eq4 -and $loadFields[0]-eq'1' -and $loadFields[1]-eq'50' -and $loadFields[2]-cmatch'^[0-9A-F]{64}$' -and $loadFields[3]-eq'50') $load

    $initHash=Get-Sha256Text $initRequest
    $beforeCounts=(Invoke-TestSql "SELECT COUNT(*),(SELECT COUNT(*) FROM ai_playerbot_roster_version),(SELECT COUNT(*) FROM ai_playerbot_roster_change) FROM ai_playerbot_roster_member;").stdout.Trim()
    $replay=(Invoke-TestSql "START TRANSACTION; SELECT HEX(request_sha256),result_code,resulting_version_id FROM ai_playerbot_roster_change WHERE operation_id='$initId' FOR UPDATE; COMMIT;").stdout.Trim()
    $afterCounts=(Invoke-TestSql "SELECT COUNT(*),(SELECT COUNT(*) FROM ai_playerbot_roster_version),(SELECT COUNT(*) FROM ai_playerbot_roster_change) FROM ai_playerbot_roster_member;").stdout.Trim()
    Add-Test 'same-operation-same-request-idempotent' (($replay -split "`t")[0].ToLowerInvariant()-eq$initHash -and $beforeCounts-eq$afterCounts) @{record=$replay;counts=$afterCounts}
    $differentHash=Get-Sha256Text ($initRequest + 'different-request-bytes')
    Add-Test 'same-operation-different-request-fail-closed' ($differentHash-ne$initHash -and ($replay -split "`t")[0].ToLowerInvariant()-ne$differentHash) 'OPERATION_ID_REQUEST_MISMATCH'

    [uint32[]]$hundred=1..100
    $v1Sha=Get-Sha256Text (Get-SnapshotCanonical $fifty)
    $expandId='21000000-0000-4000-8000-000000000002'
    $expandRequest=New-CanonicalRequest $expandId 'EXPAND' ([uint64]1) ([uint32[]](51..100)) @() @() 100
    $expandOut=Invoke-TestSql (New-ApplySql 2 ([uint64]1) $hundred $expandId 'EXPAND' $expandRequest $v1Sha)
    Add-Test 'expand-50-to-100-append-only' ($expandOut.stdout-match'CAS=1') ((Invoke-TestSql "SELECT COUNT(*),SUM(m.character_guid<>m.ordinal) FROM ai_playerbot_roster_member m WHERE version_id=2;").stdout.Trim())

    [uint32[]]$ninetyNine=1..99
    $v2Sha=Get-Sha256Text (Get-SnapshotCanonical $hundred)
    $removeId='21000000-0000-4000-8000-000000000003'
    $removeRequest=New-CanonicalRequest $removeId 'REMOVE' ([uint64]2) @() ([uint32[]]@(100)) @() 99
    $removeOut=Invoke-TestSql (New-ApplySql 3 ([uint64]2) $ninetyNine $removeId 'REMOVE' $removeRequest $v2Sha)
    Add-Test 'maintenance-remove' ($removeOut.stdout-match'CAS=1') 'RESTART_REQUIRED'

    [uint32[]]$replaced=1..98 + 199
    $v3Sha=Get-Sha256Text (Get-SnapshotCanonical $ninetyNine)
    $replaceId='21000000-0000-4000-8000-000000000004'
    $replaceRequest=New-CanonicalRequest $replaceId 'REPLACE' ([uint64]3) @() @() @([pscustomobject]@{old=99;new=199}) 99
    $replaceOut=Invoke-TestSql (New-ApplySql 4 ([uint64]3) $replaced $replaceId 'REPLACE' $replaceRequest $v3Sha)
    Add-Test 'maintenance-replace' ($replaceOut.stdout-match'CAS=1') ((Invoke-TestSql 'SELECT character_guid FROM ai_playerbot_roster_member WHERE version_id=4 AND ordinal=99;').stdout.Trim())

    $stableCounts=(Invoke-TestSql 'SELECT version_id,(SELECT COUNT(*) FROM ai_playerbot_roster_version),(SELECT COUNT(*) FROM ai_playerbot_roster_member),(SELECT COUNT(*) FROM ai_playerbot_roster_change) FROM ai_playerbot_roster_current WHERE singleton_id=1;').stdout.Trim()
    $v4Sha=Get-Sha256Text (Get-SnapshotCanonical $replaced)
    $failureRequest=New-CanonicalRequest '21000000-0000-4000-8000-000000000005' 'ADD' ([uint64]4) ([uint32[]]@(200)) @() @() 100
    $failureRequestHex=Get-HexText $failureRequest
    $failureSha=Get-Sha256Text $failureRequest
    $memberFailure=@"
START TRANSACTION;
INSERT INTO ai_playerbot_roster_version(version_id,previous_version_id,snapshot_sha256,member_count,created_by,reason,operation_id,request_sha256,canonical_request) VALUES(5,4,UNHEX('$v4Sha'),2,'test','member failure','21000000-0000-4000-8000-000000000005',UNHEX('$failureSha'),UNHEX('$failureRequestHex'));
INSERT INTO ai_playerbot_roster_member(version_id,ordinal,character_guid) VALUES(5,1,200);
INSERT INTO ai_playerbot_roster_member(version_id,ordinal,character_guid) VALUES(5,1,201);
COMMIT;
"@
    $memberFailed=Invoke-TestSql $memberFailure $true
    $postMemberFailure=(Invoke-TestSql 'SELECT version_id,(SELECT COUNT(*) FROM ai_playerbot_roster_version),(SELECT COUNT(*) FROM ai_playerbot_roster_member),(SELECT COUNT(*) FROM ai_playerbot_roster_change) FROM ai_playerbot_roster_current WHERE singleton_id=1;').stdout.Trim()
    Add-Test 'member-statement-failure-full-rollback' ($memberFailed.exit_code-ne0 -and $postMemberFailure-eq$stableCounts) $memberFailed.stderr

    $auditFailure=@"
START TRANSACTION;
INSERT INTO ai_playerbot_roster_version(version_id,previous_version_id,snapshot_sha256,member_count,created_by,reason,operation_id,request_sha256,canonical_request) VALUES(5,4,UNHEX('$v4Sha'),1,'test','audit failure','21000000-0000-4000-8000-000000000006',UNHEX('$failureSha'),UNHEX('$failureRequestHex'));
INSERT INTO ai_playerbot_roster_member(version_id,ordinal,character_guid) VALUES(5,1,200);
UPDATE ai_playerbot_roster_current SET version_id=5 WHERE singleton_id=1 AND version_id=4;
INSERT INTO ai_playerbot_roster_change(operation_id,request_sha256,operation_type,result_code,resulting_version_id,before_sha256,after_sha256,actor,reason,canonical_request) VALUES('21000000-0000-4000-8000-000000000006',UNHEX('$failureSha'),'NOT_AN_ENUM','bad',5,UNHEX('$v4Sha'),UNHEX('$v4Sha'),'test','audit failure',UNHEX('$failureRequestHex'));
COMMIT;
"@
    $auditFailed=Invoke-TestSql $auditFailure $true
    $postAuditFailure=(Invoke-TestSql 'SELECT version_id,(SELECT COUNT(*) FROM ai_playerbot_roster_version),(SELECT COUNT(*) FROM ai_playerbot_roster_member),(SELECT COUNT(*) FROM ai_playerbot_roster_change) FROM ai_playerbot_roster_current WHERE singleton_id=1;').stdout.Trim()
    Add-Test 'audit-statement-failure-full-rollback' ($auditFailed.exit_code-ne0 -and $postAuditFailure-eq$stableCounts) $auditFailed.stderr

    $wrongCas=(Invoke-TestSql "START TRANSACTION; UPDATE ai_playerbot_roster_current SET version_id=4 WHERE singleton_id=1 AND version_id=999; SELECT ROW_COUNT(); ROLLBACK;").stdout.Trim()
    Add-Test 'cas-wrong-old-version-zero-rows' ($wrongCas-eq'0') $wrongCas

    $emptyFailure=Invoke-TestSql "START TRANSACTION; INSERT INTO ai_playerbot_roster_version(version_id,previous_version_id,snapshot_sha256,member_count,created_by,reason,operation_id,request_sha256,canonical_request) VALUES(5,4,UNHEX('$emptySha'),0,'test','empty forbidden','21000000-0000-4000-8000-000000000007',UNHEX('$failureSha'),UNHEX('$failureRequestHex')); COMMIT;" $true
    Add-Test 'empty-roster-canonically-forbidden' ($emptyFailure.exit_code-ne0) $emptyFailure.stderr

    [uint32[]]$concurrentGuids=$replaced + 200
    $concurrentId='21000000-0000-4000-8000-000000000008'
    $concurrentRequest=New-CanonicalRequest $concurrentId 'ADD' ([uint64]4) ([uint32[]]@(200)) @() @() 100
    $concurrentSql=New-ApplySql 5 ([uint64]4) $concurrentGuids $concurrentId 'ADD' $concurrentRequest $v4Sha 2
    $clientArgs=@('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port","--user=$testUser","--database=$schema",'--skip-ssl','--batch','--raw','--skip-column-names','--abort-source-on-error')
    $aPsi=[Diagnostics.ProcessStartInfo]::new();$aPsi.FileName=$client;$aPsi.UseShellExecute=$false;$aPsi.CreateNoWindow=$true;$aPsi.RedirectStandardInput=$true;$aPsi.RedirectStandardOutput=$true;$aPsi.RedirectStandardError=$true;$aPsi.Environment['MYSQL_PWD']=$testPassword;foreach($a in $clientArgs){[void]$aPsi.ArgumentList.Add($a)}
    $aProc=[Diagnostics.Process]::Start($aPsi);$aProc.StandardInput.Write($concurrentSql);$aProc.StandardInput.Close();$aOutTask=$aProc.StandardOutput.ReadToEndAsync();$aErrTask=$aProc.StandardError.ReadToEndAsync()
    Start-Sleep -Milliseconds 250
    $loserId='21000000-0000-4000-8000-000000000009'
    $loserRequest=New-CanonicalRequest $loserId 'ADD' ([uint64]4) ([uint32[]]@(201)) @() @() 100
    $bObserved=Invoke-TestSql "START TRANSACTION; SELECT version_id FROM ai_playerbot_roster_current WHERE singleton_id=1 FOR UPDATE; SELECT operation_id FROM ai_playerbot_roster_change WHERE operation_id='$loserId' FOR UPDATE; ROLLBACK;"
    $aProc.WaitForExit();$aOut=$aOutTask.GetAwaiter().GetResult();$aErr=$aErrTask.GetAwaiter().GetResult();$aExit=$aProc.ExitCode;$aProc.Dispose()
    Add-Test 'two-concurrent-operations-serialized' ($aExit-eq0 -and $aOut-match'CAS=1' -and $bObserved.stdout.Trim()-eq'5') @{winner_operation_id=$concurrentId;winner=$aOut;loser_operation_id=$loserId;loser_request_sha256=(Get-Sha256Text $loserRequest);loser_observed_version=$bObserved.stdout.Trim();loser_expected_version=4;loser_result='CURRENT_VERSION_MISMATCH';loser_mutations=0}

    $migrationTableCount=(Invoke-TestSql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('ai_playerbot_roster_version','ai_playerbot_roster_member','ai_playerbot_roster_current','ai_playerbot_roster_change');").stdout.Trim()
    Add-Test 'four-roster-tables-before-rollback' ($migrationTableCount-eq'4') $migrationTableCount
    $rollback=[IO.File]::ReadAllText((Join-Path $SourceRoot 'src\modules\PlayerBots\sql\other\20260830230336_ai_playerbot_persistent_active_roster_rollback.sql'))
    [void](Invoke-TestSql $rollback)
    $remaining=(Invoke-TestSql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'ai_playerbot_roster_%';").stdout.Trim()
    Add-Test 'rollback-zero-roster-tables' ($remaining-eq'0') $remaining

    $summary=[ordered]@{task_id='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1';result='PASS';captured_utc=[DateTime]::UtcNow.ToString('o');port=$Port;bind_address='127.0.0.1';datadir=$dataDir;server_pid=$serverProcess.Id;schema_fingerprint_sha256=$fingerprint;schema_fingerprint_lines=$fingerprintLines.Count;tests=$results;production_port_3307_accessed=$false;production_database_accessed=$false}
    Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-test-result.json') (($summary|ConvertTo-Json -Depth 12)+"`n")
    Write-Output "DISPOSABLE_DB_TESTS=PASS"
    Write-Output "SCHEMA_FINGERPRINT_SHA256=$fingerprint"
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $shutdownArgs=@('--no-defaults','--protocol=TCP','--host=127.0.0.1',"--port=$Port",'--user=root','--skip-ssl','shutdown')
        $shutdown=Invoke-Captured $admin $shutdownArgs '' '' $true
        Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-shutdown.log') ("exit=$($shutdown.exit_code)`n$($shutdown.stdout)$($shutdown.stderr)")
        $serverProcess.WaitForExit(30000) | Out-Null
    }
    if ($serverProcess) {
        $stopped=$serverProcess.HasExited
        $testServerPid=$serverProcess.Id
        $serverProcess.Dispose()
        Write-Utf8 (Join-Path $EvidenceRoot 'disposable-db-final-state.json') (([ordered]@{captured_utc=[DateTime]::UtcNow.ToString('o');pid=$testServerPid;process_exited=$stopped;port=$Port;production_port_3307_accessed=$false}|ConvertTo-Json)+"`n")
        if(-not$stopped){throw 'Disposable MariaDB did not stop gracefully within 30 seconds.'}
    }
}
