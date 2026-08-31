$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$evidence=Join-Path $runbook 'evidence'
$output=Join-Path $evidence 'blocked-decision.json'
$statusOutput=Join-Path $evidence 'final-status-block.txt'
foreach($path in @($output,$statusOutput)){if(Test-Path -LiteralPath $path){throw "Refusing overwrite: $path"}}
$before=Get-Content -Raw -LiteralPath (Join-Path $evidence 'runtime-state-phase-b-before.json')|ConvertFrom-Json
$after=Get-Content -Raw -LiteralPath (Join-Path $evidence 'runtime-state-phase-b-blocked-after-world-shutdown-failure.json')|ConvertFrom-Json
$action=Get-Content -Raw -LiteralPath (Join-Path $evidence 'action-phase-b-stop-mangosd.json')|ConvertFrom-Json
$expectedCandidate='2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE'
$expectedProduction='FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$expectedMangosConf='C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D'
$expectedPlayerbotConf='490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF'

$beforeMangos=@($before.processes|Where-Object name -eq 'mangosd.exe');$afterMangos=@($after.processes|Where-Object name -eq 'mangosd.exe')
$beforeRealm=@($before.processes|Where-Object name -eq 'realmd.exe');$afterRealm=@($after.processes|Where-Object name -eq 'realmd.exe')
$beforeDb=@($before.processes|Where-Object{$_.name-in@('mysqld.exe','mariadbd.exe')});$afterDb=@($after.processes|Where-Object{$_.name-in@('mysqld.exe','mariadbd.exe')})
$beforeOllama=@($before.processes|Where-Object name -eq 'ollama.exe');$afterOllama=@($after.processes|Where-Object name -eq 'ollama.exe')
$listener8090=@($after.listeners|Where-Object local_port -eq 8090);$listener3724=@($after.listeners|Where-Object local_port -eq 3724);$listener3307=@($after.listeners|Where-Object local_port -eq 3307);$listener11434=@($after.listeners|Where-Object local_port -eq 11434)
$samePid={param($a,$b) return ($a.Count-eq1-and$b.Count-eq1-and$a[0].process_id-eq$b[0].process_id)}
$candidateHash=(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\b02b-20260829-222913\runbook\artifacts\mangosd.exe').Hash
$productionHash=(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\mangosd.exe').Hash
$mangosConfHash=(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\mangosd.conf').Hash
$playerbotConfHash=(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\aiplayerbot.conf').Hash
$backupExists=Test-Path -LiteralPath 'C:\TW\ComTW\server\mangosd.pre-source-baseline-02c-20260829.exe'
$candidatePdbHash=(Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\b02b-20260829-222913\runbook\artifacts\mangosd.pdb').Hash

if($action.exit_code-eq0){throw 'Expected controlled shutdown failure was not recorded'}
if($candidateHash-ne$expectedCandidate-or$productionHash-ne$expectedProduction){throw 'Final executable hash invariant failed'}
if($mangosConfHash-ne$expectedMangosConf-or$playerbotConfHash-ne$expectedPlayerbotConf){throw 'Final config invariant failed'}
if($backupExists){throw 'Backup unexpectedly exists although Phase C was not started'}
if(-not(& $samePid $beforeMangos $afterMangos)-or-not(& $samePid $beforeRealm $afterRealm)-or-not(& $samePid $beforeDb $afterDb)-or-not(& $samePid $beforeOllama $afterOllama)){throw 'A protected process PID changed during blocked Phase B'}

$statusLines=@(
    'SOURCE_BASELINE_02C_RESULT=BLOCKED',
    'CANDIDATE_HASH_MATCH=YES',
    'BACKUP_HASH_MATCH=NO',
    'STARTUP_REVISION_MATCH=NO',
    'DATABASE_STRUCTURE_ACCEPTED=NO',
    'CHARACTER_INVENTORY_COPY_ERROR=NO',
    'WORLD_STARTUP_COMPLETE=NO',
    'LISTENER_8090_READY=NO',
    'OBSERVATION_WINDOW_SECONDS=0',
    'OBSERVATION_WINDOW_PASS=NO',
    'LLM_ACTIVITY=NONE',
    'OLLAMA_PROCESS_CONTROL=NONE',
    'CONFIG_CHANGED=NO',
    'CONTROLLED_SHUTDOWN_PASS=NO',
    'ROLLBACK_TESTED=NO',
    'PRODUCTION_EXE_RESTORED=YES',
    "PRODUCTION_EXE_FINAL_SHA256=$productionHash",
    'MANGOSD_FINAL_STATE=RUNNING',
    'REALMD_FINAL_STATE=RUNNING',
    'STABLE_REVISION_RESULT=BLOCKED',
    'PRODUCTION_PROMOTION_STARTED=NO',
    'SSC_LLM_PRODUCTION_BRIDGE_STARTED=NO'
)
$record=[ordered]@{
    schema_version=1;task='SSC-SOURCE-BASELINE-02C';generated_utc=(Get-Date).ToUniversalTime().ToString('o')
    result='BLOCKED';blocking_phase='B_CONTROLLED_STANDSTILL';blocker='Existing validated shutdown helper failed before command delivery: WriteConsoleInput failed.'
    retry_performed=$false;forced_termination_performed=$false;phase_c_started=$false;phase_d_started=$false;phase_e_copy_rollback_required=$false
    candidate=[ordered]@{sha256=$candidateHash;hash_match=($candidateHash-eq$expectedCandidate);pdb_sha256=$candidatePdbHash;installed_to_production_slot=$false}
    production=[ordered]@{final_sha256=$productionHash;expected_sha256=$expectedProduction;unchanged_in_slot=$true;restored_without_copy_because_never_replaced=$true;backup_created=$backupExists}
    configs=[ordered]@{mangosd_sha256=$mangosConfHash;aiplayerbot_sha256=$playerbotConfHash;changed=$false}
    shutdown_action=$action
    state_invariants=[ordered]@{
        mangosd_same_pid=(& $samePid $beforeMangos $afterMangos);mangosd_pid=$afterMangos[0].process_id;listener_8090_still_owned_by_mangosd=($listener8090.Count-eq1-and$listener8090[0].owning_process_id-eq$afterMangos[0].process_id)
        realmd_same_pid=(& $samePid $beforeRealm $afterRealm);realmd_pid=$afterRealm[0].process_id;listener_3724_still_owned_by_realmd=($listener3724.Count-eq1-and$listener3724[0].owning_process_id-eq$afterRealm[0].process_id)
        mariadb_same_pid=(& $samePid $beforeDb $afterDb);mariadb_pid=$afterDb[0].process_id;mariadb_listener_127_0_0_1_3307=($listener3307.Count-eq1-and$listener3307[0].local_endpoint-eq'127.0.0.1:3307')
        ollama_same_pid=(& $samePid $beforeOllama $afterOllama);ollama_pid=$afterOllama[0].process_id;ollama_listener_127_0_0_1_11434=($listener11434.Count-eq1-and$listener11434[0].local_endpoint-eq'127.0.0.1:11434')
    }
    interpretation=[ordered]@{backup_hash_match_no_reason='No backup was created because Phase B blocked before Phase C.';startup_fields_no_reason='Candidate was never installed or started; startup gates were not evaluated.';production_exe_restored_yes_reason='The original production EXE never left the production slot and its final hash is exact.';character_inventory_copy_error_no_reason='No candidate startup occurred, so no such error was produced by this task.'}
    final_status=$statusLines
}
[IO.File]::WriteAllText($output,($record|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($statusOutput,($statusLines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
$statusLines
