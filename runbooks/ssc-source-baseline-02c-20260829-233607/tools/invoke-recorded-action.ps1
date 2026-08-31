param(
    [Parameter(Mandatory=$true)][string]$ActionName,
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory
)
$ErrorActionPreference='Stop'
$runbook='C:\TW\ComTW\runbooks\ssc-source-baseline-02c-20260829-233607'
$logPath=Join-Path $runbook "evidence\action-$ActionName.log"
$metadataPath=Join-Path $runbook "evidence\action-$ActionName.json"
foreach($path in @($logPath,$metadataPath)){if(Test-Path -LiteralPath $path){throw "Refusing overwrite: $path"}}
$startedUtc=(Get-Date).ToUniversalTime();$startedLocal=(Get-Date)
$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$FilePath;$psi.WorkingDirectory=$WorkingDirectory;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
foreach($a in $Arguments){[void]$psi.ArgumentList.Add($a)}
$p=[Diagnostics.Process]::Start($psi);$stdoutTask=$p.StandardOutput.ReadToEndAsync();$stderrTask=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult();$exitCode=$p.ExitCode;$p.Dispose()
$finishedUtc=(Get-Date).ToUniversalTime();$finishedLocal=(Get-Date)
$log=@("ACTION=$ActionName","STARTED_UTC=$($startedUtc.ToString('o'))","STARTED_LOCAL=$($startedLocal.ToString('o'))","EXECUTABLE=$FilePath","ARGUMENTS_JSON=$($Arguments|ConvertTo-Json -Compress)","WORKING_DIRECTORY=$WorkingDirectory",'--- STDOUT ---',$stdout.TrimEnd(),'--- STDERR ---',$stderr.TrimEnd(),'--- RESULT ---',"EXIT_CODE=$exitCode","FINISHED_UTC=$($finishedUtc.ToString('o'))","FINISHED_LOCAL=$($finishedLocal.ToString('o'))")-join"`n"
[IO.File]::WriteAllText($logPath,$log+"`n",[Text.UTF8Encoding]::new($false))
$meta=[ordered]@{schema_version=1;task='SSC-SOURCE-BASELINE-02C';action=$ActionName;file_path=$FilePath;arguments=$Arguments;working_directory=$WorkingDirectory;started_utc=$startedUtc.ToString('o');started_local=$startedLocal.ToString('o');finished_utc=$finishedUtc.ToString('o');finished_local=$finishedLocal.ToString('o');elapsed_seconds=[math]::Round(($finishedUtc-$startedUtc).TotalSeconds,3);exit_code=$exitCode;stdout=$stdout.TrimEnd();stderr=$stderr.TrimEnd();log_path=$logPath;log_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $logPath).Hash}
[IO.File]::WriteAllText($metadataPath,($meta|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
if($stdout){Write-Output $stdout.TrimEnd()};if($stderr){Write-Error $stderr.TrimEnd() -ErrorAction Continue};Write-Output "RECORDED_ACTION=$ActionName";Write-Output "EXIT_CODE=$exitCode";if($exitCode-ne0){exit $exitCode}
