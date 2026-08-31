[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$RunRoot='C:\TW\ComTW\runbooks\ssc-source-baseline-01-20260829-193848'
$Runbooks='C:\TW\ComTW\runbooks'
$ZipPath=Join-Path $Runbooks 'SSC-SOURCE-BASELINE-01-20260829.zip'
$ManifestPath=Join-Path $RunRoot 'SHA256SUMS.txt'
$PackageEvidencePath=Join-Path $RunRoot 'package-evidence.json'

if(Test-Path -LiteralPath $ZipPath){throw "Refusing to overwrite ZIP: $ZipPath"}
if(Test-Path -LiteralPath $ManifestPath){throw "Refusing to overwrite manifest: $ManifestPath"}
if(Test-Path -LiteralPath $PackageEvidencePath){throw "Refusing to overwrite package evidence: $PackageEvidencePath"}

function Relative([string]$Path){
    $rel=[IO.Path]::GetRelativePath($RunRoot,$Path)
    $rel.Replace('\','/')
}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}

$sourceFiles=@(Get-ChildItem -LiteralPath $RunRoot -Recurse -File -Force | Where-Object {$_.FullName -notin @($ManifestPath,$PackageEvidencePath)} | Sort-Object {[IO.Path]::GetRelativePath($RunRoot,$_.FullName)})
$manifestLines=@($sourceFiles | ForEach-Object {"$(Sha $_.FullName)  $(Relative $_.FullName)"})
[IO.File]::WriteAllText($ManifestPath,($manifestLines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open($ZipPath,[IO.Compression.ZipArchiveMode]::Create)
try{
    $allFiles=@($sourceFiles)+(Get-Item -LiteralPath $ManifestPath)
    foreach($file in ($allFiles|Sort-Object {[IO.Path]::GetRelativePath($RunRoot,$_.FullName)})){
        $entryName=([IO.Path]::GetFileName($RunRoot)+'/'+(Relative $file.FullName))
        $entry=$zip.CreateEntry($entryName,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=[DateTimeOffset]$file.LastWriteTime
        $input=[IO.File]::OpenRead($file.FullName)
        $output=$entry.Open()
        try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
    }
}finally{$zip.Dispose()}

$manifestMap=@{}
foreach($line in [IO.File]::ReadAllLines($ManifestPath)){
    if($line -match '^([0-9A-F]{64})  (.+)$'){$manifestMap[$Matches[2]]=$Matches[1]}else{throw "Invalid manifest line: $line"}
}
$verified=0
$zipRead=[IO.Compression.ZipFile]::OpenRead($ZipPath)
try{
    $prefix=[IO.Path]::GetFileName($RunRoot)+'/'
    foreach($entry in $zipRead.Entries){
        if(-not $entry.FullName.StartsWith($prefix)){throw "Unexpected ZIP prefix: $($entry.FullName)"}
        $relative=$entry.FullName.Substring($prefix.Length)
        if($relative -eq 'SHA256SUMS.txt'){continue}
        if(-not $manifestMap.ContainsKey($relative)){throw "ZIP entry missing from manifest: $relative"}
        $stream=$entry.Open()
        try{$hash=[Security.Cryptography.SHA256]::HashData($stream);$actual=[Convert]::ToHexString($hash)}finally{$stream.Dispose()}
        if($actual -ne $manifestMap[$relative]){throw "ZIP entry hash mismatch: $relative"}
        $verified++
    }
    if($verified -ne $manifestMap.Count){throw "Verified $verified entries but manifest has $($manifestMap.Count)"}
    $entryCount=$zipRead.Entries.Count
    $entryNames=@($zipRead.Entries.FullName)
}finally{$zipRead.Dispose()}

$zipItem=Get-Item -LiteralPath $ZipPath
$package=[ordered]@{
    task='SSC-SOURCE-BASELINE-01'
    created_utc=[DateTime]::UtcNow.ToString('o')
    zip_path=$ZipPath
    zip_size_bytes=$zipItem.Length
    zip_sha256=Sha $ZipPath
    zip_entry_count=$entryCount
    manifest_entry_count=$manifestMap.Count
    verified_manifest_entries_in_zip=$verified
    manifest_sha256=Sha $ManifestPath
    root_entry_prefix=([IO.Path]::GetFileName($RunRoot)+'/')
    all_manifest_hashes_verified=$true
    entries=$entryNames
}
[IO.File]::WriteAllText($PackageEvidencePath,($package|ConvertTo-Json -Depth 6)+"`n",[Text.UTF8Encoding]::new($false))
$package|ConvertTo-Json -Depth 4
