#Requires -Version 5.1
<#
Exact-build experimental repair controller. No downloads, code evaluation,
security-policy changes, background services, or automatic reapplication.
Trial stays in the foreground. Keep that PowerShell window open: automatic
rollback is best effort while this process is alive, not a power-loss guarantee.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Trial', 'Keep', 'Rollback')]
    [string]$Action = 'Status',
    [Parameter(Mandatory = $true)]
    [string]$StagingDirectory,
    [switch]$Verified
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OriginalHash = '11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8'
$script:CandidateHash = '1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5'
$script:Lease = $null
$script:TrialId = $null

function Get-FileDigest([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-PlainPath([string]$Path) {
    # Reject network/device paths and symlinks/junctions in any existing ancestor.
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOf(':', 2) -ge 0) {
        throw 'Only an absolute local drive path without alternate streams is allowed.'
    }
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A reparse point occurs in a required path; no action.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Test-IsInside([string]$Child, [string]$Parent) {
    return $Child.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    Assert-PlainPath $Path
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Status([string]$Stage, [object]$Detail) {
    Write-JsonAtomic $script:StatusPath ([ordered]@{
        stage = $Stage
        time_utc = [DateTimeOffset]::UtcNow.ToString('o')
        controller_pid = $PID
        trial_id = $script:TrialId
        helper_path = $script:LivePath
        live_sha256 = Get-FileDigest $script:LivePath
        detail = $Detail
    })
}

function Get-ActiveTrialStatus {
    Assert-PlainPath $script:StatusPath
    $status = Get-Content -LiteralPath $script:StatusPath -Raw | ConvertFrom-Json
    if ($status.trial_id -notmatch '^[0-9a-f]{32}$' -or
        $status.helper_path -ne $script:LivePath -or
        $status.stage -notin @('InstallingTrial', 'TrialReady')) {
        throw 'No matching active trial was recorded in this staging directory.'
    }
    return $status
}

function Try-AcquireLease {
    Assert-PlainPath $script:LeasePath
    try {
        $script:Lease = [IO.File]::Open($script:LeasePath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        return $true
    } catch [IO.IOException] {
        return $false
    }
}

function Assert-LeaseHeldElsewhere {
    # FileMode.Open avoids creating a lease for a stale Keep request.
    Assert-PlainPath $script:LeasePath
    if (-not (Test-Path -LiteralPath $script:LeasePath -PathType Leaf)) {
        throw 'No active controller lease exists.'
    }
    $probe = $null
    try {
        $probe = [IO.File]::Open($script:LeasePath, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        return
    } finally {
        if ($null -ne $probe) { $probe.Dispose() }
    }
    throw 'The trial controller is no longer running. Keep request refused.'
}

function Send-TrialSignal([string]$Kind, [string]$Id) {
    if ($Id -notmatch '^[0-9a-f]{32}$' -or $Kind -notin @('keep', 'rollback')) {
        throw 'Invalid trial signal.'
    }
    $path = Join-Path $script:StageRoot ($Id + '.' + $Kind + '.request')
    if (Test-Path -LiteralPath $path) { throw 'That trial signal already exists.' }
    Write-JsonAtomic $path ([ordered]@{
        trial_id = $Id
        action = $Kind
        visual_capture_and_input_verified = ($Kind -eq 'keep')
    })
}

function Test-TrialSignal([string]$Kind) {
    $path = Join-Path $script:StageRoot ($script:TrialId + '.' + $Kind + '.request')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    Assert-PlainPath $path
    $signal = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($signal.trial_id -ne $script:TrialId -or $signal.action -ne $Kind) {
        throw 'Invalid signal contents; refusing acceptance.'
    }
    if ($Kind -eq 'keep' -and $signal.visual_capture_and_input_verified -ne $true) {
        throw 'Keep signal does not attest to visual capture and input verification.'
    }
    return $true
}

function Stop-ExactHelper {
    $matches = @(Get-Process -Name 'codex-computer-use' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.Equals($script:LivePath, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($helperProcess in $matches) {
        Stop-Process -Id $helperProcess.Id -Force
        if (-not $helperProcess.WaitForExit(5000)) { throw 'Matching capture helper did not stop.' }
    }
}

function Replace-CheckedFile([string]$Source, [string]$Target,
    [string]$ExpectedSource, [string]$ExpectedTarget) {
    # Also tested with inert fixture files. Both temporary and atomic backup are
    # adjacent to Target, so File.Replace never needs a cross-volume backup.
    Assert-PlainPath $Source
    Assert-PlainPath $Target
    if ((Get-FileDigest $Source) -ne $ExpectedSource) { throw 'Replacement source hash mismatch.' }
    if ((Get-FileDigest $Target) -ne $ExpectedTarget) { throw 'Target changed; refusing replacement.' }
    $suffix = [Guid]::NewGuid().ToString('N')
    $temporary = $Target + '.capture-repair-' + $suffix + '.tmp'
    $backup = $Target + '.capture-repair-' + $suffix + '.backup.bin'
    Copy-Item -LiteralPath $Source -Destination $temporary
    if ((Get-FileDigest $temporary) -ne $ExpectedSource) { throw 'Staged replacement hash mismatch.' }
    if ((Get-FileDigest $Target) -ne $ExpectedTarget) { throw 'Target changed during staging.' }
    [IO.File]::Replace($temporary, $Target, $backup, $true)
    if ((Get-FileDigest $Target) -ne $ExpectedSource) { throw 'Replacement verification failed.' }
}

function Restore-Original {
    # Restoration deliberately does not depend on candidate.bin being available.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ((Get-FileDigest $script:OriginalPath) -ne $script:OriginalHash) {
            throw 'Original backup changed; restoration refused.'
        }
        $current = Get-FileDigest $script:LivePath
        if ($current -eq $script:OriginalHash) { return }
        if ($current -ne $script:CandidateHash) { throw 'Unknown/new helper version; refusing overwrite.' }
        try {
            Stop-ExactHelper
            Replace-CheckedFile $script:OriginalPath $script:LivePath $script:OriginalHash $script:CandidateHash
            return
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Initialize-ValidatedPaths {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
    if ($Verified -and $Action -ne 'Keep') { throw '-Verified applies only to Keep.' }
    $script:StageRoot = [IO.Path]::GetFullPath($StagingDirectory).TrimEnd('\')
    Assert-PlainPath $script:StageRoot
    if (-not (Test-Path -LiteralPath $script:StageRoot -PathType Container)) { throw 'Staging directory does not exist.' }
    $manifestPath = Join-Path $script:StageRoot 'manifest.json'
    Assert-PlainPath $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.input_sha256 -ne $script:OriginalHash -or
        $manifest.candidate_sha256 -ne $script:CandidateHash -or
        $manifest.original_filename -cne 'original.bin' -or
        $manifest.candidate_filename -cne 'candidate.bin') {
        throw 'Manifest does not match the single supported exact-build profile.'
    }
    $script:LivePath = [IO.Path]::GetFullPath([string]$manifest.helper_path)
    if ($manifest.helper_path -ne $script:LivePath) { throw 'Manifest helper_path must be absolute and normalized.' }
    Assert-PlainPath $script:LivePath
    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
    if (-not (Test-IsInside $script:LivePath $runtimeRoot) -or
        $script:LivePath -notmatch '\\bin\\node_modules\\@oai\\sky\\bin\\windows\\codex-computer-use\.exe$') {
        throw 'Helper is outside the supported current-user Codex runtime location.'
    }
    if ((Test-IsInside $script:StageRoot $runtimeRoot) -or
        (Test-IsInside $script:LivePath $script:StageRoot)) {
        throw 'Staging directory must be separate from the installed runtime tree.'
    }
    $script:OriginalPath = Join-Path $script:StageRoot 'original.bin'
    $script:CandidatePath = Join-Path $script:StageRoot 'candidate.bin'
    $script:StatusPath = Join-Path $script:StageRoot 'trial-status.json'
    $script:LeasePath = $script:LivePath + '.capture-repair.lock'
    Assert-PlainPath $script:OriginalPath
    Assert-PlainPath $script:CandidatePath
    if ((Get-FileDigest $script:OriginalPath) -ne $script:OriginalHash) { throw 'Original backup hash mismatch.' }
    if ($Action -ne 'Rollback' -and (Get-FileDigest $script:CandidatePath) -ne $script:CandidateHash) {
        throw 'Candidate hash mismatch.'
    }
}

function Invoke-Repair {
    Initialize-ValidatedPaths
    if ($Action -eq 'Status') {
        [ordered]@{
            action = 'Status'
            live_sha256 = Get-FileDigest $script:LivePath
            original_backup_verified = $true
            candidate_verified = $true
            signature_status = [string](Get-AuthenticodeSignature -FilePath $script:LivePath).Status
        } | ConvertTo-Json
        return
    }
    if ($Action -eq 'Keep') {
        if (-not $Verified) { throw 'Use Keep -Verified only after actual screenshots and input visibly work.' }
        Assert-LeaseHeldElsewhere
        $status = Get-ActiveTrialStatus
        if ($status.stage -ne 'TrialReady' -or
            [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($status.detail.automatic_rollback_deadline_utc)) {
            throw 'The trial is not ready or its acceptance deadline has passed.'
        }
        if ((Get-FileDigest $script:LivePath) -ne $script:CandidateHash) { throw 'Candidate is not installed.' }
        Send-TrialSignal 'keep' $status.trial_id
        Write-Output 'Keep requested. Confirm KeptVerifiedExperimentalTrial in the trial window or trial-status.json.'
        return
    }
    if (-not (Try-AcquireLease)) {
        if ($Action -ne 'Rollback') { throw 'Another controller owns this helper; no concurrent trial is allowed.' }
        $status = Get-ActiveTrialStatus
        Send-TrialSignal 'rollback' $status.trial_id
        $waitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
        while ([DateTimeOffset]::UtcNow -lt $waitDeadline) {
            # Wait for exclusive ownership as well as the original hash. During
            # InstallingTrial an original hash alone is not a completed rollback.
            if (Try-AcquireLease) {
                try {
                    Restore-Original
                    $script:TrialId = $status.trial_id
                    Write-Status 'RolledBack' @{ signature_status = [string](Get-AuthenticodeSignature -FilePath $script:LivePath).Status }
                    Write-Output 'Original helper hash verified after rollback request.'
                    return
                } finally {
                    $script:Lease.Dispose()
                    $script:Lease = $null
                }
            }
            Start-Sleep -Milliseconds 250
        }
        throw 'Rollback request sent, but restoration is not confirmed. Check the active trial window.'
    }
    try {
        if ($Action -eq 'Rollback') {
            Restore-Original
            Write-Status 'RolledBack' @{ signature_status = [string](Get-AuthenticodeSignature -FilePath $script:LivePath).Status }
            Write-Output 'Original helper restored and hash verified.'
            return
        }
        $os = Get-CimInstance Win32_OperatingSystem
        if ([string]$os.BuildNumber -ne '19045' -or [string]$os.Caption -notmatch 'Windows 10') {
            throw 'Trial is limited to Windows 10 22H2 build 19045. Status and Rollback remain available.'
        }
        if ((Get-FileDigest $script:LivePath) -ne $script:OriginalHash) { throw 'Trial requires the unchanged original helper.' }
        $signature = Get-AuthenticodeSignature -FilePath $script:LivePath
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'OpenAI OpCo, LLC') {
            throw 'A valid OpenAI signature on the original helper is required.'
        }
        if ((Get-AuthenticodeSignature -FilePath $script:CandidatePath).Status -ne 'NotSigned') {
            throw 'Candidate signature status differs from the reviewed unsigned candidate.'
        }
        $script:TrialId = [Guid]::NewGuid().ToString('N')
        $installed = $false
        $keep = $false
        $failure = $null
        $rollbackFailure = $null
        try {
            Write-Status 'InstallingTrial' $null
            $installed = $true # finally checks actual hash even if replacement partially succeeds.
            Stop-ExactHelper
            Replace-CheckedFile $script:CandidatePath $script:LivePath $script:CandidateHash $script:OriginalHash
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(180)
            Write-Status 'TrialReady' @{ automatic_rollback_deadline_utc = $deadline.ToString('o') }
            Write-Output 'TrialReady: keep this window OPEN. Test screenshots and input through the normal app.'
            Write-Output 'Within 180 seconds, use a second PowerShell window for Keep -Verified; otherwise the original is restored.'
            while ([DateTimeOffset]::UtcNow -lt $deadline) {
                if (Test-TrialSignal 'rollback') { break }
                if (Test-TrialSignal 'keep') {
                    if ((Get-FileDigest $script:LivePath) -ne $script:CandidateHash) { throw 'Installed candidate changed before acceptance.' }
                    $keep = $true
                    break
                }
                Start-Sleep -Milliseconds 250
            }
        } catch {
            $failure = $_.Exception.Message
        } finally {
            if ($installed -and -not $keep) {
                # A status-write error must never suppress restoration.
                try { Write-Status 'RollingBack' @{ failure = $failure } } catch { }
                try {
                    Restore-Original
                    Write-Status 'RolledBack' @{ failure = $failure; signature_status = [string](Get-AuthenticodeSignature -FilePath $script:LivePath).Status }
                    Write-Output 'RolledBack: original helper hash verified.'
                } catch {
                    $rollbackFailure = $_.Exception.Message
                    try { Write-Status 'RollbackNeedsAttention' @{ failure = $rollbackFailure } } catch { }
                }
            } elseif ($keep) {
                Write-Status 'KeptVerifiedExperimentalTrial' @{ rollback = 'Run repair.ps1 -Action Rollback with this same staging directory.' }
                Write-Output 'KeptVerifiedExperimentalTrial: unsigned experimental repair retained.'
            }
        }
        if ($rollbackFailure) { throw ('ROLLBACK NEEDS ATTENTION: ' + $rollbackFailure) }
        if ($failure) { throw $failure }
    } finally {
        if ($null -ne $script:Lease) { $script:Lease.Dispose(); $script:Lease = $null }
    }
}

Invoke-Repair
