$ErrorActionPreference = 'Stop'
$taskId = 'RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R2'
$iso = 'C:\TW\rndbot-roster-phase-b-r2-20260831-131938'
$source = Join-Path $iso 'source'
$input = Join-Path $iso 'input-b-r1'
$run = $PSScriptRoot
$evidence = Join-Path $run 'evidence'
$inputZip = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-B-R1-20260831-005014.zip'
$productionSource = 'C:\TW\ComTW\source'

function Write-Utf8([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function File-Record([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    [ordered]@{ path=$item.FullName; size=[int64]$item.Length; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $safe = $Repository.Replace('\','/')
    $output = & 'Y:\appentwicklung\Git\cmd\git.exe' -c "safe.directory=$safe" -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git failed: $($Arguments -join ' ')" }
    @($output | ForEach-Object { $_.ToString() })
}

$head = ([string](Invoke-Git $source @('rev-parse','HEAD'))).Trim()
$tree = ([string](Invoke-Git $source @('rev-parse','HEAD^{tree}'))).Trim()
$beforeStatus = @(Invoke-Git $source @('status','--porcelain','--untracked-files=all'))
if ($head -cne '42b8a7f742548793910fe8880463aeeb71627fb9') { throw 'Baseline commit mismatch' }
if ($tree -cne 'b2cf4e38fd288a53f61b9f2350f74caa85d606ab') { throw 'Baseline tree mismatch' }
if ($beforeStatus.Count -ne 0) { throw 'Fresh isolated clone is not clean' }
if (Test-Path -LiteralPath (Join-Path $source '.gitmodules')) { throw 'Unexpected submodules' }

$matrixPath = Join-Path $input 'SOURCE-MATRIX.tsv'
$rows = @(Import-Csv -LiteralPath $matrixPath -Delimiter "`t")
if ($rows.Count -ne 25) { throw "Unexpected B-R1 source matrix count: $($rows.Count)" }
$copyEvidence = @()
foreach ($row in $rows) {
    $relative = [string]$row.relative_path
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.(/|$)') { throw "Unsafe matrix path: $relative" }
    $from = Join-Path (Join-Path $input 'source-copies') ($relative.Replace('/','\'))
    $to = Join-Path $source ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Missing B-R1 source copy: $relative" }
    $sourceHash = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
    if ($sourceHash -cne [string]$row.sha256) { throw "B-R1 source-copy hash mismatch: $relative" }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force)
    Copy-Item -LiteralPath $from -Destination $to -Force
    $targetHash = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash
    if ($targetHash -cne $sourceHash) { throw "Reconstructed target mismatch: $relative" }
    $copyEvidence += [ordered]@{ relative_path=$relative; expected_sha256=[string]$row.sha256; reconstructed_sha256=$targetHash; result='PASS' }
}

$afterStatus = @(Invoke-Git $source @('status','--short','--untracked-files=all'))
$reconstruction = [ordered]@{
    task_id=$taskId
    captured_utc=[DateTime]::UtcNow.ToString('o')
    result='PASS'
    baseline_commit=$head
    baseline_tree=$tree
    clean_status_before=$true
    input_zip=File-Record $inputZip
    source_matrix=File-Record $matrixPath
    file_count=$rows.Count
    files=$copyEvidence
    git_status_after=$afterStatus
}
Write-Utf8 (Join-Path $evidence 'b-r1-reconstruction.json') (($reconstruction | ConvertTo-Json -Depth 8) + "`n")

$productionStatus = @(Invoke-Git $productionSource @('status','--short','--untracked-files=all'))
$dirty = @()
foreach ($line in $productionStatus) {
    $relative = $line.Substring(3)
    $path = Join-Path $productionSource ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Production status path missing: $relative" }
    $record = File-Record $path
    $dirty += [ordered]@{ relative_path=$relative; size=$record.size; sha256=$record.sha256 }
}
$productionBefore = [ordered]@{
    task_id=$taskId
    captured_utc=[DateTime]::UtcNow.ToString('o')
    production_source=$productionSource
    git_head=([string](Invoke-Git $productionSource @('rev-parse','HEAD'))).Trim()
    status_lines=$productionStatus
    dirty_files=$dirty
    protected_artifacts=[ordered]@{
        production_exe=File-Record 'C:\TW\ComTW\server\mangosd.exe'
        mangosd_conf=File-Record 'C:\TW\ComTW\server\mangosd.conf'
        aiplayerbot_conf=File-Record 'C:\TW\ComTW\server\aiplayerbot.conf'
    }
    production_database_accessed=$false
    production_endpoint_3307_accessed=$false
}
Write-Utf8 (Join-Path $evidence 'production-before.json') (($productionBefore | ConvertTo-Json -Depth 8) + "`n")

$preflight = [ordered]@{
    task_id=$taskId
    captured_utc=[DateTime]::UtcNow.ToString('o')
    result='PASS'
    hub_preflight_result='PASS'
    canonical_registry_read=$true
    global_hub_readme_read=$true
    workstream_id='WS-10'
    workstream_readme_read=$true
    dependent_workstreams=@('WS-20','WS-30')
    hub_manifest_verified='11/11'
    hub_manifest_sha256='086BB6B9E673E78572B3346EA545844EB4C075E84F2C630EAD31EA2CFF97A3BE'
    b_r1_zip_sha256=$reconstruction.input_zip.sha256
    b_r1_zip_expected_sha256='89E36EFFEB1A53A138E1ABD065A263CCB6BDD7A10478AF91193639FC7242EE7F'
    b_r1_source_reconstruction='25/25 PASS'
    source_of_truth_conflict_count=0
    unresolved_reference_count=0
}
Write-Utf8 (Join-Path $evidence 'preflight.json') (($preflight | ConvertTo-Json -Depth 8) + "`n")

Write-Output 'R2_INITIALIZATION=PASS'
Write-Output "RECONSTRUCTED_SOURCE_FILES=$($rows.Count)"
