param(
    [string]$Runbook = 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-20260830-173121',
    [string]$Source = 'C:\TW\ssc-llm-phase-b-20260830-173121\source',
    [string]$Build = 'C:\TW\ssc-llm-phase-b-20260830-173121\build-final-r2'
)

$ErrorActionPreference = 'Stop'
$candidate = '42b8a7f742548793910fe8880463aeeb71627fb9'
$tree = 'b2cf4e38fd288a53f61b9f2350f74caa85d606ab'
$production = 'C:\TW\ComTW\source'
$server = 'C:\TW\ComTW\server'
$exe = Join-Path $Source 'bin\Release\mangosd.exe'
$pdb = Join-Path $Source 'bin\Release\mangosd.pdb'
$cache = Join-Path $Build 'CMakeCache.txt'
$artifacts = Join-Path $Runbook 'artifacts'
$evidence = Join-Path $Runbook 'evidence'
$copies = Join-Path $Runbook 'source-copies'

$files = @(
    'src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp',
    'src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h',
    'src/modules/PlayerBots/playerbot/PlayerbotAI.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotAI.h',
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp',
    'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h',
    'src/modules/PlayerBots/playerbot/PlayerbotScripts.cpp',
    'src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in',
    'src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp'
)

foreach ($required in @($exe,$pdb,$cache)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing final build input: $required" }
}
foreach ($dir in @($artifacts,$evidence,$copies)) { [void](New-Item -ItemType Directory -Force -Path $dir) }

function Invoke-Captured([string]$File,[string[]]$Arguments,[string]$WorkingDirectory) {
    $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$File; $psi.WorkingDirectory=$WorkingDirectory
    $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync(); $process.WaitForExit()
    $record=[ordered]@{exit_code=$process.ExitCode;stdout=$outTask.GetAwaiter().GetResult().TrimEnd();stderr=$errTask.GetAwaiter().GetResult().TrimEnd()}
    $process.Dispose(); return $record
}
function Git([string]$Root,[string[]]$Arguments) {
    $safe=$Root.Replace('\','/')
    $result=Invoke-Captured 'git.exe' (@('-c',"safe.directory=$safe",'-C',$Root)+$Arguments) $Root
    if($result.exit_code -ne 0){throw "git failed: $($Arguments -join ' ')`n$($result.stderr)"}
    return $result.stdout
}
function FileRecord([string]$Path) {
    $item=Get-Item -LiteralPath $Path
    return [ordered]@{path=$item.FullName;size=[int64]$item.Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash;created_utc=$item.CreationTimeUtc.ToString('o');last_write_utc=$item.LastWriteTimeUtc.ToString('o');file_version=$item.VersionInfo.FileVersion;product_version=$item.VersionInfo.ProductVersion}
}
function Read-U16($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt16()}
function Read-U32($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt32()}
function Read-U64($reader,[int64]$offset){$reader.BaseStream.Position=$offset;$reader.ReadUInt64()}
function PeRecord([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $reader=[IO.BinaryReader]::new($stream)
    try {
        if((Read-U16 $reader 0)-ne 0x5A4D){throw 'Missing MZ'}; $pe=Read-U32 $reader 0x3c
        if((Read-U32 $reader $pe)-ne 0x4550){throw 'Missing PE'}; $coff=$pe+4
        $sectionsCount=Read-U16 $reader ($coff+2); $stamp=Read-U32 $reader ($coff+4); $optionalSize=Read-U16 $reader ($coff+16)
        $optional=$coff+20; $magic=Read-U16 $reader $optional; $is64=$magic-eq 0x20b; $directory=$optional+$(if($is64){112}else{96})
        $debugRva=Read-U32 $reader ($directory+48); $debugSize=Read-U32 $reader ($directory+52); $sectionTable=$optional+$optionalSize; $sections=@()
        for($i=0;$i-lt$sectionsCount;$i++){$off=$sectionTable+40*$i;$reader.BaseStream.Position=$off;$name=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)).Trim([char]0);$sections += [pscustomobject]@{name=$name;virtual_size=Read-U32 $reader ($off+8);virtual_address=Read-U32 $reader ($off+12);raw_size=Read-U32 $reader ($off+16);raw_pointer=Read-U32 $reader ($off+20)}}
        $debugOffset=$null; foreach($s in $sections){$extent=[math]::Max([uint64]$s.virtual_size,[uint64]$s.raw_size);if($debugRva -ge $s.virtual_address -and $debugRva -lt ([uint64]$s.virtual_address+$extent)){$debugOffset=[uint64]$s.raw_pointer+([uint64]$debugRva-[uint64]$s.virtual_address);break}}
        $codeView=@(); if($null-ne$debugOffset){for($i=0;$i-lt[math]::Floor($debugSize/28);$i++){$d=$debugOffset+28*$i;if((Read-U32 $reader ($d+12))-eq 2){$size=Read-U32 $reader ($d+16);$raw=Read-U32 $reader ($d+24);$reader.BaseStream.Position=$raw;$sig=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(4));if($sig-eq'RSDS'){$guid=[Guid]::new($reader.ReadBytes(16));$age=$reader.ReadUInt32();$bytes=[Collections.Generic.List[byte]]::new();while($reader.BaseStream.Position-lt$reader.BaseStream.Length){$b=$reader.ReadByte();if($b-eq0){break};$bytes.Add($b)};$codeView += [pscustomobject]@{signature=$sig;guid=$guid.ToString('D').ToUpperInvariant();age=$age;pdb_path=[Text.Encoding]::UTF8.GetString($bytes.ToArray());size=$size}}}}}
        return [ordered]@{machine=('0x{0:X4}'-f(Read-U16 $reader $coff));linker_timestamp_unix=$stamp;linker_timestamp_utc=[DateTimeOffset]::FromUnixTimeSeconds($stamp).UtcDateTime.ToString('o');pe32_plus=$is64;image_base=('0x{0:X16}'-f(Read-U64 $reader ($optional+24)));size_of_image=Read-U32 $reader ($optional+56);codeview=$codeView}
    } finally {$reader.Dispose();$stream.Dispose()}
}

$head=(Git $Source @('rev-parse','HEAD')).Trim(); $actualTree=(Git $Source @('rev-parse','HEAD^{tree}')).Trim()
if($head-ne$candidate-or$actualTree-ne$tree){throw 'Baseline identity mismatch'}
$status=Git $Source @('status','--short','--untracked-files=all')
$changed=@($status -split "`r?`n" | Where-Object {$_} | ForEach-Object {$_.Substring(3).Replace('\','/')} | Where-Object {$_ -notlike 'bin/*'} | Sort-Object -Unique)
if(@(Compare-Object ($files|Sort-Object) $changed).Count-ne0){throw "Unexpected production file set: $($changed -join ', ')"}

$trackedDiff=Git $Source @('diff','--binary','HEAD','--')
$fullDiff=$trackedDiff+$(if($trackedDiff){"`n"}else{''})
foreach($newFile in @('src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.cpp','src/modules/PlayerBots/playerbot/ExternalLLMBridgeService.h')){
    $entry=Invoke-Captured 'git.exe' @('-c','safe.directory=C:/TW/ssc-llm-phase-b-20260830-173121/source','-C',$Source,'diff','--no-index','--binary','--','/dev/null',$newFile) $Source
    if($entry.exit_code-ne1){throw "Unable to create new-file diff: $newFile"}; $fullDiff += $entry.stdout+"`n"
}
[IO.File]::WriteAllText((Join-Path $evidence 'full-git-diff.patch'),$fullDiff,[Text.UTF8Encoding]::new($false))

foreach($relative in $files){$destination=Join-Path $copies $relative;$parent=Split-Path -Parent $destination;[void](New-Item -ItemType Directory -Force -Path $parent);Copy-Item -LiteralPath (Join-Path $Source $relative) -Destination $destination -Force;if((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Source $relative)).Hash-ne(Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash){throw "Source copy mismatch: $relative"}}

$artifactExe=Join-Path $artifacts 'mangosd.exe'; Copy-Item -LiteralPath $exe -Destination $artifactExe -Force
if((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash-ne(Get-FileHash -Algorithm SHA256 -LiteralPath $artifactExe).Hash){throw 'EXE copy mismatch'}
Copy-Item -LiteralPath $cache -Destination (Join-Path $evidence 'CMakeCache.txt') -Force

$productionBefore=@(
' M src/modules/PlayerBots/CMakeLists.txt',
' M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp',
' M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h',
' M src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp',
'?? bin/Release/MoveMapGen.pdb',
'?? bin/Release/mangosd.pdb',
'?? bin/Release/mapextractor.pdb',
'?? bin/Release/realmd.pdb',
'?? bin/Release/vmap_assembler.pdb',
'?? bin/Release/vmapextractor.pdb')
$productionAfterText=Git $production @('status','--short','--untracked-files=all'); $productionAfter=@($productionAfterText -split "`r?`n"|Where-Object{$_})
[IO.File]::WriteAllLines((Join-Path $evidence 'production-status-before.txt'),$productionBefore,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $evidence 'production-status-after.txt'),$productionAfterText+"`n",[Text.UTF8Encoding]::new($false))

$buildLog=Join-Path $Runbook 'logs\build-final-r2.combined.log'
$configureLog=Join-Path $Runbook 'logs\configure-final-r2.stdout.log'
$diagnostics=@(Select-String -LiteralPath $buildLog -Pattern '(?i)warning (C|LNK)[0-9]+|CMake Warning|error (C|LNK)[0-9]+|fatal error' | ForEach-Object {$_.Line})
[IO.File]::WriteAllLines((Join-Path $evidence 'final-build-diagnostics.txt'),$diagnostics,[Text.UTF8Encoding]::new($false))

$bytes=[IO.File]::ReadAllBytes($exe); $ascii=[Text.Encoding]::Latin1.GetString($bytes)
$symbolic=Invoke-Captured 'git.exe' @('-c','safe.directory=C:/TW/ssc-llm-phase-b-20260830-173121/source','-C',$Source,'symbolic-ref','-q','HEAD') $Source
$record=[ordered]@{
    schema_version=1;task='SSC-LLM-PRODUCTION-BRIDGE-01-PHASE-B';generated_utc=(Get-Date).ToUniversalTime().ToString('o')
    baseline=[ordered]@{commit=$head;tree=$actualTree;detached=($symbolic.exit_code-ne0);submodules=((Git $Source @('submodule','status')).Trim())}
    a_r2_zip=FileRecord 'C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-a-r2-20260830-170407-deliverables.zip'
    planned_production_files=$files;unplanned_production_files=@();isolated_status=@($status-split"`r?`n"|Where-Object{$_})
    build=[ordered]@{target='Release/mangosd only';generator='Visual Studio 17 2022 x64';cmake_version=(& 'C:\Program Files\CMake\bin\cmake.exe' --version|Select-Object -First 1);msvc='19.44.35228 / tools 14.44.35207';windows_sdk='10.0.26100.0';parallel_projects=2;cl_mp_count=2;cmake_cache=FileRecord $cache;configure_log=FileRecord $configureLog;final_log=FileRecord $buildLog;diagnostics=$diagnostics;error_count=@($diagnostics|Where-Object{$_-match'(?i)error'}).Count}
    artifacts=[ordered]@{executable=FileRecord $exe;deliverable_executable=FileRecord $artifactExe;pdb=FileRecord $pdb;pe=PeRecord $exe;embedded_revision_present=($ascii.Contains('42b8a7f742548793910f'));embedded_release_noop_present=($ascii.Contains('LLM generation disabled in this build'))}
    production=[ordered]@{source_status_before=$productionBefore;source_status_after=$productionAfter;source_status_unchanged=(($productionBefore-join"`n")-eq($productionAfter-join"`n"));executable=FileRecord (Join-Path $server 'mangosd.exe');mangosd_config=FileRecord (Join-Path $server 'mangosd.conf');playerbot_config=FileRecord (Join-Path $server 'aiplayerbot.conf')}
    prohibited_actions=[ordered]@{real_bridge_started=$false;ollama_accessed=$false;inference_performed=$false;game_chat_sent=$false;database_accessed=$false;deployment_performed=$false;phase_c_started=$false;active_config_changed=$false;production_exe_changed=$false}
}
if($record.a_r2_zip.sha256-ne'8D62769D838C1B359B590F3797EC9C17D809EAC1F1B907A49BF4A9644907625F'){throw 'A-R2 ZIP pin mismatch'}
if(-not$record.production.source_status_unchanged){throw 'Production source status changed'}
if($record.production.executable.sha256-ne'FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC'){throw 'Production EXE mismatch'}
if($record.production.mangosd_config.sha256-ne'C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D'){throw 'mangosd.conf mismatch'}
if($record.production.playerbot_config.sha256-ne'490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF'){throw 'aiplayerbot.conf mismatch'}
if($record.build.error_count-ne0-or-not$record.artifacts.embedded_revision_present){throw 'Final build provenance gate failed'}
[IO.File]::WriteAllText((Join-Path $evidence 'final-evidence.json'),($record|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
$record|ConvertTo-Json -Depth 4
