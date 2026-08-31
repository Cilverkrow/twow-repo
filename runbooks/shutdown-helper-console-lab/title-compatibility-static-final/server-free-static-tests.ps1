param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HelperPath = 'C:\TW\ComTW\server\shutdown-tortoise-servers-gracefully-candidate.ps1'
$SmokePath = 'C:\TW\ComTW\runbooks\tw-world-shutdown-smoke-count-fix-candidate.ps1'
$ExpectedHelperSha256 = '76D899BE55BAE77E72CCD5DF6C5CBD8203986524E944C3AEE7B8C2DD7862EA1A'
$ExpectedSmokeSha256 = '27E1C99A1CB547B9E8BBC8FE0D175A0295BA357624BF4AA1D42E66C56800E655'

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Parse-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors)
    if ($errors.Count -ne 0) {
        throw ('Parser errors in {0}: {1}' -f $Path, ($errors -join ' | '))
    }
    return $ast
}

if ((Get-Sha256 -Path $HelperPath) -cne $ExpectedHelperSha256) {
    throw 'Helper identity mismatch.'
}
if ((Get-Sha256 -Path $SmokePath) -cne $ExpectedSmokeSha256) {
    throw 'Smoke candidate identity mismatch.'
}

$helperAst = Parse-File -Path $HelperPath
$titleIfStatements = @($helperAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('Unerwarteter Konsolentitel fuer PID')
}, $true))
if ($titleIfStatements.Count -ne 1) {
    throw "Expected one title-validation statement, found $($titleIfStatements.Count)."
}

$titleRejectCondition = $titleIfStatements[0].Clauses[0].Item1.Extent.Text
$titleAcceptSource = 'param($actualTitle, $ExpectedWindowTitle)' +
    [Environment]::NewLine +
    ('-not ({0})' -f $titleRejectCondition)
$titleAcceptScript = [scriptblock]::Create($titleAcceptSource)
$titleCases = @(
    [pscustomobject]@{ Actual = 'mangosd'; Expected = 'mangosd'; Accept = $true; Name = 'exact-world' },
    [pscustomobject]@{ Actual = 'Administrator:  mangosd'; Expected = 'mangosd'; Accept = $true; Name = 'elevated-world-two-spaces' },
    [pscustomobject]@{ Actual = 'realmd'; Expected = 'realmd'; Accept = $true; Name = 'exact-realm' },
    [pscustomobject]@{ Actual = 'Administrator:  realmd'; Expected = 'realmd'; Accept = $true; Name = 'elevated-realm-two-spaces' },
    [pscustomobject]@{ Actual = 'Administrator: mangosd'; Expected = 'mangosd'; Accept = $false; Name = 'one-space' },
    [pscustomobject]@{ Actual = 'administrator:  mangosd'; Expected = 'mangosd'; Accept = $false; Name = 'lowercase-prefix' },
    [pscustomobject]@{ Actual = 'Administrator:  mangosd '; Expected = 'mangosd'; Accept = $false; Name = 'trailing-space' },
    [pscustomobject]@{ Actual = ' Administrator:  mangosd'; Expected = 'mangosd'; Accept = $false; Name = 'leading-space' },
    [pscustomobject]@{ Actual = 'prefix Administrator:  mangosd'; Expected = 'mangosd'; Accept = $false; Name = 'arbitrary-prefix' },
    [pscustomobject]@{ Actual = 'Administrator:   mangosd'; Expected = 'mangosd'; Accept = $false; Name = 'three-spaces' },
    [pscustomobject]@{ Actual = 'Administrator:  wrong'; Expected = 'mangosd'; Accept = $false; Name = 'wrong-title' }
)

foreach ($case in $titleCases) {
    $actual = [bool](& $titleAcceptScript $case.Actual $case.Expected)
    if ($actual -ne $case.Accept) {
        throw "Title case failed: $($case.Name)"
    }
    $visible = $case.Actual.Replace(' ', '<SP>')
    [Console]::Out.WriteLine(
        "TITLE_CASE|NAME=$($case.Name)|ACTUAL=$visible|EXPECTED_RESULT=$($case.Accept)|PASS=true")
}

$smokeAst = Parse-File -Path $SmokePath
$remainingAssignments = @($smokeAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$remainingWorldProcesses'
}, $true))
if ($remainingAssignments.Count -ne 1) {
    throw "Expected one remaining-world assignment, found $($remainingAssignments.Count)."
}

$remainingRhs = $remainingAssignments[0].Right.Extent.Text
if (-not $remainingRhs.StartsWith('@(if ', [StringComparison]::Ordinal)) {
    throw "The remaining-world assignment is not wrapped by an outer array expression: $remainingRhs"
}

function Get-ProcessCandidates {
    param([string]$Kind)
    return @($script:FakeResults)
}

function Get-Process {
    param([string]$Name, [object]$ErrorAction)
    return @($script:FakeResults)
}

$countSource = ('$remainingWorldProcesses = {0}' -f $remainingRhs) +
    [Environment]::NewLine +
    '[pscustomobject]@{ Type = $remainingWorldProcesses.GetType().FullName; Count = $remainingWorldProcesses.Count; Ids = @($remainingWorldProcesses | ForEach-Object { $_.Id }) }'
$countScript = [scriptblock]::Create($countSource)

foreach ($subsetLoaded in @($true, $false)) {
    $script:SubsetLoaded = $subsetLoaded
    foreach ($count in @(0, 1, 3)) {
        $script:FakeResults = @(
            for ($index = 1; $index -le $count; $index++) {
                [pscustomobject]@{ Id = $index }
            })
        $result = & $countScript
        $expectedIds = @(1..$count)
        if ($count -eq 0) {
            $expectedIds = @()
        }
        if ($result.Type -cne 'System.Object[]' -or
            $result.Count -ne $count -or
            (($result.Ids -join ',') -cne ($expectedIds -join ','))) {
            throw "Count case failed: SubsetLoaded=$subsetLoaded Count=$count Result=$($result | ConvertTo-Json -Compress)"
        }
        [Console]::Out.WriteLine(
            "COUNT_CASE|SUBSET_LOADED=$subsetLoaded|COUNT=$count|TYPE=$($result.Type)|IDS=$($result.Ids -join ',')|PASS=true")
    }
}

[Console]::Out.WriteLine('STATIC_TESTS_PASS=true')
exit 0
