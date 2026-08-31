param(
    [Parameter(Mandatory=$true)][string]$InventoryTsv,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$OperationId,
    [Parameter(Mandatory=$true)][string]$Actor,
    [string]$Reason = ''
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function ConvertTo-Base64Url([string]$Value) {
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    return [Convert]::ToBase64String($utf8.GetBytes($Value)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

if ($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
    throw 'operation_id is not a canonical lowercase UUIDv4'
}
if ($Actor.Length -eq 0) { throw 'actor must not be empty' }
if ($Actor -cne $Actor.Normalize([Text.NormalizationForm]::FormC)) { throw 'actor is not Unicode NFC' }
if ($Reason -cne $Reason.Normalize([Text.NormalizationForm]::FormC)) { throw 'reason is not Unicode NFC' }
if (!(Test-Path -LiteralPath $InventoryTsv -PathType Leaf)) { throw 'inventory TSV is missing' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'output directory must not already exist' }

$rows = @(Import-Csv -LiteralPath $InventoryTsv -Delimiter "`t")
if ($rows.Count -ne 50) { throw "exactly 50 inventory rows required; observed $($rows.Count)" }
if (@($rows | Where-Object { $_.eligible -ne '1' }).Count -ne 0) { throw 'every row must have eligible=1' }

$guids = @()
foreach ($row in $rows) {
    [uint64]$parsed = 0
    if (![uint64]::TryParse($row.character_guid, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 4294967295) {
        throw "invalid Character GUID: $($row.character_guid)"
    }
    $guids += [uint32]$parsed
}
if (@($guids | Sort-Object -Unique).Count -ne 50) { throw 'duplicate Character GUID' }
$sorted = @($guids | Sort-Object)
for ($i=0; $i -lt 50; $i++) {
    if ($guids[$i] -ne $sorted[$i]) { throw 'inventory must already be sorted by numeric Character GUID' }
}

$snapshotLines = @(
    'ssc-rndbot-roster-v1',
    'schema_version=1',
    'ordinal_base=1',
    'member_count=50'
)
for ($i=0; $i -lt 50; $i++) {
    $snapshotLines += ('{0:D10}' -f ($i + 1)) + "`t" + ('{0:D10}' -f $guids[$i])
}

$requestLines = @(
    'ssc-rndbot-admin-request-v1',
    'schema_version=1',
    "operation_id=$OperationId",
    'operation_type=INITIALIZE',
    'expected_current_version_id=null',
    ('actor_utf8_b64url=' + (ConvertTo-Base64Url $Actor)),
    ('reason_utf8_b64url=' + (ConvertTo-Base64Url $Reason)),
    'requested_target_count=50',
    'add_count=50'
)
for ($i=0; $i -lt 50; $i++) {
    $requestLines += 'add' + "`t" + ('{0:D10}' -f ($i + 1)) + "`t" + ('{0:D10}' -f $guids[$i])
}
$requestLines += @('remove_count=0', 'replace_count=0', 'rollback_version_id=null')

$utf8 = [Text.UTF8Encoding]::new($false, $true)
$snapshotBytes = $utf8.GetBytes(($snapshotLines -join "`n") + "`n")
$requestBytes = $utf8.GetBytes(($requestLines -join "`n") + "`n")
$snapshotHash = Get-Sha256Hex $snapshotBytes
$requestHash = Get-Sha256Hex $requestBytes

[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'ordered-roster-snapshot-v1.txt'), $snapshotBytes)
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'canonical-initialize-request-v1.txt'), $requestBytes)
$hashText = "ROSTER_GUID_SET_SHA256=$snapshotHash`nCANONICAL_INITIALIZE_REQUEST_SHA256=$requestHash`nOPERATION_ID=$OperationId`n"
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'HASHES.txt'), $utf8.GetBytes($hashText))

Write-Output $hashText.TrimEnd()
