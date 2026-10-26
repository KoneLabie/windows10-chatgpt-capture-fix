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

# Extract only filesystem primitives, not controller entry points/process code.
$allowedFunctions = @('Get-FileDigest', 'Assert-PlainPath', 'Replace-CheckedFile',
    'Try-AcquireLease', 'Assert-LeaseHeldElsewhere')
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
[IO.File]::WriteAllText($manifestPath, '{"input_sha256":"unknown","candidate_sha256":"unknown","helper_path":"C:\\invalid","original_filename":"original.bin","candidate_filename":"candidate.bin"}')
$before = @(Get-ChildItem -LiteralPath $fixtureRoot -File | Select-Object -ExpandProperty Name)
Assert-Throws { & $controller -StagingDirectory $fixtureRoot -Action Status } 'Unsupported manifest should be refused.'
$after = @(Get-ChildItem -LiteralPath $fixtureRoot -File | Select-Object -ExpandProperty Name)
Assert-Test (($before -join '|') -eq ($after -join '|')) 'Refused Status created files.'

[ordered]@{
    syntax_valid = $true
    inert_atomic_replace_and_restore = $true
    atomic_backups_verified = $true
    unknown_target_and_source_refused = $true
    unsafe_paths_refused = $true
    exclusive_lease_and_stale_lease_checks = $true
    unsupported_manifest_status_read_only = $true
    fixture_directory = $fixtureRoot
    limits = 'Does not execute Trial, test live process control, full concurrent controller signals, signatures, real rollback, or capture.'
} | ConvertTo-Json
