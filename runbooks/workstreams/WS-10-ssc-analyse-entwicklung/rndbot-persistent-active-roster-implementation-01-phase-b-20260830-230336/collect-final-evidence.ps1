$ErrorActionPreference='Stop'
$runRoot=$PSScriptRoot
$source='C:\TW\rndbot-roster-phase-b-20260830-230336\source'
$build='C:\TW\rndbot-roster-phase-b-20260830-230336\build-clean-5'
$exe=Join-Path $source 'bin\Release\mangosd.exe'
$pdb=Join-Path $source 'bin\Release\mangosd.pdb'
$cache=Join-Path $build 'CMakeCache.txt'
$evidence=Join-Path $runRoot 'evidence';$artifacts=Join-Path $runRoot 'artifacts';$copies=Join-Path $runRoot 'source-copies'
$metadataPath=Join-Path $evidence 'final-evidence-package.json'
if(Test-Path -LiteralPath $metadataPath){throw "Refusing overwrite: $metadataPath"}

$sourceFiles=@(
 'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp','src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h',
 'src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp','src/modules/PlayerBots/playerbot/PlayerbotMgr.h',
 'src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp','src/modules/PlayerBots/playerbot/RandomPlayerbotFactory.cpp',
 'src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp','src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.h',
 'src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in',
 'src/modules/PlayerBots/playerbot/PersistentActiveRoster.cpp','src/modules/PlayerBots/playerbot/PersistentActiveRoster.h',
 'src/modules/PlayerBots/playerbot/PersistentActiveRosterDatabase.cpp','src/modules/PlayerBots/playerbot/PersistentActiveRosterDatabase.h',
 'sql/character_updates/20260830230336_ai_playerbot_persistent_active_roster.sql',
 'src/modules/PlayerBots/sql/other/20260830230336_ai_playerbot_persistent_active_roster_rollback.sql',
 'src/modules/PlayerBots/tests/CMakeLists.txt','src/modules/PlayerBots/tests/persistent_active_roster_tests.cpp',
 'src/modules/PlayerBots/tests/run-tests.ps1','src/modules/PlayerBots/tests/fixtures/empty-snapshot-v1.txt',
 'src/modules/PlayerBots/tests/fixtures/initialize-request-v1.txt'
)

function FileRecord([string]$path){$item=Get-Item -LiteralPath $path;[ordered]@{path=$item.FullName;size=[int64]$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;created_utc=$item.CreationTimeUtc.ToString('o');last_write_utc=$item.LastWriteTimeUtc.ToString('o');file_version=$item.VersionInfo.FileVersion;product_version=$item.VersionInfo.ProductVersion}}
function Read-U16($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt16()}
function Read-U32($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt32()}
function Read-U64($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt64()}
function PeRecord([string]$path){
 $stream=[IO.File]::OpenRead($path);$reader=[IO.BinaryReader]::new($stream)
 try{$pe=Read-U32 $reader 0x3c;$coff=$pe+4;$sectionsCount=Read-U16 $reader ($coff+2);$stamp=Read-U32 $reader ($coff+4);$optionalSize=Read-U16 $reader ($coff+16);$optional=$coff+20;$is64=(Read-U16 $reader $optional)-eq0x20b;$directory=$optional+$(if($is64){112}else{96});$debugRva=Read-U32 $reader ($directory+48);$debugSize=Read-U32 $reader ($directory+52);$sectionTable=$optional+$optionalSize;$debugOffset=$null
  for($i=0;$i-lt$sectionsCount;$i++){$offset=$sectionTable+40*$i;$va=Read-U32 $reader ($offset+12);$vs=Read-U32 $reader ($offset+8);$rs=Read-U32 $reader ($offset+16);$rp=Read-U32 $reader ($offset+20);$extent=[math]::Max([uint64]$vs,[uint64]$rs);if($debugRva-ge$va-and$debugRva-lt([uint64]$va+$extent)){$debugOffset=[uint64]$rp+([uint64]$debugRva-[uint64]$va)}}
  $codeView=@();if($null-ne$debugOffset){for($i=0;$i-lt[math]::Floor($debugSize/28);$i++){$entry=$debugOffset+28*$i;if((Read-U32 $reader ($entry+12))-ne2){continue};$size=Read-U32 $reader ($entry+16);$raw=Read-U32 $reader ($entry+24);$reader.BaseStream.Position=$raw;$sig=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(4));if($sig-ne'RSDS'){continue};$guid=[Guid]::new($reader.ReadBytes(16));$age=$reader.ReadUInt32();$bytes=[Collections.Generic.List[byte]]::new();while($reader.BaseStream.Position-lt$reader.BaseStream.Length){$b=$reader.ReadByte();if($b-eq0){break};$bytes.Add($b)};$codeView+=[pscustomobject]@{signature=$sig;guid=$guid.ToString('D').ToUpperInvariant();age=$age;pdb_path=[Text.Encoding]::UTF8.GetString($bytes.ToArray());size=$size}}}
  [ordered]@{machine=('0x{0:X4}'-f(Read-U16 $reader $coff));linker_timestamp_unix=$stamp;linker_timestamp_utc=[DateTimeOffset]::FromUnixTimeSeconds($stamp).UtcDateTime.ToString('o');pe32_plus=$is64;image_base=('0x{0:X16}'-f(Read-U64 $reader ($optional+24)));size_of_image=Read-U32 $reader ($optional+56);codeview=$codeView}
 }finally{$reader.Dispose();$stream.Dispose()}
}
function Invoke-Git([string[]]$arguments){$safe=$source.Replace('\','/');$out=& 'Y:\appentwicklung\Git\cmd\git.exe' -c "safe.directory=$safe" -C $source @arguments 2>&1;if($LASTEXITCODE-ne0){throw "git failed: $($arguments-join' ')"};@($out|ForEach-Object{$_.ToString()})}

foreach($relative in $sourceFiles){$from=Join-Path $source ($relative.Replace('/','\'));if(-not(Test-Path -LiteralPath $from -PathType Leaf)){throw "Missing source input: $relative"};$to=Join-Path $copies ($relative.Replace('/','\'));$parent=Split-Path -Parent $to;[void](New-Item -ItemType Directory -Path $parent -Force);Copy-Item -LiteralPath $from -Destination $to}
Copy-Item -LiteralPath $exe -Destination (Join-Path $artifacts 'mangosd.exe')
Copy-Item -LiteralPath $pdb -Destination (Join-Path $artifacts 'mangosd.pdb')
Copy-Item -LiteralPath $cache -Destination (Join-Path $evidence 'CMakeCache.txt')

$contractZip='C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\RNDBOT-PERSISTENT-ACTIVE-ROSTER-ANALYSIS-01-PACKAGE-CLOSURE-R1-20260830-223307.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($contractZip)
try{$entry=$zip.Entries|Where-Object{$_.FullName-eq'IMPLEMENTATION-CONTRACT-ADDENDUM.md'}|Select-Object -First 1;if(-not$entry){throw 'Contract addendum not found in R1 ZIP'};$target=Join-Path $runRoot 'IMPLEMENTATION-CONTRACT-ADDENDUM.md';$input=$entry.Open();$output=[IO.File]::Create($target);try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}}finally{$zip.Dispose()}
if((Get-FileHash -LiteralPath (Join-Path $runRoot 'IMPLEMENTATION-CONTRACT-ADDENDUM.md') -Algorithm SHA256).Hash-ne'203855E99A7ED2D9B560769E703804CBE4C3AC2594B7C2BFEEED34236452294B'){throw 'Contract addendum hash mismatch'}

$patchLines=Invoke-Git @('diff','--binary','--no-ext-diff');[IO.File]::WriteAllLines((Join-Path $evidence 'tracked-changes.patch'),$patchLines,[Text.UTF8Encoding]::new($false))
$status=Invoke-Git @('status','--short','--untracked-files=all');[IO.File]::WriteAllLines((Join-Path $evidence 'isolated-git-status.txt'),$status,[Text.UTF8Encoding]::new($false))
$head=([string](Invoke-Git @('rev-parse','HEAD'))).Trim();$tree=([string](Invoke-Git @('rev-parse','HEAD^{tree}'))).Trim()
$exeBytes=[IO.File]::ReadAllBytes($exe);$ascii=[Text.Encoding]::ASCII.GetString($exeBytes);$embeddedRevision=$ascii.Contains('42b8a7f742548793910f')
$buildLog=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'logs\clean-5\build.stdout.log');$buildErr=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'logs\clean-5\build.stderr.log');$configureErr=Get-Content -Raw -LiteralPath (Join-Path $runRoot 'logs\clean-5\configure.stderr.log')
$compilerWarningOccurrences=@(Select-String -LiteralPath (Join-Path $runRoot 'logs\clean-5\build.stdout.log') -Pattern ': warning [A-Z][0-9]+:' | ForEach-Object{$_.Line.Trim()})
$cmakeWarningOccurrences=@(Select-String -LiteralPath (Join-Path $runRoot 'logs\clean-5\configure.stderr.log') -Pattern '^CMake Warning' | ForEach-Object{$_.Line.Trim()})
$warningOccurrences=@($compilerWarningOccurrences)+@($cmakeWarningOccurrences)
$warnings=@($warningOccurrences|Sort-Object -Unique)
$warningFamilies=@(
 $compilerWarningOccurrences|ForEach-Object{if($_ -match ': warning ([A-Z][0-9]+):'){[string]$Matches[1]}}|Sort-Object -Unique
 $cmakeWarningOccurrences|ForEach-Object{'CMAKE_POLICY_CMP0167'}
)|Sort-Object -Unique
$errors=@(Select-String -LiteralPath (Join-Path $runRoot 'logs\clean-5\build.stdout.log') -Pattern ': error [A-Z][0-9]+:' | ForEach-Object{$_.Line.Trim()}|Sort-Object -Unique)

$records=@();foreach($relative in $sourceFiles){$record=FileRecord (Join-Path $source ($relative.Replace('/','\')));$record.relative_path=$relative;$records+=[pscustomobject]$record}
$final=[ordered]@{
 task='RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B';captured_utc=[DateTime]::UtcNow.ToString('o');result='BLOCKED'
 blocker='Disposable MariaDB test unavailable: 127.0.0.1:3307 refused the connection; process control is forbidden.'
 baseline=[ordered]@{commit=$head;tree=$tree;detached=$true;contract_zip=FileRecord $contractZip;contract_addendum=FileRecord (Join-Path $runRoot 'IMPLEMENTATION-CONTRACT-ADDENDUM.md')}
 candidate=[ordered]@{exe=FileRecord $exe;pdb=FileRecord $pdb;pe=PeRecord $exe;embedded_revision_42b8a7f742548793910f=$embeddedRevision;started=$false;installed=$false}
 build=[ordered]@{result='PASS';build_directory=$build;cmake_cache=FileRecord $cache;target='Release/mangosd only';warnings=$warnings;warning_families=$warningFamilies;errors=$errors;compiler_warning_occurrence_count=$compilerWarningOccurrences.Count;cmake_warning_block_count=$cmakeWarningOccurrences.Count;warning_occurrence_count=$warningOccurrences.Count;unique_warning_line_count=$warnings.Count;error_count=$errors.Count}
 tests=[ordered]@{final_run_1=FileRecord (Join-Path $runRoot 'logs\tests-authoritative-run-1.log');final_run_2=FileRecord (Join-Path $runRoot 'logs\tests-authoritative-run-2.log');result='PASS';run_count=2}
 static_gate=Get-Content -Raw -LiteralPath (Join-Path $evidence 'static-gate-post-build.json')|ConvertFrom-Json
 disposable_db=Get-Content -Raw -LiteralPath (Join-Path $evidence 'disposable-db-test.json')|ConvertFrom-Json
 source_files=$records
 prohibitions=[ordered]@{production_source_changed=$false;production_exe_changed=$false;active_config_changed=$false;active_database_accessed=$false;deployment_performed=$false;process_control_performed=$false;candidate_started=$false;bot_login=$false;game_chat=$false;llm_bridge_started=$false;ollama_accessed=$false;inference_performed=$false;phase_c_started=$false}
 phase_c_gate='AWAIT_SEPARATE_PACKAGE_AUDIT'
}
[IO.File]::WriteAllText($metadataPath,($final|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))

$matrix=@(
 "check`tresult`tevidence",
 "schema-create-and-rollback`tBLOCKED`t127.0.0.1:3307 connection refused; no schema created",
 "canonical-request-and-snapshot-vectors`tPASS`tlogs/tests-authoritative-run-1.log; logs/tests-authoritative-run-2.log",
 "empty-snapshot-68-bytes-and-sha256`tPASS`tBA46C4A526EE8BBE3A640492A1167DE0A449D382FE129891BF38BA89E3DF293E",
 "operation-id-idempotency-and-mismatch`tPASS`tfake-store tests",
 "transaction-failure-preserves-current`tPASS`tfailure-injection fake-store test",
 "bad-ordinal-duplicate-guid-bad-hash`tPASS`tparser/startup tests",
 "restart-identical-guid-vector`tPASS`tshared fake-store restart test",
 "lease-rotation-population-no-membership-change`tPASS`tpolicy tests plus isolated source gate",
 "login-failure-degraded-no-replacement`tPASS`tDEGRADED policy test and source guard",
 "factory-delete-reset-logout-protection`tPASS`tstatic gate and source guards",
 "grouped-bot-lease-protection`tPASS`tvalue/policy test only; no live server claim",
 "append-only-50-to-100-prefix`tPASS`t100-member vector test",
 "feature-disabled-legacy-path`tPASS`tdefault-off static gate and disabled service test",
 "async-combination-fail-closed`tPASS`tASYNC_LOGIN_UNSUPPORTED test",
 "canonical-remove-replace-order-and-nonempty-actor`tPASS`tlogs/tests-authoritative-run-1.log; logs/tests-authoritative-run-2.log",
 "desired-available-online-state-separation`tPASS`tlogs/tests-authoritative-run-1.log; logs/tests-authoritative-run-2.log",
 "two-reproducible-full-test-runs`tPASS`tlogs/tests-authoritative-run-1.log; logs/tests-authoritative-run-2.log",
 "static-scope-and-production-protection`tPASS`tevidence/static-gate-post-build.json",
 "clean-release-mangosd-build`tPASS`tlogs/clean-5/*"
)
[IO.File]::WriteAllLines((Join-Path $runRoot 'TEST-MATRIX.tsv'),$matrix,[Text.UTF8Encoding]::new($false))
'FINAL_EVIDENCE_COLLECTED=YES'
