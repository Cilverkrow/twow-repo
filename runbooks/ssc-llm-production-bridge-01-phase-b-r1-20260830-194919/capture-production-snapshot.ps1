param([Parameter(Mandatory=$true)][string]$OutputPath)

$ErrorActionPreference='Stop'
$source='C:\TW\ComTW\source'
$server='C:\TW\ComTW\server'
$oldZip='C:\TW\ComTW\runbooks\ssc-llm-production-bridge-01-phase-b-20260830-173121-deliverables.zip'
$git='git.exe'

function Invoke-Git([string[]]$Arguments) {
    $result=& $git -c safe.directory=C:/TW/ComTW/source -C $source @Arguments
    if($LASTEXITCODE-ne0){throw "git failed: $($Arguments-join' ')"}
    return @($result)
}
function Get-FileRecord([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [ordered]@{path=$Path;exists=$false}}
    $item=Get-Item -LiteralPath $Path
    return [ordered]@{
        path=$item.FullName
        exists=$true
        size=[int64]$item.Length
        sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
        created_utc=$item.CreationTimeUtc.ToString('o')
        last_write_utc=$item.LastWriteTimeUtc.ToString('o')
    }
}

$status=@(Invoke-Git @('status','--porcelain=v1','--untracked-files=all') | Where-Object {$_})
$dirty=@()
foreach($line in $status) {
    if($line.Length-lt4){throw "Malformed git status line: $line"}
    $relative=$line.Substring(3).Replace('/','\')
    if($relative.Contains(' -> ')){throw 'Rename status is not expected in the production snapshot'}
    $record=Get-FileRecord (Join-Path $source $relative)
    $dirty += [ordered]@{status=$line.Substring(0,2);relative_path=$relative.Replace('\','/');file=$record}
}
$snapshot=[ordered]@{
    schema_version=1
    task='SSC-LLM-PRODUCTION-BRIDGE-01-PHASE-B-R1'
    captured_utc=(Get-Date).ToUniversalTime().ToString('o')
    method='live git status plus direct SHA-256 of every dirty path; no hard-coded status inventory'
    repository=[ordered]@{
        path=$source
        head=(Invoke-Git @('rev-parse','HEAD') | Select-Object -First 1)
        tree=(Invoke-Git @('rev-parse','HEAD^{tree}') | Select-Object -First 1)
        status_lines=$status
        dirty_files=$dirty
    }
    protected_artifacts=[ordered]@{
        production_exe=Get-FileRecord (Join-Path $server 'mangosd.exe')
        mangosd_config=Get-FileRecord (Join-Path $server 'mangosd.conf')
        playerbot_config=Get-FileRecord (Join-Path $server 'aiplayerbot.conf')
        previous_phase_b_zip=Get-FileRecord $oldZip
    }
    review_inputs=@(
        Get-FileRecord 'C:\Users\djfav\Downloads\ExternalLLMBridgeService.cpp'
        Get-FileRecord 'C:\Users\djfav\Downloads\collect-final-evidence.ps1'
        Get-FileRecord 'C:\Users\djfav\Downloads\external_llm_bridge_tests.cpp'
    )
}
[IO.File]::WriteAllText($OutputPath,($snapshot|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false))
$snapshot|ConvertTo-Json -Depth 5
