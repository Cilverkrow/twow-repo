param(
    [string]$RawPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence\DB-READONLY-INVENTORY-ATTEMPT-2.raw.tsv'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence')
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$lines = [IO.File]::ReadAllLines($RawPath, $utf8)

function Find-Line([string]$Prefix) {
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($Prefix)) { return $i }
    }
    return -1
}

function Write-Lines([string]$Name, [string[]]$Content) {
    $path = Join-Path $EvidenceDirectory $Name
    if (Test-Path -LiteralPath $path) { throw "refusing to overwrite parsed evidence: $path" }
    [IO.File]::WriteAllLines($path, $Content, $utf8)
}

function Tsv([object[]]$Values) {
    foreach ($value in $Values) {
        if ($null -ne $value -and ([string]$value).IndexOfAny(@([char]9,[char]10,[char]13)) -ge 0) {
            throw 'unexpected control character in TSV value'
        }
    }
    return (($Values | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } }) -join "`t")
}

$snapshotHeader = Find-Line "evidence_key`tevidence_value"
$columnHeader = Find-Line "TABLE_SCHEMA`tTABLE_NAME`tCOLUMN_NAME"
$indexHeader = Find-Line "TABLE_SCHEMA`tTABLE_NAME`tINDEX_NAME"
$addHeader = Find-Line "add_row_id`tcharacter_guid"
$activeHeader = Find-Line "character_guid`tactive_add_row_count"
$stockHeader = Find-Line "character_guid`tcharacter_name"
$countHeader = Find-Line "active_add_rows`tactive_add_distinct"
foreach ($index in @($snapshotHeader,$columnHeader,$indexHeader,$addHeader,$stockHeader,$countHeader)) {
    if ($index -lt 0) { throw 'required result-set header is missing' }
}

$addEnd = if ($activeHeader -ge 0) { $activeHeader - 1 } else { $stockHeader - 1 }
$activeEnd = $stockHeader - 1
$columns = @($lines[$columnHeader..($indexHeader-1)])
$indexes = @($lines[$indexHeader..($addHeader-1)])
$addLines = @($lines[$addHeader..$addEnd])
$stockLines = @($lines[$stockHeader..($countHeader-1)])
$countLines = @($lines[$countHeader..($countHeader+1)])
$activeLines = if ($activeHeader -ge 0) {
    @($lines[$activeHeader..$activeEnd])
} else {
    @("character_guid`tactive_add_row_count`tcharacter_name`taccount_id`taccount_name`tcharacter_level`tclass_id`trace_id`tcharacter_online`tcharacter_logout_unix`tcharacter_logout_utc_server`tcharacter_active`tcharacter_delete_unix`taccount_last_login`taccount_online`taccount_active`taccount_locked`taccount_banned_flag`tbanned_now`tgroup_count`tgroup_ids`tsession_status`teligible_under_c0_gate")
}

Write-Lines 'DB-SCHEMA-COLUMNS.tsv' $columns
Write-Lines 'DB-SCHEMA-INDEXES.tsv' $indexes
Write-Lines 'ADD-LEASE-INVENTORY.tsv' $addLines
Write-Lines 'ACTIVE-ADD-COHORT.tsv' $activeLines
Write-Lines 'DB-COUNTS.tsv' $countLines
Write-Lines 'DB-SNAPSHOT-UTC.tsv' @($lines[$snapshotHeader],$lines[$snapshotHeader+1])

$add = @($addLines | ConvertFrom-Csv -Delimiter "`t")
$stock = @($stockLines | ConvertFrom-Csv -Delimiter "`t")
$counts = @($countLines | ConvertFrom-Csv -Delimiter "`t")
if ($counts.Count -ne 1) { throw 'count result must contain exactly one row' }

$candidateHeader = Tsv @(
    'character_guid','character_name','account_id','account_name','level','class_id','race_id',
    'character_online','character_last_logout_utc','account_last_login','group_count','group_ids',
    'rndbot_stock','character_active','character_deleted','account_online','account_active',
    'account_locked','account_banned_flag','banned_now','session_status','all_add_rows',
    'active_add_rows','base_eligible','selection_status'
)
$candidateLines = [Collections.Generic.List[string]]::new()
$candidateLines.Add($candidateHeader)
$stockByGuid = @{}
$eligibleCount = 0
foreach ($row in ($stock | Sort-Object {[uint64]$_.character_guid})) {
    $stockByGuid[$row.character_guid] = $row
    $eligible = $row.character_active -eq '1' -and $row.character_delete_unix -eq 'NULL' -and
        $row.account_active -eq '1' -and $row.account_locked -eq '0' -and
        $row.account_banned_flag -eq '0' -and $row.banned_now -eq '0' -and
        $row.session_status -eq 'NO_REGISTERED_SESSION_SERVER_STOPPED'
    if ($eligible) { $eligibleCount++ }
    $candidateLines.Add((Tsv @(
        $row.character_guid,$row.character_name,$row.account_id,$row.account_name,
        $row.character_level,$row.class_id,$row.race_id,$row.character_online,
        $row.character_logout_utc_server,$row.account_last_login,$row.group_count,$row.group_ids,
        '1',$row.character_active,($(if($row.character_delete_unix -eq 'NULL'){'0'}else{'1'})),
        $row.account_online,$row.account_active,$row.account_locked,$row.account_banned_flag,
        $row.banned_now,$row.session_status,$row.all_add_rows,$row.active_add_rows,
        ($(if($eligible){'1'}else{'0'})),'REQUIRES_EXPLICIT_USER_SELECTION'
    )))
}
Write-Lines 'ROSTER-CANDIDATES.tsv' $candidateLines

$expiredHeader = Tsv @(
    'character_guid','character_name','account_id','account_name','level','class_id','race_id',
    'lease_started_utc','lease_expires_utc','lease_seconds','active_add_lease',
    'character_online','account_active','account_locked','account_banned_flag','banned_now',
    'group_count','group_ids','base_eligible','selection_status'
)
$expiredLines = [Collections.Generic.List[string]]::new()
$expiredLines.Add($expiredHeader)
foreach ($lease in ($add | Sort-Object {[uint64]$_.character_guid})) {
    if (!$stockByGuid.ContainsKey($lease.character_guid)) { throw "add GUID is not RNDBOT stock: $($lease.character_guid)" }
    $row = $stockByGuid[$lease.character_guid]
    $eligible = $row.character_active -eq '1' -and $row.character_delete_unix -eq 'NULL' -and
        $row.account_active -eq '1' -and $row.account_locked -eq '0' -and
        $row.account_banned_flag -eq '0' -and $row.banned_now -eq '0'
    $expiredLines.Add((Tsv @(
        $lease.character_guid,$row.character_name,$row.account_id,$row.account_name,
        $row.character_level,$row.class_id,$row.race_id,$lease.lease_started_utc_server,
        $lease.lease_expires_utc_server,$lease.lease_seconds,$lease.active_add_lease,
        $row.character_online,$row.account_active,$row.account_locked,$row.account_banned_flag,
        $row.banned_now,$row.group_count,$row.group_ids,$(if($eligible){'1'}else{'0'}),
        'EXPIRED_HISTORY_REQUIRES_EXPLICIT_USER_SELECTION'
    )))
}
Write-Lines 'EXPIRED-ADD-CANDIDATES.tsv' $expiredLines

$activeRows = @($add | Where-Object active_add_lease -eq '1')
$duplicateGuids = @($add | Group-Object character_guid | Where-Object Count -gt 1)
if ([int]$counts[0].active_add_rows -ne $activeRows.Count) { throw 'active row count mismatch' }
if ([int]$counts[0].total_rndbot_characters -ne $stock.Count) { throw 'stock count mismatch' }

$summary = @(
    'TASK_ID=RNDBOT-PERSISTENT-ACTIVE-ROSTER-IMPLEMENTATION-01-PHASE-C0',
    ('CURRENT_ACTIVE_RNDBOT_COUNT=' + $counts[0].active_rndbot),
    ('ELIGIBLE_ACTIVE_RNDBOT_COUNT=' + $counts[0].eligible_rndbot),
    ('ACTIVE_ADD_ROWS=' + $counts[0].active_add_rows),
    ('ACTIVE_ADD_DISTINCT=' + $counts[0].active_add_distinct),
    ('HISTORICAL_ADD_ROWS=' + $add.Count),
    ('HISTORICAL_ADD_DISTINCT=' + @($add.character_guid | Sort-Object -Unique).Count),
    ('HISTORICAL_ADD_DUPLICATE_GUIDS=' + $duplicateGuids.Count),
    ('EXPIRED_ADD_ROWS=' + @($add | Where-Object active_add_lease -eq '0').Count),
    ('RNDBOT_STOCK_CHARACTER_COUNT=' + $stock.Count),
    ('BASE_ELIGIBLE_STOCK_COUNT=' + $eligibleCount),
    'TARGET_ROSTER_SIZE=50',
    'MISSING_ACTIVE_GUIDS_TO_TARGET=50',
    'PROPOSED_ROSTER_COUNT=0',
    'EXACT_50_GUIDS_AVAILABLE=NO',
    'AUTOMATIC_TRIM=NO',
    'AUTOMATIC_TOP_UP=NO',
    'AUTOMATIC_REPLACEMENT=NO',
    'USER_ROSTER_APPROVAL_REQUIRED=YES'
)
Write-Lines 'ROSTER-SELECTION-SUMMARY.txt' $summary

Write-Output ($summary -join "`n")
