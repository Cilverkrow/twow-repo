$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$logs='C:\TW\ComTW\logs'
$output=Join-Path $runbook 'evidence\active-production-log-tail-after-phase-b-block.txt'
$metadataOutput=Join-Path $runbook 'evidence\active-production-log-tail-after-phase-b-block.json'
foreach($path in @($output,$metadataOutput)){if(Test-Path -LiteralPath $path){throw "Refusing overwrite: $path"}}
$source=Get-ChildItem -LiteralPath $logs -File -Filter 'server_*.log'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
if($null-eq$source){throw 'No server log found'}
$captureBytes=1048576
$stream=[IO.File]::Open($source.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try{
    $lengthAtOpen=$stream.Length;$start=[math]::Max([int64]0,$lengthAtOpen-$captureBytes);$stream.Position=$start;$buffer=New-Object byte[] ([int]($lengthAtOpen-$start));$read=0
    while($read-lt$buffer.Length){$n=$stream.Read($buffer,$read,$buffer.Length-$read);if($n-le0){break};$read+=$n}
}finally{$stream.Dispose()}
if($read-ne$buffer.Length){$buffer=$buffer[0..($read-1)]}
[IO.File]::WriteAllBytes($output,$buffer)
$meta=[ordered]@{schema_version=1;captured_utc=(Get-Date).ToUniversalTime().ToString('o');source_path=$source.FullName;source_length_at_open=[int64]$lengthAtOpen;tail_start_offset=[int64]$start;captured_bytes=[int]$read;output_path=$output;output_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash;purpose='bounded read-only tail after controlled shutdown helper failed; production process remained running'}
[IO.File]::WriteAllText($metadataOutput,($meta|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
$meta|Format-List
