[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = 'C:\TW\ComTW\source'
$commit = '42b8a7f742548793910fe8880463aeeb71627fb9'
$output = 'C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222\evidence\character-fourth-row-source-excerpts.txt'
if (Test-Path -LiteralPath $output) { throw 'Refusing overwrite' }
function Read-GitFile([string]$Path) {
    $lines = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo --no-pager show "$commit`:$Path")
    if ($LASTEXITCODE -ne 0) { throw "git show failed: $Path" }
    return $lines
}
$result = [System.Collections.Generic.List[string]]::new()
foreach ($item in @(
    [pscustomobject]@{ Path = 'sql/create_databases.sql'; Start = 640; End = 662 },
    [pscustomobject]@{ Path = 'src/game/Handlers/CharacterHandler.cpp'; Start = 80; End = 90 },
    [pscustomobject]@{ Path = 'src/game/HonorMgr.cpp'; Start = 580; End = 593 }
)) {
    $lines = @(Read-GitFile $item.Path)
    $result.Add("===== $($item.Path) @ $commit lines $($item.Start)-$($item.End) =====")
    for ($number = $item.Start; $number -le [Math]::Min($item.End, $lines.Count); $number++) {
        $result.Add(('{0,6}: {1}' -f $number, $lines[$number - 1]))
    }
}
$history = @(& git -c safe.directory=C:/TW/ComTW/source -C $repo --no-pager log --follow --date=iso-strict --format='%H%x09%aI%x09%s' -- 'sql/database_updates/character/20260817151028_character.sql')
if ($LASTEXITCODE -ne 0) { throw 'git history query failed' }
$result.Add('===== file history (read-only) =====')
foreach ($line in $history) { $result.Add($line) }
[IO.File]::WriteAllLines($output, $result, [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $output | Select-Object FullName, Length
