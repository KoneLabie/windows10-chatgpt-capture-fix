#Requires -Version 5.1
<#
Manage a current-user, event-driven capture-update watcher. Install only registers
one interactive, limited-privilege logon task. There is no periodic trigger,
execution-policy override, service, elevation, or automatic helper patching.
All generated configuration and state stay outside the repository.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Install', 'Start', 'Stop', 'Uninstall')]
    [string]$Action = 'Status',
    [string]$ThreadId,
    [string]$RepositoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ManagerLease = $null
$script:OwnerTag = 'windows10-chatgpt-capture-fix/capture-update-watch/v1'

function Assert-LocalPlainPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOf(':', 2) -ge 0 -or
        $Path.IndexOfAny([char[]]@('"', "`r", "`n", [char]0)) -ge 0) {
        throw 'Expected an absolute local path without streams or command-line control characters.'
    }
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'A required path contains a reparse point; refusing the operation.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-Digest([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-QuotedArgument([string]$Value) {
    # These arguments are absolute file paths, never script expressions. Windows
    # file paths cannot contain double quotes; also reject newline/NUL input.
    if ($Value.IndexOfAny([char[]]@('"', "`r", "`n", [char]0)) -ge 0 -or $Value.EndsWith('\')) {
        throw 'Unsafe command-line argument.'
    }
    return '"' + $Value + '"'
}

function Get-WatcherArguments {
    return '-NoProfile -NonInteractive -WindowStyle Hidden -File ' +
        (Get-QuotedArgument $script:InstalledWatcher) + ' -ConfigPath ' +
        (Get-QuotedArgument $script:ConfigPath)
}

function Get-OwnershipDescription([object]$Config) {
    return $script:OwnerTag + '; installation_id=' + $Config.installation_id + '; config=' + $script:ConfigPath
}

function Write-PrivateJson([string]$Path, [object]$Value) {
    Assert-LocalPlainPath $Path
    if ([IO.Path]::GetDirectoryName($Path) -ne $script:PrivateRoot) { throw 'Write outside private watcher directory refused.' }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-OwnedConfig {
    Assert-LocalPlainPath $script:ConfigPath
    $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    $guid = [Guid]::Empty
    $threadGuid = [Guid]::Empty
    if ($config.schema_version -ne 1 -or $config.owner_tag -cne $script:OwnerTag -or
        $config.owner_sid -ne $script:UserSid -or
        -not [Guid]::TryParseExact([string]$config.installation_id, 'D', [ref]$guid) -or $guid -eq [Guid]::Empty -or
        -not [Guid]::TryParseExact([string]$config.thread_id, 'D', [ref]$threadGuid) -or $threadGuid -eq [Guid]::Empty -or
        $config.state_dir -ne $script:PrivateRoot -or $config.watcher_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $config.enabled -isnot [bool]) {
        throw 'Existing configuration is not a valid installation owned by this manager.'
    }
    Assert-LocalPlainPath ([string]$config.repository_path)
    Assert-LocalPlainPath ([string]$config.codex_executable)
    return $config
}

function Get-RegisteredTask {
    $task = @(Get-ScheduledTask -TaskPath '\' -TaskName $script:TaskName -ErrorAction SilentlyContinue)
    if ($task.Count -gt 1) { throw 'Ambiguous scheduled task identity.' }
    if ($task.Count -eq 1) { return $task[0] }
    return $null
}

function Test-CurrentUserIdentity([string]$Identifier) {
    if ([string]::IsNullOrWhiteSpace($Identifier) -or $Identifier -ne $Identifier.Trim()) { return $false }
    if ($Identifier -match '^S-\d+(?:-\d+)+$') { return $Identifier -eq $script:UserSid }
    try {
        # Task Scheduler can normalize the principal to a bare local account
        # name, while the trigger retains DOMAIN\name. Resolve both through
        # Windows and compare SIDs; a matching name alone is never sufficient.
        $account = New-Object Security.Principal.NTAccount($Identifier)
        $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
        return $sid -eq $script:UserSid
    } catch {
        return $false
    }
}

function Assert-OwnedTask([object]$Task, [object]$Config) {
    if ($null -eq $Task) { return }
    $actions = @($Task.Actions)
    $triggers = @($Task.Triggers)
    $hasRepetition = $false
    if ($triggers.Count -eq 1 -and $null -ne $triggers[0].PSObject.Properties['Repetition'] -and
        $null -ne $triggers[0].Repetition) {
        $hasRepetition = -not [string]::IsNullOrWhiteSpace([string]$triggers[0].Repetition.Interval)
    }
    if ($Task.Description -cne (Get-OwnershipDescription $Config) -or
        $actions.Count -ne 1 -or $triggers.Count -ne 1 -or $hasRepetition -or
        $actions[0].Execute -ne $script:PowerShellPath -or
        $actions[0].Arguments -cne (Get-WatcherArguments) -or
        $actions[0].WorkingDirectory -ne $script:PrivateRoot -or
        $triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' -or
        -not (Test-CurrentUserIdentity ([string]$triggers[0].UserId)) -or
        -not (Test-CurrentUserIdentity ([string]$Task.Principal.UserId)) -or
        [int]$Task.Principal.LogonType -ne 3 -or [int]$Task.Principal.RunLevel -ne 0) {
        throw 'Task collision or changed task definition; refusing to modify or start it.'
    }
}

function Assert-OwnedWatcherFile([object]$Config) {
    Assert-LocalPlainPath $script:InstalledWatcher
    if (-not (Test-Path -LiteralPath $script:InstalledWatcher -PathType Leaf) -or
        (Get-Digest $script:InstalledWatcher) -ne $Config.watcher_sha256) {
        throw 'Installed watcher source differs from its recorded hash. Inspect it before reinstalling.'
    }
}

function Test-ProcessIdentity([object]$Record, [object]$Process, [object]$Config) {
    if ($null -eq $Process -or $Record.installation_id -ne $Config.installation_id -or
        $Record.config_path -ne $script:ConfigPath -or [int]$Record.pid -le 0 -or
        [int]$Process.ProcessId -ne [int]$Record.pid -or
        $Process.ExecutablePath -ne $script:PowerShellPath) { return $false }
    $recordStart = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Record.process_start_time_utc, [ref]$recordStart)) { return $false }
    $actualStart = ([DateTime]$Process.CreationDate).ToUniversalTime()
    if ([Math]::Abs(($actualStart - $recordStart.UtcDateTime).TotalSeconds) -gt 1) { return $false }
    $executable = [regex]::Escape($script:PowerShellPath)
    $arguments = [regex]::Escape((Get-WatcherArguments))
    return ([string]$Process.CommandLine -match ('^\s*(?:"' + $executable + '"|' + $executable + ')\s+' + $arguments + '\s*$'))
}

function Get-OwnedWatcherProcess([object]$Config) {
    Assert-LocalPlainPath $script:PidPath
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) { return $null }
    $record = Get-Content -LiteralPath $script:PidPath -Raw | ConvertFrom-Json
    if ($record.installation_id -ne $Config.installation_id -or $record.config_path -ne $script:ConfigPath) {
        throw 'Watcher PID record belongs to a different installation; no process will be touched.'
    }
    $recordPid = 0
    if (-not [int]::TryParse([string]$record.pid, [ref]$recordPid) -or $recordPid -le 0) { throw 'Invalid watcher PID record.' }
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $recordPid) -ErrorAction Stop
    if ($null -eq $process) { return $null }
    if (-not (Test-ProcessIdentity $record $process $Config)) {
        # A recycled PID is not our process. Never stop it or report it running.
        return $null
    }
    return $process
}

function Resolve-VerifiedCodex {
    $command = Get-Command codex.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $path = [IO.Path]::GetFullPath($command.Source)
    Assert-LocalPlainPath $path
    $allowedRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (-not $path.StartsWith($allowedRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $path -notmatch '\\bin\\[A-Fa-f0-9]{8,64}\\codex\.exe$') {
        throw 'Existing codex.exe is outside the supported current-user OpenAI vendor directory.'
    }
    $signature = Get-AuthenticodeSignature -FilePath $path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'OpenAI OpCo, LLC') {
        throw 'The existing Codex executable does not have a valid OpenAI signature.'
    }
    return $path
}

function Assert-Repository([string]$Path) {
    Assert-LocalPlainPath $Path
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git')) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'README.md') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $Path 'scripts\repair.ps1') -PathType Leaf)) {
        throw 'RepositoryPath must be a local checkout of the capture-fix repository.'
    }
    $expectedSource = Join-Path $Path 'plugins\capture-update-watch\scripts\Watch-CaptureUpdates.ps1'
    $actualSource = Join-Path $PSScriptRoot 'Watch-CaptureUpdates.ps1'
    if ([IO.Path]::GetFullPath($expectedSource) -ne [IO.Path]::GetFullPath($actualSource)) {
        throw 'Run this manager from the same repository checkout supplied as RepositoryPath.'
    }
    Assert-LocalPlainPath $expectedSource
    if (-not (Test-Path -LiteralPath $expectedSource -PathType Leaf)) { throw 'Reviewed watcher source is missing.' }
}

function Register-OwnedLogonTask([object]$Config, [object]$ExistingTask) {
    Assert-OwnedTask $ExistingTask $Config
    $taskAction = New-ScheduledTaskAction -Execute $script:PowerShellPath -Argument (Get-WatcherArguments) -WorkingDirectory $script:PrivateRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $script:UserSid
    $principal = New-ScheduledTaskPrincipal -UserId $script:UserSid -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $definition = New-ScheduledTask -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description (Get-OwnershipDescription $Config)
    Register-ScheduledTask -TaskPath '\' -TaskName $script:TaskName -InputObject $definition -Force | Out-Null
    $registered = Get-RegisteredTask
    if ($null -eq $registered) { throw 'Task registration returned without a discoverable task.' }
    Assert-OwnedTask $registered $Config
}

function Archive-StopSignal {
    Assert-LocalPlainPath $script:StopPath
    if (Test-Path -LiteralPath $script:StopPath -PathType Leaf) {
        $archive = Join-Path $script:PrivateRoot ('stop.request.' + [Guid]::NewGuid().ToString('N') + '.archived.json')
        Move-Item -LiteralPath $script:StopPath -Destination $archive
    }
}

function Stop-OwnedWatcher([object]$Config, [object]$Task) {
    Assert-OwnedTask $Task $Config
    $Config.enabled = $false
    Write-PrivateJson $script:ConfigPath $Config
    if ($null -ne $Task) { Disable-ScheduledTask -TaskPath '\' -TaskName $script:TaskName | Out-Null }
    Write-PrivateJson $script:StopPath ([ordered]@{ installation_id = $Config.installation_id; requested_utc = [DateTimeOffset]::UtcNow.ToString('o') })
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do {
        $process = Get-OwnedWatcherProcess $Config
        if ($null -eq $process) {
            $currentTask = Get-RegisteredTask
            Assert-OwnedTask $currentTask $Config
            if ($null -eq $currentTask -or [string]$currentTask.State -ne 'Running') { return }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    # Reacquire identity immediately before termination; no broad process-name kill.
    $process = Get-OwnedWatcherProcess $Config
    if ($null -ne $process) {
        $processId = [int]$process.ProcessId
        $owned = Get-Process -Id $processId -ErrorAction Stop
        if ([Math]::Abs(($owned.StartTime.ToUniversalTime() - ([DateTime]$process.CreationDate).ToUniversalTime()).TotalSeconds) -gt 1 -or
            $owned.Path -ne $script:PowerShellPath) { throw 'Process identity changed during stop; termination refused.' }
        Stop-Process -InputObject $owned -Force
        if (-not $owned.WaitForExit(5000)) { throw 'Owned watcher did not stop.' }
    }
    # A task can still be starting before a PID record exists. Its definition was
    # checked against our exact action, user, and installation marker above.
    $currentTask = Get-RegisteredTask
    Assert-OwnedTask $currentTask $Config
    if ($null -ne $currentTask -and [string]$currentTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskPath '\' -TaskName $script:TaskName
        $stopDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        do {
            $currentTask = Get-RegisteredTask
            Assert-OwnedTask $currentTask $Config
            if ($null -eq $currentTask -or [string]$currentTask.State -ne 'Running') { return }
            Start-Sleep -Milliseconds 250
        } while ([DateTimeOffset]::UtcNow -lt $stopDeadline)
        throw 'Owned task stop was requested, but completion was not confirmed.'
    }
}

function Initialize-Manager {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Run this manager with built-in Windows PowerShell 5.1 (powershell.exe), not pwsh. No policy override is needed or supplied.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:UserSid = $identity.User.Value
    $script:UserName = $identity.Name
    $script:PrivateRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\CaptureUpdateWatch'))
    $script:ConfigPath = Join-Path $script:PrivateRoot 'config.json'
    $script:InstalledWatcher = Join-Path $script:PrivateRoot 'Watch-CaptureUpdates.ps1'
    $script:PidPath = Join-Path $script:PrivateRoot 'watcher.pid.json'
    $script:StopPath = Join-Path $script:PrivateRoot 'stop.request.json'
    $script:PowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:TaskName = 'Codex Capture Update Watch - ' + $script:UserSid
    Assert-LocalPlainPath $script:PrivateRoot
    Assert-LocalPlainPath $script:PowerShellPath
    if ($Action -ne 'Install' -and ($ThreadId -or $RepositoryPath)) { throw 'ThreadId and RepositoryPath apply only to Install.' }
    Get-Command Get-ScheduledTask, Register-ScheduledTask, Start-ScheduledTask -ErrorAction Stop | Out-Null
}

function Invoke-Manager {
    Initialize-Manager
    $task = Get-RegisteredTask
    $exists = Test-Path -LiteralPath $script:ConfigPath -PathType Leaf
    if ($Action -eq 'Status') {
        if (-not $exists) {
            [ordered]@{ installed = $false; task_collision = ($null -ne $task); state_dir = $script:PrivateRoot } | ConvertTo-Json
            return
        }
        $config = Read-OwnedConfig
        Assert-OwnedTask $task $config
        $process = Get-OwnedWatcherProcess $config
        $watcherHashMatches = (Test-Path -LiteralPath $script:InstalledWatcher -PathType Leaf) -and ((Get-Digest $script:InstalledWatcher) -eq $config.watcher_sha256)
        [ordered]@{
            installed = ($null -ne $task)
            enabled = $config.enabled
            task_name = $script:TaskName
            task_state = $(if ($null -ne $task) { [string]$task.State } else { 'Absent' })
            watcher_running = ($null -ne $process)
            watcher_pid = $(if ($null -ne $process) { [int]$process.ProcessId } else { $null })
            watcher_hash_matches = $watcherHashMatches
            codex_executable_exists = (Test-Path -LiteralPath $config.codex_executable -PathType Leaf)
            thread_id = $config.thread_id
            state_dir = $script:PrivateRoot
        } | ConvertTo-Json
        return
    }
    if ($Action -eq 'Install') {
        $threadGuid = [Guid]::Empty
        if (-not [Guid]::TryParseExact($ThreadId, 'D', [ref]$threadGuid) -or $threadGuid -eq [Guid]::Empty -or -not $RepositoryPath) {
            throw 'Install requires an explicit nonempty thread UUID and RepositoryPath.'
        }
        $repository = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\')
        Assert-Repository $repository
        $codex = Resolve-VerifiedCodex
        if (-not $exists) {
            if ($null -ne $task) { throw 'A task with the reserved name already exists without an owned configuration.' }
            if ((Test-Path -LiteralPath $script:PrivateRoot) -and @(Get-ChildItem -LiteralPath $script:PrivateRoot -Force).Count -gt 0) {
                throw 'Private directory contains unrecognized data; refusing to take ownership.'
            }
            [IO.Directory]::CreateDirectory($script:PrivateRoot) | Out-Null
        }
    } elseif (-not $exists) {
        throw 'No owned installation exists. No task or process was changed.'
    }
    $leasePath = Join-Path $script:PrivateRoot 'manager.lock'
    Assert-LocalPlainPath $leasePath
    try {
        $script:ManagerLease = [IO.File]::Open($leasePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw 'Another manager is active; no concurrent management is allowed.' }
    try {
        # Re-read ownership after taking the lease.
        $task = Get-RegisteredTask
        if ($exists) {
            $config = Read-OwnedConfig
            Assert-OwnedTask $task $config
        } else {
            if ($null -ne $task -or (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Installation state changed concurrently.' }
            $config = [pscustomobject][ordered]@{
                schema_version = 1
                owner_tag = $script:OwnerTag
                owner_sid = $script:UserSid
                installation_id = [Guid]::NewGuid().ToString('D')
                thread_id = $threadGuid.ToString('D')
                repository_path = $repository
                codex_executable = $codex
                state_dir = $script:PrivateRoot
                enabled = $true
                watcher_sha256 = ''
            }
        }
        if ($Action -eq 'Install') {
            if ($exists -and ($config.thread_id -ne $threadGuid.ToString('D') -or $config.repository_path -ne $repository)) {
                throw 'Existing installation targets a different chat or checkout; refusing to overwrite it.'
            }
            if ($exists) {
                Assert-OwnedWatcherFile $config
                if ($null -ne (Get-OwnedWatcherProcess $config) -or
                    ($null -ne $task -and [string]$task.State -eq 'Running')) {
                    throw 'Stop the owned watcher before reinstalling or updating its source.'
                }
            }
            $source = Join-Path $PSScriptRoot 'Watch-CaptureUpdates.ps1'
            $sourceDigest = Get-Digest $source
            $temporary = Join-Path $script:PrivateRoot ('watcher.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Item -LiteralPath $source -Destination $temporary
            if ((Get-Digest $temporary) -ne $sourceDigest) { throw 'Watcher copy hash differs.' }
            Move-Item -LiteralPath $temporary -Destination $script:InstalledWatcher -Force
            $config.watcher_sha256 = $sourceDigest
            $config.codex_executable = $codex
            $config.enabled = $true
            Write-PrivateJson $script:ConfigPath $config
            Archive-StopSignal
            Register-OwnedLogonTask $config $task
            Write-Output 'Installed one current-user logon task. No watcher was started; use -Action Start.'
            return
        }
        if ($Action -eq 'Start') {
            if ($null -eq $task) { throw 'Owned logon task is absent; run Install first.' }
            Assert-OwnedWatcherFile $config
            if ($null -ne (Get-OwnedWatcherProcess $config)) { Write-Output 'Owned watcher is already running.'; return }
            $config.codex_executable = Resolve-VerifiedCodex
            $config.enabled = $true
            Write-PrivateJson $script:ConfigPath $config
            Archive-StopSignal
            Enable-ScheduledTask -TaskPath '\' -TaskName $script:TaskName | Out-Null
            Start-ScheduledTask -TaskPath '\' -TaskName $script:TaskName
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            do {
                $process = Get-OwnedWatcherProcess $config
                if ($null -ne $process) { Write-Output ('Owned watcher running: PID ' + $process.ProcessId); return }
                Start-Sleep -Milliseconds 250
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            throw 'Task start was requested, but an owned watcher process was not confirmed. Inspect private watcher diagnostics; do not weaken execution policy.'
        }
        Stop-OwnedWatcher $config $task
        if ($Action -eq 'Uninstall') {
            $task = Get-RegisteredTask
            Assert-OwnedTask $task $config
            if ($null -ne $task) { Unregister-ScheduledTask -TaskPath '\' -TaskName $script:TaskName -Confirm:$false }
            Write-Output 'Owned logon task removed and watcher stopped. Private source, config, and state were retained disabled.'
        } else {
            Write-Output 'Owned watcher stopped and logon task disabled. Use Start to enable it again.'
        }
    } finally {
        if ($null -ne $script:ManagerLease) { $script:ManagerLease.Dispose(); $script:ManagerLease = $null }
    }
}

Invoke-Manager
