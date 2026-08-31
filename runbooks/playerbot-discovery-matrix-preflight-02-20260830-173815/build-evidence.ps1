$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$OutputDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repository = 'C:\TW\ComTW\source'
$ServerDirectory = 'C:\TW\ComTW\server'
$ConfigPath = Join-Path $ServerDirectory 'aiplayerbot.conf'
$MainConfigPath = Join-Path $ServerDirectory 'mangosd.conf'
$ProfessionEvidenceDirectory = 'C:\TW\ComTW\runbooks\db-profession-riding-discovery-01-20260830-010856'
$PhaseOneEvidenceDirectory = 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352'
$PersonalityEvidenceDirectory = 'C:\TW\ComTW\runbooks\bot-personality-discovery-20260828-224032'
$CapturedUtc = [DateTime]::UtcNow
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256([string]$Path)
{
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-FileIdentity([string]$Path, [long]$ExpectedLength, [string]$ExpectedSha256)
{
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Required evidence file is missing: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $hash = Get-Sha256 $Path
    if ($item.Length -ne $ExpectedLength -or $hash -ne $ExpectedSha256)
    {
        throw "Evidence identity mismatch: $Path; bytes=$($item.Length); sha256=$hash"
    }
}

function Write-Utf8Text([string]$Path, [string]$Text)
{
    $normalized = $Text -replace "`r?`n", "`r`n"
    if (-not $normalized.EndsWith("`r`n"))
    {
        $normalized += "`r`n"
    }
    [System.IO.File]::WriteAllText($Path, $normalized, $Utf8NoBom)
}

function Write-Csv([string]$Path, [object[]]$Rows)
{
    $lines = @($Rows | ConvertTo-Csv -NoTypeInformation)
    [System.IO.File]::WriteAllLines($Path, $lines, $Utf8NoBom)
}

function Get-Number([object]$Value)
{
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value))
    {
        return 0
    }
    return [int]$Value
}

function Get-PairKey([int]$Race, [int]$Class)
{
    return "$Race`:$Class"
}

function Get-EqualTargets([object[]]$Pairs, [int]$TargetSize)
{
    $targets = @{}
    foreach ($pair in $Pairs)
    {
        $targets[(Get-PairKey $pair.race_id $pair.class_id)] = 0
    }

    foreach ($faction in @('Alliance', 'Horde'))
    {
        $factionPairs = @($Pairs | Where-Object { $_.faction -eq $faction } | Sort-Object race_id, class_id)
        $quota = [int]($TargetSize / 2)
        $base = [int][Math]::Floor($quota / $factionPairs.Count)
        $remainder = $quota - ($base * $factionPairs.Count)
        $raceTotals = @{}
        $classTotals = @{}

        foreach ($pair in $factionPairs)
        {
            $key = Get-PairKey $pair.race_id $pair.class_id
            $targets[$key] = $base
            $raceTotals[$pair.race_id] = (Get-Number $raceTotals[$pair.race_id]) + $base
            $classTotals[$pair.class_id] = (Get-Number $classTotals[$pair.class_id]) + $base
        }

        for ($seat = 0; $seat -lt $remainder; $seat++)
        {
            $candidate = $factionPairs |
                Where-Object { $targets[(Get-PairKey $_.race_id $_.class_id)] -eq $base } |
                Sort-Object @{ Expression = { Get-Number $raceTotals[$_.race_id] } },
                            @{ Expression = { Get-Number $classTotals[$_.class_id] } },
                            race_id, class_id |
                Select-Object -First 1

            $key = Get-PairKey $candidate.race_id $candidate.class_id
            $targets[$key]++
            $raceTotals[$candidate.race_id] = (Get-Number $raceTotals[$candidate.race_id]) + 1
            $classTotals[$candidate.class_id] = (Get-Number $classTotals[$candidate.class_id]) + 1
        }
    }

    return $targets
}

function Get-WeightedTargets([object[]]$Pairs, [int]$TargetSize)
{
    $targets = @{}
    foreach ($pair in $Pairs)
    {
        $targets[(Get-PairKey $pair.race_id $pair.class_id)] = 0
    }

    foreach ($faction in @('Alliance', 'Horde'))
    {
        $factionPairs = @($Pairs | Where-Object { $_.faction -eq $faction } | Sort-Object race_id, class_id)
        $quota = [int]($TargetSize / 2)
        $raceTotals = @{}
        $classTotals = @{}

        for ($seat = 0; $seat -lt $quota; $seat++)
        {
            $candidatePool = @($factionPairs | Where-Object { $targets[(Get-PairKey $_.race_id $_.class_id)] -eq 0 })
            if ($candidatePool.Count -eq 0)
            {
                $candidatePool = $factionPairs
            }

            $candidate = $candidatePool |
                Sort-Object @{ Expression = { Get-Number $classTotals[$_.class_id] } },
                            @{ Expression = { Get-Number $raceTotals[$_.race_id] } },
                            @{ Expression = { $targets[(Get-PairKey $_.race_id $_.class_id)] } },
                            race_id, class_id |
                Select-Object -First 1

            $key = Get-PairKey $candidate.race_id $candidate.class_id
            $targets[$key]++
            $raceTotals[$candidate.race_id] = (Get-Number $raceTotals[$candidate.race_id]) + 1
            $classTotals[$candidate.class_id] = (Get-Number $classTotals[$candidate.class_id]) + 1
        }
    }

    return $targets
}

$ProfessionRowsPath = Join-Path $ProfessionEvidenceDirectory 'rndbot-professions.csv'
$ProfessionSummaryPath = Join-Path $ProfessionEvidenceDirectory 'profession-skill-distribution.csv'
$WorldPairsPath = Join-Path $PersonalityEvidenceDirectory 'evidence\query-results\world-race-class-combinations.tsv'
$EventEvidencePath = Join-Path $PhaseOneEvidenceDirectory 'evidence\db-discovery-selects.stdout.txt'
$GroupEvidencePath = Join-Path $PhaseOneEvidenceDirectory 'evidence\bot-candidate-selects.stdout.txt'

Assert-FileIdentity $ConfigPath 283717 '490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF'
Assert-FileIdentity $ProfessionRowsPath 267246 'C04DE6B7D214C97582CDA26CA6150717891078B1DC4E37CEDBD7423B49C3CB15'
Assert-FileIdentity $ProfessionSummaryPath 796 'D15757A036F9A835CD88CAA2F785250951C3C24FCF2C7A76F32F70F6251FBF56'
Assert-FileIdentity $WorldPairsPath 398 'B343AB94D3BC29C037464894E12F4470D5B19BF0D0660A03AC3D0E316B194369'
Assert-FileIdentity $EventEvidencePath 8567 '1420338A9A9613F9FBB0AEABEC45BFF34065F7249682ED1216BB2AD2392A8431'
Assert-FileIdentity $GroupEvidencePath 441 '044CF654F944D00CEF2574DCDE6B33EAC3221EA116084426873F15D29201CFDE'

$raceNames = @{
    1 = 'Human'; 2 = 'Orc'; 3 = 'Dwarf'; 4 = 'Night Elf'; 5 = 'Undead'
    6 = 'Tauren'; 7 = 'Gnome'; 8 = 'Troll'; 9 = 'Goblin'; 10 = 'High Elf'
}
$classNames = @{
    1 = 'Warrior'; 2 = 'Paladin'; 3 = 'Hunter'; 4 = 'Rogue'; 5 = 'Priest'
    7 = 'Shaman'; 8 = 'Mage'; 9 = 'Warlock'; 11 = 'Druid'
}
$allianceRaces = @(1, 3, 4, 7, 10)

$generatableDefinition = @{
    1 = @(1,2,3,4,5,6,7,8,9,10)
    2 = @(1,3,10)
    3 = @(1,2,3,4,6,8,9,10)
    4 = @(1,2,3,4,5,7,8,9,10)
    5 = @(1,3,4,5,8,10)
    7 = @(2,6,8)
    8 = @(1,5,7,8,9,10)
    9 = @(1,2,5,7,9)
    11 = @(4,6)
}

$generatableKeys = @{}
foreach ($classId in $generatableDefinition.Keys)
{
    foreach ($raceId in $generatableDefinition[$classId])
    {
        $generatableKeys[(Get-PairKey $raceId $classId)] = $true
    }
}
if ($generatableKeys.Count -ne 52)
{
    throw "The source allow-list model did not produce exactly 52 pairs."
}

$worldPairRows = @()
$worldPairLines = Get-Content -LiteralPath $WorldPairsPath
foreach ($line in @($worldPairLines | Select-Object -Skip 1))
{
    $parts = $line -split "`t"
    if ($parts.Count -lt 2)
    {
        $parts = $line -split '\\t'
    }
    if ($parts.Count -lt 2)
    {
        throw "Malformed playercreateinfo evidence row: $line"
    }
    $worldPairRows += [pscustomobject]@{ race_id = [int]$parts[0]; class_id = [int]$parts[1] }
}
if ($worldPairRows.Count -ne 59 -or @($worldPairRows | Sort-Object race_id, class_id -Unique).Count -ne 59)
{
    throw "The accepted playercreateinfo evidence is not the expected unique 59-pair matrix."
}

$configLines = Get-Content -LiteralPath $ConfigPath
$explicitConfig = @{}
for ($lineIndex = 0; $lineIndex -lt $configLines.Count; $lineIndex++)
{
    $match = [regex]::Match($configLines[$lineIndex], '^AiPlayerbot\.ClassRaceProb\.(\d+)\.(\d+)\s*=\s*(\d+)')
    if ($match.Success)
    {
        $classId = [int]$match.Groups[1].Value
        $raceId = [int]$match.Groups[2].Value
        $explicitConfig[(Get-PairKey $raceId $classId)] = [pscustomobject]@{
            value = [int]$match.Groups[3].Value
            line = $lineIndex + 1
        }
    }
}
if ($explicitConfig.Count -ne 40)
{
    throw "The active config did not contain the expected 40 explicit class/race rows."
}

$stockRows = @(Import-Csv -LiteralPath $ProfessionRowsPath)
if ($stockRows.Count -ne 4500 -or @($stockRows | Group-Object guid | Where-Object Count -ne 1).Count -ne 0)
{
    throw "The accepted RNDBOT evidence is not a unique 4,500-GUID population."
}

$stockByGuid = @{}
foreach ($row in $stockRows)
{
    $stockByGuid[[int]$row.guid] = $row
}

$stockPairGroups = @($stockRows | Group-Object race, class)
$stockByPair = @{}
foreach ($group in $stockPairGroups)
{
    $row = $group.Group[0]
    $stockByPair[(Get-PairKey ([int]$row.race) ([int]$row.class))] = $group.Count
}
if ($stockByPair.Count -ne 52)
{
    throw "The accepted RNDBOT stock did not produce the expected 52 observed pairs."
}

$eventRows = @()
$inEventSection = $false
foreach ($line in Get-Content -LiteralPath $EventEvidencePath)
{
    if ($line -eq "SECTION`tADD_LOGIN_ROWS")
    {
        $inEventSection = $true
        continue
    }
    if ($inEventSection -and $line.StartsWith("SECTION`t"))
    {
        break
    }
    if ($inEventSection -and -not [string]::IsNullOrWhiteSpace($line))
    {
        $parts = $line -split "`t"
        if ($parts.Count -ne 5 -or $parts[1] -ne 'add')
        {
            throw "Malformed sanitized add-event evidence row: $line"
        }
        $eventRows += [pscustomobject]@{
            guid = [int]$parts[0]
            value = [int]$parts[2]
            changed_epoch = [long]$parts[3]
            valid_seconds = [long]$parts[4]
        }
    }
}
if ($eventRows.Count -ne 53)
{
    throw "The accepted event evidence did not contain exactly 53 stored add rows."
}

$captureEpoch = [DateTimeOffset]$CapturedUtc
$captureEpochSeconds = $captureEpoch.ToUnixTimeSeconds()
$eventByPairLevel = @{}
$sanitizedEventRows = @()
foreach ($event in $eventRows | Sort-Object guid)
{
    if (-not $stockByGuid.ContainsKey($event.guid))
    {
        throw "Stored add GUID is absent from the accepted RNDBOT stock: $($event.guid)"
    }
    $stock = $stockByGuid[$event.guid]
    $expiresEpoch = $event.changed_epoch + $event.valid_seconds
    $timerActive = [int](($event.value -ne 0) -and ($expiresEpoch -gt $captureEpochSeconds))
    $aggregateKey = "$($stock.race):$($stock.class):$($stock.level)"
    if (-not $eventByPairLevel.ContainsKey($aggregateKey))
    {
        $eventByPairLevel[$aggregateKey] = [pscustomobject]@{ stored = 0; active = 0 }
    }
    $eventByPairLevel[$aggregateKey].stored++
    $eventByPairLevel[$aggregateKey].active += $timerActive

    $sanitizedEventRows += [pscustomobject]@{
        snapshot_type = 'stored_add_event'
        guid = $event.guid
        race_id = [int]$stock.race
        race = $raceNames[[int]$stock.race]
        class_id = [int]$stock.class
        class = $classNames[[int]$stock.class]
        level = [int]$stock.level
        event_value = $event.value
        changed_utc = [DateTimeOffset]::FromUnixTimeSeconds($event.changed_epoch).UtcDateTime.ToString('o')
        expires_utc = [DateTimeOffset]::FromUnixTimeSeconds($expiresEpoch).UtcDateTime.ToString('o')
        effective_timer_active_at_capture = $timerActive
    }
}

$groupEvidenceTimestamp = (Get-Item -LiteralPath $GroupEvidencePath).LastWriteTimeUtc
$groupDataFiles = @(
    'C:\TW\ComTW\DB\data\tw_char\groups.MYD',
    'C:\TW\ComTW\DB\data\tw_char\groups.MYI',
    'C:\TW\ComTW\DB\data\tw_char\group_member.MYD',
    'C:\TW\ComTW\DB\data\tw_char\group_member.MYI'
)
$groupEvidenceCurrent = $true
foreach ($path in $groupDataFiles)
{
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).LastWriteTimeUtc -gt $groupEvidenceTimestamp)
    {
        $groupEvidenceCurrent = $false
    }
}

$lastAcceptedGroupRows = @()
$inGroupDetailSection = $false
foreach ($line in Get-Content -LiteralPath $GroupEvidencePath)
{
    if ($line -eq "SECTION`tGROUP_SIDE_PATH_DETAILS_REDACTED")
    {
        $inGroupDetailSection = $true
        continue
    }
    if ($inGroupDetailSection -and $line.StartsWith("SECTION`t"))
    {
        break
    }
    if ($inGroupDetailSection -and -not [string]::IsNullOrWhiteSpace($line))
    {
        $parts = $line -split "`t"
        if ($parts.Count -ne 5)
        {
            throw "Malformed prior group evidence row."
        }
        $guid = [int]$parts[1]
        if (-not $stockByGuid.ContainsKey($guid))
        {
            throw "Prior group GUID is absent from the accepted RNDBOT stock: $guid"
        }
        $stock = $stockByGuid[$guid]
        $lastAcceptedGroupRows += [pscustomobject]@{
            guid = $guid
            race_id = [int]$stock.race
            race = $raceNames[[int]$stock.race]
            class_id = [int]$stock.class
            class = $classNames[[int]$stock.class]
            level = [int]$stock.level
            prior_leader_type = $parts[4]
            evidence_status = if ($groupEvidenceCurrent) { 'CURRENT' } else { 'SUPERSEDED_BY_LATER_GROUP_FILE_WRITES' }
            current_group_membership = if ($groupEvidenceCurrent) { 'PROVEN' } else { 'UNPROVEN' }
        }
    }
}
if ($lastAcceptedGroupRows.Count -ne 11)
{
    throw "The accepted prior group evidence did not contain exactly 11 sanitized GUIDs."
}

$populationRows = @()
foreach ($group in @($stockRows | Group-Object race, class, level))
{
    $row = $group.Group[0]
    $key = "$($row.race):$($row.class):$($row.level)"
    $stored = 0
    $active = 0
    if ($eventByPairLevel.ContainsKey($key))
    {
        $stored = $eventByPairLevel[$key].stored
        $active = $eventByPairLevel[$key].active
    }
    $populationRows += [pscustomobject]@{
        race_id = [int]$row.race
        race = $raceNames[[int]$row.race]
        class_id = [int]$row.class
        class = $classNames[[int]$row.class]
        level = [int]$row.level
        stock_count = $group.Count
        stored_add_event_rows = $stored
        effective_timer_active_events = $active
        currently_online_in_world = 0
    }
}
$populationRows = @($populationRows | Sort-Object race_id, class_id, level)

$pairComparison = @()
foreach ($pair in $worldPairRows | Sort-Object race_id, class_id)
{
    $key = Get-PairKey $pair.race_id $pair.class_id
    $generatable = $generatableKeys.ContainsKey($key)
    $configMode = 'factory_rejected'
    $configLine = ''
    $configuredValue = ''
    $effectiveValue = 0
    if ($generatable)
    {
        if ($explicitConfig.ContainsKey($key))
        {
            $configMode = 'explicit_pair_override'
            $configLine = $explicitConfig[$key].line
            $configuredValue = $explicitConfig[$key].value
            $effectiveValue = $explicitConfig[$key].value
        }
        else
        {
            $configMode = 'implicit_default'
            $effectiveValue = 100
        }
    }

    $stockCount = 0
    if ($stockByPair.ContainsKey($key))
    {
        $stockCount = $stockByPair[$key]
    }
    $pairStoredEvents = @($sanitizedEventRows | Where-Object { $_.race_id -eq $pair.race_id -and $_.class_id -eq $pair.class_id }).Count
    $pairActiveEvents = @($sanitizedEventRows | Where-Object { $_.race_id -eq $pair.race_id -and $_.class_id -eq $pair.class_id -and $_.effective_timer_active_at_capture -eq 1 }).Count

    $pairComparison += [pscustomobject]@{
        race_id = $pair.race_id
        race = $raceNames[$pair.race_id]
        faction = if ($allianceRaces -contains $pair.race_id) { 'Alliance' } else { 'Horde' }
        class_id = $pair.class_id
        class = $classNames[$pair.class_id]
        playercreateinfo_present = 1
        playerbot_factory_allowed = [int]$generatable
        observed_in_rndbot_stock = [int]($stockCount -gt 0)
        stock_count = $stockCount
        config_mode = $configMode
        config_line = $configLine
        configured_value = $configuredValue
        effective_probability = $effectiveValue
        stored_add_event_rows = $pairStoredEvents
        effective_timer_active_events = $pairActiveEvents
        currently_online_in_world = 0
    }
}

$generatablePairs = @($pairComparison | Where-Object playerbot_factory_allowed -eq 1)
$matrixSummaryRows = @()
foreach ($targetSize in @(50, 100, 500, 1000))
{
    $equalTargets = Get-EqualTargets $generatablePairs $targetSize
    $weightedTargets = Get-WeightedTargets $generatablePairs $targetSize
    $matrixRows = @()

    foreach ($model in @('equal_pair_comparison', 'class_rarity_race_faction_balanced'))
    {
        $targets = if ($model -eq 'equal_pair_comparison') { $equalTargets } else { $weightedTargets }
        foreach ($pair in $pairComparison)
        {
            $key = Get-PairKey $pair.race_id $pair.class_id
            $target = 0
            if ($targets.ContainsKey($key))
            {
                $target = [int]$targets[$key]
            }
            $addDeficit = [Math]::Max(0, $target - [int]$pair.stock_count)
            $matrixRows += [pscustomobject]@{
                model = $model
                target_population = $targetSize
                race_id = $pair.race_id
                race = $pair.race
                faction = $pair.faction
                class_id = $pair.class_id
                class = $pair.class
                playerbot_factory_allowed = $pair.playerbot_factory_allowed
                current_stock = $pair.stock_count
                current_stored_add_rows = $pair.stored_add_event_rows
                current_effective_active_events = $pair.effective_timer_active_events
                current_online = 0
                target = $target
                add_deficit = $addDeficit
            }
        }

        $modelRows = @($matrixRows | Where-Object model -eq $model)
        $matrixSummaryRows += [pscustomobject]@{
            model = $model
            target_population = $targetSize
            target_sum = ($modelRows | Measure-Object target -Sum).Sum
            alliance_target = ($modelRows | Where-Object faction -eq 'Alliance' | Measure-Object target -Sum).Sum
            horde_target = ($modelRows | Where-Object faction -eq 'Horde' | Measure-Object target -Sum).Sum
            total_add_deficit_against_stock = ($modelRows | Measure-Object add_deficit -Sum).Sum
            supported_pairs_with_zero_target = @($modelRows | Where-Object { $_.playerbot_factory_allowed -eq 1 -and $_.target -eq 0 }).Count
            unsupported_pairs_with_nonzero_target = @($modelRows | Where-Object { $_.playerbot_factory_allowed -eq 0 -and $_.target -ne 0 }).Count
        }
    }
    Write-Csv (Join-Path $OutputDirectory "matrix-$targetSize.csv") $matrixRows
}

$professionSource = @(Import-Csv -LiteralPath $ProfessionSummaryPath | Where-Object account_type -eq 'RNDBOT')
$professionRows = @()
foreach ($row in $professionSource)
{
    $classification = 'PRIMARY'
    if ([int]$row.skill -in @(129, 142, 185, 356))
    {
        $classification = if ([int]$row.skill -eq 142) { 'SECONDARY_SURVIVAL' } else { 'SECONDARY' }
    }
    $professionRows += [pscustomobject]@{
        skill_id = [int]$row.skill
        profession = $row.skill_name
        classification = $classification
        character_count = [int]$row.character_count
        min_value = [int]$row.min_value
        max_value = [int]$row.max_value
        min_cap = [int]$row.min_cap
        max_cap = [int]$row.max_cap
    }
}

$professionCountRows = @(
    [pscustomobject]@{ primary_profession_count = '0'; character_count = @($stockRows | Where-Object { [int]$_.primary_profession_count -eq 0 }).Count },
    [pscustomobject]@{ primary_profession_count = '1'; character_count = @($stockRows | Where-Object { [int]$_.primary_profession_count -eq 1 }).Count },
    [pscustomobject]@{ primary_profession_count = '2'; character_count = @($stockRows | Where-Object { [int]$_.primary_profession_count -eq 2 }).Count },
    [pscustomobject]@{ primary_profession_count = '>2'; character_count = @($stockRows | Where-Object { [int]$_.primary_profession_count -gt 2 }).Count }
)

$professionSetRows = @()
foreach ($group in @($stockRows | Group-Object primary_professions | Sort-Object Count -Descending))
{
    $normalizedSet = $group.Name
    if ([string]::IsNullOrWhiteSpace($normalizedSet) -or $normalizedSet -eq 'NULL')
    {
        $normalizedSet = '(none)'
    }
    else
    {
        $normalizedSet = (($normalizedSet -split ';' | ForEach-Object { ($_ -split ':')[0] }) -join ' + ')
    }
    $professionSetRows += [pscustomobject]@{ primary_profession_set = $normalizedSet; character_count = $group.Count }
}

$orphanRules = @{
    'Alchemy' = 'Herbalism'
    'Blacksmithing' = 'Mining'
    'Engineering' = 'Mining'
    'Jewelcrafting' = 'Mining'
    'Leatherworking' = 'Skinning'
    'Enchanting' = 'Tailoring'
}
$orphanRows = @()
foreach ($stock in $stockRows)
{
    $names = @()
    if (-not [string]::IsNullOrWhiteSpace($stock.primary_professions) -and $stock.primary_professions -ne 'NULL')
    {
        $names = @(($stock.primary_professions -split ';') | ForEach-Object { ($_ -split ':')[0] })
    }
    foreach ($craft in $orphanRules.Keys | Sort-Object)
    {
        if ($names -contains $craft -and $names -notcontains $orphanRules[$craft])
        {
            $orphanRows += [pscustomobject]@{
                guid = [int]$stock.guid
                race_id = [int]$stock.race
                class_id = [int]$stock.class
                level = [int]$stock.level
                manufacturing_profession = $craft
                missing_companion_profession = $orphanRules[$craft]
            }
        }
    }
}

$classFallback = @{
    1 = [pscustomobject]@{ tab = 2; spec = 'Protection'; role = 'TANK' }
    2 = [pscustomobject]@{ tab = 2; spec = 'Retribution'; role = 'DPS' }
    3 = [pscustomobject]@{ tab = 0; spec = 'Beast Mastery'; role = 'DPS' }
    4 = [pscustomobject]@{ tab = 0; spec = 'Assassination'; role = 'DPS' }
    5 = [pscustomobject]@{ tab = 1; spec = 'Holy'; role = 'HEALER' }
    7 = [pscustomobject]@{ tab = 1; spec = 'Enhancement'; role = 'DPS' }
    8 = [pscustomobject]@{ tab = 1; spec = 'Fire'; role = 'DPS' }
    9 = [pscustomobject]@{ tab = 0; spec = 'Affliction'; role = 'DPS' }
    11 = [pscustomobject]@{ tab = 0; spec = 'Balance'; role = 'DPS' }
}
$specRows = @()
foreach ($group in @($stockRows | Group-Object class | Sort-Object { [int]$_.Name }))
{
    $classId = [int]$group.Name
    $fallback = $classFallback[$classId]
    $specRows += [pscustomobject]@{
        class_id = $classId
        class = $classNames[$classId]
        character_count = $group.Count
        minimum_level = (@($group.Group | ForEach-Object { [int]$_.level }) | Measure-Object -Minimum).Minimum
        maximum_level = (@($group.Group | ForEach-Object { [int]$_.level }) | Measure-Object -Maximum).Maximum
        effective_runtime_talent_tab = $fallback.tab
        effective_runtime_spec = $fallback.spec
        effective_runtime_role = $fallback.role
        confidence = 'HIGH_FOR_CURRENT_LEVELS_1_TO_9'
        stored_specNo_status = 'NOT_CAPTURED'
    }
}

$premadeSpecRows = @()
for ($lineIndex = 0; $lineIndex -lt $configLines.Count; $lineIndex++)
{
    $match = [regex]::Match($configLines[$lineIndex], '^AiPlayerbot\.PremadeSpecName\.(\d+)\.(\d+)\s*=\s*(\S+)')
    if ($match.Success)
    {
        $classId = [int]$match.Groups[1].Value
        $specId = [int]$match.Groups[2].Value
        $probability = 100
        $probabilityPattern = '^AiPlayerbot\.PremadeSpecProb\.' + $classId + '\.' + $specId + '\s*=\s*(\d+)'
        foreach ($probabilityLine in $configLines)
        {
            $probabilityMatch = [regex]::Match($probabilityLine, $probabilityPattern)
            if ($probabilityMatch.Success)
            {
                $probability = [int]$probabilityMatch.Groups[1].Value
                break
            }
        }
        $premadeSpecRows += [pscustomobject]@{
            class_id = $classId
            class = $classNames[$classId]
            path_id = $specId
            configured_name = $match.Groups[3].Value
            probability = $probability
            config_line = $lineIndex + 1
        }
    }
}

$activeConfigRows = @()
$configPattern = 'RandomBot|ClassRace|SyncLevel|LogInGroupOnly|LoginCriteria|FreeRoomForNonSpareBots|DisableRandomLevels|randombotStartingLevel|PinnedBots|BotAutologin|AsyncBotLogin'
for ($lineIndex = 0; $lineIndex -lt $configLines.Count; $lineIndex++)
{
    if ($configLines[$lineIndex] -match $configPattern)
    {
        $activeConfigRows += [pscustomobject]@{ line = $lineIndex + 1; text = $configLines[$lineIndex] }
    }
}

$configExcerpt = New-Object System.Collections.Generic.List[string]
$configExcerpt.Add("Source: $ConfigPath")
$configExcerpt.Add("Bytes: $((Get-Item -LiteralPath $ConfigPath).Length)")
$configExcerpt.Add("SHA-256: $(Get-Sha256 $ConfigPath)")
foreach ($range in @(@(1,245), @(450,545), @(1069,1079), @(1143,1150), @(1280,1328)))
{
    $configExcerpt.Add('')
    $configExcerpt.Add("===== LINES $($range[0])-$($range[1]) =====")
    for ($lineNumber = $range[0]; $lineNumber -le $range[1]; $lineNumber++)
    {
        $configExcerpt.Add(('{0}:{1}' -f $lineNumber, $configLines[$lineNumber - 1]))
    }
}

function Add-SourceRange([System.Collections.Generic.List[string]]$Destination, [string]$Path, [int]$Start, [int]$End)
{
    $Destination.Add('')
    $Destination.Add("===== $Path LINES $Start-$End =====")
    $lines = Get-Content -LiteralPath $Path
    for ($lineNumber = $Start; $lineNumber -le $End; $lineNumber++)
    {
        $Destination.Add(('{0}:{1}' -f $lineNumber, $lines[$lineNumber - 1]))
    }
}

$sourceEvidence = New-Object System.Collections.Generic.List[string]
$sourceEvidence.Add('PLAYERBOT-DISCOVERY-AND-MATRIX-PREFLIGHT-02 source semantics evidence')
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp') 246 263
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp') 294 340
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp') 362 500
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp') 34 151
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp') 874 1003
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotScripts.cpp') 32 55
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') 644 775
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') 1121 1399
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') 1992 2062
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') 2302 2386
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') 3456 3532
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotLoginMgr.cpp') 510 548
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotLoginMgr.cpp') 562 769
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\AiFactory.cpp') 90 288
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotFactory.cpp') 243 253
Add-SourceRange $sourceEvidence (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotFactory.cpp') 2502 2536

$sourcePaths = @(
    $ConfigPath,
    $MainConfigPath,
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotLoginMgr.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotScripts.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\AiFactory.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\PlayerbotFactory.cpp'),
    (Join-Path $Repository 'src\modules\PlayerBots\playerbot\strategy\actions\ChangeTalentsAction.cpp'),
    (Join-Path $Repository 'src\game\ObjectMgr.cpp'),
    (Join-Path $Repository 'sql\base\tw_world_playercreateinfo.sql'),
    $ProfessionRowsPath,
    $ProfessionSummaryPath,
    $WorldPairsPath,
    $EventEvidencePath,
    $GroupEvidencePath,
    'C:\TW\ComTW\DB\data\tw_world\playercreateinfo.MYD',
    'C:\TW\ComTW\DB\data\tw_world\playercreateinfo.MYI',
    'C:\TW\ComTW\DB\data\tw_char\characters.MYD',
    'C:\TW\ComTW\DB\data\tw_char\characters.MYI',
    'C:\TW\ComTW\DB\data\tw_char\character_skills.MYD',
    'C:\TW\ComTW\DB\data\tw_char\character_skills.MYI',
    'C:\TW\ComTW\DB\data\tw_char\ai_playerbot_random_bots.ibd',
    'C:\TW\ComTW\DB\data\tw_char\groups.MYD',
    'C:\TW\ComTW\DB\data\tw_char\groups.MYI',
    'C:\TW\ComTW\DB\data\tw_char\group_member.MYD',
    'C:\TW\ComTW\DB\data\tw_char\group_member.MYI'
)
$provenanceRows = @()
foreach ($path in $sourcePaths)
{
    $item = Get-Item -LiteralPath $path
    $provenanceRows += [pscustomobject]@{
        path = $item.FullName
        bytes = $item.Length
        last_write_time_utc = $item.LastWriteTimeUtc.ToString('o')
        sha256 = Get-Sha256 $item.FullName
    }
}

$oldGitOptionalLocks = $env:GIT_OPTIONAL_LOCKS
$env:GIT_OPTIONAL_LOCKS = '0'
try
{
    $branch = (& git -c "safe.directory=$Repository" -C $Repository branch --show-current).Trim()
    $head = (& git -c "safe.directory=$Repository" -C $Repository rev-parse HEAD).Trim()
    $gitStatus = @(& git -c "safe.directory=$Repository" -C $Repository status --short --untracked-files=all --no-renames)
}
finally
{
    $env:GIT_OPTIONAL_LOCKS = $oldGitOptionalLocks
}

$processRows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('mysqld','mariadbd','mangosd','realmd') })
$portRows = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in @(3307,8090) })

Write-Csv (Join-Path $OutputDirectory 'source-config-provenance.csv') $provenanceRows
Write-Csv (Join-Path $OutputDirectory 'active-config-relevant-lines.csv') $activeConfigRows
Write-Utf8Text (Join-Path $OutputDirectory 'active-config-randombot-classrace-excerpt.txt') ($configExcerpt -join "`r`n")
Write-Utf8Text (Join-Path $OutputDirectory 'source-semantics-evidence.txt') ($sourceEvidence -join "`r`n")
Write-Csv (Join-Path $OutputDirectory 'race-class-52-59-comparison.csv') $pairComparison
Write-Csv (Join-Path $OutputDirectory 'rndbot-population-race-class-level.csv') $populationRows
Write-Csv (Join-Path $OutputDirectory 'sanitized-stored-add-guid-snapshot.csv') $sanitizedEventRows
Write-Utf8Text (Join-Path $OutputDirectory 'sanitized-online-rndbot-guid-snapshot.csv') 'guid,race_id,race,class_id,class,level,status'
Write-Csv (Join-Path $OutputDirectory 'sanitized-last-accepted-group-guid-snapshot.csv') $lastAcceptedGroupRows
Write-Csv (Join-Path $OutputDirectory 'rndbot-profession-skill-summary.csv') $professionRows
Write-Csv (Join-Path $OutputDirectory 'rndbot-primary-profession-counts.csv') $professionCountRows
Write-Csv (Join-Path $OutputDirectory 'rndbot-primary-profession-pairs.csv') $professionSetRows
Write-Csv (Join-Path $OutputDirectory 'rndbot-orphan-manufacturing-professions.csv') $orphanRows
Write-Csv (Join-Path $OutputDirectory 'current-effective-spec-role-summary.csv') $specRows
Write-Csv (Join-Path $OutputDirectory 'premade-spec-config-mapping.csv') $premadeSpecRows
Write-Csv (Join-Path $OutputDirectory 'matrix-summary.csv') $matrixSummaryRows

$selectionStateRows = @(
    [pscustomobject]@{ state = 'rndbot_stock'; count = 4500; current_status = 'PROVEN'; evidence = 'characters and character_skills MyISAM files unchanged since accepted capture' },
    [pscustomobject]@{ state = 'stored_add_event_rows'; count = 53; current_status = 'PROVEN'; evidence = 'ai_playerbot_random_bots.ibd unchanged since accepted capture' },
    [pscustomobject]@{ state = 'effective_unexpired_add_events'; count = 0; current_status = 'PROVEN_AT_PACKAGE_CAPTURE'; evidence = 'all accepted time plus validIn deadlines expired' },
    [pscustomobject]@{ state = 'online_rndbot_guids'; count = 0; current_status = 'PROVEN_IN_MEMORY'; evidence = 'no mangosd process exists' },
    [pscustomobject]@{ state = 'group_login_candidates'; count = ''; current_status = 'UNPROVEN'; evidence = 'group table files changed after the last accepted group query' }
)
Write-Csv (Join-Path $OutputDirectory 'selection-state-summary.csv') $selectionStateRows

$roleTotals = @($specRows | Group-Object effective_runtime_role | ForEach-Object {
    [pscustomobject]@{ role = $_.Name; count = ($_.Group | Measure-Object character_count -Sum).Sum }
})
Write-Csv (Join-Path $OutputDirectory 'current-effective-role-totals.csv') $roleTotals

$report = @"
# PLAYERBOT-DISCOVERY-AND-MATRIX-PREFLIGHT-02

Captured UTC: $($CapturedUtc.ToString('o'))

## Scope and decision

This package is read-only with respect to configuration, databases, source, and server processes. No database engine or game server was started. Only aggregated and sanitized evidence was created in this directory.

`DISCOVERY_PREFLIGHT_RESULT=BLOCKED`

The source/config, 59-versus-52 matrix, current stock, levels, professions, effective low-level runtime roles, and planning matrices are proven. The preflight remains BLOCKED only because the current persistent group membership and stored `specNo` events were not captured after the group-table files changed. Starting MariaDB was expressly outside this task. A Worldserver restart is not required; a separately authorized MariaDB-only read capture is sufficient.

## Status fields

```ini
DISCOVERY_PREFLIGHT_RESULT=BLOCKED
SOURCE_CONFIG_IDENTITY_VERIFIED=YES
PLAYERCREATEINFO_PAIR_COUNT=59
RNDBOT_OBSERVED_PAIR_COUNT=52
PLAYERBOT_GENERATABLE_PAIR_COUNT=52
PAIR_DIFFERENCE_RESOLVED=YES
CURRENT_RNDBOT_STOCK_COUNT=4500
CURRENT_ACTIVE_EVENT_GUID_COUNT=0
CURRENT_STORED_ADD_EVENT_ROW_COUNT=53
CURRENT_ONLINE_RNDBOT_COUNT=0
CURRENT_GROUP_LOGIN_CANDIDATE_COUNT=UNPROVEN
TIME_BASED_ROTATION_CONFIRMED=YES
LEVEL_CAP_REPLACEMENT_CONFIRMED=NO
RESTART_TEST_REQUIRED=NO
BOTS_WITH_ZERO_PRIMARY_PROFESSIONS=4491
BOTS_WITH_ONE_PRIMARY_PROFESSION=5
BOTS_WITH_TWO_PRIMARY_PROFESSIONS=4
BOTS_WITH_MORE_THAN_TWO_PRIMARY_PROFESSIONS=0
SPEC_MAPPING_CONFIDENCE=HIGH
STORED_SPECNO_DISTRIBUTION=UNPROVEN
WEIGHTED_MATRIX_50_READY=YES
WEIGHTED_MATRIX_100_READY=YES
WEIGHTED_MATRIX_500_READY=YES
WEIGHTED_MATRIX_1000_READY=YES
PRODUCTION_CONFIG_CREATED=NO
```

`CURRENT_ACTIVE_EVENT_GUID_COUNT=0` is the effective timer-active count at package capture. The 53 physical `owner=0,event=add` rows are still stored, but every accepted `time + validIn` deadline is in the past. `GetBots()` initially loads those rows; `GetEventValue()` evaluates them as zero, and the normal manager path then removes/logs out the expired rotation entries.

## Active configuration identity

- Path: `$ConfigPath`
- Bytes: $((Get-Item -LiteralPath $ConfigPath).Length)
- SHA-256: `$(Get-Sha256 $ConfigPath)`
- Resolution: `mangosd.conf` leaves `AiPlayerbot.ConfigFile` empty; `PlayerbotAIConfig.cpp:100-128` resolves the bot config next to the active main config.

Effective control values:

| Setting | Effective value | Meaning |
|---|---:|---|
| `AiPlayerbot.Enabled` | 1 | Playerbot module enabled |
| `RandomBotAutologin` | 1 | Legacy random-bot manager enabled |
| `RandomBotAutoCreate` | 1 | Startup scans/creates random accounts and missing characters |
| `MinRandomBots` / `MaxRandomBots` | 50 / 50 | Global `bot_count` target |
| `AsyncBotLogin` | 0 | Legacy selector is active; `PlayerbotLoginMgr` is inactive |
| `RandomBotTimedLogout` | omitted, default 1 | Rotation timers are active |
| `MinRandomBotInWorldTime` / `MaxRandomBotInWorldTime` | omitted, defaults 1800 / 21600 seconds | Per-login rotation lifetime |
| `RandomBotTimedOffline` | omitted, default 0 | No enforced offline timer |
| `DisableRandomLevels` | 1 | Bots level naturally; normal random level reassignment is disabled |
| `randombotStartingLevel` | 1 | New bots start at level 1 |
| `SyncLevelWithPlayers` / `MaxAbove` / `NoPlayer` | 1 / 4 / 1 | Legacy candidate query prefers a level window, but its final fallback removes that filter |
| `ClassRace.UseFixedClassRaceCounts` | omitted, default 0 | Current distribution is probability-based |
| `RandomBotLoginAtStartup` | 1 | Loaded but no consumer exists in this source tree |
| `LogInGroupOnly` | omitted, default 1 | Misleading name: it gates Engine diagnostic logging, not bot login |

The complete relevant raw ranges and every matching setting line are in `active-config-randombot-classrace-excerpt.txt` and `active-config-relevant-lines.csv`.

## 59 schema pairs versus 52 factory pairs

The accepted live `playercreateinfo` evidence contains 59 unique pairs. Its physical MyISAM table files are older than that capture and remain unchanged. `RandomPlayerbotFactory::availableRaces` allows exactly 52 pairs. The 4,500 current RNDBOT rows contain exactly those same 52 pairs.

The seven schema-valid but factory-rejected pairs are:

| Race | Class | Active config line | Effective bot probability |
|---|---|---|---:|
| Orc | Mage | none | 0 |
| Dwarf | Mage | none | 0 |
| Dwarf | Warlock | none | 0 |
| Undead | Hunter | none | 0 |
| Tauren | Priest | none | 0 |
| Gnome | Hunter | none | 0 |
| Troll | Warlock | none | 0 |

They begin at the default probability 100, but `PlayerbotAIConfig.cpp:446-456` calls `isAvailableRace()` and forces each rejected pair to zero. This resolves the discrepancy: 59 is the World schema matrix; 52 is the actual Playerbot factory/login matrix.

Among the 52 supported pairs, 40 have explicit pair overrides and 12 use the implicit default 100. The 12 defaults are Human Hunter plus the supported Goblin and High Elf combinations. The effective probability total is 2,483. At target 50, the legacy probability formula creates aggregate class/race allowances totaling 83, while the global target still stops selection at 50; it is a probabilistic cap, not an exact matrix.

## Fixed-count semantics

Fixed mode is understood but is not ready for a production config in this task:

1. Startup creation copies configured exact pair counts into `remaining` and creates new characters only in unused account slots. It does not subtract or rebalance the 4,500 existing characters and deletes none.
2. The current 500 accounts already contain 4,500 characters (nine each), so there are no creation slots.
3. The active legacy selector (`AsyncBotLogin=0`) uses `fixedClassRaceCounts` as per-pair selection quotas for existing bots.
4. The inactive async selector has a source inconsistency: `PlayerbotLoginMgr::GetClassRaceBucketSize()` returns `classRaceProbability` in fixed mode instead of `fixedClassRaceCounts`. Omitted supported pairs therefore behave as default 100 in that path.
5. Fixed parser entries with value zero are retained. The creation loop decrements the unsigned zero and can underflow if a free character slot exists. A 50-of-52 candidate must therefore not encode zero entries without a separate source review/fix.

No fixed-count switch or production config is generated. Model and target approval must come first, and the async/zero-count source defects require their own narrowly scoped change candidate if fixed mode is selected.

## Selection, rotation, level, and group behavior

- `PlayerbotWorldScript::OnStartup()` always calls `CreateRandomBots()` when the module is enabled.
- The legacy manager normalizes global `bot_count` into the configured 50..50 range and selects from RNDBOT accounts until that target is reached.
- Candidate account order is shuffled on each pass. Fixed counts control pair totals, not GUID identity.
- Successful login assigns a fresh `add` timer. Expired `add` causes controlled logout/removal, except grouped bots receive a 120-second deferral. The manager then fills the global target with other eligible bots. This confirms time-based rotation.
- No source path replaces a bot merely because it reaches `RandomBotMaxLevel`. With `DisableRandomLevels=1`, normal level/spec randomization returns early. Level sync affects preferred candidate queries, but the third legacy fallback removes the level predicate when needed.
- `AddOfflineGroupBots()` can add 1..5 offline group bots for an online real-player group leader outside the ordinary target-filling loop. The last accepted group query is stale because all four active group data/index files were written later. Current group-login candidates are therefore unproven, not assumed zero.
- No Worldserver is running, so the actual in-memory online RNDBOT GUID set is empty.

## Current population

- Stock: 4,500 RNDBOT characters, 52 observed pairs.
- Levels: 1=4,382; 2=10; 3=5; 4=7; 5=12; 6=53; 7=27; 8=2; 9=2.
- Stored add rows: 53; effective unexpired add timers at capture: 0; online in world: 0.
- The detailed aggregate is `rndbot-population-race-class-level.csv`. GUID-level deliverables are separated into stored-add, empty online, and explicitly superseded last-accepted group snapshots; none contains names or accounts.

## Professions

- Zero primary professions: 4,491.
- One primary profession: 5.
- Two primary professions: 4.
- More than two: 0.
- Learned primary skills: Blacksmithing 1, Leatherworking 1, Alchemy 2, Herbalism 5, Mining 3, Skinning 1.
- Learned secondary skills: First Aid 5, Cooking 3, Fishing 4, Survival 4.
- Survival (skill 142) is a locally verified secondary custom profession and does not count against the primary limit.
- Complete manufacturing/gathering pair: Alchemy + Herbalism, one bot.
- Orphan manufacturing professions: Alchemy without Herbalism 1; Blacksmithing without Mining 1; Leatherworking without Skinning 1. Engineering, Jewelcrafting, Enchanting, and Tailoring are not currently learned by any RNDBOT in this capture.

No profession is taught, removed, or recommended for direct SQL manipulation here.

## Talent/spec/role mapping

The character database persists learned talent spells in `character_spell`; there is no separate vanilla `character_talent` table. `AiFactory::GetPlayerSpecTabs()` walks Talent/TalentTab DBC rows and sums ranks for spells found by `Player::HasSpell()`. For level 10+ it chooses the highest-point tab. `specNo` is a persistent Playerbot event used to select a configured premade path, but current `specNo` rows were not captured in the accepted read-only evidence.

All 4,500 current RNDBOTs are level 1..9. `AiFactory::GetPlayerSpecTab()` therefore uses its deterministic low-level fallback rather than learned talent points. The effective current runtime mapping is high-confidence:

| Class | Fallback spec | Runtime role | Count |
|---|---|---|---:|
| Warrior | Protection | Tank | 719 |
| Paladin | Retribution | DPS | 424 |
| Hunter | Beast Mastery | DPS | 959 |
| Rogue | Assassination | DPS | 717 |
| Priest | Holy | Healer | 362 |
| Shaman | Enhancement | DPS | 155 |
| Mage | Fire | DPS | 574 |
| Warlock | Affliction | DPS | 393 |
| Druid | Balance | DPS | 197 |

Role totals are Tank 719, Healer 362, DPS 3,419. This is the effective low-level runtime role distribution, not proof of stored `specNo` choices or future level-10+ talent distributions.

## Matrix models

Every matrix uses the 52 factory-supported pairs and assigns target zero to the seven schema-only pairs. No deletion is proposed. Each `matrix-N.csv` contains both models and, per pair, current stock, stored/effective event counts, target, and `add_deficit = max(target - current_stock, 0)`.

Equal-pair comparison:

- split the target exactly 50/50 by faction;
- assign the same base count to every supported pair within a faction;
- assign indivisible remainders to the currently least represented target race, then class, then numeric pair ID.

Recommended class-rarity/race/faction-balanced model:

- split the target exactly 50/50 by faction;
- maximize distinct supported-pair coverage before assigning a second seat to any pair;
- repeatedly give the next seat to the faction-local class with the smallest target total;
- break ties by the race with the smallest target total, then pair count and numeric IDs.

This gives scarce classes more seats per valid pair while retaining faction balance and strong race balance. It is a planning matrix only. It does not select GUIDs, alter events, or create characters.

## Remaining proof gap and next gate

No controlled Worldserver restart test is required. Before a production config candidate, perform one separately authorized MariaDB-only read capture of:

1. current `owner=0,event IN ('add','login','specNo')` rows;
2. current RNDBOT group members and leader account type;
3. current `characters.online` flags as consistency evidence;
4. stored `specNo` distribution.

Then approve a target size and one matrix model. Any fixed-count source correction, GUID-cohort mechanism, profession pairing, spec behavior, grouping lifecycle, gear scoring, gathering, quest turn-in, or LLM context remains a separate candidate and rollback point.

## Git and process state

- Repository: `$Repository`
- Branch: `$branch`
- HEAD: `$head`
- Server process count at capture: $($processRows.Count)
- Listener count on ports 3307/8090 at capture: $($portRows.Count)

Git status at capture:

```text
$($gitStatus -join "`r`n")
```

No config, database, source, server executable, or existing evidence file was modified.
"@
Write-Utf8Text (Join-Path $OutputDirectory 'report.md') $report

$outputFiles = @(Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name)
$manifestLines = @()
foreach ($file in $outputFiles)
{
    $manifestLines += "$(Get-Sha256 $file.FullName) *$($file.Name)"
}
Write-Utf8Text (Join-Path $OutputDirectory 'SHA256SUMS.txt') ($manifestLines -join "`r`n")

Write-Output "OUTPUT_DIRECTORY=$OutputDirectory"
Write-Output "FILES=$((Get-ChildItem -LiteralPath $OutputDirectory -File).Count)"
Write-Output "REPORT_SHA256=$(Get-Sha256 (Join-Path $OutputDirectory 'report.md'))"
Write-Output "MANIFEST_SHA256=$(Get-Sha256 (Join-Path $OutputDirectory 'SHA256SUMS.txt'))"
Write-Output "SERVER_PROCESS_COUNT=$($processRows.Count)"
Write-Output "PORT_LISTENER_COUNT=$($portRows.Count)"
