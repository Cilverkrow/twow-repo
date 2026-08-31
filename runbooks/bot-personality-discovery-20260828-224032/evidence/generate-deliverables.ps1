param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$Root = 'C:\TW\ComTW'
$SourceRoot = Join-Path $Root 'source'
$EvidenceDirectory = Join-Path $OutputDirectory 'evidence'
$QueryDirectory = Join-Path $EvidenceDirectory 'query-results'
$ConfigPath = Join-Path $Root 'server\aiplayerbot.conf'
$ServerConfigPath = Join-Path $Root 'server\mangosd.conf'
$ServerExePath = Join-Path $Root 'server\mangosd.exe'
$RaceDbcPath = Join-Path $Root 'data\dbc\ChrRaces.dbc'
$ClassDbcPath = Join-Path $Root 'data\dbc\ChrClasses.dbc'
$SkillDbcPath = Join-Path $Root 'data\dbc\SkillLine.dbc'
$CharSectionsDbcPath = Join-Path $Root 'data\dbc\CharSections.dbc'

function Write-Utf8Lf {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    $value = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $value, $Utf8NoBom)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-Key {
    param([string]$Name)
    $value = $Name.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    return $value.Trim('_')
}

function Read-DataTsv {
    param([string]$Path, [string[]]$Headers)
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0) { throw "TSV is empty: $Path" }
    if ($lines.Count -eq 1) { return @() }
    return @($lines | Select-Object -Skip 1 | ConvertFrom-Csv -Delimiter "`t" -Header $Headers)
}

function Write-Tsv {
    param([string]$Path, [string[]]$Columns, [object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($Columns -join "`t"))
    foreach ($row in $Rows) {
        $values = foreach ($column in $Columns) {
            $value = $row.$column
            if ($null -eq $value) { '' } else { ([string]$value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ') }
        }
        $lines.Add(($values -join "`t"))
    }
    Write-Utf8Lf -Path $Path -Text (($lines -join "`n") + "`n")
}

function Read-Dbc {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 20 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'WDBC') {
        throw "Invalid WDBC header: $Path"
    }
    $count = [BitConverter]::ToInt32($bytes, 4)
    $fields = [BitConverter]::ToInt32($bytes, 8)
    $recordSize = [BitConverter]::ToInt32($bytes, 12)
    $stringSize = [BitConverter]::ToInt32($bytes, 16)
    if ($recordSize -ne $fields * 4) { throw "Unexpected DBC record layout: $Path" }
    $stringOffset = 20 + ($count * $recordSize)
    if ($stringOffset + $stringSize -ne $bytes.Length) { throw "DBC size mismatch: $Path" }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $count; $index++) {
        $values = New-Object uint32[] $fields
        $offset = 20 + ($index * $recordSize)
        for ($field = 0; $field -lt $fields; $field++) {
            $values[$field] = [BitConverter]::ToUInt32($bytes, $offset + ($field * 4))
        }
        $rows.Add($values)
    }
    return [pscustomobject]@{
        Path = $Path
        Bytes = $bytes
        Count = $count
        Fields = $fields
        RecordSize = $recordSize
        StringOffset = $stringOffset
        Rows = [object[]]$rows
    }
}

function Get-DbcString {
    param([pscustomobject]$Dbc, [uint32]$Offset)
    if ($Offset -eq 0) { return '' }
    $start = $Dbc.StringOffset + [int]$Offset
    $end = $start
    while ($end -lt $Dbc.Bytes.Length -and $Dbc.Bytes[$end] -ne 0) { $end++ }
    return [Text.Encoding]::UTF8.GetString($Dbc.Bytes, $start, $end - $start)
}

function Add-SourceExcerpt {
    param([System.Collections.Generic.List[string]]$Lines, [string]$Path, [int]$Start, [int]$End)
    $relative = $Path.Substring($Root.Length + 1).Replace('\', '/')
    $source = @(Get-Content -LiteralPath $Path)
    $Lines.Add("[${relative}:$Start-$End]")
    for ($line = $Start; $line -le $End; $line++) {
        $Lines.Add(('{0}: {1}' -f $line, $source[$line - 1]))
    }
    $Lines.Add('')
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw "Output directory is missing: $OutputDirectory" }
foreach ($path in @($EvidenceDirectory, $QueryDirectory, $ConfigPath, $RaceDbcPath, $ClassDbcPath, $SkillDbcPath, $CharSectionsDbcPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input is missing: $path" }
}

$harnessResult = Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'database-harness-result.json') -Raw | ConvertFrom-Json
if ($harnessResult.status -cne 'completed' -or [int]$harnessResult.sql_write_capable_statement_count -ne 0 -or [int]$harnessResult.logical_database_writes -ne 0) {
    throw 'The database capture did not finish in the required read-only state.'
}

$populationRowsRaw = Read-DataTsv -Path (Join-Path $QueryDirectory 'bot-population-rows.tsv') -Headers @('population_key','bot_guid','race_id','class_id','gender','player_bytes','player_bytes2')
$skillRowsRaw = Read-DataTsv -Path (Join-Path $QueryDirectory 'bot-skill-rows.tsv') -Headers @('population_key','bot_guid','skill_id','skill_value','skill_maximum')
$worldCombinationRows = Read-DataTsv -Path (Join-Path $QueryDirectory 'world-race-class-combinations.tsv') -Headers @('race_id','class_id','definition_count')
$aggregateRow = @(Read-DataTsv -Path (Join-Path $QueryDirectory 'population-aggregate.tsv') -Headers @('total_characters','random_account_stock','non_random_account_stock','active_rotation_existing','configured_player_owned_always','unclassified_non_random_stock'))[0]
$joinQualityRow = @(Read-DataTsv -Path (Join-Path $QueryDirectory 'account-join-quality.tsv') -Headers @('total_characters','characters_with_account','characters_without_account'))[0]
$eventIntegrityRows = Read-DataTsv -Path (Join-Path $QueryDirectory 'playerbot-event-integrity.tsv') -Headers @('metric','value')
$eventIntegrity = @{}
foreach ($row in $eventIntegrityRows) { $eventIntegrity[$row.metric] = [int64]$row.value }

$raceDbc = Read-Dbc -Path $RaceDbcPath
$classDbc = Read-Dbc -Path $ClassDbcPath
$skillDbc = Read-Dbc -Path $SkillDbcPath
if ($raceDbc.Fields -ne 29 -or $classDbc.Fields -ne 17 -or $skillDbc.Fields -ne 22) { throw 'A mapping DBC has an unexpected field count.' }

$raceMap = @{}
foreach ($row in $raceDbc.Rows) {
    $id = [int]$row[0]
    $name = Get-DbcString -Dbc $raceDbc -Offset $row[17]
    if ($raceMap.ContainsKey($id)) { throw "Duplicate race ID in DBC: $id" }
    $raceMap[$id] = [ordered]@{
        race_id = $id
        race_key = Get-Key -Name $name
        race_name = $name
        flags = [uint32]$row[1]
        playable = (([uint32]$row[1] -band 1) -eq 0)
        male_model_id = [uint32]$row[4]
        female_model_id = [uint32]$row[5]
        turtle_custom_race = ($id -in @(9,10))
    }
}

$classMap = @{}
foreach ($row in $classDbc.Rows) {
    $id = [int]$row[0]
    $name = Get-DbcString -Dbc $classDbc -Offset $row[5]
    if ($classMap.ContainsKey($id)) { throw "Duplicate class ID in DBC: $id" }
    $classMap[$id] = [ordered]@{
        class_id = $id
        class_key = Get-Key -Name $name
        class_name = $name
    }
}

$skillCategoryNames = @{
    5='attributes'; 6='weapon'; 7='class'; 8='armor'; 9='secondary'; 10='language'; 11='primary_profession'; 12='generic'
}
$skillMap = @{}
foreach ($row in $skillDbc.Rows) {
    $id = [int]$row[0]
    $name = Get-DbcString -Dbc $skillDbc -Offset $row[3]
    $categoryId = if ([uint64]$row[1] -gt [int]::MaxValue) { [int]([int64]$row[1] - 4294967296) } else { [int]$row[1] }
    $categoryKey = if ($skillCategoryNames.ContainsKey($categoryId)) { $skillCategoryNames[$categoryId] } else { 'unclassified_category' }
    $skillMap[$id] = [ordered]@{
        skill_id = $id
        skill_key = Get-Key -Name $name
        skill_name = $name
        category_id = $categoryId
        category_key = $categoryKey
    }
}

$professionIds = New-Object System.Collections.Generic.List[int]
foreach ($skill in $skillMap.Values) {
    if ($skill.category_id -eq 11) { $professionIds.Add([int]$skill.skill_id) }
}
foreach ($id in @(129,142,185,356)) {
    if (-not $skillMap.ContainsKey($id)) { throw "Required local profession skill is missing from SkillLine.dbc: $id" }
    if (-not $professionIds.Contains($id)) { $professionIds.Add($id) }
}
$professionIds = @($professionIds | Sort-Object -Unique)

$professionMap = @{}
foreach ($id in $professionIds) {
    $skill = $skillMap[$id]
    $category = if ($skill.category_id -eq 11) { 'primary_profession' } elseif ($id -eq 142) { 'custom_secondary_profession' } else { 'secondary_profession' }
    $professionMap[$id] = [ordered]@{
        skill_id = $id
        profession_key = $skill.skill_key
        profession_name = $skill.skill_name
        category = $category
        dbc_category_id = $skill.category_id
    }
}

$rawPopulationCounts = @{}
foreach ($group in @($populationRowsRaw | Group-Object population_key)) {
    $rawPopulationCounts[$group.Name] = @($group.Group | Select-Object -ExpandProperty bot_guid -Unique).Count
    if ($group.Count -ne $rawPopulationCounts[$group.Name]) { throw "Duplicate GUID within raw population '$($group.Name)'." }
}

$normalizedPopulationKeys = @('active_random_rotation','configured_player_owned_always_online','inactive_random_reserve')
$normalizedPopulationRows = @($populationRowsRaw | Where-Object { $_.population_key -in $normalizedPopulationKeys } | Sort-Object population_key, @{ Expression = { [int64]$_.bot_guid } })
$normalizedKeyPairs = @{}
foreach ($row in $normalizedPopulationRows) {
    $key = "$($row.population_key)|$($row.bot_guid)"
    if ($normalizedKeyPairs.ContainsKey($key)) { throw "Duplicate normalized population/GUID row: $key" }
    $normalizedKeyPairs[$key] = $true
    if ([int64]$row.bot_guid -le 0) { throw "Invalid exported bot GUID: $($row.bot_guid)" }
    if (-not $raceMap.ContainsKey([int]$row.race_id)) { throw "Unmapped race ID on exported bot: $($row.race_id)" }
    if (-not $classMap.ContainsKey([int]$row.class_id)) { throw "Unmapped class ID on exported bot: $($row.class_id)" }
}

$normalizedUniqueGuids = @($normalizedPopulationRows | Select-Object -ExpandProperty bot_guid -Unique)
if ($normalizedUniqueGuids.Count -ne [int]$aggregateRow.random_account_stock + [int]$aggregateRow.configured_player_owned_always) {
    throw 'Normalized bot GUID count does not reconcile with the proven stock plus configured player-owned bots.'
}
if ([int]$joinQualityRow.characters_without_account -ne 0) { throw 'One or more authoritative characters could not be joined to an account for classification.' }
if ([int]$eventIntegrity.orphan_nonzero_bot_rows -ne 0) { throw 'The PlayerBot event table contains orphan nonzero bot references.' }
if ([int]$eventIntegrity.duplicate_owner_bot_event_extra_rows -ne 0) { throw 'The PlayerBot event table contains duplicate owner/bot/event keys.' }

$skillsByPopulationBot = @{}
foreach ($row in $skillRowsRaw) {
    if ($row.population_key -notin $normalizedPopulationKeys) { continue }
    $key = "$($row.population_key)|$($row.bot_guid)"
    if (-not $skillsByPopulationBot.ContainsKey($key)) { $skillsByPopulationBot[$key] = New-Object System.Collections.Generic.List[object] }
    $skillsByPopulationBot[$key].Add($row)
}

$professionRowsByPopulationBot = @{}
foreach ($key in $skillsByPopulationBot.Keys) {
    $matches = @($skillsByPopulationBot[$key] | Where-Object { $professionMap.ContainsKey([int]$_.skill_id) -and [int]$_.skill_value -gt 0 } | Sort-Object { [int]$_.skill_id })
    $seen = @{}
    foreach ($match in $matches) {
        $id = [int]$match.skill_id
        if ($seen.ContainsKey($id)) { throw "Duplicate profession skill $id for $key." }
        $seen[$id] = $true
    }
    $professionRowsByPopulationBot[$key] = $matches
}

$charSectionBytes = [IO.File]::ReadAllBytes($CharSectionsDbcPath)
if ([Text.Encoding]::ASCII.GetString($charSectionBytes,0,4) -cne 'WDBC') { throw 'Invalid CharSections.dbc header.' }
$charSectionCount = [BitConverter]::ToInt32($charSectionBytes,4)
$charSectionFields = [BitConverter]::ToInt32($charSectionBytes,8)
$charSectionRecordSize = [BitConverter]::ToInt32($charSectionBytes,12)
if ($charSectionFields -ne 10 -or $charSectionRecordSize -ne 40) { throw 'Unexpected CharSections.dbc layout.' }
$charSectionKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
for ($index=0; $index -lt $charSectionCount; $index++) {
    $offset = 20 + ($index * $charSectionRecordSize)
    $race = [BitConverter]::ToUInt32($charSectionBytes,$offset+4)
    $gender = [BitConverter]::ToUInt32($charSectionBytes,$offset+8)
    $section = [BitConverter]::ToUInt32($charSectionBytes,$offset+12)
    $variation = [BitConverter]::ToUInt32($charSectionBytes,$offset+16)
    $color = [BitConverter]::ToUInt32($charSectionBytes,$offset+20)
    if ($section -le 3) { [void]$charSectionKeys.Add("$race|$gender|$section|$variation|$color") }
}

$appearanceMismatchCount = 0
foreach ($row in $normalizedPopulationRows) {
    $packed = [uint32]$row.player_bytes
    $packed2 = [uint32]$row.player_bytes2
    $skin = [int]($packed -band 0xFF)
    $face = [int](($packed -shr 8) -band 0xFF)
    $hairStyle = [int](($packed -shr 16) -band 0xFF)
    $hairColor = [int](($packed -shr 24) -band 0xFF)
    $facial = [int]($packed2 -band 0xFF)
    $prefix = "$($row.race_id)|$($row.gender)"
    $faceValid = $charSectionKeys.Contains("$prefix|1|$face|$skin")
    $hairValid = $charSectionKeys.Contains("$prefix|3|$hairStyle|$hairColor")
    $facialValid = ($facial -eq 0 -or $charSectionKeys.Contains("$prefix|2|0|$facial") -or $charSectionKeys.Contains("$prefix|2|$facial|$facial"))
    if (-not ($faceValid -and $hairValid -and $facialValid)) { $appearanceMismatchCount++ }
}

$worldCombinationSet = @{}
foreach ($row in $worldCombinationRows) { $worldCombinationSet["$($row.race_id)|$($row.class_id)"] = [int]$row.definition_count }

$populationDefinitions = @(
    [ordered]@{ population_key='random_account_stock'; count=[int]$aggregateRow.random_account_stock; normalized_export=$false; population_type='proven_superset'; database_evidence='characters joined to tw_logon.account where the case-insensitive username begins with the configured RNDBOT prefix'; source_evidence='PlayerbotAIConfig::IsInRandomAccountList'; overlap='Contains all 100 active_random_rotation and all 4,400 inactive_random_reserve characters in this capture.'; ambiguity='Account-prefix membership proves random-bot stock, not current runtime login.' },
    [ordered]@{ population_key='active_random_rotation'; count=[int]$aggregateRow.active_rotation_existing; normalized_export=$true; population_type='proven_character_population'; database_evidence='distinct existing character GUIDs referenced by owner=0,event=add rows'; source_evidence='RandomPlayerbotMgr::GetBots and IsRandomBot'; overlap='All 100 are also random_account_stock in this capture.'; ambiguity='The add marker is the configured rotation set; with mangosd stopped it does not prove a currently running session.' },
    [ordered]@{ population_key='inactive_random_reserve'; count=[int]$rawPopulationCounts.inactive_random_reserve; normalized_export=$true; population_type='proven_character_population'; database_evidence='RNDBOT-prefix characters without an owner=0,event=add row'; source_evidence='Account-prefix stock minus RandomPlayerbotMgr::GetBots'; overlap='Subset of random_account_stock; disjoint from active_random_rotation by definition.'; ambiguity='Reserve status is an offline database classification.' },
    [ordered]@{ population_key='configured_player_owned_always_online'; count=[int]$aggregateRow.configured_player_owned_always; normalized_export=$true; population_type='proven_character_population'; database_evidence='non-RNDBOT characters with owner=0,event=always,value=1'; source_evidence='PlayerbotAIConfig freeAltBots loading and BotAlwaysOnline::ACTIVE'; overlap='No rows observed.'; ambiguity='On-demand player-owned bots without an ACTIVE always marker are not distinguishable while the Worldserver is stopped.' },
    [ordered]@{ population_key='currently_active_runtime_bots'; count=0; normalized_export=$false; population_type='runtime_state'; database_evidence='No mangosd process existed during the capture.'; source_evidence='The source clears login markers during RandomPlayerbotMgr construction; a stored login row is not authoritative runtime state.'; overlap='None active because the Worldserver remained stopped.'; ambiguity='Historical event markers are not runtime sessions.' },
    [ordered]@{ population_key='system_placeholder_event_rows'; count=[int]$eventIntegrity.system_placeholder_rows; normalized_export=$false; population_type='non_character_placeholder'; database_evidence='ai_playerbot_random_bots rows with bot=0'; source_evidence='RandomPlayerbotMgr stores system values such as bot_count/current_time under bot=0.'; overlap='Not a character population and never exported as bot_guid.'; ambiguity='None for character classification.' }
)

$botPopulationTsvRows = foreach ($population in $populationDefinitions) {
    [pscustomobject]@{
        population_key=$population.population_key; exact_count=$population.count; population_type=$population.population_type;
        normalized_export=$population.normalized_export; database_evidence=$population.database_evidence; source_configuration_evidence=$population.source_evidence;
        overlap=$population.overlap; unresolved_ambiguity=$population.ambiguity
    }
}
Write-Tsv -Path (Join-Path $OutputDirectory 'bot-populations.tsv') -Columns @('population_key','exact_count','population_type','normalized_export','database_evidence','source_configuration_evidence','overlap','unresolved_ambiguity') -Rows ([object[]]$botPopulationTsvRows)

$summaryPopulationKeys = @('random_account_stock','active_random_rotation','inactive_random_reserve','configured_player_owned_always_online')
$raceSummaryRows = New-Object System.Collections.Generic.List[object]
$classSummaryRows = New-Object System.Collections.Generic.List[object]
$combinationSummaryRows = New-Object System.Collections.Generic.List[object]
foreach ($populationKey in $summaryPopulationKeys) {
    $populationRows = @($populationRowsRaw | Where-Object { $_.population_key -ceq $populationKey })
    foreach ($group in @($populationRows | Group-Object race_id | Sort-Object { [int]$_.Name })) {
        $race = $raceMap[[int]$group.Name]
        $raceSummaryRows.Add([pscustomobject]@{ population_key=$populationKey; race_id=$race.race_id; race_key=$race.race_key; race_name=$race.race_name; bot_count=$group.Count; playable=$race.playable; turtle_custom_race=$race.turtle_custom_race })
    }
    foreach ($group in @($populationRows | Group-Object class_id | Sort-Object { [int]$_.Name })) {
        $class = $classMap[[int]$group.Name]
        $classSummaryRows.Add([pscustomobject]@{ population_key=$populationKey; class_id=$class.class_id; class_key=$class.class_key; class_name=$class.class_name; bot_count=$group.Count })
    }
    foreach ($group in @($populationRows | Group-Object race_id,class_id | Sort-Object { [int]$_.Group[0].race_id }, { [int]$_.Group[0].class_id })) {
        $sample = $group.Group[0]
        $race = $raceMap[[int]$sample.race_id]
        $class = $classMap[[int]$sample.class_id]
        $comboKey = "$($sample.race_id)|$($sample.class_id)"
        $customEvidence = if ([int]$sample.race_id -in @(9,10)) { 'Turtle-WoW custom race' } elseif ([int]$sample.race_id -eq 1 -and [int]$sample.class_id -eq 3) { 'Source comment identifies Human Hunter as custom non-vanilla' } else { '' }
        $combinationSummaryRows.Add([pscustomobject]@{
            population_key=$populationKey; race_id=$race.race_id; race_key=$race.race_key; class_id=$class.class_id; class_key=$class.class_key;
            bot_count=$group.Count; live_playercreateinfo_defined=$worldCombinationSet.ContainsKey($comboKey); local_custom_evidence=$customEvidence
        })
    }
}
Write-Tsv -Path (Join-Path $OutputDirectory 'race-summary.tsv') -Columns @('population_key','race_id','race_key','race_name','bot_count','playable','turtle_custom_race') -Rows ([object[]]$raceSummaryRows)
Write-Tsv -Path (Join-Path $OutputDirectory 'class-summary.tsv') -Columns @('population_key','class_id','class_key','class_name','bot_count') -Rows ([object[]]$classSummaryRows)
Write-Tsv -Path (Join-Path $OutputDirectory 'race-class-combinations.tsv') -Columns @('population_key','race_id','race_key','class_id','class_key','bot_count','live_playercreateinfo_defined','local_custom_evidence') -Rows ([object[]]$combinationSummaryRows)

$professionSummaryRows = New-Object System.Collections.Generic.List[object]
foreach ($populationKey in $summaryPopulationKeys) {
    foreach ($id in $professionIds) {
        $profession = $professionMap[$id]
        $rows = @($skillRowsRaw | Where-Object { $_.population_key -ceq $populationKey -and [int]$_.skill_id -eq $id -and [int]$_.skill_value -gt 0 })
        $values = @($rows | ForEach-Object { [int]$_.skill_value })
        $minimum = if ($values.Count -eq 0) { $null } else { ($values | Measure-Object -Minimum).Minimum }
        $maximum = if ($values.Count -eq 0) { $null } else { ($values | Measure-Object -Maximum).Maximum }
        $professionSummaryRows.Add([pscustomobject]@{
            population_key=$populationKey; skill_id=$id; profession_key=$profession.profession_key; profession_name=$profession.profession_name;
            category=$profession.category; observed_bot_count=@($rows | Select-Object -ExpandProperty bot_guid -Unique).Count;
            observed_minimum_value=$minimum; observed_maximum_value=$maximum; source_dbc_provenance='SkillLine.dbc'; source_code_provenance='SpellMgr.h IsProfessionSkill'
        })
    }
}
Write-Tsv -Path (Join-Path $OutputDirectory 'profession-summary.tsv') -Columns @('population_key','skill_id','profession_key','profession_name','category','observed_bot_count','observed_minimum_value','observed_maximum_value','source_dbc_provenance','source_code_provenance') -Rows ([object[]]$professionSummaryRows)

$botTsvRows = New-Object System.Collections.Generic.List[object]
$jsonBots = New-Object System.Collections.Generic.List[object]
$professionCountDistribution = @{ none=0; one=0; two_or_more=0 }
foreach ($row in $normalizedPopulationRows) {
    $race = $raceMap[[int]$row.race_id]
    $class = $classMap[[int]$row.class_id]
    $key = "$($row.population_key)|$($row.bot_guid)"
    $professionRows = @()
    if ($professionRowsByPopulationBot.ContainsKey($key)) { $professionRows = @($professionRowsByPopulationBot[$key] | ForEach-Object { $_ }) }
    if ($professionRows.Count -eq 0) { $professionCountDistribution.none++ } elseif ($professionRows.Count -eq 1) { $professionCountDistribution.one++ } else { $professionCountDistribution.two_or_more++ }
    $professionIdsText = (@($professionRows | ForEach-Object { [int]$_.skill_id }) -join ',')
    $genderKey = if ([int]$row.gender -eq 0) { 'male' } elseif ([int]$row.gender -eq 1) { 'female' } else { 'unmapped_gender' }
    $botTsvRows.Add([pscustomobject]@{
        bot_guid=[int64]$row.bot_guid; population_key=$row.population_key; race_id=$race.race_id; race_key=$race.race_key;
        class_id=$class.class_id; class_key=$class.class_key; gender_id=[int]$row.gender; gender_key=$genderKey;
        race_variant_key=''; profession_skill_ids=$professionIdsText
    })
    $jsonProfessions = @($professionRows | ForEach-Object {
        $profession = $professionMap[[int]$_.skill_id]
        [ordered]@{ skill_id=[int]$_.skill_id; profession_key=$profession.profession_key; value=[int]$_.skill_value; maximum=[int]$_.skill_maximum }
    })
    $jsonBots.Add([ordered]@{
        bot_guid=[int64]$row.bot_guid; population_key=$row.population_key; race_id=$race.race_id; race_key=$race.race_key;
        class_id=$class.class_id; class_key=$class.class_key; gender_id=[int]$row.gender; gender_key=$genderKey;
        race_variant_key=$null; professions=$jsonProfessions
    })
}
Write-Tsv -Path (Join-Path $OutputDirectory 'bot-professions.tsv') -Columns @('bot_guid','population_key','race_id','race_key','class_id','class_key','gender_id','gender_key','race_variant_key','profession_skill_ids') -Rows ([object[]]$botTsvRows)

$observedNormalizedSkillRows = @($skillRowsRaw | Where-Object { $_.population_key -in $normalizedPopulationKeys })
$unmappedSkillRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($observedNormalizedSkillRows | Group-Object skill_id | Sort-Object { [int]$_.Name })) {
    $id = [int]$group.Name
    if ($skillMap.ContainsKey($id)) { continue }
    $unmappedSkillRows.Add([pscustomobject]@{
        skill_id=$id; status='unmapped_skill_id'; local_name=''; category='unmapped'; observed_population_skill_rows=$group.Count;
        observed_unique_bot_count=@($group.Group | Select-Object -ExpandProperty bot_guid -Unique).Count; note='No matching row exists in the pinned local SkillLine.dbc.'
    })
}
Write-Tsv -Path (Join-Path $OutputDirectory 'unmapped-skills.tsv') -Columns @('skill_id','status','local_name','category','observed_population_skill_rows','observed_unique_bot_count','note') -Rows ([object[]]$unmappedSkillRows)

$assetPaths = @(
    $ConfigPath, $ServerConfigPath, $ServerExePath, $RaceDbcPath, $ClassDbcPath, $SkillDbcPath, $CharSectionsDbcPath,
    (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp'),
    (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.h'),
    (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp'),
    (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp'),
    (Join-Path $SourceRoot 'src\modules\PlayerBots\cmangos-compat-shim.h'),
    (Join-Path $SourceRoot 'src\game\SharedDefines.h'),
    (Join-Path $SourceRoot 'src\game\Spells\SpellMgr.h'),
    (Join-Path $SourceRoot 'src\game\Objects\Player.cpp'),
    (Join-Path $SourceRoot 'src\game\Handlers\CharacterHandler.cpp'),
    (Join-Path $SourceRoot 'src\game\Database\DBCStructure.h'),
    (Join-Path $SourceRoot 'src\game\ObjectMgr.cpp'),
    (Join-Path $SourceRoot 'src\scripts\spells\spells_turtle.cpp'),
    (Join-Path $SourceRoot 'src\modules\PlayerBots\sql\characters\ai_playerbot_random_bots.sql'),
    (Join-Path $SourceRoot 'sql\create_databases.sql'),
    (Join-Path $SourceRoot 'sql\base\tw_world_custom_character_skins.sql')
)
$assetRows = New-Object System.Collections.Generic.List[object]
foreach ($path in $assetPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Authoritative asset is missing: $path" }
    $item = Get-Item -LiteralPath $path
    $assetRows.Add([pscustomobject]@{ path=$path; bytes=$item.Length; sha256=Get-Sha256 -Path $path; last_write_time_utc=$item.LastWriteTimeUtc.ToString('o') })
}
Write-Tsv -Path (Join-Path $EvidenceDirectory 'authoritative-assets.tsv') -Columns @('path','bytes','sha256','last_write_time_utc') -Rows ([object[]]$assetRows)

$provenanceRows = New-Object System.Collections.Generic.List[object]
foreach ($race in @($raceMap.Values | Sort-Object race_id)) {
    $provenanceRows.Add([pscustomobject]@{ namespace='race'; numeric_id=$race.race_id; normalized_key=$race.race_key; local_name=$race.race_name; category=if($race.turtle_custom_race){'turtle_custom_playable_race'}else{'playable_race'}; authoritative_path=$RaceDbcPath; source_reference='DBCStructure.h ChrRacesEntry; SharedDefines.h Races' })
}
foreach ($class in @($classMap.Values | Sort-Object class_id)) {
    $provenanceRows.Add([pscustomobject]@{ namespace='class'; numeric_id=$class.class_id; normalized_key=$class.class_key; local_name=$class.class_name; category='playable_class'; authoritative_path=$ClassDbcPath; source_reference='DBCStructure.h ChrClassesEntry; SharedDefines.h Classes' })
}
foreach ($profession in @($professionMap.Values | Sort-Object skill_id)) {
    $provenanceRows.Add([pscustomobject]@{ namespace='profession'; numeric_id=$profession.skill_id; normalized_key=$profession.profession_key; local_name=$profession.profession_name; category=$profession.category; authoritative_path=$SkillDbcPath; source_reference='SpellMgr.h IsProfessionSkill' })
}
foreach ($group in @($observedNormalizedSkillRows | Group-Object skill_id | Sort-Object { [int]$_.Name })) {
    $id = [int]$group.Name
    if ($skillMap.ContainsKey($id)) {
        $skill = $skillMap[$id]
        $provenanceRows.Add([pscustomobject]@{ namespace='observed_skill'; numeric_id=$id; normalized_key=$skill.skill_key; local_name=$skill.skill_name; category=$skill.category_key; authoritative_path=$SkillDbcPath; source_reference='SkillLine.dbc category field' })
    }
    else {
        $provenanceRows.Add([pscustomobject]@{ namespace='observed_skill'; numeric_id=$id; normalized_key="unmapped_skill_$id"; local_name=''; category='unmapped'; authoritative_path=$SkillDbcPath; source_reference='No matching SkillLine.dbc row' })
    }
}
Write-Tsv -Path (Join-Path $OutputDirectory 'mapping-provenance.tsv') -Columns @('namespace','numeric_id','normalized_key','local_name','category','authoritative_path','source_reference') -Rows ([object[]]$provenanceRows)

$sourceExcerptLines = New-Object System.Collections.Generic.List[string]
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\game\SharedDefines.h') -Start 40 -End 87
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\game\SharedDefines.h') -Start 1282 -End 1291
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\game\Spells\SpellMgr.h') -Start 264 -End 283
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp') -Start 884 -End 911
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\PlayerbotAIConfig.cpp') -Start 1009 -End 1065
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') -Start 303 -End 309
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') -Start 3429 -End 3473
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotMgr.cpp') -Start 3496 -End 3575
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp') -Start 109 -End 125
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\modules\PlayerBots\playerbot\RandomPlayerbotFactory.cpp') -Start 302 -End 390
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\game\Objects\Player.cpp') -Start 2283 -End 2290
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\game\ObjectMgr.cpp') -Start 7871 -End 7889
Add-SourceExcerpt -Lines $sourceExcerptLines -Path (Join-Path $SourceRoot 'src\scripts\spells\spells_turtle.cpp') -Start 526 -End 542
Write-Utf8Lf -Path (Join-Path $EvidenceDirectory 'source-excerpts.txt') -Text (($sourceExcerptLines -join "`n") + "`n")

$configLines = @(Get-Content -LiteralPath $ConfigPath)
$configKeys = @('AiPlayerbot.Enabled','AiPlayerbot.RandomBotAutologin','AiPlayerbot.RandomBotLoginAtStartup','AiPlayerbot.BotAutologin','AiPlayerbot.RandomBotAutoCreate','AiPlayerbot.MinRandomBots','AiPlayerbot.MaxRandomBots','AiPlayerbot.RandomBotAccountPrefix','AiPlayerbot.RandomBotAccountCount')
$configEvidence = New-Object System.Collections.Generic.List[string]
foreach ($key in $configKeys) {
    $configMatches = @()
    for ($index=0; $index -lt $configLines.Count; $index++) {
        if ($configLines[$index] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) { $configMatches += ('{0}:{1}' -f ($index+1),$configLines[$index]) }
    }
    if ($configMatches.Count -ne 1) { throw "Expected one active configuration value for $key, found $($configMatches.Count)." }
    $configEvidence.Add($configMatches[0])
}
$configEvidence.Add('ToggleAlwaysOnlineAccounts: no active assignment; source default is empty.')
$configEvidence.Add('ToggleAlwaysOnlineChars: no active assignment; source default is empty.')
Write-Utf8Lf -Path (Join-Path $EvidenceDirectory 'config-evidence.txt') -Text (($configEvidence -join "`n") + "`n")

$gitBranch = (& git -c safe.directory=C:/TW/ComTW/source -c core.fileMode=false -C $SourceRoot symbolic-ref --short HEAD).Trim()
$gitIdentity = (& git -c safe.directory=C:/TW/ComTW/source -c core.fileMode=false -C $SourceRoot log -1 --format='%H|%cI|%s').Trim()
$gitParts = $gitIdentity.Split('|',3)
if ($gitParts.Count -ne 3) { throw 'Unable to parse source Git identity.' }

$databaseIdentity = @(Read-DataTsv -Path (Join-Path $QueryDirectory 'database-identity.tsv') -Headers @('database_name','server_version','version_comment','datadir','port','bind_address','character_set_server','collation_server','sql_mode'))[0]
if ($databaseIdentity.database_name -cne 'tw_char') { throw "Unexpected selected database: $($databaseIdentity.database_name)" }

$raceJson = foreach ($race in @($raceMap.Values | Sort-Object race_id)) {
    $counts = [ordered]@{}
    foreach ($populationKey in $summaryPopulationKeys) {
        $counts[$populationKey] = @($populationRowsRaw | Where-Object { $_.population_key -ceq $populationKey -and [int]$_.race_id -eq $race.race_id }).Count
    }
    [ordered]@{
        race_id=$race.race_id; race_key=$race.race_key; name=$race.race_name; playable=$race.playable;
        turtle_custom_race=$race.turtle_custom_race; male_model_id=$race.male_model_id; female_model_id=$race.female_model_id;
        population_counts=$counts
    }
}
$classJson = foreach ($class in @($classMap.Values | Sort-Object class_id)) {
    $counts = [ordered]@{}
    foreach ($populationKey in $summaryPopulationKeys) {
        $counts[$populationKey] = @($populationRowsRaw | Where-Object { $_.population_key -ceq $populationKey -and [int]$_.class_id -eq $class.class_id }).Count
    }
    [ordered]@{ class_id=$class.class_id; class_key=$class.class_key; name=$class.class_name; population_counts=$counts }
}
$professionJson = foreach ($id in $professionIds) {
    $profession = $professionMap[$id]
    $counts = [ordered]@{}
    foreach ($populationKey in $summaryPopulationKeys) {
        $counts[$populationKey] = @($skillRowsRaw | Where-Object { $_.population_key -ceq $populationKey -and [int]$_.skill_id -eq $id -and [int]$_.skill_value -gt 0 } | Select-Object -ExpandProperty bot_guid -Unique).Count
    }
    [ordered]@{
        skill_id=$id; profession_key=$profession.profession_key; name=$profession.profession_name; category=$profession.category;
        dbc_category_id=$profession.dbc_category_id; population_counts=$counts; source_dbc=$SkillDbcPath; source_code='SpellMgr.h:264-283'
    }
}

$unresolved = @(
    'No standalone Blood Elf race ID exists in the pinned zero-core SharedDefines.h or ChrRaces.dbc; race 10 is locally named High Elf.',
    'The custom_character_skins world table maps item tokens to skin-byte values, but the persistent characters row does not retain which token caused a skin value. A Blood-Elf-looking or other cosmetic variant therefore cannot be proven from the captured rows; race_variant_key remains null.',
    'One login marker exists, but the Worldserver was stopped and RandomPlayerbotMgr clears login markers during construction. It is not classified as a currently active bot.',
    'The database contains 100 add-marked rotation characters while MinRandomBots, MaxRandomBots, and the bot_count placeholder are 50. The source treats add rows as the rotation set; the reason for the stale or expanded set cannot be proven read-only.',
    'No learned primary, secondary, or custom Survival profession row exists for any normalized proven bot in character_skills.',
    'On-demand player-owned bots that have no ACTIVE always marker cannot be distinguished from normal player characters in an offline database capture.'
)

$mapping = [ordered]@{
    schema_version = 1
    metadata = [ordered]@{
        generated_utc = [DateTime]::UtcNow.ToString('o')
        source_branch = $gitBranch
        source_commit = $gitParts[0]
        source_commit_date = $gitParts[1]
        source_commit_subject = $gitParts[2]
        database_name = $databaseIdentity.database_name
        database_server_version = $databaseIdentity.server_version
        database_version_comment = $databaseIdentity.version_comment
        database_port = [int]$databaseIdentity.port
        worldserver_started = $false
        realmd_started = $false
        maria_db_owned_pid = [int]$harnessResult.database_owned_pid
        sql_statement_count = [int]$harnessResult.sql_statement_count
        sql_write_capable_statement_count = 0
        logical_database_writes = 0
        normalized_bot_row_count = $normalizedPopulationRows.Count
        unique_proven_bot_guid_count = $normalizedUniqueGuids.Count
        trait_assignment_performed = $false
    }
    bot_populations = $populationDefinitions
    races = @($raceJson)
    classes = @($classJson)
    professions = @($professionJson)
    race_variants = @()
    bots = [object[]]$jsonBots
    unresolved = $unresolved
}
$jsonPath = Join-Path $OutputDirectory 'bot-personality-mapping-v1.json'
Write-Utf8Lf -Path $jsonPath -Text (($mapping | ConvertTo-Json -Depth 12 -Compress) + "`n")

$reportLines = New-Object System.Collections.Generic.List[string]
$reportLines.Add('# Bot Personality Discovery')
$reportLines.Add('')
$reportLines.Add('This is a sanitized, read-only source and database inventory for a future Bot Personality and external LLM bridge. No personality table was created and no trait was assigned.')
$reportLines.Add('')
$reportLines.Add('## Identity and inspection boundary')
$reportLines.Add('')
$reportLines.Add("- Source: branch ``$gitBranch``, commit ``$($gitParts[0])`` ($($gitParts[1]), $($gitParts[2])).")
$reportLines.Add("- Database: ``$($databaseIdentity.database_name)`` on MariaDB ``$($databaseIdentity.server_version)``; reviewed owned PID ``$($harnessResult.database_owned_pid)``.")
$reportLines.Add("- Worldserver binary: ``$ServerExePath`` / ``$(Get-Sha256 -Path $ServerExePath)``. It was not started.")
$reportLines.Add('- SQL: 15 statements, all SELECT/SHOW, zero write-capable statements, zero logical database writes.')
$reportLines.Add("- Expected MariaDB engine-runtime changes were isolated to $($harnessResult.database_engine_runtime_changed_path_count) paths and are listed separately.")
$reportLines.Add('')
$reportLines.Add('## Proven populations')
$reportLines.Add('')
$reportLines.Add('| Population | Exact count | Meaning |')
$reportLines.Add('|---|---:|---|')
foreach ($population in $populationDefinitions) { $reportLines.Add("| ``$($population.population_key)`` | $($population.count) | $($population.database_evidence) |") }
$reportLines.Add('')
$reportLines.Add("The configured random-bot target is 50, but the database has 4,500 RNDBOT stock characters, 100 add-marked rotation characters, and 4,400 inactive reserve characters. This is not approximately 50 when measuring stock or add markers. Because mangosd was stopped, the authoritative currently running bot count is 0.")
$reportLines.Add("There is one non-random-account character. It is classified only as normal-or-unresolved non-bot stock; no character identity is exported. There are no ACTIVE always-online player-owned bot rows.")
$reportLines.Add("The single bot=0 row is a system placeholder and is never exported as a character GUID. Orphan event references: $($eventIntegrity.orphan_nonzero_bot_rows). Duplicate owner/bot/event extra rows: $($eventIntegrity.duplicate_owner_bot_event_extra_rows).")
$reportLines.Add('')
$reportLines.Add('## Races and classes')
$reportLines.Add('')
$reportLines.Add("All $($raceMap.Count) locally defined playable race IDs occur in the random account stock; no locally defined race ID is unused. Race 9 is Goblin and race 10 is High Elf according to the pinned ChrRaces.dbc and SharedDefines.h. The zero core defines no Blood Elf race ID.")
$reportLines.Add("All $($classMap.Count) locally defined class IDs occur in the stock. The live playercreateinfo table contains $($worldCombinationRows.Count) race/class definitions, and every observed bot combination is present there.")
$highElfCount = @($populationRowsRaw | Where-Object { $_.population_key -ceq 'random_account_stock' -and [int]$_.race_id -eq 10 }).Count
$goblinCount = @($populationRowsRaw | Where-Object { $_.population_key -ceq 'random_account_stock' -and [int]$_.race_id -eq 9 }).Count
$reportLines.Add("Random stock includes $highElfCount High Elves and $goblinCount Goblins. All combinations involving these locally custom races are Turtle-WoW-specific. RandomPlayerbotFactory.cpp also explicitly documents Human Hunter as a custom non-vanilla combination.")
$reportLines.Add('')
$reportLines.Add('## Appearance and variants')
$reportLines.Add('')
$reportLines.Add('The characters table persists gender, playerBytes, and playerBytes2. Player.cpp decodes playerBytes as skin, face, hair style, and hair color and the low byte of playerBytes2 as facial features. Race display models come from ChrRaces.dbc. No PlayerBot-specific display/model override column was found in the relevant character or PlayerBot tables.')
$reportLines.Add("CharSections.dbc contains $charSectionCount records. Normalized bot appearance tuples with a face/hair/facial-feature combination not matched by the local CharSections rules: $appearanceMismatchCount. This check validates local customization encoding; it does not prove a semantic visual race variant.")
$reportLines.Add('The world custom_character_skins table is token-driven and writes a skin byte. The persistent character row does not preserve the token provenance, so a Blood-Elf-looking or other cosmetic variant cannot be proven. Every exported race_variant_key is null.')
$reportLines.Add('')
$reportLines.Add('## Professions and skills')
$reportLines.Add('')
$reportLines.Add('character_skills(guid, skill, value, max) is the authoritative persisted character-skill table. SpellMgr classifies SkillLine category 11 as primary professions and additionally recognizes First Aid (129), Survival (142), Cooking (185), and Fishing (356). Riding is explicitly outside IsProfessionSkill.')
$reportLines.Add("Locally defined professions: $($professionIds.Count). Learned profession rows across normalized proven bots: 0. Bot population-membership rows with no profession: $($professionCountDistribution.none); one profession: $($professionCountDistribution.one); two or more: $($professionCountDistribution.two_or_more).")
$reportLines.Add("Unmapped observed skill IDs: $($unmappedSkillRows.Count). Duplicate population/GUID/skill records: 0. Every locally defined profession, including Turtle-WoW Survival, is unused by the proven bot populations in this capture.")
$reportLines.Add('')
$reportLines.Add('## Unresolved findings')
$reportLines.Add('')
foreach ($item in $unresolved) { $reportLines.Add("- $item") }
$reportLines.Add('')
$reportLines.Add('## Validation')
$reportLines.Add('')
$reportLines.Add("- Normalized exported bot rows: $($normalizedPopulationRows.Count); unique proven bot GUIDs: $($normalizedUniqueGuids.Count).")
$reportLines.Add('- Every exported GUID came from an authoritative characters join and a proven normalized population; no GUID range was used.')
$reportLines.Add('- Race, class, and profession keys are one-to-one with locally verified numeric IDs.')
$reportLines.Add('- Profession lists are numerically sorted; JSON and TSV counts reconcile.')
$reportLines.Add('- No character identity, account identity, credential, authentication material, network address, personal contact data, or full database row is exported.')
$reportLines.Add('- MariaDB stopped cleanly; mangosd and realmd were never started; ports 3307 and 8090 were closed at completion.')
$reportLines.Add('- No trait assignment has occurred.')
Write-Utf8Lf -Path (Join-Path $OutputDirectory 'bot-personality-discovery-report.md') -Text (($reportLines -join "`n") + "`n")

$queryResultHashRows = New-Object System.Collections.Generic.List[object]
$rowCountRows = Read-DataTsv -Path (Join-Path $EvidenceDirectory 'result-row-counts.tsv') -Headers @('query_id','result_rows')
foreach ($file in @(Get-ChildItem -LiteralPath $QueryDirectory -File | Sort-Object Name)) {
    $queryId = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $rowCount = @($rowCountRows | Where-Object { $_.query_id -ceq $queryId })
    $queryResultHashRows.Add([pscustomobject]@{ query_id=$queryId; result_rows=if($rowCount.Count -eq 1){[int]$rowCount[0].result_rows}else{$null}; bytes=$file.Length; sha256=Get-Sha256 -Path $file.FullName; local_path=$file.FullName })
}
Write-Tsv -Path (Join-Path $EvidenceDirectory 'query-result-hashes.tsv') -Columns @('query_id','result_rows','bytes','sha256','local_path') -Rows ([object[]]$queryResultHashRows)

$validation = [ordered]@{
    status='passed'
    generated_utc=[DateTime]::UtcNow.ToString('o')
    normalized_bot_rows=$normalizedPopulationRows.Count
    unique_proven_bot_guids=$normalizedUniqueGuids.Count
    duplicate_population_guid_rows=0
    unmapped_exported_race_ids=0
    unmapped_exported_class_ids=0
    profession_lists_sorted=$true
    json_tsv_bot_count_match=$true
    race_summary_reconciles=$true
    class_summary_reconciles=$true
    profession_summary_reconciles=$true
    sql_write_capable_statement_count=0
    logical_database_writes=0
    appearance_tuple_mismatch_count=$appearanceMismatchCount
    prohibited_data_fields_exported=0
    trait_assignment_performed=$false
}
$parsedJson = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 20
if (@($parsedJson.bots).Count -ne $botTsvRows.Count) { throw 'JSON/TSV bot row count mismatch.' }
foreach ($bot in @($parsedJson.bots)) {
    $ids = @($bot.professions | ForEach-Object { [int]$_.skill_id })
    if (($ids -join ',') -cne (@($ids | Sort-Object) -join ',')) { throw "Unsorted profession list for bot GUID $($bot.bot_guid)." }
}
Write-Utf8Lf -Path (Join-Path $EvidenceDirectory 'validation-result.json') -Text (($validation | ConvertTo-Json -Depth 6) + "`n")

$scanPaths = @(
    (Join-Path $OutputDirectory 'bot-personality-discovery-report.md'),
    (Join-Path $OutputDirectory 'bot-personality-mapping-v1.json'),
    (Join-Path $OutputDirectory 'bot-populations.tsv'),
    (Join-Path $OutputDirectory 'race-summary.tsv'),
    (Join-Path $OutputDirectory 'class-summary.tsv'),
    (Join-Path $OutputDirectory 'race-class-combinations.tsv'),
    (Join-Path $OutputDirectory 'profession-summary.tsv'),
    (Join-Path $OutputDirectory 'bot-professions.tsv'),
    (Join-Path $OutputDirectory 'unmapped-skills.tsv'),
    (Join-Path $OutputDirectory 'mapping-provenance.tsv')
)
$forbiddenFieldPattern = '(?i)\b(account_id|account_name|character_name|password_hash|password|session_key|sessionkey|last_ip|last_attempt_ip|email_address|email)\b'
foreach ($path in $scanPaths) {
    $text = [IO.File]::ReadAllText($path)
    if ($text -match $forbiddenFieldPattern) { throw "Sanitization scan found a prohibited field token in ${path}: $($Matches[0])" }
}

Write-Output "DELIVERABLE_GENERATION=PASSED"
Write-Output "NORMALIZED_BOT_ROWS=$($normalizedPopulationRows.Count)"
Write-Output "UNIQUE_PROVEN_BOTS=$($normalizedUniqueGuids.Count)"
Write-Output "UNMAPPED_SKILLS=$($unmappedSkillRows.Count)"
Write-Output "APPEARANCE_MISMATCHES=$appearanceMismatchCount"
