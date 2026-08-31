#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
Write-Output ("PARSER_ERRORS={0}" -f $errors.Count)
foreach ($errorItem in $errors) {
    Write-Output $errorItem.Message
}
if ($errors.Count -ne 0) { exit 1 }
exit 0
