$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$evidence=Join-Path $runbook 'evidence'
$indexPath=Join-Path $runbook 'deliverable-index.json'
$sumsPath=Join-Path $runbook 'SHA256SUMS.txt'
$zipPath='C:\TW\ComTW\runbooks\SSC-SOURCE-BASELINE-02C-BLOCKED-20260830-001200.zip'
$metadataPath=$zipPath+'.metadata.json'
foreach($path in @($indexPath,$sumsPath,$zipPath,$metadataPath)){if(Test-Path -LiteralPath $path){throw "Refusing overwrite: $path"}}
$decision=Get-Content -Raw -LiteralPath (Join-Path $evidence 'blocked-decision.json')|ConvertFrom-Json
$action=Get-Content -Raw -LiteralPath (Join-Path $evidence 'action-phase-b-stop-mangosd.json')|ConvertFrom-Json
$finalState=Get-Content -Raw -LiteralPath (Join-Path $evidence 'runtime-state-final-before-package.json')|ConvertFrom-Json
$expectedCandidate='2C24707C587279B8E110D9B92248FFA61278005757A8A6287F9D11985CAD10AE'
$expectedProduction='FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'
$expectedMangos='C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D'
$expectedPlayerbot='490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF'
if($decision.result-ne'BLOCKED'-or$decision.blocking_phase-ne'B_CONTROLLED_STANDSTILL'){throw 'Decision gate failed'}
if($action.exit_code-eq0-or$action.stderr-notmatch'WriteConsoleInput failed'){throw 'Shutdown failure evidence gate failed'}
if((Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\b02b-20260829-222913\runbook\artifacts\mangosd.exe').Hash-ne$expectedCandidate){throw 'Candidate changed'}
if((Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\mangosd.exe').Hash-ne$expectedProduction){throw 'Production slot changed'}
if((Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\mangosd.conf').Hash-ne$expectedMangos){throw 'mangosd.conf changed'}
if((Get-FileHash -Algorithm SHA256 -LiteralPath 'C:\TW\ComTW\server\aiplayerbot.conf').Hash-ne$expectedPlayerbot){throw 'aiplayerbot.conf changed'}
if(Test-Path -LiteralPath 'C:\TW\ComTW\server\mangosd.pre-source-baseline-02c-20260829.exe'){throw 'Backup unexpectedly created'}
$mangos=@($finalState.processes|Where-Object name -eq 'mangosd.exe');$realm=@($finalState.processes|Where-Object name -eq 'realmd.exe');$db=@($finalState.processes|Where-Object{$_.name -in @('mysqld.exe','mariadbd.exe')});$ollama=@($finalState.processes|Where-Object name -eq 'ollama.exe')
if($mangos.Count-ne1-or$mangos[0].process_id-ne13808-or$realm.Count-ne1-or$realm[0].process_id-ne32260-or$db.Count-ne1-or$db[0].process_id-ne31724-or$ollama.Count-ne1-or$ollama[0].process_id-ne5528){throw 'Final process invariant failed'}
foreach($gate in @(@(8090,13808),@(3724,32260),@(3307,31724),@(11434,5528))){$matches=@($finalState.listeners|Where-Object{$_.local_port -eq $gate[0] -and $_.owning_process_id -eq $gate[1]});if($matches.Count -ne 1){throw "Final listener invariant failed for $($gate[0])"}}

function Get-Files{return @(Get-ChildItem -LiteralPath $runbook -Recurse -File|Sort-Object FullName)}
function Get-Entry($file){return [ordered]@{relative_path=[IO.Path]::GetRelativePath($runbook,$file.FullName).Replace('\','/');length=[int64]$file.Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash}}
$payload=Get-Files
$index=[ordered]@{schema_version=1;task='SSC-SOURCE-BASELINE-02C';generated_utc=(Get-Date).ToUniversalTime().ToString('o');result='BLOCKED';blocking_phase='B_CONTROLLED_STANDSTILL';blocker='WriteConsoleInput failed';candidate_hash_match=$true;production_exe_final_sha256=$expectedProduction;production_exe_unchanged=$true;backup_created=$false;phase_c_started=$false;phase_d_started=$false;rollback_copy_required=$false;mangosd_final_state='RUNNING';realmd_final_state='RUNNING';production_promotion_started=$false;ssc_llm_production_bridge_started=$false;listed_payload_count=$payload.Count;entries=@($payload|ForEach-Object{[pscustomobject](Get-Entry $_)})}
[IO.File]::WriteAllText($indexPath,($index|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
$sumFiles=Get-Files;$sumLines=@($sumFiles|ForEach-Object{$e=Get-Entry $_;"$($e.sha256) *$($e.relative_path)"});[IO.File]::WriteAllText($sumsPath,($sumLines-join"`n")+"`n",[Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($runbook,$zipPath,[IO.Compression.CompressionLevel]::Optimal,$false)
$zipHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash;$zipItem=Get-Item -LiteralPath $zipPath;$archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{$entryCount=$archive.Entries.Count;$entryNames=@($archive.Entries|ForEach-Object{$_.FullName.Replace('\','/')})}finally{$archive.Dispose()}
$finalFiles=Get-Files;if($entryCount-ne$finalFiles.Count){throw 'ZIP entry count mismatch'}
foreach($required in @('source-baseline-02c-blocked-report.md','SHA256SUMS.txt','evidence/blocked-decision.json','evidence/action-phase-b-stop-mangosd.log','evidence/final-status-block.txt')){if($entryNames -notcontains $required){throw "ZIP missing $required"}}
$metadata=[ordered]@{schema_version=1;task='SSC-SOURCE-BASELINE-02C';result='BLOCKED';zip_path=$zipPath;zip_size_bytes=[int64]$zipItem.Length;zip_entry_count=$entryCount;zip_sha256=$zipHash;generated_utc=(Get-Date).ToUniversalTime().ToString('o');production_exe_final_sha256=$expectedProduction;mangosd_final_state='RUNNING';realmd_final_state='RUNNING'}
[IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "ZIP=$zipPath";Write-Output "ZIP_SIZE_BYTES=$($zipItem.Length)";Write-Output "ZIP_ENTRY_COUNT=$entryCount";Write-Output "ZIP_SHA256=$zipHash";Write-Output "METADATA=$metadataPath";Write-Output 'FINAL_BLOCKED_GATES=PASS'
