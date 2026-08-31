$ErrorActionPreference = 'Stop'

$candidate = 'C:\TW\ComTW\runbooks\tw-char-migration-semantic-acl-candidate.ps1'
$cLab = Join-Path (Split-Path -Parent $PSCommandPath) 'run-2'
$eLab = 'E:\TWoW-Migration-Backups\semantic-acl-e2e-lab-4'
$resultPath = Join-Path $cLab 'test-results.json'
$result = [ordered]@{ Status = 'started'; StartedUtc = [DateTime]::UtcNow.ToString('o') }

function Save-TestResult {
    param([object]$Value)
    [IO.File]::WriteAllText($resultPath, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

function Get-SafeAclSnapshotHash {
    param([string]$Root)
    $rootPath = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\')
    $queue = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $queue.Enqueue((Get-Item -LiteralPath $rootPath -Force))
    $lines = New-Object System.Collections.Generic.List[string]
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        $relative = if ($directory.FullName -eq $rootPath) { '.' } else { $directory.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/') }
        $lines.Add("D|$relative|$((Get-Acl -LiteralPath $directory.FullName -Audit -ErrorAction Stop).Sddl)")
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            $childRelative = $item.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $lines.Add("R|$childRelative|$((Get-Acl -LiteralPath $item.FullName -Audit -ErrorAction Stop).Sddl)")
            }
            elseif ($item.PSIsContainer) {
                $queue.Enqueue($item)
            }
            else {
                $lines.Add("F|$childRelative|$((Get-Acl -LiteralPath $item.FullName -Audit -ErrorAction Stop).Sddl)")
            }
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($lines | Sort-Object) -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object ToString X2) -join '') }
    finally { $sha.Dispose() }
}

function Invoke-CoverageFailureTest {
    param([string]$Name, [string]$Manifest, [string]$Target, [string]$BeforeHash)
    try {
        Set-AclManifestOnDirectory -ManifestPath $Manifest -Directory $Target
        throw "Coverage test was unexpectedly accepted: $Name"
    }
    catch {
        $message = $_.Exception.Message
    }
    $afterHash = Get-SafeAclSnapshotHash -Root $Target
    if ($BeforeHash -cne $afterHash) { throw "A target ACL changed before coverage rejection: $Name" }
    return [pscustomobject]@{ Name = $Name; Rejected = $true; AclUnchanged = $true; Error = $message }
}

try {
    if (Test-Path -LiteralPath $cLab) { throw "Disposable test path already exists: $cLab" }
    New-Item -ItemType Directory -Path $cLab -ErrorAction Stop | Out-Null
    foreach ($path in @(
        (Join-Path $cLab 'source-root'),
        (Join-Path $cLab 'restore-staging'),
        (Join-Path $cLab 'negative-coverage-target'),
        (Join-Path $cLab 'negative-reparse-target'),
        $resultPath,
        $eLab
    )) {
        if (Test-Path -LiteralPath $path) { throw "Disposable test path already exists: $path" }
    }

    New-Item -ItemType Directory -Path $eLab -ErrorAction Stop | Out-Null
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($candidate, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Candidate parser errors prevent testing.' }
    foreach ($functionAst in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        Invoke-Expression $functionAst.Extent.Text
    }
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)

    $source = Join-Path $cLab 'source-root'
    $inherited = Join-Path $source 'inherited-dir'
    $protected = Join-Path $source 'protected-dir'
    $deeper = Join-Path $protected 'deeper-dir'
    New-Item -ItemType Directory -Path $source, $inherited, $protected, $deeper -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'root-file.txt'), 'root content', $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $inherited 'inherited-file.txt'), 'inherited content', $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $deeper 'explicit-file.txt'), 'explicit content', $Utf8NoBom)

    $authenticatedUsers = New-Object Security.Principal.SecurityIdentifier('S-1-5-11')
    $everyone = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
    $guests = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-546')
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit

    $acl = Get-Acl -LiteralPath $source -Audit -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $true)
    $allow = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $authenticatedUsers,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $audit = New-Object -TypeName Security.AccessControl.FileSystemAuditRule -ArgumentList @(
        $everyone,
        [Security.AccessControl.FileSystemRights]::ReadData,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AuditFlags]::Success
    )
    [void]$acl.AddAccessRule($allow)
    [void]$acl.AddAuditRule($audit)
    Set-Acl -LiteralPath $source -AclObject $acl -ErrorAction Stop

    $acl = Get-Acl -LiteralPath $protected -Audit -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $true)
    $deny = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $guests,
        [Security.AccessControl.FileSystemRights]::Delete,
        [Security.AccessControl.AccessControlType]::Deny
    )
    [void]$acl.AddAccessRule($deny)
    Set-Acl -LiteralPath $protected -AclObject $acl -ErrorAction Stop

    $explicitFile = Join-Path $deeper 'explicit-file.txt'
    $acl = Get-Acl -LiteralPath $explicitFile -Audit -ErrorAction Stop
    $fileAllow = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $currentUser,
        [Security.AccessControl.FileSystemRights]::WriteAttributes,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($fileAllow)
    Set-Acl -LiteralPath $explicitFile -AclObject $acl -ErrorAction Stop

    $runDirectory = Join-Path $eLab 'probe-run'
    $coldBackup = Join-Path $runDirectory 'cold-backup'
    $evidenceDirectory = Join-Path $runDirectory 'evidence'
    $migrationDirectory = Join-Path $runDirectory 'migration-files'
    New-Item -ItemType Directory -Path $runDirectory, $evidenceDirectory, $migrationDirectory -ErrorAction Stop | Out-Null
    $sourceManifest = Join-Path $evidenceDirectory 'physical-source.sha256'
    $sourceAclManifest = Join-Path $evidenceDirectory 'physical-source.acl.txt'
    $backupManifest = Join-Path $evidenceDirectory 'physical-backup.sha256'
    $backupAclManifest = Join-Path $evidenceDirectory 'physical-backup.acl.txt'

    New-TreeManifest -Directory $source -ManifestPath $sourceManifest
    New-AclManifest -Directory $source -ManifestPath $sourceAclManifest
    Invoke-RobocopyVerified -Source $source -Destination $coldBackup
    Assert-NoReparsePoints -Directory $coldBackup
    Copy-RootAcl -Source $source -Destination $coldBackup
    New-TreeManifest -Directory $coldBackup -ManifestPath $backupManifest
    New-AclManifest -Directory $coldBackup -ManifestPath $backupAclManifest
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $coldBackup
    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $coldBackup
    Assert-AclManifestMatchesDirectory -ManifestPath $backupAclManifest -Directory $coldBackup
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $coldBackup

    $sourceEntries = @(Get-AclManifestEntries -Lines @(Get-Content -LiteralPath $sourceAclManifest) -Context $sourceAclManifest)
    $sourceLines = @(Get-Content -LiteralPath $sourceAclManifest)
    $coldLines = @(Get-AclManifestLines -Directory $coldBackup)
    $rawDifferences = 0
    for ($index = 0; $index -lt $sourceLines.Count; $index++) {
        if ($sourceLines[$index] -cne $coldLines[$index]) { $rawDifferences++ }
    }
    $saclPresentObjects = @($sourceEntries | Where-Object { $null -ne $_.Descriptor.SystemAcl }).Count

    $Migrations = @()
    foreach ($name in @('one.sql', 'two.sql', 'three.sql', 'four.sql')) {
        $Migrations += [pscustomobject]@{ FileName = $name }
        [IO.File]::WriteAllText((Join-Path $migrationDirectory $name), "-- $name`r`n", $Utf8NoBom)
    }
    Copy-Item -LiteralPath $candidate -Destination (Join-Path $evidenceDirectory 'executed-runbook.ps1') -ErrorAction Stop
    $anchorPath = Join-Path $evidenceDirectory 'backup-evidence-anchor.sha256'
    New-BackupEvidenceAnchor -RunDirectory $runDirectory -EvidenceDirectory $evidenceDirectory -MigrationDirectory $migrationDirectory -AnchorPath $anchorPath
    $anchorHash = Get-Sha256 -Path $anchorPath
    Assert-BackupEvidenceAnchor -RunDirectory $runDirectory -EvidenceDirectory $evidenceDirectory -MigrationDirectory $migrationDirectory -AnchorPath $anchorPath -ExpectedAnchorSha256 $anchorHash
    $anchorLines = @(Get-Content -LiteralPath $anchorPath)
    foreach ($required in @('physical-source.sha256', 'physical-source.acl.txt', 'physical-backup.sha256', 'physical-backup.acl.txt')) {
        if (@($anchorLines | Where-Object { $_ -match [regex]::Escape($required) }).Count -ne 1) { throw "Anchor entry is missing or duplicated: $required" }
    }

    $staging = Join-Path $cLab 'restore-staging'
    Invoke-RobocopyVerified -Source $coldBackup -Destination $staging
    Assert-NoReparsePoints -Directory $staging
    $coverage = @(Assert-AclManifestCoverage -ManifestPath $sourceAclManifest -Directory $staging)
    Set-AclManifestOnDirectory -ManifestPath $sourceAclManifest -Directory $staging
    Assert-ManifestMatchesDirectory -ManifestPath $sourceManifest -Directory $staging
    Assert-ManifestMatchesDirectory -ManifestPath $backupManifest -Directory $staging
    Assert-SemanticAclManifestMatchesDirectory -ManifestPath $sourceAclManifest -Directory $staging
    Assert-NoReparsePoints -Directory $staging

    $stagingEntries = @(Get-AclManifestEntries -Lines @(Get-AclManifestLines -Directory $staging) -Context 'restore staging')
    $ownerMatches = 0
    $groupMatches = 0
    $protectionMatches = 0
    $saclPresenceMatches = 0
    for ($index = 0; $index -lt $sourceEntries.Count; $index++) {
        $expected = $sourceEntries[$index].Descriptor
        $actual = $stagingEntries[$index].Descriptor
        if ($expected.Owner.Value -ceq $actual.Owner.Value) { $ownerMatches++ }
        if ($expected.Group.Value -ceq $actual.Group.Value) { $groupMatches++ }
        $expectedProtected = ($expected.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
        $actualProtected = ($actual.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
        if ($expectedProtected -eq $actualProtected) { $protectionMatches++ }
        if (($null -ne $expected.SystemAcl) -eq ($null -ne $actual.SystemAcl)) { $saclPresenceMatches++ }
    }

    $negativeTarget = Join-Path $cLab 'negative-coverage-target'
    Invoke-RobocopyVerified -Source $coldBackup -Destination $negativeTarget
    Assert-NoReparsePoints -Directory $negativeTarget
    $beforeHash = Get-SafeAclSnapshotHash -Root $negativeTarget
    $manifestLines = @(Get-Content -LiteralPath $sourceAclManifest)
    $coverageFailures = New-Object System.Collections.Generic.List[object]

    $manifest = Join-Path $cLab 'missing.acl.txt'
    Write-Utf8Lines -Path $manifest -Lines @($manifestLines | Select-Object -SkipLast 1)
    $coverageFailures.Add((Invoke-CoverageFailureTest -Name 'missing path' -Manifest $manifest -Target $negativeTarget -BeforeHash $beforeHash))

    $manifest = Join-Path $cLab 'type.acl.txt'
    $lines = @($manifestLines)
    $lines[0] = $lines[0] -replace '^D\|', 'F|'
    Write-Utf8Lines -Path $manifest -Lines $lines
    $coverageFailures.Add((Invoke-CoverageFailureTest -Name 'type changed' -Manifest $manifest -Target $negativeTarget -BeforeHash $beforeHash))

    $manifest = Join-Path $cLab 'duplicate.acl.txt'
    $match = [regex]::Match($manifestLines[1], '^(D|F)\|([^|]+)\|(.+)$')
    $duplicate = "$($match.Groups[1].Value)|$($match.Groups[2].Value.ToUpperInvariant())|$($match.Groups[3].Value)"
    Write-Utf8Lines -Path $manifest -Lines @($manifestLines + $duplicate)
    $coverageFailures.Add((Invoke-CoverageFailureTest -Name 'case-insensitive duplicate' -Manifest $manifest -Target $negativeTarget -BeforeHash $beforeHash))

    $manifest = Join-Path $cLab 'additional.acl.txt'
    Write-Utf8Lines -Path $manifest -Lines @($manifestLines + "F|additional.txt|$($sourceEntries[0].Sddl)")
    $coverageFailures.Add((Invoke-CoverageFailureTest -Name 'additional path' -Manifest $manifest -Target $negativeTarget -BeforeHash $beforeHash))

    $pathFailures = New-Object System.Collections.Generic.List[object]
    foreach ($unsafe in @('../escape', '..\escape', 'nested/../../escape', 'nested\..\escape', '\absolute', 'C:\absolute', 'C:qualified')) {
        try {
            [void](Resolve-AclManifestPath -Root $negativeTarget -Entry ([pscustomobject]@{ Relative = $unsafe }))
            throw "Unsafe path was accepted: $unsafe"
        }
        catch {
            $message = $_.Exception.Message
        }
        $pathFailures.Add([pscustomobject]@{ Path = $unsafe; Rejected = $true; Error = $message })
    }

    $reparseTarget = Join-Path $cLab 'negative-reparse-target'
    Invoke-RobocopyVerified -Source $coldBackup -Destination $reparseTarget
    $junctionTarget = Join-Path $cLab 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $junctionTarget 'outside.txt'), 'outside', $Utf8NoBom)
    New-Item -ItemType Junction -Path (Join-Path $reparseTarget 'disposable-link') -Target $junctionTarget -ErrorAction Stop | Out-Null
    $reparseBefore = Get-SafeAclSnapshotHash -Root $reparseTarget
    try {
        Set-AclManifestOnDirectory -ManifestPath $sourceAclManifest -Directory $reparseTarget
        throw 'Reparse target was unexpectedly accepted.'
    }
    catch {
        $reparseError = $_.Exception.Message
    }
    $reparseAfter = Get-SafeAclSnapshotHash -Root $reparseTarget
    if ($reparseBefore -cne $reparseAfter) { throw 'Reparse rejection changed a target ACL.' }
    if ($reparseError -notmatch '^Reparse point found below protected tree:') { throw "The initial reparse gate did not reject the target: $reparseError" }
    try {
        [void](Resolve-AclManifestPath -Root $reparseTarget -Entry ([pscustomobject]@{ Relative = 'disposable-link/outside.txt' }))
        throw 'Junction traversal was unexpectedly accepted.'
    }
    catch {
        $resolveError = $_.Exception.Message
    }
    if ($resolveError -notmatch 'reparse point') { throw "Resolve-AclManifestPath did not reject junction traversal: $resolveError" }

    $result = [ordered]@{
        Status = 'pass'
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Source = [ordered]@{ Files = @(Get-Content -LiteralPath $sourceManifest).Count; Objects = $sourceEntries.Count; SaclPresentObjects = $saclPresentObjects; InheritedAndExplicit = 'pass' }
        ColdBackup = [ordered]@{ SourceContent = 'pass'; BackupContent = 'pass'; RawBackupAcl = 'exact pass'; SemanticAcl = 'pass'; RawDifferences = $rawDifferences; Reparse = 'pass' }
        Staging = [ordered]@{ Coverage = $coverage.Count; SourceContent = 'pass'; BackupContent = 'pass'; Owner = $ownerMatches; Group = $groupMatches; Protection = $protectionMatches; SaclPresence = $saclPresenceMatches; SemanticDacl = 'pass'; SemanticSacl = 'pass'; Inheritance = 'pass'; Reparse = 'pass' }
        CoverageFailures = $coverageFailures.ToArray()
        PathFailures = $pathFailures.ToArray()
        ReparseFailure = [ordered]@{ RejectedBeforeResolution = $true; AclUnchanged = ($reparseBefore -ceq $reparseAfter); Error = $reparseError; ResolveRejected = $true; ResolveError = $resolveError }
        Anchor = [ordered]@{ Created = 'pass'; Verified = 'pass'; Entries = $anchorLines.Count; AllFour = 'pass'; Sha256 = $anchorHash }
    }
    Save-TestResult -Value $result
    exit 0
}
catch {
    $result.Status = 'fail'
    $result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $result.Error = $_.Exception.Message
    Save-TestResult -Value $result
    exit 1
}
