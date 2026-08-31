param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ApprovedHarnessSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = 'C:\TW\ComTW'
$ReviewedRunbook = Join-Path $Root 'runbooks\tw-char-migration-F92F86D6.ps1'
$ExpectedReviewedRunbookSha256 = 'F92F86D66FEB4C1743F1E09B1CA14101B8249E858CB5B18DC2894AA27E06F881'
$DatabaseRoot = Join-Path $Root 'DB'
$DataDir = Join-Path $DatabaseRoot 'data'
$DatabaseLauncher = Join-Path $DatabaseRoot 'start-database.bat'
$MariaDbServer = Join-Path $DatabaseRoot 'bin\mysqld.exe'
$MariaDbClient = Join-Path $DatabaseRoot 'bin\mariadb.exe'
$MariaDbDump = Join-Path $DatabaseRoot 'bin\mariadb-dump.exe'
$MariaDbAdmin = Join-Path $DatabaseRoot 'bin\mariadb-admin.exe'
$MyIni = Join-Path $DataDir 'my.ini'
$ServerDir = Join-Path $Root 'server'
$ProductionExe = Join-Path $ServerDir 'mangosd.exe'
$DatabaseName = 'tw_char'
$DatabaseHost = '127.0.0.1'
$DatabasePort = 3307
$DatabaseUser = 'root'
$MariaDbPasswordlessTlsWarning = 'WARNING: option --ssl-verify-server-cert is disabled, because of an insecure passwordless login.'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

$ApprovedFiles = @{
    DatabaseLauncher = @{ Path = $DatabaseLauncher; Sha256 = 'C0EEC81CE8797DDE77685D5639E90AD36892EE473CAD01F8558B6A8C6237336A' }
    MyIni             = @{ Path = $MyIni;             Sha256 = '7039B21A8D50E85511EDF7D5BC2ECD501830AD151D9EF0331243B43ADA4BA9B8' }
    MariaDbServer     = @{ Path = $MariaDbServer;     Sha256 = 'FF99D2F64CC6E236BAA4257A905F27B15683DC2F4B52C003E4859D56558DFDC7' }
    MariaDbClient     = @{ Path = $MariaDbClient;     Sha256 = '9A6A56B05BE9528276A9B04A437D98F4C616300295C17CA075C3BDE70F75CC95' }
    MariaDbDump       = @{ Path = $MariaDbDump;       Sha256 = 'FD6E467EAA49F166E355A5660952E2488ABB2BE80CB90B2DB229DF7253D24EDB' }
    MariaDbAdmin      = @{ Path = $MariaDbAdmin;      Sha256 = '1430004FFC66FEAF60734A8F9CE5DD6FE445211E2B1B33671C720D9C803F297E' }
}

$script:RunState = @{
    Database = @{
        LaunchAttempted = $false
        LaunchUtc = $null
        LauncherPid = $null
        PreExistingPids = @()
        OwnedPid = $null
        OwnedStartTimeUtcTicks = $null
        ExpectedPath = $MariaDbServer
    }
    World = @{
        LaunchAttempted = $false
        LaunchUtc = $null
        LauncherPid = $null
        PreExistingPids = @()
        OwnedPid = $null
        OwnedStartTimeUtcTicks = $null
        ExpectedPath = $ProductionExe
    }
}

$EvidenceDirectory = Join-Path $OutputDirectory 'evidence'
$QueryResultDirectory = Join-Path $EvidenceDirectory 'query-results'
$ConsoleLog = Join-Path $EvidenceDirectory 'database-harness-console.txt'
$TranscriptPath = Join-Path $EvidenceDirectory 'read-only-sql-transcript.txt'
$RowCountsPath = Join-Path $EvidenceDirectory 'result-row-counts.tsv'
$SqlAuditPath = Join-Path $EvidenceDirectory 'sql-write-capability-audit.json'
$SchemaEvidencePath = Join-Path $EvidenceDirectory 'schema-definitions.txt'
$EngineChangesPath = Join-Path $EvidenceDirectory 'database-engine-runtime-changes.tsv'
$HarnessResultPath = Join-Path $EvidenceDirectory 'database-harness-result.json'

function Write-Utf8Lf {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, $Utf8NoBom)
}

function Write-ConsoleEvidence {
    param([string]$Message)
    $line = ('{0:o}|{1}' -f [DateTime]::UtcNow, $Message)
    [Console]::Out.WriteLine($line)
    [System.IO.File]::AppendAllText($ConsoleLog, $line + "`n", $Utf8NoBom)
}

function Assert-WindowsPowerShell51 {
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        throw "Windows PowerShell 5.1 is required. Found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }
}

function Get-ListenerOwnerPids {
    param([int]$Port)
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
}

function Get-MatchingRunningServices {
    try {
        return @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.State -eq 'Running' -and (
                $_.Name -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
                $_.DisplayName -match '(?i)maria|mysql|mangos|realmd|turtle|twow' -or
                $_.PathName -match '(?i)\\TW\\ComTW\\(DB|server)\\'
            )
        })
    }
    catch {
        throw "Windows service inspection failed: $($_.Exception.Message)"
    }
}

function Assert-InitialCleanState {
    $processes = @()
    foreach ($name in @('mysqld', 'mariadbd', 'mangosd', 'realmd')) {
        $processes += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
    $services = @(Get-MatchingRunningServices)
    $port3307 = @(Get-ListenerOwnerPids -Port 3307)
    $port8090 = @(Get-ListenerOwnerPids -Port 8090)
    if ($processes.Count -ne 0 -or $services.Count -ne 0 -or $port3307.Count -ne 0 -or $port8090.Count -ne 0) {
        throw ("Initial clean-state gate failed: processes={0}, services={1}, port3307={2}, port8090={3}." -f
            $processes.Count, $services.Count, $port3307.Count, $port8090.Count)
    }
}

function Get-DataFileManifest {
    $manifest = @{}
    $rootWithSeparator = $DataDir.TrimEnd('\') + '\'
    foreach ($file in @(Get-ChildItem -LiteralPath $DataDir -File -Recurse -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($rootWithSeparator.Length).Replace('\', '/')
        $manifest[$relative] = [pscustomobject]@{
            Length = [long]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    }
    return $manifest
}

function Write-EngineChanges {
    param([hashtable]$Before, [hashtable]$After)
    $paths = @($Before.Keys + $After.Keys | Sort-Object -Unique)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('relative_path\tchange_type\tbefore_bytes\tafter_bytes\tbefore_sha256\tafter_sha256')
    foreach ($path in $paths) {
        $hasBefore = $Before.ContainsKey($path)
        $hasAfter = $After.ContainsKey($path)
        if (-not $hasBefore) {
            $lines.Add(("{0}\tcreated\t\t{1}\t\t{2}" -f $path, $After[$path].Length, $After[$path].Sha256))
        }
        elseif (-not $hasAfter) {
            $lines.Add(("{0}\tremoved\t{1}\t\t{2}\t" -f $path, $Before[$path].Length, $Before[$path].Sha256))
        }
        elseif ($Before[$path].Length -ne $After[$path].Length -or $Before[$path].Sha256 -cne $After[$path].Sha256) {
            $lines.Add(("{0}\tmodified\t{1}\t{2}\t{3}\t{4}" -f $path, $Before[$path].Length, $After[$path].Length, $Before[$path].Sha256, $After[$path].Sha256))
        }
    }
    Write-Utf8Lf -Path $EngineChangesPath -Text (($lines -join "`n") + "`n")
    return ($lines.Count - 1)
}

function Import-ReviewedDatabaseFunctions {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ReviewedRunbook, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "Reviewed runbook parser error count is $($errors.Count)."
    }
    $required = @(
        'Get-Sha256', 'Assert-Hash', 'Assert-Administrator', 'Get-NormalizedPath',
        'Get-ProcessPath', 'Get-ProcessCandidates', 'Test-PortOpen', 'Get-PortOwnerPids',
        'Set-LaunchAttempt', 'Set-LauncherPid', 'Get-VerifiedOwnedProcess',
        'Try-AdoptLaunchedProcess', 'Wait-ForOwnedProcess', 'Wait-ForProcessExit',
        'Assert-DatabaseProgramFiles', 'Assert-RestoredDatabaseConfiguration',
        'Resolve-MariaDbClientResult', 'ConvertTo-WindowsCommandLineArgument',
        'Invoke-ProcessWithCapturedOutput', 'Invoke-MariaDb', 'Assert-SingleValue',
        'Assert-DatabaseIdentity', 'Assert-DatabasePortOwnership', 'Wait-ForDatabaseReady',
        'Assert-ReviewedDatabaseConfiguration', 'Stop-OwnedDatabase', 'Start-ReviewedDatabase'
    )
    $definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $source = New-Object System.Collections.Generic.List[string]
    $audit = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        $matches = @($definitions | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            throw "Reviewed function '$name' count is $($matches.Count), expected one."
        }
        $text = $matches[0].Extent.Text
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') } finally { $sha.Dispose() }
        $audit.Add(("{0}\t{1}\t{2}\t{3}" -f $name, $matches[0].Extent.StartLineNumber, $matches[0].Extent.EndLineNumber, $hash))
        $source.Add($text)
    }
    Write-Utf8Lf -Path (Join-Path $EvidenceDirectory 'reviewed-function-imports.tsv') -Text ("function_name\tstart_line\tend_line\textent_sha256`n" + ($audit -join "`n") + "`n")
    return ($source -join "`n`n")
}

function Assert-ReadOnlyQuerySet {
    param([object[]]$Queries)
    $writeCapable = New-Object System.Collections.Generic.List[string]
    foreach ($query in $Queries) {
        $text = $query.Sql.Trim()
        if ($text.Contains(';')) {
            $writeCapable.Add("$($query.Id): contains a statement separator")
            continue
        }
        if ($text -notmatch '^(?is)(SELECT|SHOW|DESCRIBE)\b') {
            $writeCapable.Add("$($query.Id): unapproved leading statement")
            continue
        }
        if ($text -match '(?is)\bINTO\s+(OUTFILE|DUMPFILE)\b|\bFOR\s+UPDATE\b|\bLOCK\s+IN\s+SHARE\s+MODE\b') {
            $writeCapable.Add("$($query.Id): contains a write-capable SELECT form")
        }
    }
    $audit = [ordered]@{
        generated_utc = [DateTime]::UtcNow.ToString('o')
        statement_count = $Queries.Count
        read_only_statement_count = $Queries.Count - $writeCapable.Count
        write_capable_statement_count = $writeCapable.Count
        allowed_leading_statements = @('SELECT', 'SHOW', 'DESCRIBE')
        findings = @($writeCapable)
    }
    Write-Utf8Lf -Path $SqlAuditPath -Text (($audit | ConvertTo-Json -Depth 5) + "`n")
    if ($writeCapable.Count -ne 0) {
        throw "SQL static audit rejected $($writeCapable.Count) statement(s)."
    }
}

function Invoke-SanitizedQuery {
    param([pscustomobject]$Query)
    $result = Invoke-MariaDb -Sql $Query.Sql -AllowEmpty:$Query.AllowEmpty
    $body = if ([string]::IsNullOrEmpty($result)) { '' } else { $result.Replace("`r`n", "`n").Replace("`r", "`n") }
    $text = $Query.Header + "`n"
    if (-not [string]::IsNullOrEmpty($body)) { $text += $body.TrimEnd("`n") + "`n" }
    $path = Join-Path $QueryResultDirectory ($Query.Id + '.tsv')
    Write-Utf8Lf -Path $path -Text $text
    $rowCount = if ([string]::IsNullOrEmpty($body)) { 0 } else { @($body.TrimEnd("`n").Split("`n")).Count }
    [System.IO.File]::AppendAllText($TranscriptPath,
        ("QUERY {0}`nPURPOSE {1}`nSQL {2}`nRESULT_ROWS {3}`nRESULT_FILE {4}`n`n" -f $Query.Id, $Query.Purpose, $Query.Sql, $rowCount, $path), $Utf8NoBom)
    return $rowCount
}

$queries = @(
    [pscustomobject]@{ Id='database-identity'; Header='database_name\tserver_version\tversion_comment\tdatadir\tport\tbind_address\tcharacter_set_server\tcollation_server\tsql_mode'; AllowEmpty=$false; Purpose='Prove the selected logical database and reviewed runtime identity.'; Sql='SELECT DATABASE(),VERSION(),@@version_comment,REPLACE(@@datadir,''\\'',''/''),@@port,@@bind_address,@@character_set_server,@@collation_server,@@sql_mode' },
    [pscustomobject]@{ Id='relevant-table-presence'; Header='table_schema\ttable_name\tengine\ttable_collation\ttable_rows_estimate'; AllowEmpty=$false; Purpose='Inventory relevant live tables without reading unrelated rows.'; Sql='SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE,TABLE_COLLATION,TABLE_ROWS FROM information_schema.TABLES WHERE (TABLE_SCHEMA=''tw_char'' AND TABLE_NAME IN (''characters'',''character_skills'',''ai_playerbot_random_bots'')) OR (TABLE_SCHEMA=''tw_world'' AND TABLE_NAME=''playercreateinfo'') ORDER BY TABLE_SCHEMA,TABLE_NAME' },
    [pscustomobject]@{ Id='relevant-columns'; Header='table_schema\ttable_name\tordinal_position\tcolumn_name\tcolumn_type\tis_nullable\tcolumn_default\tcolumn_key'; AllowEmpty=$false; Purpose='Capture authoritative relevant column semantics.'; Sql='SELECT TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,IFNULL(COLUMN_DEFAULT,''<NULL>''),COLUMN_KEY FROM information_schema.COLUMNS WHERE (TABLE_SCHEMA=''tw_char'' AND TABLE_NAME IN (''characters'',''character_skills'',''ai_playerbot_random_bots'')) OR (TABLE_SCHEMA=''tw_world'' AND TABLE_NAME=''playercreateinfo'') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION' },
    [pscustomobject]@{ Id='appearance-columns'; Header='table_schema\ttable_name\tordinal_position\tcolumn_name\tcolumn_type'; AllowEmpty=$true; Purpose='Find schema fields that could encode character or PlayerBot appearance.'; Sql='SELECT TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN (''tw_char'',''tw_world'') AND (LOWER(COLUMN_NAME) REGEXP ''appearance|display|model|skin|face|hair|playerbytes'' OR LOWER(TABLE_NAME) REGEXP ''appearance|display|model|customization'') ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION' },
    [pscustomobject]@{ Id='show-create-characters'; Header='table_name\tcreate_definition'; AllowEmpty=$false; Purpose='Record the authoritative live characters definition.'; Sql='SHOW CREATE TABLE `characters`' },
    [pscustomobject]@{ Id='show-create-character-skills'; Header='table_name\tcreate_definition'; AllowEmpty=$false; Purpose='Record the authoritative live character skill definition.'; Sql='SHOW CREATE TABLE `character_skills`' },
    [pscustomobject]@{ Id='show-create-playerbot-events'; Header='table_name\tcreate_definition'; AllowEmpty=$false; Purpose='Record the authoritative PlayerBot event definition.'; Sql='SHOW CREATE TABLE `ai_playerbot_random_bots`' },
    [pscustomobject]@{ Id='account-join-quality'; Header='total_characters\tcharacters_with_account\tcharacters_without_account'; AllowEmpty=$false; Purpose='Prove that account-prefix classification covers authoritative characters without exporting account identity.'; Sql='SELECT COUNT(*),SUM(CASE WHEN a.id IS NOT NULL THEN 1 ELSE 0 END),SUM(CASE WHEN a.id IS NULL THEN 1 ELSE 0 END) FROM tw_char.characters c LEFT JOIN tw_logon.account a ON a.id=c.account' },
    [pscustomobject]@{ Id='population-aggregate'; Header='total_characters\trandom_account_stock\tnon_random_account_stock\tactive_rotation_existing\tconfigured_player_owned_always\tunclassified_non_random_stock'; AllowEmpty=$false; Purpose='Sanitized aggregate classification of character populations.'; Sql='SELECT COUNT(*),SUM(CASE WHEN LOWER(a.username) LIKE ''rndbot%'' THEN 1 ELSE 0 END),SUM(CASE WHEN LOWER(a.username) NOT LIKE ''rndbot%'' THEN 1 ELSE 0 END),SUM(CASE WHEN EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''add'') THEN 1 ELSE 0 END),SUM(CASE WHEN LOWER(a.username) NOT LIKE ''rndbot%'' AND EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''always'' AND e.value=1) THEN 1 ELSE 0 END),SUM(CASE WHEN LOWER(a.username) NOT LIKE ''rndbot%'' AND NOT EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''add'') AND NOT EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''always'' AND e.value=1) THEN 1 ELSE 0 END) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account' },
    [pscustomobject]@{ Id='bot-population-rows'; Header='population_key\tbot_guid\trace_id\tclass_id\tgender\tplayer_bytes\tplayer_bytes2'; AllowEmpty=$true; Purpose='Export only GUIDs belonging to independently proven bot populations, with no character or account names.'; Sql='SELECT p.population_key,p.bot_guid,c.race,c.class,c.gender,c.playerBytes,c.playerBytes2 FROM (SELECT DISTINCT ''random_account_stock'' AS population_key,c.guid AS bot_guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' UNION SELECT DISTINCT ''active_random_rotation'',c.guid FROM tw_char.characters c JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''add'' WHERE e.bot<>0 UNION SELECT DISTINCT ''inactive_random_reserve'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' AND NOT EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''add'') UNION SELECT DISTINCT ''configured_player_owned_always_online'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''always'' AND e.value=1 WHERE LOWER(a.username) NOT LIKE ''rndbot%'') p JOIN tw_char.characters c ON c.guid=p.bot_guid ORDER BY p.population_key,p.bot_guid' },
    [pscustomobject]@{ Id='bot-skill-rows'; Header='population_key\tbot_guid\tskill_id\tskill_value\tskill_maximum'; AllowEmpty=$true; Purpose='Capture character skill records only for proven bot populations.'; Sql='SELECT p.population_key,p.bot_guid,s.skill,s.value,s.max FROM (SELECT DISTINCT ''random_account_stock'' AS population_key,c.guid AS bot_guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' UNION SELECT DISTINCT ''active_random_rotation'',c.guid FROM tw_char.characters c JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''add'' WHERE e.bot<>0 UNION SELECT DISTINCT ''inactive_random_reserve'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' AND NOT EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''add'') UNION SELECT DISTINCT ''configured_player_owned_always_online'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''always'' AND e.value=1 WHERE LOWER(a.username) NOT LIKE ''rndbot%'') p JOIN tw_char.character_skills s ON s.guid=p.bot_guid ORDER BY p.population_key,p.bot_guid,s.skill' },
    [pscustomobject]@{ Id='playerbot-event-summary'; Header='owner_is_zero\tbot_is_zero\tevent\trow_count\tdistinct_bot_count\tminimum_value\tmaximum_value'; AllowEmpty=$true; Purpose='Summarize PlayerBot event records without exporting event data or account identity.'; Sql='SELECT IF(owner=0,1,0),IF(bot=0,1,0),event,COUNT(*),COUNT(DISTINCT bot),MIN(value),MAX(value) FROM tw_char.ai_playerbot_random_bots GROUP BY IF(owner=0,1,0),IF(bot=0,1,0),event ORDER BY 1 DESC,2 DESC,3' },
    [pscustomobject]@{ Id='playerbot-event-integrity'; Header='metric\tvalue'; AllowEmpty=$false; Purpose='Count placeholder, orphan, duplicate, and non-prefix event conditions without exporting orphan GUIDs.'; Sql='SELECT ''system_placeholder_rows'',COUNT(*) FROM tw_char.ai_playerbot_random_bots WHERE bot=0 UNION ALL SELECT ''orphan_nonzero_bot_rows'',COUNT(*) FROM tw_char.ai_playerbot_random_bots e LEFT JOIN tw_char.characters c ON c.guid=e.bot WHERE e.bot<>0 AND c.guid IS NULL UNION ALL SELECT ''duplicate_owner_bot_event_extra_rows'',IFNULL(SUM(x.row_count-1),0) FROM (SELECT COUNT(*) AS row_count FROM tw_char.ai_playerbot_random_bots GROUP BY owner,bot,event HAVING COUNT(*)>1) x UNION ALL SELECT ''nonprefix_add_characters'',COUNT(DISTINCT c.guid) FROM tw_char.ai_playerbot_random_bots e JOIN tw_char.characters c ON c.guid=e.bot JOIN tw_logon.account a ON a.id=c.account WHERE e.owner=0 AND e.event=''add'' AND LOWER(a.username) NOT LIKE ''rndbot%'' UNION ALL SELECT ''login_marker_rows'',COUNT(*) FROM tw_char.ai_playerbot_random_bots WHERE owner=0 AND event=''login''' },
    [pscustomobject]@{ Id='bot-skill-integrity'; Header='metric\tvalue'; AllowEmpty=$false; Purpose='Prove skill-row uniqueness for proven bots and count zero-valued skill records.'; Sql='SELECT ''duplicate_population_guid_skill_extra_rows'',IFNULL(SUM(x.row_count-1),0) FROM (SELECT p.population_key,p.bot_guid,s.skill,COUNT(*) AS row_count FROM (SELECT DISTINCT ''random_account_stock'' AS population_key,c.guid AS bot_guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' UNION SELECT DISTINCT ''active_random_rotation'',c.guid FROM tw_char.characters c JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''add'' WHERE e.bot<>0 UNION SELECT DISTINCT ''inactive_random_reserve'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' AND NOT EXISTS (SELECT 1 FROM tw_char.ai_playerbot_random_bots e WHERE e.owner=0 AND e.bot=c.guid AND e.event=''add'') UNION SELECT DISTINCT ''configured_player_owned_always_online'',c.guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event=''always'' AND e.value=1 WHERE LOWER(a.username) NOT LIKE ''rndbot%'') p JOIN tw_char.character_skills s ON s.guid=p.bot_guid GROUP BY p.population_key,p.bot_guid,s.skill HAVING COUNT(*)>1) x UNION ALL SELECT ''zero_value_population_skill_rows'',COUNT(*) FROM (SELECT DISTINCT c.guid AS bot_guid FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE LOWER(a.username) LIKE ''rndbot%'' UNION SELECT DISTINCT c.guid FROM tw_char.characters c JOIN tw_char.ai_playerbot_random_bots e ON e.owner=0 AND e.bot=c.guid AND e.event IN (''add'',''always'') AND e.bot<>0) p JOIN tw_char.character_skills s ON s.guid=p.bot_guid WHERE s.value=0' },
    [pscustomobject]@{ Id='world-race-class-combinations'; Header='race_id\tclass_id\tdefinition_count'; AllowEmpty=$true; Purpose='Capture locally configured character-creation combinations without names or gameplay rows.'; Sql='SELECT race,class,COUNT(*) FROM tw_world.playercreateinfo GROUP BY race,class ORDER BY race,class' }
)

$exitCode = 1
$primaryError = $null
$cleanupErrors = New-Object System.Collections.Generic.List[string]
$databasePid = $null
$beforeManifest = $null
$afterManifest = $null
$runtimeChangeCount = $null
$reviewedFunctionsLoaded = $false

try {
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw "Output directory is missing: $OutputDirectory" }
    if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) { throw "Evidence directory is missing: $EvidenceDirectory" }
    if (-not (Test-Path -LiteralPath $QueryResultDirectory -PathType Container)) { throw "Query result directory is missing: $QueryResultDirectory" }
    if (Test-Path -LiteralPath $ConsoleLog) { throw "Harness console evidence already exists: $ConsoleLog" }
    Write-Utf8Lf -Path $ConsoleLog -Text ''
    Assert-WindowsPowerShell51
    $actualHarnessHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHarnessHash -cne $ApprovedHarnessSha256.ToUpperInvariant()) { throw "Harness identity mismatch. Expected $ApprovedHarnessSha256, found $actualHarnessHash." }
    $reviewedHash = (Get-FileHash -LiteralPath $ReviewedRunbook -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($reviewedHash -cne $ExpectedReviewedRunbookSha256) { throw "Reviewed runbook identity mismatch. Found $reviewedHash." }
    $reviewedFunctionSource = Import-ReviewedDatabaseFunctions
    Invoke-Expression $reviewedFunctionSource
    $reviewedFunctionsLoaded = $true
    Assert-Administrator
    Assert-InitialCleanState
    foreach ($key in $ApprovedFiles.Keys) { Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256 }
    Assert-ReadOnlyQuerySet -Queries $queries
    Write-Utf8Lf -Path $TranscriptPath -Text ("READ-ONLY SQL TRANSCRIPT`nGenerated UTC: $([DateTime]::UtcNow.ToString('o'))`nStatement count: $($queries.Count)`nWrite-capable statement count: 0`n`n")
    Write-ConsoleEvidence 'Preflight passed: Windows PowerShell 5.1, Administrator=True, clean process/service/port state, runtime hashes verified.'
    $beforeManifest = Get-DataFileManifest
    Write-ConsoleEvidence ("Recorded pre-start active-data manifest in memory: files=$($beforeManifest.Count).")
    $database = Start-ReviewedDatabase
    $databasePid = $database.Id
    Write-ConsoleEvidence ("Started and adopted reviewed MariaDB process: pid=$databasePid.")
    Assert-DatabasePortOwnership
    Assert-ReviewedDatabaseConfiguration
    $rowLines = New-Object System.Collections.Generic.List[string]
    $rowLines.Add('query_id\tresult_rows')
    foreach ($query in $queries) {
        $count = Invoke-SanitizedQuery -Query $query
        $rowLines.Add(("{0}\t{1}" -f $query.Id, $count))
        Write-ConsoleEvidence ("Read-only query completed: id=$($query.Id), rows=$count.")
    }
    Write-Utf8Lf -Path $RowCountsPath -Text (($rowLines -join "`n") + "`n")
    $schemaIds = @('relevant-table-presence','relevant-columns','appearance-columns','show-create-characters','show-create-character-skills','show-create-playerbot-events')
    $schemaText = New-Object System.Collections.Generic.List[string]
    foreach ($id in $schemaIds) {
        $schemaText.Add("[$id]")
        $schemaText.Add([IO.File]::ReadAllText((Join-Path $QueryResultDirectory ($id + '.tsv'))))
    }
    Write-Utf8Lf -Path $SchemaEvidencePath -Text (($schemaText -join "`n").TrimEnd() + "`n")
    $exitCode = 0
}
catch {
    $primaryError = $_.Exception.Message
    [Console]::Error.WriteLine("[DISCOVERY ERROR] $primaryError")
}
finally {
    try {
        if ($reviewedFunctionsLoaded) {
            $owned = Get-VerifiedOwnedProcess -Kind Database
            if ($null -ne $owned) {
                [void](Stop-OwnedDatabase)
                Write-ConsoleEvidence ("Controlled MariaDB shutdown completed for owned pid=$($owned.Id).")
            }
        }
    }
    catch {
        $cleanupErrors.Add($_.Exception.Message)
        [Console]::Error.WriteLine("[CLEANUP ERROR] $($_.Exception.Message)")
        $exitCode = 1
    }
    try {
        $remainingDatabase = @()
        foreach ($name in @('mysqld','mariadbd')) { $remainingDatabase += @(Get-Process -Name $name -ErrorAction SilentlyContinue) }
        $remainingWorld = @(Get-Process -Name mangosd -ErrorAction SilentlyContinue)
        $remainingRealm = @(Get-Process -Name realmd -ErrorAction SilentlyContinue)
        $services = @(Get-MatchingRunningServices)
        $port3307 = @(Get-ListenerOwnerPids -Port 3307)
        $port8090 = @(Get-ListenerOwnerPids -Port 8090)
        if ($remainingDatabase.Count -ne 0 -or $remainingWorld.Count -ne 0 -or $remainingRealm.Count -ne 0 -or $services.Count -ne 0 -or $port3307.Count -ne 0 -or $port8090.Count -ne 0) {
            $cleanupErrors.Add(("Final clean-state failure: database={0}, world={1}, realm={2}, services={3}, port3307={4}, port8090={5}." -f $remainingDatabase.Count,$remainingWorld.Count,$remainingRealm.Count,$services.Count,$port3307.Count,$port8090.Count))
            $exitCode = 1
        }
        Write-ConsoleEvidence ("Final state: database_processes=$($remainingDatabase.Count), mangosd=$($remainingWorld.Count), realmd=$($remainingRealm.Count), services=$($services.Count), port3307=$($port3307.Count), port8090=$($port8090.Count).")
    }
    catch {
        $cleanupErrors.Add("Final-state inspection failed: $($_.Exception.Message)")
        $exitCode = 1
    }
    try {
        if (Test-Path -LiteralPath $DataDir -PathType Container) {
            $afterManifest = Get-DataFileManifest
            if ($null -ne $beforeManifest) {
                $runtimeChangeCount = Write-EngineChanges -Before $beforeManifest -After $afterManifest
                Write-ConsoleEvidence ("Recorded expected engine-runtime file changes separately: changed_paths=$runtimeChangeCount.")
            }
        }
    }
    catch {
        $cleanupErrors.Add("Engine-runtime change capture failed: $($_.Exception.Message)")
        $exitCode = 1
    }
    try {
        foreach ($key in $ApprovedFiles.Keys) { Assert-Hash -Path $ApprovedFiles[$key].Path -ExpectedSha256 $ApprovedFiles[$key].Sha256 }
    }
    catch {
        $cleanupErrors.Add("Post-run database runtime hash verification failed: $($_.Exception.Message)")
        $exitCode = 1
    }
    $result = [ordered]@{
        status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
        completed_utc = [DateTime]::UtcNow.ToString('o')
        powershell_version = $PSVersionTable.PSVersion.ToString()
        powershell_edition = $PSVersionTable.PSEdition
        administrator = $true
        reviewed_runbook_path = $ReviewedRunbook
        reviewed_runbook_sha256 = $ExpectedReviewedRunbookSha256
        harness_sha256 = if (Test-Path -LiteralPath $PSCommandPath) { (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToUpperInvariant() } else { $null }
        database_owned_pid = $databasePid
        sql_statement_count = $queries.Count
        sql_write_capable_statement_count = 0
        logical_database_writes = 0
        database_engine_runtime_changed_path_count = $runtimeChangeCount
        primary_error = $primaryError
        cleanup_errors = @($cleanupErrors)
    }
    try { Write-Utf8Lf -Path $HarnessResultPath -Text (($result | ConvertTo-Json -Depth 6) + "`n") } catch { [Console]::Error.WriteLine("[RESULT ERROR] $($_.Exception.Message)"); $exitCode = 1 }
}

exit $exitCode
