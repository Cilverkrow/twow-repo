[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HarnessPath,

    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$Model,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixtureDirectory = Join-Path $PSScriptRoot 'test-fixtures'
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$pwshPath = (Get-Process -Id $PID).Path

function Write-JsonFixture {
    param([string]$Name, [object]$Value)
    $path = Join-Path $fixtureDirectory $Name
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8)
    return $path
}

function Invoke-HarnessCase {
    param([string[]]$Arguments)
    $output = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $HarnessPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $parsed = $null
    try {
        $parsed = $text | ConvertFrom-Json -Depth 20
    }
    catch {
        # Test assertions report malformed harness output without aborting the suite.
    }
    return [pscustomobject]@{ exit_code = $exitCode; raw = $text; envelope = $parsed }
}

function New-MockResponse {
    param([string]$Content)
    return [ordered]@{
        model             = $Model
        message           = [ordered]@{ role = 'assistant'; content = $Content }
        done              = $true
        total_duration    = 1000000
        load_duration     = 0
        prompt_eval_count = 20
        eval_count        = 8
    }
}

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Results.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
}

$validRequest = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json -Depth 20
$results = [Collections.Generic.List[object]]::new()

$validMock = Write-JsonFixture -Name 'valid-response.json' -Value (New-MockResponse -Content 'Ich sehe mich heute etwas in der Gegend um.')
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $RequestPath, '-Model', $Model, '-MockResponsePath', $validMock)
$passed = $case.exit_code -eq 0 -and $null -ne $case.envelope -and $case.envelope.status -eq 'ok' -and $case.envelope.bot_guid -eq $validRequest.bot_guid -and $case.envelope.request_id -eq $validRequest.request_id
Add-Result -Name 'valid_context_and_request' -Passed $passed -Detail "exit=$($case.exit_code); status=$($case.envelope.status)"

$missingGuidRequest = [ordered]@{ schema_version = 1; request_id = 'missing-guid-test'; channel = 'phase0_console'; speaker = 'synthetic_phase0_user'; message = 'Hallo?' }
$missingGuidPath = Write-JsonFixture -Name 'missing-guid-request.json' -Value $missingGuidRequest
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $missingGuidPath, '-Model', $Model, '-MockResponsePath', $validMock)
$passed = $case.exit_code -eq 2 -and $null -ne $case.envelope -and $case.envelope.status -eq 'error_validation'
Add-Result -Name 'missing_bot_guid' -Passed $passed -Detail "exit=$($case.exit_code); status=$($case.envelope.status)"

$mismatchRequest = [ordered]@{ schema_version = 1; request_id = 'mismatch-test'; channel = 'phase0_console'; speaker = 'synthetic_phase0_user'; bot_guid = 99999; message = 'Hallo?' }
$mismatchPath = Write-JsonFixture -Name 'mismatch-request.json' -Value $mismatchRequest
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $mismatchPath, '-Model', $Model, '-MockResponsePath', $validMock)
$passed = $case.exit_code -eq 2 -and $null -ne $case.envelope -and $case.envelope.status -eq 'error_validation'
Add-Result -Name 'request_context_guid_mismatch' -Passed $passed -Detail "exit=$($case.exit_code); status=$($case.envelope.status)"

$invalidJsonPath = Join-Path $fixtureDirectory 'invalid-request.json'
[IO.File]::WriteAllText($invalidJsonPath, '{ invalid json', $utf8)
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $invalidJsonPath, '-Model', $Model, '-MockResponsePath', $validMock)
$passed = $case.exit_code -eq 2 -and $null -ne $case.envelope -and $case.envelope.status -eq 'error_validation'
Add-Result -Name 'invalid_json' -Passed $passed -Detail "exit=$($case.exit_code); status=$($case.envelope.status)"

$emptyMessageRequest = [ordered]@{ schema_version = 1; request_id = 'empty-message-test'; channel = 'phase0_console'; speaker = 'synthetic_phase0_user'; bot_guid = $validRequest.bot_guid; message = '   ' }
$emptyMessagePath = Write-JsonFixture -Name 'empty-message-request.json' -Value $emptyMessageRequest
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $emptyMessagePath, '-Model', $Model, '-MockResponsePath', $validMock)
$passed = $case.exit_code -eq 2 -and $null -ne $case.envelope -and $case.envelope.status -eq 'error_validation'
Add-Result -Name 'empty_user_message' -Passed $passed -Detail "exit=$($case.exit_code); status=$($case.envelope.status)"

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$unusedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $RequestPath, '-Model', $Model, '-Endpoint', "http://127.0.0.1:$unusedPort", '-ConnectTimeoutSeconds', '1', '-ResponseTimeoutSeconds', '2')
$passed = $case.exit_code -eq 3 -and $null -ne $case.envelope -and $case.envelope.status -eq 'error_http'
Add-Result -Name 'unreachable_loopback_endpoint' -Passed $passed -Detail "port=$unusedPort; exit=$($case.exit_code); status=$($case.envelope.status)"

$oversizedText = ('Heute ziehe ich los, um mir die Gegend gründlich anzusehen und dabei wachsam zu bleiben. ' * 8) + 'Danach ruhe ich mich aus. Ein dritter Satz darf nicht erscheinen.'
$oversizedMock = Write-JsonFixture -Name 'oversized-response.json' -Value (New-MockResponse -Content $oversizedText)
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $RequestPath, '-Model', $Model, '-MockResponsePath', $oversizedMock)
$visibleCount = if ($null -ne $case.envelope) { [Globalization.StringInfo]::ParseCombiningCharacters([string]$case.envelope.text).Count } else { 9999 }
$sentenceCount = if ($null -ne $case.envelope) { [regex]::Matches([string]$case.envelope.text, '[.!?…]+').Count } else { 9999 }
$passed = $case.exit_code -eq 0 -and $visibleCount -le 240 -and $sentenceCount -le 2
Add-Result -Name 'oversized_model_response' -Passed $passed -Detail "exit=$($case.exit_code); visible_characters=$visibleCount; sentence_terminators=$sentenceCount"

$controlMock = Write-JsonFixture -Name 'control-multiline-response.json' -Value (New-MockResponse -Content "Erste`u{0001} Zeile.`r`nZweite Zeile.`nDritte Zeile.")
$case = Invoke-HarnessCase -Arguments @('-ContextPath', $ContextPath, '-RequestPath', $RequestPath, '-Model', $Model, '-MockResponsePath', $controlMock)
$hasControl = $false
if ($null -ne $case.envelope) {
    foreach ($character in ([string]$case.envelope.text).ToCharArray()) {
        if ([char]::IsControl($character)) { $hasControl = $true; break }
    }
}
$passed = $case.exit_code -eq 0 -and -not $hasControl -and [string]$case.envelope.text -eq 'Erste Zeile. Zweite Zeile.'
Add-Result -Name 'control_characters_and_multiline_response' -Passed $passed -Detail "exit=$($case.exit_code); controls_remaining=$hasControl; text=$($case.envelope.text)"

$summary = [ordered]@{
    schema_version = 1
    generated_utc  = [DateTime]::UtcNow.ToString('o')
    all_passed     = -not ($results | Where-Object { -not $_.passed })
    test_count     = $results.Count
    tests          = $results
}

[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), ($summary | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8)
$summary | ConvertTo-Json -Depth 20
if (-not $summary.all_passed) { exit 1 }
