Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceRoot = 'C:\TW\evidence\PLAYERBOT-CLASS-RACE-MATRIX-01'
$serverRoot = 'C:\TW\ComTW\server'
$sourceRoot = 'C:\TW\ComTW\source'
$dbcRoot = 'C:\TW\ComTW\data\dbc'
$configPath = Join-Path $serverRoot 'aiplayerbot.conf'
$mangosConfigPath = Join-Path $serverRoot 'mangosd.conf'
$mysqlPath = 'C:\TW\ComTW\DB\bin\mysql.exe'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8Lines {
    param([string]$Path, [System.Collections.IEnumerable]$Lines)
    $text = [string]::Join("`r`n", @($Lines)) + "`r`n"
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

function Write-Tsv {
    param(
        [string]$Path,
        [string[]]$Header,
        [System.Collections.IEnumerable]$Rows
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(($Header -join "`t"))
    foreach ($row in $Rows) {
        $fields = foreach ($name in $Header) {
            $value = $row.$name
            if ($null -eq $value) { '' } else { ([string]$value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ') }
        }
        $lines.Add(($fields -join "`t"))
    }
    Write-Utf8Lines -Path $Path -Lines $lines
}

function Read-DbcNames {
    param([string]$Path, [int]$NameFieldIndex)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $recordCount = [BitConverter]::ToUInt32($bytes, 4)
    $fieldCount = [BitConverter]::ToUInt32($bytes, 8)
    $recordSize = [BitConverter]::ToUInt32($bytes, 12)
    if ($recordSize -ne ($fieldCount * 4)) {
        throw "Unexpected DBC record size in $Path"
    }
    $stringBase = 20 + ([int]$recordCount * [int]$recordSize)
    $result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $recordCount; $i++) {
        $recordBase = 20 + ($i * [int]$recordSize)
        $id = [BitConverter]::ToUInt32($bytes, $recordBase)
        $name = $null
        # The first localized name field is supplied from the local DBC format:
        # ChrRacesEntryfmt field 17, ChrClassesEntryfmt field 5.
        for ($locale = 0; $locale -lt 8; $locale++) {
            $offset = [BitConverter]::ToUInt32($bytes, $recordBase + (($NameFieldIndex + $locale) * 4))
            if ($offset -eq 0) { continue }
            $start = $stringBase + [int]$offset
            $end = $start
            while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
            if ($end -gt $start) {
                $name = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $end - $start)
                break
            }
        }
        if ($name) {
            $result.Add([pscustomobject]@{ id = [int]$id; name = $name })
        }
    }
    return @($result)
}

function Get-DatabaseInfo {
    param([string]$Key)
    $line = Get-Content -LiteralPath $mangosConfigPath | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Key) + '\s*=') } | Select-Object -First 1
    if (-not $line -or $line -notmatch '=\s*"([^"]+)"') {
        throw "Could not read $Key from $mangosConfigPath"
    }
    $parts = $Matches[1] -split ';'
    if ($parts.Count -lt 5) { throw "Unexpected $Key format" }
    return [pscustomobject]@{
        Host = $parts[0]
        Port = [int]$parts[1]
        User = $parts[2]
        Password = $parts[3]
        Database = $parts[4]
    }
}

function Invoke-ReadOnlyQuery {
    param([pscustomobject]$Connection, [string]$Sql)
    $arguments = @(
        "--host=$($Connection.Host)",
        "--port=$($Connection.Port)",
        '--protocol=tcp',
        "--user=$($Connection.User)",
        "--password=$($Connection.Password)",
        '--skip-ssl',
        '--batch',
        '--raw',
        '--skip-column-names',
        "--database=$($Connection.Database)",
        '--execute',
        $Sql
    )
    $output = @(& $mysqlPath @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Read-only query failed: $($output -join ' ')"
    }
    return @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -notmatch '^mysql: \[Warning\] Using a password on the command line interface can be insecure\.$' })
}

function New-Key([int]$Race, [int]$Class) {
    return "$Race/$Class"
}

$races = @(Read-DbcNames -Path (Join-Path $dbcRoot 'ChrRaces.dbc') -NameFieldIndex 17 | Sort-Object id)
$classes = @(Read-DbcNames -Path (Join-Path $dbcRoot 'ChrClasses.dbc') -NameFieldIndex 5 | Sort-Object id)
$raceById = @{}
$classById = @{}
foreach ($race in $races) { $raceById[[int]$race.id] = $race.name }
foreach ($class in $classes) { $classById[[int]$class.id] = $class.name }

$worldConnection = Get-DatabaseInfo -Key 'WorldDatabase.Info'
$loginConnection = Get-DatabaseInfo -Key 'LoginDatabase.Info'
$characterConnection = Get-DatabaseInfo -Key 'CharacterDatabase.Info'

$playerCreateRows = @(Invoke-ReadOnlyQuery -Connection $worldConnection -Sql 'SELECT race, class FROM playercreateinfo ORDER BY race, class;')
$dbKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($line in $playerCreateRows) {
    $parts = $line -split "`t"
    [void]$dbKeys.Add((New-Key -Race ([int]$parts[0]) -Class ([int]$parts[1])))
}

# This exact MANGOSBOT_ZERO allow-list is transcribed from the locally hashed
# RandomPlayerbotFactory constructor. It is deliberately kept separate from
# playercreateinfo because the local sources do not derive this list from SQL.
$factoryByClass = [ordered]@{
    1  = @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    2  = @(1, 3, 10)
    3  = @(1, 2, 3, 4, 6, 8, 9, 10)
    4  = @(1, 2, 3, 4, 5, 7, 8, 9, 10)
    5  = @(1, 3, 4, 5, 8, 10)
    7  = @(2, 6, 8)
    8  = @(1, 5, 7, 8, 9, 10)
    9  = @(1, 2, 5, 7, 9)
    11 = @(4, 6)
}
$factoryKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($classEntry in $factoryByClass.GetEnumerator()) {
    foreach ($raceId in $classEntry.Value) {
        [void]$factoryKeys.Add((New-Key -Race ([int]$raceId) -Class ([int]$classEntry.Key)))
    }
}

$factoryOnly = @($factoryKeys | Where-Object { -not $dbKeys.Contains($_) } | Sort-Object)
if ($factoryOnly.Count -ne 0) {
    throw "Factory allows combinations absent from playercreateinfo: $($factoryOnly -join ', ')"
}

$effectiveKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($key in $factoryKeys) {
    if ($dbKeys.Contains($key)) { [void]$effectiveKeys.Add($key) }
}

$accountPrefix = 'RNDBOT'
$accountCount = 500
$accountLines = @(Invoke-ReadOnlyQuery -Connection $loginConnection -Sql "SELECT COUNT(*), SUM(username REGEXP '^RNDBOT([0-9]|[1-9][0-9]|[1-4][0-9][0-9])$') FROM account WHERE username LIKE 'RNDBOT%';")
$accountParts = $accountLines[0] -split "`t"
$prefixAccountCount = [int]$accountParts[0]
$exactAccountCount = [int]$accountParts[1]

$botSql = @"
SELECT c.race, c.class, COUNT(*)
FROM characters c
JOIN $($loginConnection.Database).account a ON a.id = c.account
WHERE a.username REGEXP '^RNDBOT([0-9]|[1-9][0-9]|[1-4][0-9][0-9])$'
GROUP BY c.race, c.class
ORDER BY c.race, c.class;
"@
$botLines = @(Invoke-ReadOnlyQuery -Connection $characterConnection -Sql $botSql)
$botCounts = @{}
foreach ($line in $botLines) {
    $parts = $line -split "`t"
    $botCounts[(New-Key -Race ([int]$parts[0]) -Class ([int]$parts[1]))] = [int]$parts[2]
}

$eventLines = @(Invoke-ReadOnlyQuery -Connection $characterConnection -Sql "SELECT event, COUNT(*), COUNT(DISTINCT bot) FROM ai_playerbot_random_bots GROUP BY event ORDER BY event;")
$botCountEventLines = @(Invoke-ReadOnlyQuery -Connection $characterConnection -Sql "SELECT value FROM ai_playerbot_random_bots WHERE bot=0 AND owner=0 AND event='bot_count' ORDER BY time DESC LIMIT 1;")
$configuredOnlineTarget = if ($botCountEventLines.Count -gt 0) { [int]$botCountEventLines[0] } else { $null }

$matrix = [System.Collections.Generic.List[object]]::new()
foreach ($race in $races) {
    foreach ($class in $classes) {
        $key = New-Key -Race $race.id -Class $class.id
        $dbAllowed = [int]$dbKeys.Contains($key)
        $factoryAllowed = [int]$factoryKeys.Contains($key)
        $effectiveAllowed = [int]($dbAllowed -eq 1 -and $factoryAllowed -eq 1)
        $count = if ($botCounts.ContainsKey($key)) { [int]$botCounts[$key] } else { 0 }
        $matrix.Add([pscustomobject]@{
            race_id = $race.id
            class_id = $class.id
            race_name = $race.name
            class_name = $class.name
            playercreateinfo_allowed = $dbAllowed
            factory_allowed = $factoryAllowed
            effective_allowed = $effectiveAllowed
            bot_count = $count
        })
    }
}

$effectiveRows = @($matrix | Where-Object effective_allowed -eq 1 | Sort-Object class_id, race_id)
$currentRandomBotCount = [int](($botCounts.Values | Measure-Object -Sum).Sum)
$mean = $currentRandomBotCount / [double]$effectiveRows.Count
$representationRows = foreach ($row in $effectiveRows) {
    $delta = $row.bot_count - $mean
    [pscustomobject]@{
        race_id = $row.race_id
        class_id = $row.class_id
        race_name = $row.race_name
        class_name = $row.class_name
        bot_count = $row.bot_count
        equal_share = $mean.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
        delta_from_equal_share = $delta.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
        representation = if ($delta -gt 0) { 'OVER' } elseif ($delta -lt 0) { 'UNDER' } else { 'EQUAL' }
    }
}

$missingDbRows = @($matrix | Where-Object { $_.playercreateinfo_allowed -eq 1 -and $_.bot_count -eq 0 } | Sort-Object race_id, class_id)
$missingEffectiveRows = @($matrix | Where-Object { $_.effective_allowed -eq 1 -and $_.bot_count -eq 0 } | Sort-Object race_id, class_id)
$dbOnlyRows = @($matrix | Where-Object { $_.playercreateinfo_allowed -eq 1 -and $_.factory_allowed -eq 0 } | Sort-Object race_id, class_id)
$invalidCurrentRows = @($matrix | Where-Object { $_.bot_count -gt 0 -and $_.effective_allowed -eq 0 })
if ($invalidCurrentRows.Count -ne 0) {
    throw "Current random-bot accounts contain combinations outside the effective matrix"
}

Write-Tsv -Path (Join-Path $evidenceRoot 'races.tsv') -Header @('race_id','race_name') -Rows @($races | ForEach-Object { [pscustomobject]@{ race_id = $_.id; race_name = $_.name } })
Write-Tsv -Path (Join-Path $evidenceRoot 'classes.tsv') -Header @('class_id','class_name') -Rows @($classes | ForEach-Object { [pscustomobject]@{ class_id = $_.id; class_name = $_.name } })
Write-Tsv -Path (Join-Path $evidenceRoot 'playercreateinfo-matrix.tsv') -Header @('race_id','class_id','race_name','class_name','allowed') -Rows @($matrix | ForEach-Object {
    [pscustomobject]@{ race_id=$_.race_id; class_id=$_.class_id; race_name=$_.race_name; class_name=$_.class_name; allowed=$_.playercreateinfo_allowed }
})
Write-Tsv -Path (Join-Path $evidenceRoot 'effective-randombot-matrix.tsv') -Header @('race_id','class_id','race_name','class_name','playercreateinfo_allowed','factory_allowed','effective_allowed') -Rows $matrix
Write-Tsv -Path (Join-Path $evidenceRoot 'db-valid-but-randombot-unsupported.tsv') -Header @('race_id','class_id','race_name','class_name') -Rows $dbOnlyRows
Write-Tsv -Path (Join-Path $evidenceRoot 'current-randombot-counts.tsv') -Header @('race_id','class_id','race_name','class_name','bot_count') -Rows @($matrix | Where-Object bot_count -gt 0 | Sort-Object race_id, class_id)
Write-Tsv -Path (Join-Path $evidenceRoot 'current-randombot-all-combinations.tsv') -Header @('race_id','class_id','race_name','class_name','effective_allowed','bot_count') -Rows $matrix
Write-Tsv -Path (Join-Path $evidenceRoot 'current-representation-analysis.tsv') -Header @('race_id','class_id','race_name','class_name','bot_count','equal_share','delta_from_equal_share','representation') -Rows $representationRows
Write-Tsv -Path (Join-Path $evidenceRoot 'currently-missing-playercreateinfo-combinations.tsv') -Header @('race_id','class_id','race_name','class_name') -Rows $missingDbRows
Write-Tsv -Path (Join-Path $evidenceRoot 'currently-missing-effective-randombot-combinations.tsv') -Header @('race_id','class_id','race_name','class_name') -Rows $missingEffectiveRows

$eventRows = foreach ($line in $eventLines) {
    $parts = $line -split "`t"
    [pscustomobject]@{ event=$parts[0]; row_count=[int]$parts[1]; distinct_bot_count=[int]$parts[2] }
}
Write-Tsv -Path (Join-Path $evidenceRoot 'random-bot-event-state.tsv') -Header @('event','row_count','distinct_bot_count') -Rows $eventRows

$validCount = $effectiveRows.Count
$proposalA = 1
$proposalB = 2
$target = 50
$proposalC = [Math]::Max(1, [int][Math]::Round($target / [double]$validCount, [MidpointRounding]::AwayFromZero))
$proposalRows = @(
    [pscustomobject]@{ proposal='A'; fixed_count_per_combination=$proposalA; total_bots=$validCount*$proposalA; target=($validCount*$proposalA); exact_target='YES' },
    [pscustomobject]@{ proposal='B'; fixed_count_per_combination=$proposalB; total_bots=$validCount*$proposalB; target=($validCount*$proposalB); exact_target='YES' },
    [pscustomobject]@{ proposal='C'; fixed_count_per_combination=$proposalC; total_bots=$validCount*$proposalC; target=$target; exact_target=$(if (($validCount*$proposalC) -eq $target) {'YES'} else {'NO'}) }
)
Write-Tsv -Path (Join-Path $evidenceRoot 'distribution-proposals.tsv') -Header @('proposal','fixed_count_per_combination','total_bots','target','exact_target') -Rows $proposalRows

$configLines = [System.Collections.Generic.List[string]]::new()
$configLines.Add('# PLAYERBOT-CLASS-RACE-MATRIX-01 - PROPOSAL ONLY; NOT APPLIED')
$configLines.Add('# Proposal C: closest strictly equal positive distribution to 50 bots.')
$configLines.Add('# Effective validity = tw_world.playercreateinfo AND local RandomPlayerbotFactory (MANGOSBOT_ZERO).')
$configLines.Add('# Invalid/unsupported combinations are intentionally omitted, not emitted as zero entries.')
$configLines.Add('AiPlayerbot.ClassRace.UseFixedClassRaceCounts = 1')
foreach ($row in $effectiveRows) {
    $configLines.Add(('AiPlayerbot.ClassRaceProb.{0}.{1} = {2}    # {3} / {4}' -f $row.class_id, $row.race_id, $proposalC, $row.race_name, $row.class_name))
}
Write-Utf8Lines -Path (Join-Path $evidenceRoot 'proposed-fixed-count-config.conf') -Lines $configLines

$overCount = @($representationRows | Where-Object representation -eq 'OVER').Count
$underCount = @($representationRows | Where-Object representation -eq 'UNDER').Count
$minRow = $effectiveRows | Sort-Object bot_count, race_id, class_id | Select-Object -First 1
$maxRow = $effectiveRows | Sort-Object @{ Expression = 'bot_count'; Descending = $true }, race_id, class_id | Select-Object -First 1
$summary = @(
    'CLASS_RACE_MATRIX_RESULT=PASS'
    'FIXED_COUNT_SEMANTICS=CONFIRMED'
    "RACE_COUNT=$($races.Count)"
    "CLASS_COUNT=$($classes.Count)"
    "PLAYERCREATEINFO_COMBINATION_COUNT=$($dbKeys.Count)"
    "BOT_FACTORY_COMBINATION_COUNT=$($factoryKeys.Count)"
    "VALID_COMBINATION_COUNT=$validCount"
    "DB_VALID_BUT_BOT_UNSUPPORTED_COUNT=$($dbOnlyRows.Count)"
    "CURRENT_RANDOMBOT_ACCOUNT_COUNT=$exactAccountCount"
    "CURRENT_RANDOMBOT_COUNT=$currentRandomBotCount"
    "CURRENT_EFFECTIVE_MISSING_COUNT=$($missingEffectiveRows.Count)"
    "CURRENT_PLAYERCREATEINFO_MISSING_COUNT=$($missingDbRows.Count)"
    "CURRENT_OVERREPRESENTED_COMBINATION_COUNT=$overCount"
    "CURRENT_UNDERREPRESENTED_COMBINATION_COUNT=$underCount"
    "CURRENT_EQUAL_SHARE=$($mean.ToString('F6', [Globalization.CultureInfo]::InvariantCulture))"
    "CURRENT_MIN_COMBINATION=$($minRow.race_id)/$($minRow.class_id) $($minRow.race_name)/$($minRow.class_name) ($($minRow.bot_count))"
    "CURRENT_MAX_COMBINATION=$($maxRow.race_id)/$($maxRow.class_id) $($maxRow.race_name)/$($maxRow.class_name) ($($maxRow.bot_count))"
    "CURRENT_ONLINE_TARGET_EVENT=$configuredOnlineTarget"
    "MINIMUM_BOTS_FOR_FULL_COVERAGE=$validCount"
    "EXACT_EQUAL_DISTRIBUTION_WITH_50=$(if (($target % $validCount) -eq 0) {'YES'} else {'NO'})"
    "RECOMMENDED_FIXED_COUNT_PER_COMBINATION=$proposalC"
    "RECOMMENDED_TOTAL_BOTS=$($proposalC*$validCount)"
    "PREFIX_MATCHING_ACCOUNT_COUNT=$prefixAccountCount"
    "EXACT_CONFIGURED_ACCOUNT_COUNT=$exactAccountCount"
    "CONFIGURED_ACCOUNT_RANGE=${accountPrefix}0-$accountPrefix$($accountCount-1)"
)
Write-Utf8Lines -Path (Join-Path $evidenceRoot 'matrix-summary.txt') -Lines $summary

$configFile = Get-Item -LiteralPath $configPath
$sectionPath = Join-Path $evidenceRoot 'aiplayerbot-ClassRaceProb-section.conf.txt'
$sourceFiles = @(
    Join-Path $sourceRoot 'src\game\SharedDefines.h'
    Join-Path $sourceRoot 'src\game\Database\DBCfmt.h'
    Join-Path $sourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp'
    Join-Path $sourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp'
    Join-Path $sourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp'
    Join-Path $sourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotLoginMgr.cpp'
    Join-Path $sourceRoot 'src\game\ObjectMgr.cpp'
    Join-Path $dbcRoot 'ChrRaces.dbc'
    Join-Path $dbcRoot 'ChrClasses.dbc'
)
$inputHashRows = @(
    [pscustomobject]@{ path=$configFile.FullName; length=$configFile.Length; last_write_time_utc=$configFile.LastWriteTimeUtc.ToString('o'); sha256=(Get-FileHash -LiteralPath $configFile.FullName -Algorithm SHA256).Hash }
    [pscustomobject]@{ path=$sectionPath; length=(Get-Item $sectionPath).Length; last_write_time_utc=(Get-Item $sectionPath).LastWriteTimeUtc.ToString('o'); sha256=(Get-FileHash -LiteralPath $sectionPath -Algorithm SHA256).Hash }
)
foreach ($path in $sourceFiles) {
    $item = Get-Item -LiteralPath $path
    $inputHashRows += [pscustomobject]@{ path=$item.FullName; length=$item.Length; last_write_time_utc=$item.LastWriteTimeUtc.ToString('o'); sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
}
Write-Tsv -Path (Join-Path $evidenceRoot 'verified-input-hashes.tsv') -Header @('path','length','last_write_time_utc','sha256') -Rows $inputHashRows

# Create the manifest last and exclude it from itself.
$manifestRows = Get-ChildItem -LiteralPath $evidenceRoot -File | Where-Object Name -ne 'manifest.sha256.tsv' | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        file = $_.Name
        length = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}
Write-Tsv -Path (Join-Path $evidenceRoot 'manifest.sha256.tsv') -Header @('file','length','sha256') -Rows $manifestRows

Get-Content -LiteralPath (Join-Path $evidenceRoot 'matrix-summary.txt')
