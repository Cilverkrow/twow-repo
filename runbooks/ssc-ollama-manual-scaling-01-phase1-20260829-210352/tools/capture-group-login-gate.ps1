[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = 'C:\TW\ComTW\source'
$relativePath = 'src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp'
$outputPath = 'C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352\evidence\source-group-login-gate.txt'
if (Test-Path -LiteralPath $outputPath) { throw 'Refusing overwrite' }
$head = (& git -c safe.directory=C:/TW/ComTW/source -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse failed' }
$lines = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo --no-pager show "HEAD:$relativePath")
if ($LASTEXITCODE -ne 0) { throw 'git show failed' }
$result = [System.Collections.Generic.List[string]]::new()
$result.Add("===== $relativePath @ $head =====")
foreach ($range in @(@(1992, 2055), @(3848, 3890))) {
    $result.Add("----- lines $($range[0])-$($range[1]) -----")
    for ($lineNumber = $range[0]; $lineNumber -le $range[1]; $lineNumber++) {
        $result.Add(('{0,6}: {1}' -f $lineNumber, $lines[$lineNumber - 1]))
    }
}
[IO.File]::WriteAllLines($outputPath, $result, [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $outputPath | Select-Object FullName, Length
