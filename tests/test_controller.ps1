#Requires -Version 5.1
<# Tests syntax and atomic replacement/refusal on inert files only.
   Never runs Trial, stops a helper, installs a candidate, or loads a PE image.
   Test fixtures remain in the printed temporary directory for inspection. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$controller = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\repair.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Extract profile selection and filesystem primitives, not controller entry points/process code.
$allowedFunctions = @('Get-FileDigest', 'Assert-PlainPath', 'Replace-CheckedFile',
    'Try-AcquireLease', 'Assert-LeaseHeldElsewhere', 'Get-ExactProfile')
foreach ($name in $allowedFunctions) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $node) { throw ('Missing function: ' + $name) }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    Assert-Test $failed $Message
}

$profilePairs = @(
    @('11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8', '1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5'),
    @('49C7F43DA0C2A9DBCADFB0C993058147018BF7C1D0FDE4360DE11ACE2C98F45D', '25A8CD31B5BC44C387CBF53EC3FE4CD314B5FCAC0D8D84201F444F1B2DB10FAB')
)
foreach ($pair in $profilePairs) {
    $selected = Get-ExactProfile $pair[0] $pair[1]
    Assert-Test ($selected.OriginalHash -eq $pair[0] -and $selected.CandidateHash -eq $pair[1]) 'Exact pair selection failed.'
    Assert-Throws { Get-ExactProfile $pair[1] $pair[0] } 'Patched hash must not be accepted as an original.'
}
Assert-Throws { Get-ExactProfile $profilePairs[0][0] $profilePairs[1][1] } 'Old original/new candidate cross-pair was accepted.'
Assert-Throws { Get-ExactProfile $profilePairs[1][0] $profilePairs[0][1] } 'New original/old candidate cross-pair was accepted.'
Assert-Throws { Get-ExactProfile 'unknown' $profilePairs[0][1] } 'Unknown original was accepted.'
Assert-Throws { Get-ExactProfile $profilePairs[0][0] 'unknown' } 'Unknown candidate was accepted.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('capture-repair-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$fixtureOriginal = Join-Path $fixtureRoot 'original.bin'
$fixtureCandidate = Join-Path $fixtureRoot 'candidate.bin'
$fixtureTarget = Join-Path $fixtureRoot 'target.bin'
[IO.File]::WriteAllBytes($fixtureOriginal, [Text.Encoding]::UTF8.GetBytes('INERT ORIGINAL - no executable code'))
[IO.File]::WriteAllBytes($fixtureCandidate, [Text.Encoding]::UTF8.GetBytes('INERT CANDIDATE - no executable code'))
Copy-Item -LiteralPath $fixtureOriginal -Destination $fixtureTarget
$originalDigest = Get-FileDigest $fixtureOriginal
$candidateDigest = Get-FileDigest $fixtureCandidate

Replace-CheckedFile $fixtureCandidate $fixtureTarget $candidateDigest $originalDigest
Assert-Test ((Get-FileDigest $fixtureTarget) -eq $candidateDigest) 'Candidate replacement failed.'
Replace-CheckedFile $fixtureOriginal $fixtureTarget $originalDigest $candidateDigest
Assert-Test ((Get-FileDigest $fixtureTarget) -eq $originalDigest) 'Restoration failed.'
$backups = @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.backup.bin' -File)
Assert-Test ($backups.Count -eq 2) 'Expected two retained atomic backups.'
$backupDigests = @($backups | ForEach-Object { Get-FileDigest $_.FullName })
Assert-Test ($backupDigests -contains $originalDigest -and $backupDigests -contains $candidateDigest) 'Atomic backup contents differ.'

Assert-Throws { Replace-CheckedFile $fixtureCandidate $fixtureTarget $candidateDigest $candidateDigest } 'Unknown target should be refused.'
Assert-Test ((Get-FileDigest $fixtureTarget) -eq $originalDigest) 'Refusal changed the target.'
Assert-Throws { Replace-CheckedFile $fixtureCandidate $fixtureTarget $originalDigest $originalDigest } 'Wrong source hash should be refused.'
Assert-Test ((Get-FileDigest $fixtureTarget) -eq $originalDigest) 'Source refusal changed the target.'
Assert-Throws { Assert-PlainPath '\\server\share\helper.exe' } 'Network path should be refused.'
Assert-Throws { Assert-PlainPath ($fixtureTarget + ':stream') } 'Alternate stream should be refused.'
Assert-Throws { Assert-PlainPath '.\relative.bin' } 'Relative path should be refused.'

# The per-helper lease must block another controller until its owner releases it.
$script:LeasePath = Join-Path $fixtureRoot 'inert-helper.lock'
$script:Lease = $null
Assert-Throws { Assert-LeaseHeldElsewhere } 'Missing active lease should be refused.'
Assert-Test (-not (Test-Path -LiteralPath $script:LeasePath)) 'Lease probe created a file.'
Assert-Test (Try-AcquireLease) 'First lease acquisition failed.'
try {
    Assert-Test (-not (Try-AcquireLease)) 'Concurrent lease acquisition was allowed.'
    Assert-LeaseHeldElsewhere
} finally {
    if ($null -ne $script:Lease) { $script:Lease.Dispose(); $script:Lease = $null }
}
Assert-Throws { Assert-LeaseHeldElsewhere } 'Stale unlocked lease should be refused.'
Assert-Test (Try-AcquireLease) 'Lease could not be reacquired after release.'
$script:Lease.Dispose()
$script:Lease = $null

$manifestPath = Join-Path $fixtureRoot 'manifest.json'
$rejectedPairs = @(
    @('unknown', 'unknown'),
    @($profilePairs[0][0], $profilePairs[1][1]),
    @($profilePairs[1][0], $profilePairs[0][1])
)
foreach ($pair in $rejectedPairs) {
    $badManifest = @{ input_sha256 = $pair[0]; candidate_sha256 = $pair[1]; helper_path = 'C:\invalid'; original_filename = 'original.bin'; candidate_filename = 'candidate.bin' }
    [IO.File]::WriteAllText($manifestPath, ($badManifest | ConvertTo-Json))
    $before = @(Get-ChildItem -LiteralPath $fixtureRoot -File | Select-Object -ExpandProperty Name)
    Assert-Throws { & $controller -StagingDirectory $fixtureRoot -Action Status } 'Unsupported or cross-pair manifest should be refused.'
    $after = @(Get-ChildItem -LiteralPath $fixtureRoot -File | Select-Object -ExpandProperty Name)
    Assert-Test (($before -join '|') -eq ($after -join '|')) 'Refused Status created files.'
}

[ordered]@{
    syntax_valid = $true
    both_exact_profiles_and_cross_pair_refusal = $true
    inert_atomic_replace_and_restore = $true
    atomic_backups_verified = $true
    unknown_target_and_source_refused = $true
    unsafe_paths_refused = $true
    exclusive_lease_and_stale_lease_checks = $true
    unsupported_manifest_status_read_only = $true
    fixture_directory = $fixtureRoot
    limits = 'Does not execute Trial, test live process control, full concurrent controller signals, signatures, real rollback, or capture.'
} | ConvertTo-Json
