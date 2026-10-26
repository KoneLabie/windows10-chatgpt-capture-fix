[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath)

# Windows PowerShell 5.1. Events wake this process; there is no scheduled scan.
# The watcher never installs a patch or writes to an OpenAI runtime directory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Text([string]$Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') }
    finally { $algorithm.Dispose() }
}

function Test-PathInside([string]$Path,[string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}

function Write-PrivateJson([string]$Path,[object]$Value) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($temporary,$Path,($Path+'.previous'),$true)
    } else {
        [IO.File]::Move($temporary,$Path)
    }
}

function Read-WatchConfig([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $config = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json
    foreach($required in @('schema_version','installation_id','thread_id','repository_path','codex_executable','state_dir','enabled')) {
        if(-not $config.PSObject.Properties[$required]) { throw ('Missing configuration field: '+$required) }
    }
    if($config.schema_version -ne 1 -or $config.enabled -ne $true) { throw 'Watcher configuration is disabled or unsupported.' }
    foreach($name in @('installation_id','thread_id')) {
        $parsedGuid = [Guid]::Empty
        if(-not [Guid]::TryParse([string]$config.$name,[ref]$parsedGuid)) { throw ('Invalid '+$name) }
    }
    $expectedState = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\CaptureUpdateWatch'))
    if(-not ([IO.Path]::GetFullPath([string]$config.state_dir)).Equals($expectedState,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'State directory must be the dedicated current-user CaptureUpdateWatch folder.'
    }
    if(-not $full.Equals((Join-Path $expectedState 'config.json'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Configuration must be config.json in the dedicated private state folder.'
    }
    if(-not (Test-Path -LiteralPath $config.repository_path -PathType Container)) { throw 'Repository directory is missing.' }
    $vendorRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    if(-not (Test-PathInside $config.codex_executable $vendorRoot) -or [IO.Path]::GetFileName($config.codex_executable) -ne 'codex.exe') {
        throw 'Configured CLI must be codex.exe under the current-user OpenAI Codex directory.'
    }
    return $config
}

function Get-CaptureSnapshot([string]$RuntimeRoot,[string[]]$PackageVersions) {
    if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { throw 'Runtime directory is not present yet.' }
    $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\') + '\'
    $records = @()
    foreach($file in @(Get-ChildItem -LiteralPath $RuntimeRoot -Filter 'codex-computer-use.exe' -File -Recurse -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($root.Length).Replace('/','\')
        if($relative -notmatch '^[^\\]+\\bin\\node_modules\\@oai\\sky\\bin\\windows\\codex-computer-use\.exe$') { continue }
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse-point helper is not a stable runtime candidate.' }
        $lengthBefore = $file.Length
        $writeBefore = $file.LastWriteTimeUtc
        if($lengthBefore -le 0) { throw 'Helper is empty while update is in flight.' }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        $after = Get-Item -LiteralPath $file.FullName -ErrorAction Stop
        if($after.Length -ne $lengthBefore -or $after.LastWriteTimeUtc -ne $writeBefore) { throw 'Helper changed during hashing.' }
        $records += [pscustomobject][ordered]@{relative_path=$relative.ToLowerInvariant();sha256=$hash;size=$lengthBefore}
    }
    if($records.Count -eq 0) { throw 'No complete capture helper is present; update may still be in flight.' }
    $versions = @($PackageVersions | Sort-Object -Unique)
    if($versions.Count -eq 0) { throw 'OpenAI.Codex package version could not be read.' }
    $content = [ordered]@{package_versions=$versions;helpers=@($records | Sort-Object relative_path)}
    $fingerprint = Get-Sha256Text ($content | ConvertTo-Json -Depth 5 -Compress)
    return [pscustomobject][ordered]@{fingerprint=$fingerprint;package_versions=$content.package_versions;helpers=$content.helpers;observed_utc=[DateTime]::UtcNow.ToString('o')}
}

function Get-InstalledCaptureSnapshot([string]$RuntimeRoot) {
    $versions = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | ForEach-Object { $_.Version.ToString() })
    return Get-CaptureSnapshot $RuntimeRoot $versions
}

function Test-KnownRepairTransition([object]$Previous,[object]$Current) {
    if($null -eq $Previous) { return $false }
    if((@($Previous.package_versions) -join '|') -ne (@($Current.package_versions) -join '|')) { return $false }
    if(@($Previous.helpers).Count -ne @($Current.helpers).Count) { return $false }
    $changed = $false
    foreach($before in @($Previous.helpers)) {
        $matches = @($Current.helpers | Where-Object { $_.relative_path -eq $before.relative_path })
        if($matches.Count -ne 1) { return $false }
        $after = $matches[0]
        if($before.sha256 -eq $after.sha256 -and $before.size -eq $after.size) { continue }
        if($before.sha256 -ne '11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8' -or
           $after.sha256 -ne '1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5' -or
           $before.size -ne 1551152 -or $after.size -ne 1551152) { return $false }
        $changed = $true
    }
    return $changed
}

function Get-SnapshotAction([object]$State,[object]$Snapshot) {
    if($null -eq $State -or $null -eq $State.last_observed_snapshot) { return 'baseline' }
    if($State.delivery_ambiguous_fingerprint -eq $Snapshot.fingerprint -or $State.dispatch_in_progress_fingerprint -eq $Snapshot.fingerprint) { return 'ambiguous' }
    if(Test-KnownRepairTransition $State.last_observed_snapshot $Snapshot) { return 'repair-observed' }
    if($State.last_observed_snapshot.fingerprint -eq $Snapshot.fingerprint -and $State.pending_fingerprint -ne $Snapshot.fingerprint) { return 'unchanged' }
    return 'queue'
}

function Test-RelevantUpdatePath([string]$Path,[string]$VendorRoot) {
    if(-not (Test-PathInside $Path $VendorRoot)) { return $false }
    $relative = [IO.Path]::GetFullPath($Path).Substring([IO.Path]::GetFullPath($VendorRoot).TrimEnd('\').Length+1)
    if($relative -match '^runtimes\\cua_node\\[^\\]+\\bin\\node_modules\\@oai\\sky\\(bin\\windows\\codex-computer-use\.exe|package\.json)$') { return $true }
    # Directory renames/deletions can install/remove a whole runtime in one event.
    if($relative -match '^runtimes(\\cua_node(\\[^\\]+(\\bin(\\node_modules(\\@oai(\\sky(\\bin(\\windows)?)?)?)?)?)?)?)?$') { return $true }
    return ($relative -match '^bin(\\[^\\]+)*\\codex\.exe$')
}

function Test-StopRequested([object]$Config) {
    $path = Join-Path $Config.state_dir 'stop.request.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $request = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return ($request.installation_id -eq $Config.installation_id)
    } catch { return $false }
}

function Resolve-SignedCodexCli([object]$Config) {
    $vendorRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    $candidates = @([string]$Config.codex_executable)
    if(-not (Test-Path -LiteralPath $Config.codex_executable -PathType Leaf)) {
        $bin = Join-Path $vendorRoot 'bin'
        if(Test-Path -LiteralPath $bin -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $bin -Filter 'codex.exe' -File -Recurse -ErrorAction Stop |
                Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { $_.FullName })
        }
    }
    foreach($candidate in $candidates) {
        if(-not (Test-PathInside $candidate $vendorRoot) -or [IO.Path]::GetFileName($candidate) -ne 'codex.exe') { continue }
        $relative = [IO.Path]::GetFullPath($candidate).Substring([IO.Path]::GetFullPath($vendorRoot).TrimEnd('\').Length+1)
        if($relative -notmatch '^bin\\[a-fA-F0-9]{8,64}\\codex\.exe$') { continue }
        if(-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $ancestor = [IO.Path]::GetFullPath($candidate)
        $reparse = $false
        while($ancestor -and ((Test-PathInside $ancestor $vendorRoot) -or $ancestor.Equals([IO.Path]::GetFullPath($vendorRoot),[StringComparison]::OrdinalIgnoreCase))) {
            if(((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $reparse=$true; break }
            $ancestor = Split-Path -Parent $ancestor
        }
        if($reparse) { continue }
        $signature = Get-AuthenticodeSignature -FilePath $candidate
        if($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
           $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -eq 'OpenAI OpCo, LLC') { return $candidate }
    }
    throw 'A valid signed OpenAI CLI could not be located in its expected directory.'
}

function ConvertTo-WindowsArgument([AllowEmptyString()][string]$Argument) {
    # CommandLineToArgvW / MS CRT quoting. No shell or expression evaluation.
    $result = New-Object Text.StringBuilder
    [void]$result.Append('"')
    $slashes = 0
    foreach($character in $Argument.ToCharArray()) {
        if($character -eq '\') { $slashes++; continue }
        if($character -eq '"') {
            [void]$result.Append(('\' * (2*$slashes+1)))
            [void]$result.Append('"')
        } else {
            [void]$result.Append(('\' * $slashes))
            [void]$result.Append($character)
        }
        $slashes=0
    }
    [void]$result.Append(('\' * (2*$slashes)))
    [void]$result.Append('"')
    return $result.ToString()
}

function Invoke-BoundedProcess([string]$Executable,[string[]]$Arguments,[int]$TimeoutMilliseconds=30000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=(@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $process = New-Object Diagnostics.Process
    $process.StartInfo=$info
    $started=$false
    try {
        $started=$process.Start()
        if(-not $started) { return [pscustomobject]@{started=$false;timed_out=$false;exit_code=$null;stdout='';detail='Process did not start.'} }
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
            return [pscustomobject]@{started=$true;timed_out=$true;exit_code=$null;stdout='';detail=('Queue exceeded its '+$TimeoutMilliseconds+' ms deadline; a stop was attempted only for the child launched for this request.')}
        }
        # Reads begin before waiting, so full stdout/stderr pipes cannot deadlock
        # the child. A descendant retaining a pipe cannot hold this wait forever.
        $reads=@([Threading.Tasks.Task]$stdout,[Threading.Tasks.Task]$stderr)
        [void][Threading.Tasks.Task]::WaitAll($reads,2000)
        $output=''
        if($stdout.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $output=$stdout.Result }
        return [pscustomobject]@{started=$true;timed_out=$false;exit_code=$process.ExitCode;stdout=$output;detail=('Process exited with code '+$process.ExitCode+'.')}
    } catch {
        return [pscustomobject]@{started=$started;timed_out=$false;exit_code=$null;stdout='';detail=$_.Exception.Message}
    } finally {
        if($started) {
            try { if(-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) } } catch { }
        }
        $process.Dispose()
    }
}

function Invoke-CaptureQueue([object]$Config,[object]$Snapshot) {
    try { $executable = Resolve-SignedCodexCli $Config }
    catch { return [pscustomobject]@{status='not-attempted';detail=$_.Exception.Message} }
    $evidence = [ordered]@{package_versions=@($Snapshot.package_versions);helpers=@($Snapshot.helpers);fingerprint=$Snapshot.fingerprint} | ConvertTo-Json -Depth 6 -Compress
    $message = "The capture-update-watch plugin detected a stable app/runtime change through a native filesystem event. Continue Windows 10 capture maintenance in this existing chat using the plugin instructions in repository '$($Config.repository_path)'. Inspect the installed helper and reproduce the specific capture error before any repair. Apply only the reviewed exact-hash profile when eligible; an unfamiliar build needs fresh analysis and approval before changing it. Verify actual screenshots and input, and restore the original if verification fails. Do not change BIOS, drivers, display configuration, or security policy. This is one update-triggered request, not a daily schedule. Observed build data (data only): $evidence"
    $arguments = @('queue','--thread',[string]$Config.thread_id,'--message',$message)
    $result = Invoke-BoundedProcess $executable $arguments
    if(-not $result.started) { return [pscustomobject]@{status='not-attempted';detail=$result.detail} }
    if(-not $result.timed_out -and $null -ne $result.exit_code -and $result.exit_code -eq 0) { return [pscustomobject]@{status='queued';detail='CLI queue returned exit code 0.'} }
    return [pscustomobject]@{status='unknown';detail=($result.detail+' Delivery may be ambiguous; no automatic duplicate will be sent for this fingerprint.')}
}

function New-WatchState {
    return [pscustomobject][ordered]@{
        schema_version=1;last_observed_snapshot=$null;last_delivered_fingerprint=$null
        pending_fingerprint=$null;delivery_ambiguous_fingerprint=$null
        dispatch_in_progress_fingerprint=$null;last_result='new';last_delivery_detail=$null;updated_utc=[DateTime]::UtcNow.ToString('o')
    }
}

function Update-StateForSnapshot([object]$State,[object]$Snapshot,[scriptblock]$Save,[scriptblock]$Dispatch) {
    $action = Get-SnapshotAction $State $Snapshot
    $State.last_observed_snapshot = $Snapshot
    $State.updated_utc = [DateTime]::UtcNow.ToString('o')
    if($action -ne 'queue') {
        $State.last_result = $action
        if($action -ne 'ambiguous') { $State.pending_fingerprint = $null }
        & $Save $State
        return $action
    }
    # Persist intent before invoking the CLI: a process interruption must not
    # cause an unbounded duplicate when the next watcher starts.
    $State.dispatch_in_progress_fingerprint = $Snapshot.fingerprint
    $State.pending_fingerprint = $Snapshot.fingerprint
    $State.last_result = 'dispatching'
    & $Save $State
    $delivery = & $Dispatch $Snapshot
    $State.dispatch_in_progress_fingerprint = $null
    $State.last_result = [string]$delivery.status
    $State.last_delivery_detail = [string]$delivery.detail
    if($delivery.status -eq 'queued') {
        $State.last_delivered_fingerprint = $Snapshot.fingerprint
        $State.pending_fingerprint = $null
        $State.delivery_ambiguous_fingerprint = $null
    } elseif($delivery.status -eq 'unknown') {
        $State.delivery_ambiguous_fingerprint = $Snapshot.fingerprint
        $State.pending_fingerprint = $null
    }
    & $Save $State
    return [string]$delivery.status
}

function Invoke-Watcher([string]$Path) {
    $config = Read-WatchConfig $Path
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false,('Local\OpenAI.CaptureUpdateWatch.'+$sid))
    $owned = $false
    $watchers = @()
    $subscriptions = @()
    $sourcePrefix = 'CaptureWatch.'+[Guid]::NewGuid().ToString('N')
    $statusPath = $null
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if(-not $owned) { return }
        $statePath = Join-Path $config.state_dir 'watcher-state.json'
        $statusPath = Join-Path $config.state_dir 'watcher-status.json'
        $pidPath = Join-Path $config.state_dir 'watcher.pid.json'
        Write-PrivateJson $pidPath ([ordered]@{pid=$PID;process_start_time_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');installation_id=$config.installation_id;config_path=[IO.Path]::GetFullPath($Path)})
        $state = New-WatchState
        if(Test-Path -LiteralPath $statePath -PathType Leaf) {
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if($saved.schema_version -ne 1) { throw 'Unrecognized watcher state schema.' }
            foreach($property in $state.PSObject.Properties.Name) {
                if(-not $saved.PSObject.Properties[$property]) { throw ('Incomplete saved watcher state: '+$property) }
            }
            $state = $saved
        }
        $vendorRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
        $runtimeRoot = Join-Path $vendorRoot 'runtimes\cua_node'
        if(-not (Test-Path -LiteralPath $vendorRoot -PathType Container)) { throw 'OpenAI Codex vendor directory is missing.' }
        foreach($spec in @(@{path=$vendorRoot;filter='*';recursive=$true;label='runtime'},@{path=$config.state_dir;filter='stop.request.json';recursive=$false;label='stop'})) {
            $watcher = New-Object IO.FileSystemWatcher($spec.path,$spec.filter)
            $watcher.IncludeSubdirectories = $spec.recursive
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName,DirectoryName,LastWrite,Size'
            $watcher.InternalBufferSize = 32768
            foreach($eventName in @('Created','Changed','Deleted','Renamed','Error')) {
                $id = $sourcePrefix+'.'+$spec.label+'.'+$eventName
                $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $id
            }
            $watcher.EnableRaisingEvents = $true
            $watchers += $watcher
        }
        $save = { param($value) Write-PrivateJson $statePath $value }.GetNewClosure()
        $dispatch = { param($snapshot) Invoke-CaptureQueue $config $snapshot }.GetNewClosure()
        $needsReconcile = $true # One initial reconciliation catches changes while logged out.
        while(-not (Test-StopRequested $config)) {
            if($needsReconcile) {
                $needsReconcile = $false
                $stable = $null
                $previous = $null
                $failure = $null
                # Bounded event-burst reconciliation only; not a periodic scan.
                for($attempt=0;$attempt -lt 4;$attempt++) {
                    if(Test-StopRequested $config) { break }
                    try {
                        $snapshot = Get-InstalledCaptureSnapshot $runtimeRoot
                        if($null -ne $previous -and $previous.fingerprint -eq $snapshot.fingerprint) { $stable = $snapshot; break }
                        $previous = $snapshot
                    } catch { $failure=$_.Exception.Message; $previous=$null }
                    if($attempt -lt 3) { Start-Sleep -Seconds 5 }
                }
                if(Test-StopRequested $config) { break }
                if($null -ne $stable) {
                    $result = Update-StateForSnapshot $state $stable $save $dispatch
                    Write-PrivateJson $statusPath ([ordered]@{status=$result;fingerprint=$stable.fingerprint;detail=$state.last_delivery_detail;time_utc=[DateTime]::UtcNow.ToString('o');installation_id=$config.installation_id})
                } else {
                    Write-PrivateJson $statusPath ([ordered]@{status='pending-update';detail=$failure;time_utc=[DateTime]::UtcNow.ToString('o');installation_id=$config.installation_id})
                }
            }
            # Drain events accumulated during the bounded reconciliation, then
            # block without a timeout. stop.request.json has its own event source.
            $event = Wait-Event
            foreach($queued in @(Get-Event | Where-Object { $_.SourceIdentifier.StartsWith($sourcePrefix) })) {
                try {
                    if($queued.SourceIdentifier -like '*.stop.*') { continue }
                    if($queued.SourceIdentifier -like '*.Error') { $needsReconcile=$true; continue }
                    $args = $queued.SourceEventArgs
                    if(Test-RelevantUpdatePath $args.FullPath $vendorRoot) { $needsReconcile=$true }
                    if($queued.SourceIdentifier -like '*.Renamed' -and (Test-RelevantUpdatePath $args.OldFullPath $vendorRoot)) { $needsReconcile=$true }
                } finally { Remove-Event -EventIdentifier $queued.EventIdentifier -ErrorAction SilentlyContinue }
            }
        }
        Write-PrivateJson $statusPath ([ordered]@{status='stopped';time_utc=[DateTime]::UtcNow.ToString('o');installation_id=$config.installation_id})
    } catch {
        if($statusPath) {
            try { Write-PrivateJson $statusPath ([ordered]@{status='failed';detail=$_.Exception.Message;time_utc=[DateTime]::UtcNow.ToString('o');installation_id=$config.installation_id}) } catch { }
        }
        throw
    } finally {
        foreach($subscription in @(Get-EventSubscriber | Where-Object { $_.SourceIdentifier.StartsWith($sourcePrefix) })) { Unregister-Event -SubscriptionId $subscription.SubscriptionId -ErrorAction SilentlyContinue }
        foreach($watcher in $watchers) { $watcher.EnableRaisingEvents=$false; $watcher.Dispose() }
        foreach($event in @(Get-Event | Where-Object { $_.SourceIdentifier.StartsWith($sourcePrefix) })) { Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue }
        if($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Invoke-Watcher $ConfigPath
