param(
    [string]$RunbookRoot = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717',
    [string]$ProposalDirectory = 'C:\TW\ComTW\runbooks\workstreams\WS-10-ssc-analyse-entwicklung\rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717\proposal-50-a552de67342df740',
    [string]$Actor = 'ssc-c0-preflight',
    [string]$Reason = 'Prepare audited explicit 50-GUID RNDBOT roster; not applied'
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function B64Url([string]$Text) {
    return [Convert]::ToBase64String($utf8.GetBytes($Text)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Assert-CanonicalBytes([byte[]]$Bytes, [string]$Name) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw "$Name has a BOM" }
    if ($Bytes -contains 0x0D) { throw "$Name contains CR" }
    if ($Bytes.Length -eq 0 -or $Bytes[$Bytes.Length-1] -ne 0x0A) { throw "$Name lacks final LF" }
    $null = $utf8.GetString($Bytes)
}

$shortlistPath = Join-Path $RunbookRoot 'evidence\ROSTER-CANDIDATES-SHORTLIST-50-from-expired.txt'
$selectedPath = Join-Path $RunbookRoot 'evidence\PROPOSED-ROSTER-50.tsv'
$snapshotPath = Join-Path $ProposalDirectory 'ordered-roster-snapshot-v1.txt'
$requestPath = Join-Path $ProposalDirectory 'canonical-initialize-request-v1.txt'
$hashesPath = Join-Path $ProposalDirectory 'HASHES.txt'

$shortlist = @(Get-Content -LiteralPath $shortlistPath | Where-Object { $_ -ne '' })
$selected = @(Import-Csv -LiteralPath $selectedPath -Delimiter "`t")
if ($shortlist.Count -ne 50 -or $selected.Count -ne 50) { throw 'selection count mismatch' }
if (@($selected | Where-Object { $_.eligible -ne '1' -or $_.base_eligible -ne '1' }).Count -ne 0) { throw 'selected eligibility mismatch' }
for ($i=0; $i -lt 50; $i++) {
    if ($shortlist[$i] -cne $selected[$i].character_guid) { throw "selected order mismatch at ordinal $($i+1)" }
    if ($i -gt 0 -and [uint64]$shortlist[$i] -le [uint64]$shortlist[$i-1]) { throw 'selection is not strictly ascending' }
}

$snapshotLines = @('ssc-rndbot-roster-v1','schema_version=1','ordinal_base=1','member_count=50')
for ($i=0; $i -lt 50; $i++) { $snapshotLines += ('{0:D10}' -f ($i+1)) + "`t" + ('{0:D10}' -f [uint64]$shortlist[$i]) }
$expectedSnapshot = $utf8.GetBytes(($snapshotLines -join "`n") + "`n")
$actualSnapshot = [IO.File]::ReadAllBytes($snapshotPath)
Assert-CanonicalBytes $actualSnapshot 'snapshot'
if (![Linq.Enumerable]::SequenceEqual([byte[]]$expectedSnapshot,[byte[]]$actualSnapshot)) { throw 'snapshot bytes mismatch' }

$requestBytes = [IO.File]::ReadAllBytes($requestPath)
Assert-CanonicalBytes $requestBytes 'request'
$requestText = $utf8.GetString($requestBytes)
$requestLines = @($requestText -split "`n")
if ($requestLines.Count -ne 63 -or $requestLines[-1] -ne '') { throw 'request line count/final LF mismatch' }
$operationId = ($requestLines[2] -split '=',2)[1]
if ($operationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') { throw 'operation_id is not canonical UUIDv4' }

$expectedRequestLines = @(
    'ssc-rndbot-admin-request-v1','schema_version=1',('operation_id=' + $operationId),
    'operation_type=INITIALIZE','expected_current_version_id=null',
    ('actor_utf8_b64url=' + (B64Url $Actor)),('reason_utf8_b64url=' + (B64Url $Reason)),
    'requested_target_count=50','add_count=50'
)
for ($i=0; $i -lt 50; $i++) { $expectedRequestLines += 'add' + "`t" + ('{0:D10}' -f ($i+1)) + "`t" + ('{0:D10}' -f [uint64]$shortlist[$i]) }
$expectedRequestLines += @('remove_count=0','replace_count=0','rollback_version_id=null')
$expectedRequest = $utf8.GetBytes(($expectedRequestLines -join "`n") + "`n")
if (![Linq.Enumerable]::SequenceEqual([byte[]]$expectedRequest,[byte[]]$requestBytes)) { throw 'request bytes mismatch' }

$declared = @{}
foreach ($line in (Get-Content -LiteralPath $hashesPath)) { $p=$line -split '=',2; if($p.Count-eq2){$declared[$p[0]]=$p[1]} }
$snapshotHash = Sha $actualSnapshot
$requestHash = Sha $requestBytes
if ($declared['ROSTER_GUID_SET_SHA256'] -cne $snapshotHash) { throw 'snapshot hash declaration mismatch' }
if ($declared['CANONICAL_INITIALIZE_REQUEST_SHA256'] -cne $requestHash) { throw 'request hash declaration mismatch' }
if ($declared['OPERATION_ID'] -cne $operationId) { throw 'operation ID declaration mismatch' }

@(
    'PROPOSAL_BYTE_VALIDATION=PASS',
    'PROPOSED_ROSTER_COUNT=50',
    'GUID_ORDER=STRICT_NUMERIC_ASCENDING',
    'GUID_DUPLICATE_COUNT=0',
    'BASE_ELIGIBLE_COUNT=50',
    ('SNAPSHOT_BYTES=' + $actualSnapshot.Length),
    ('ROSTER_GUID_SET_SHA256=' + $snapshotHash),
    ('REQUEST_BYTES=' + $requestBytes.Length),
    ('CANONICAL_INITIALIZE_REQUEST_SHA256=' + $requestHash),
    ('OPERATION_ID=' + $operationId),
    'REQUEST_APPLIED=NO'
)
