[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$Root='C:\TW\ComTW\runbooks\ssc-ollama-manual-scaling-01-phase1-20260829-210352';$Ev=Join-Path $Root 'evidence';$Repo='C:\TW\ComTW\source';$Conf='C:\TW\ComTW\server\aiplayerbot.conf';$Out=Join-Path $Ev 'source-control-flow-excerpts.txt';$Integrity=Join-Path $Ev 'phase1-readonly-integrity.json';foreach($p in @($Out,$Integrity)){if(Test-Path $p){throw "Refusing overwrite $p"}}
function GitShow([string]$p){$o=& git -c safe.directory=C:/TW/ComTW/source -C $Repo show "HEAD:$p" 2>&1;if($LASTEXITCODE-ne 0){throw($o-join"`n")};,@($o)}
$head=(& git -c safe.directory=C:/TW/ComTW/source -C $Repo rev-parse HEAD).Trim();$sb=[Text.StringBuilder]::new()
function AddRanges([string]$Path,[int[][]]$Ranges){[void]$sb.AppendLine("===== $Path @ $head =====");$lines=GitShow $Path;foreach($range in $Ranges){[void]$sb.AppendLine("--- $($range[0])-$($range[1]) ---");for($i=$range[0]-1;$i-lt[Math]::Min($range[1],$lines.Count);$i++){[void]$sb.AppendLine(('{0,6}: {1}'-f($i+1),$lines[$i]))}}}
AddRanges 'src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp' @(@(246,250),@(294,310),@(340,340),@(362,363),@(705,718),@(772,800),@(1365,1372))
AddRanges 'src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp' @(@(644,704),@(724,773),@(1121,1133),@(1261,1300),@(1992,2055),@(2232,2283),@(3456,3473))
AddRanges 'src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp' @(@(823,866),@(908,942),@(1022,1074),@(2105,2151))
AddRanges 'src/modules/PlayerBots/playerbot/strategy/actions/SayAction.cpp' @(@(512,515),@(602,655))
AddRanges 'src/modules/PlayerBots/playerbot/strategy/triggers/RpgTriggers.cpp' @(@(627,639))
AddRanges 'src/game/SharedDefines.h' @(@(1168,1172))
[IO.File]::WriteAllText($Out,$sb.ToString(),[Text.UTF8Encoding]::new($false));$cfg=(Get-Content -Raw -LiteralPath (Join-Path $Ev 'active-aiplayerbot-config-evidence.json')|ConvertFrom-Json);$now=(Get-FileHash $Conf -Algorithm SHA256).Hash;$audit=[ordered]@{captured_utc=[DateTime]::UtcNow.ToString('o');config_sha256_initial=$cfg.sha256;config_sha256_final=$now;config_unchanged=($cfg.sha256-eq$now);source_or_config_writes=@();database_statement_class='SELECT only';database_writes=@();bot_login_actions=@();process_control_actions=@();ollama_inference_actions=@();phase2_started=$false};[IO.File]::WriteAllText($Integrity,($audit|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false));'Excerpts captured.'
