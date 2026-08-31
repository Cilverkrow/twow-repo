[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$RunRoot='C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848'
$Evidence=Join-Path $RunRoot 'evidence'
$Repo='C:\TW\ComTW\source'
$Server='C:\TW\ComTW\server'
$Logs='C:\TW\ComTW\logs'
function Write-NewUtf8([string]$Path,[AllowEmptyString()][string]$Content){if(Test-Path -LiteralPath $Path){throw "Refusing to overwrite $Path"};[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function Write-NewJson([string]$Name,$Value){Write-NewUtf8 (Join-Path $Evidence $Name) (($Value|ConvertTo-Json -Depth 12)+"`n")}
function Invoke-Git([string[]]$Arguments){$o=& git -c safe.directory=C:/TW/ComTW/source -C $Repo @Arguments 2>&1;if($LASTEXITCODE-ne 0){throw "git failed: $($o -join "`n")"};$o -join "`n"}
function Get-HashRecord([string]$Path){$i=Get-Item -LiteralPath $Path;[ordered]@{path=$i.FullName;size_bytes=$i.Length;creation_utc=$i.CreationTimeUtc.ToString('o');last_write_utc=$i.LastWriteTimeUtc.ToString('o');sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}}
function Get-PdbIdentity([string]$Path){
    $b=[IO.File]::ReadAllBytes($Path)
    $magic=[Text.Encoding]::ASCII.GetString($b,0,32)
    if(-not $magic.StartsWith('Microsoft C/C++ MSF 7.00')){throw "Unsupported PDB container: $Path"}
    $block=[BitConverter]::ToUInt32($b,32);$dirBytes=[BitConverter]::ToUInt32($b,44);$blockMap=[BitConverter]::ToUInt32($b,52)
    $dirBlockCount=[Math]::Ceiling($dirBytes/$block)
    $dir=[byte[]]::new($dirBlockCount*$block)
    for($i=0;$i-lt $dirBlockCount;$i++){$page=[BitConverter]::ToUInt32($b,$blockMap*$block+$i*4);[Array]::Copy($b,$page*$block,$dir,$i*$block,$block)}
    $streamCount=[BitConverter]::ToUInt32($dir,0);$sizes=@();for($i=0;$i-lt $streamCount;$i++){$sizes += [BitConverter]::ToUInt32($dir,4+$i*4)}
    $cursor=4+$streamCount*4;$streamPages=@()
    for($s=0;$s-lt $streamCount;$s++){
        $pages=@();if($sizes[$s]-ne 0xFFFFFFFF){$count=[Math]::Ceiling($sizes[$s]/$block);for($j=0;$j-lt $count;$j++){$pages += [BitConverter]::ToUInt32($dir,$cursor);$cursor+=4}}
        $streamPages += ,$pages
    }
    $size=$sizes[1];$data=[byte[]]::new([int]$size);$written=0
    foreach($page in $streamPages[1]){$take=[Math]::Min($block,$size-$written);[Array]::Copy($b,$page*$block,$data,$written,$take);$written+=$take}
    $g=[byte[]]::new(16);[Array]::Copy($data,12,$g,0,16)
    [ordered]@{container='MSF 7.00';pdb_stream_version=[BitConverter]::ToUInt32($data,0);signature=[BitConverter]::ToUInt32($data,4);age=[BitConverter]::ToUInt32($data,8);guid=([Guid]::new($g)).ToString('D')}
}

$latestRecord=Get-Content -Raw -LiteralPath (Join-Path $Evidence 'production-start-log-evidence.json')|ConvertFrom-Json
$logPath=$latestRecord.latest_successful.file.path
$lines=[IO.File]::ReadAllLines($logPath)
$revisionRows=@()
for($i=0;$i-lt $lines.Count;$i++){
    if($lines[$i]-match 'INSERT INTO uptime' -and $lines[$i]-match "'([0-9a-f]{20})'\s*\)\s*$"){$revisionRows += [pscustomobject][ordered]@{line=$i+1;timestamp=($lines[$i].Substring(0,[Math]::Min(19,$lines[$i].Length)));revision=$Matches[1]}}
}
$donationLog=$null
foreach($candidate in (Get-ChildItem -LiteralPath $Logs -Filter 'server_*.log' -File|Sort-Object LastWriteTimeUtc -Descending)){
    $candidateLines=[IO.File]::ReadAllLines($candidate.FullName)
    if($candidateLines -match 'donation_point_progress'){$donationLog=$candidate;$donationLines=$candidateLines;break}
}
$donationEvents=@()
if($donationLog){for($i=0;$i-lt $donationLines.Count;$i++){if($donationLines[$i]-notmatch 'donation_point_progress'){continue};$op=if($donationLines[$i]-match 'INSERT INTO'){ 'UPSERT' }elseif($donationLines[$i]-match 'SELECT'){ 'SELECT' }else{'OTHER'};$donationEvents += [pscustomobject][ordered]@{line=$i+1;timestamp=$donationLines[$i].Substring(0,[Math]::Min(19,$donationLines[$i].Length));operation=$op}}}
Write-NewJson 'production-log-revision-and-donation-evidence.json' ([ordered]@{
    latest_successful_log=Get-HashRecord $logPath
    uptime_revision_rows=$revisionRows
    donation_activity_log=if($donationLog){Get-HashRecord $donationLog.FullName}else{$null}
    donation_activity=$donationEvents
    redaction='SQL literals, realm/account identifiers, and values other than the embedded 20-hex revision are omitted.'
})

$correctSpecs=@(
    [pscustomobject]@{path='src/modules/PlayerBots/playerbot/strategy/triggers/RpgTriggers.cpp';patterns=@('LLMEnabled','LLMRpgAIChatChance')},
    [pscustomobject]@{path='src/game/World.cpp';patterns=@('World::Update\(','UpdateSessions','donation_point_progress')},
    [pscustomobject]@{path='src/game/WorldSession.h';patterns=@('World::UpdateSessions','packet')}
)
$correct=@()
foreach($spec in $correctSpecs){$content=Invoke-Git @('show',"HEAD:$($spec.path)");$ls=$content -split "`n";$hits=@();for($i=0;$i-lt $ls.Count;$i++){foreach($p in $spec.patterns){if($ls[$i]-match $p){$hits += [pscustomobject][ordered]@{line=$i+1;pattern=$p;text=$ls[$i].TrimEnd()};break}}};$correct += [pscustomobject][ordered]@{path=$spec.path;head_blob=(Invoke-Git @('rev-parse',"HEAD:$($spec.path)")).Trim();matches=$hits}}
Write-NewJson 'integration-points-path-correction.json' ([ordered]@{replaces_missing_paths=@('src/modules/PlayerBots/playerbot/strategy/values/RpgTriggers.cpp','src/game/World/World.cpp','src/game/Server/WorldSession.h');correct_files=$correct})

$schemaGrep=Invoke-Git @('grep','-n','-e','character_inventory_copy','-e','donation_point_progress','HEAD','--','src')
Write-NewUtf8 (Join-Path $Evidence 'schema-code-point-matches.txt') ($schemaGrep+"`n")
$rootCmake=(Invoke-Git @('show','HEAD:CMakeLists.txt'))-split "`n";$ctx=@();for($i=337;$i-lt [Math]::Min(371,$rootCmake.Count);$i++){$ctx += ('{0,6}: {1}' -f ($i+1),$rootCmake[$i])}
Write-NewUtf8 (Join-Path $Evidence 'cmake-revision-generation-context.txt') (($ctx -join "`n")+"`n")

$exeData=Get-Content -Raw -LiteralPath (Join-Path $Evidence 'exe-evidence.json')|ConvertFrom-Json
$serverPdb=Join-Path $Server 'mangosd.pdb';$sourcePdb=Join-Path $Repo 'bin\Release\mangosd.pdb'
$serverId=Get-PdbIdentity $serverPdb;$sourceId=Get-PdbIdentity $sourcePdb
Write-NewJson 'pdb-identity-verification.json' ([ordered]@{
    production_exe_codeview=$exeData.production_pe.codeview
    server_pdb=[ordered]@{file=Get-HashRecord $serverPdb;identity=$serverId;matches_production_exe=($serverId.guid-eq $exeData.production_pe.codeview.guid -and $serverId.age-eq $exeData.production_pe.codeview.age)}
    later_source_pdb=[ordered]@{file=Get-HashRecord $sourcePdb;identity=$sourceId;matches_production_exe=($sourceId.guid-eq $exeData.production_pe.codeview.guid -and $sourceId.age-eq $exeData.production_pe.codeview.age)}
})

$launcher=Join-Path $Server 'start-mangosd.bat'
Write-NewJson 'production-launcher-evidence.json' ([ordered]@{file=Get-HashRecord $launcher;content=[IO.File]::ReadAllText($launcher);interpretation='The launcher changes to its own directory and invokes mangosd.exe from that directory.'})
Write-Output 'Supplement captured.'
