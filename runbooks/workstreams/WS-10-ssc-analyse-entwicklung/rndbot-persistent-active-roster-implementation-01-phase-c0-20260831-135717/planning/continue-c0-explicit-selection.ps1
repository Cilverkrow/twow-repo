param(
    [string]$RunbookRoot = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717',
    [string]$Actor = 'ssc-c0-preflight',
    [string]$Reason = 'Prepare audited explicit 50-GUID RNDBOT roster; not applied'
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$shortlistPath = Join-Path $RunbookRoot 'evidence\ROSTER-CANDIDATES-SHORTLIST-50-from-expired.txt'
$candidatePath = Join-Path $RunbookRoot 'evidence\ROSTER-CANDIDATES.tsv'
$expiredPath = Join-Path $RunbookRoot 'evidence\EXPIRED-ADD-CANDIDATES.tsv'
$selectedPath = Join-Path $RunbookRoot 'evidence\PROPOSED-ROSTER-50.tsv'
$validationPath = Join-Path $RunbookRoot 'evidence\PROPOSED-ROSTER-50-VALIDATION.txt'
$generatorPath = Join-Path $RunbookRoot 'planning\prepare-canonical-initialize.ps1'

foreach ($path in @($shortlistPath,$candidatePath,$expiredPath,$generatorPath)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "required input missing: $path" }
}
foreach ($path in @($selectedPath,$validationPath)) {
    if (Test-Path -LiteralPath $path) { throw "refusing to overwrite output: $path" }
}

$shortlistBytes = [IO.File]::ReadAllBytes($shortlistPath)
if ($shortlistBytes.Length -ge 3 -and $shortlistBytes[0] -eq 0xEF -and $shortlistBytes[1] -eq 0xBB -and $shortlistBytes[2] -eq 0xBF) {
    throw 'shortlist must not contain a UTF-8 BOM'
}
$shortlistText = $utf8.GetString($shortlistBytes)
if ($shortlistText -cnotmatch '^(?:[1-9][0-9]{0,9}\r\n){50}$') {
    throw 'shortlist bytes must be exactly 50 positive decimal GUID lines with CRLF and a final CRLF'
}
$guidText = @($shortlistText -split "`r`n" | Where-Object { $_ -ne '' })
if ($guidText.Count -ne 50) { throw 'shortlist must contain exactly 50 GUIDs' }
$guids = [Collections.Generic.List[uint32]]::new()
foreach ($text in $guidText) {
    [uint64]$parsedGuid = 0
    if (![uint64]::TryParse($text, [ref]$parsedGuid) -or $parsedGuid -lt 1 -or $parsedGuid -gt 4294967295) {
        throw "invalid Character GUID: $text"
    }
    $guids.Add([uint32]$parsedGuid)
}
for ($i=1; $i -lt $guids.Count; $i++) {
    if ($guids[$i] -le $guids[$i-1]) { throw 'GUIDs must be unique and strictly numerically increasing' }
}

$candidates = @(Import-Csv -LiteralPath $candidatePath -Delimiter "`t")
$expired = @(Import-Csv -LiteralPath $expiredPath -Delimiter "`t")
if ($candidates.Count -ne 4500) { throw 'dated candidate inventory count mismatch' }
if (@($candidates.character_guid | Sort-Object -Unique).Count -ne 4500) { throw 'dated candidate inventory contains duplicate GUIDs' }
$candidateByGuid = @{}
foreach ($row in $candidates) { $candidateByGuid[$row.character_guid] = $row }
$expiredByGuid = @{}
foreach ($row in $expired) { $expiredByGuid[$row.character_guid] = $row }

$selected = [Collections.Generic.List[object]]::new()
foreach ($guid in $guids) {
    $key = [string]$guid
    if (!$candidateByGuid.ContainsKey($key)) { throw "GUID missing from dated candidate inventory: $key" }
    if (!$expiredByGuid.ContainsKey($key)) { throw "GUID missing from referenced expired shortlist source: $key" }
    $row = $candidateByGuid[$key]
    if ($row.base_eligible -ne '1') { throw "GUID is not base_eligible=1: $key" }
    if ($expiredByGuid[$key].base_eligible -ne '1') { throw "expired-source eligibility mismatch: $key" }
    $selected.Add($row)
}

$properties = @(
    'character_guid','character_name','account_id','account_name','level','class_id','race_id',
    'character_online','character_last_logout_utc','account_last_login','group_count','group_ids',
    'rndbot_stock','character_active','character_deleted','account_online','account_active',
    'account_locked','account_banned_flag','banned_now','session_status','all_add_rows',
    'active_add_rows','base_eligible','selection_status','eligible'
)
$selectedLines = [Collections.Generic.List[string]]::new()
$selectedLines.Add(($properties -join "`t"))
foreach ($row in $selected) {
    $values = foreach ($property in $properties) {
        if ($property -eq 'eligible') { '1' } else { [string]$row.$property }
    }
    foreach ($cell in $values) {
        if (([string]$cell).IndexOfAny(@([char]9,[char]10,[char]13)) -ge 0) { throw 'unexpected control character in selected TSV value' }
    }
    $selectedLines.Add(($values -join "`t"))
}
[IO.File]::WriteAllLines($selectedPath, $selectedLines, $utf8)

$shortlistHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $shortlistPath).Hash
$selectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $selectedPath).Hash
$operationId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
$proposalDirectory = Join-Path $RunbookRoot ('proposal-50-' + $shortlistHash.Substring(0,16).ToLowerInvariant())
if (Test-Path -LiteralPath $proposalDirectory) { throw "refusing to overwrite proposal directory: $proposalDirectory" }

& $generatorPath -InventoryTsv $selectedPath -OutputDirectory $proposalDirectory -OperationId $operationId -Actor $Actor -Reason $Reason
$generatorSucceeded = $?
if (!$generatorSucceeded) { throw 'canonical generator failed' }

$hashesPath = Join-Path $proposalDirectory 'HASHES.txt'
$hashes = @{}
foreach ($line in (Get-Content -LiteralPath $hashesPath)) {
    $pair = $line -split '=',2
    if ($pair.Count -eq 2) { $hashes[$pair[0]] = $pair[1] }
}
$validationLines = @(
    'TASK_ID=RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-C0',
    'SELECTION_MODE=EXPLICIT_USER_SHORTLIST',
    ('SHORTLIST_PATH=' + $shortlistPath),
    ('SHORTLIST_BYTES=' + $shortlistBytes.Length),
    ('SHORTLIST_SHA256=' + $shortlistHash),
    'SHORTLIST_ENCODING=UTF8_NO_BOM_ASCII_SUBSET',
    'SHORTLIST_LINE_ENDING=CRLF',
    'SHORTLIST_FINAL_LINE_ENDING=YES',
    'SHORTLIST_GUID_COUNT=50',
    'SHORTLIST_STRICTLY_ASCENDING=YES',
    'SHORTLIST_DUPLICATE_COUNT=0',
    'MATCHED_DATED_CANDIDATE_COUNT=50',
    'MATCHED_EXPIRED_SOURCE_COUNT=50',
    'BASE_ELIGIBLE_COUNT=50',
    'HUMAN_CHARACTER_COUNT=0',
    ('SELECTED_TSV_SHA256=' + $selectedHash),
    ('OPERATION_ID=' + $operationId),
    ('ROSTER_GUID_SET_SHA256=' + $hashes['ROSTER_GUID_SET_SHA256']),
    ('CANONICAL_INITIALIZE_REQUEST_SHA256=' + $hashes['CANONICAL_INITIALIZE_REQUEST_SHA256']),
    'REQUEST_APPLIED=NO',
    'DATABASE_CHANGED=NO',
    'CONFIG_CHANGED=NO',
    'PRODUCTION_EXE_CHANGED=NO',
    'CANDIDATE_STARTED=NO',
    'ROSTER_PHASE_C_STARTED=NO',
    'USER_ROSTER_APPROVAL_REQUIRED=YES',
    'NEXT_TASK_AUTHORIZED=NO'
)
[IO.File]::WriteAllLines($validationPath, $validationLines, $utf8)
Write-Output ($validationLines -join "`n")
