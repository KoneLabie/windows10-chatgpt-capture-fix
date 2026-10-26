#Requires -Version 5.1
<# Inert tests only: no task registration, process launch/termination, installation,
   or Codex execution. Windows account-name resolution is read-only and may use
   the configured account authority. Temporary fixture files are retained. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manager = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Manage-CaptureWatch.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($manager, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$safeFunctions = @('Assert-LocalPlainPath', 'Get-QuotedArgument', 'Get-WatcherArguments',
    'Get-OwnershipDescription', 'Test-CurrentUserIdentity', 'Assert-OwnedTask', 'Test-ProcessIdentity', 'Read-OwnedConfig')
foreach ($name in $safeFunctions) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $node) { throw ('Missing function: ' + $name) }
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation } catch { $failed = $true }
    Assert-Test $failed $Message
}
function Copy-TestObject([object]$Value) { return ($Value | ConvertTo-Json -Depth 8 | ConvertFrom-Json) }

$script:PrivateRoot = Join-Path ([IO.Path]::GetTempPath()) ('capture watch manager test ' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:PrivateRoot) | Out-Null
$script:ConfigPath = Join-Path $script:PrivateRoot 'config.json'
$script:InstalledWatcher = Join-Path $script:PrivateRoot 'Watch-CaptureUpdates.ps1'
$script:PowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:UserSid = 'S-1-5-21-1-2-3-1001'
$script:UserName = 'EXAMPLE\fixture'
$script:OwnerTag = 'windows10-chatgpt-capture-fix/capture-update-watch/v1'
$config = [pscustomobject]@{
    schema_version = 1
    owner_tag = $script:OwnerTag
    owner_sid = $script:UserSid
    installation_id = [Guid]::NewGuid().ToString('D')
    thread_id = [Guid]::NewGuid().ToString('D')
    state_dir = $script:PrivateRoot
    repository_path = $script:PrivateRoot
    codex_executable = Join-Path $script:PrivateRoot 'inert-codex.exe'
    watcher_sha256 = ('A' * 64)
    enabled = $true
}
$task = [pscustomobject]@{
    Description = Get-OwnershipDescription $config
    Actions = @([pscustomobject]@{ Execute = $script:PowerShellPath; Arguments = Get-WatcherArguments; WorkingDirectory = $script:PrivateRoot })
    Triggers = @([pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }; UserId = $script:UserSid })
    Principal = [pscustomobject]@{ UserId = $script:UserSid; LogonType = 3; RunLevel = 0 }
}
Assert-OwnedTask $task $config
$changed = Copy-TestObject $task
$changed.Actions[0].Arguments += ' -Command malicious'
Assert-Throws { Assert-OwnedTask $changed $config } 'Changed task arguments were accepted.'
$changed = Copy-TestObject $task
$changed.Principal.RunLevel = 1
Assert-Throws { Assert-OwnedTask $changed $config } 'Elevated task was accepted.'
$changed = Copy-TestObject $task
$changed.Triggers = @($changed.Triggers[0], $changed.Triggers[0])
Assert-Throws { Assert-OwnedTask $changed $config } 'Additional trigger was accepted.'
$changed = Copy-TestObject $task
$changed.Description = 'A different application'
Assert-Throws { Assert-OwnedTask $changed $config } 'Foreign task marker was accepted.'
$changed = Copy-TestObject $task
$changed.Triggers[0].CimClass.CimClassName = 'MSFT_TaskDailyTrigger'
Assert-Throws { Assert-OwnedTask $changed $config } 'Daily trigger was accepted.'
$changed = Copy-TestObject $task
$changed.Triggers[0] | Add-Member -NotePropertyName Repetition -NotePropertyValue ([pscustomobject]@{ Interval = 'P1D' })
Assert-Throws { Assert-OwnedTask $changed $config } 'Repeating logon trigger was accepted.'
$changed = Copy-TestObject $task
$changed.Principal.UserId = 'S-1-5-18'
Assert-Throws { Assert-OwnedTask $changed $config } 'A different principal SID was accepted.'

# Verify real Windows name normalization without touching any scheduled task.
$fixtureSid = $script:UserSid
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:UserSid = $identity.User.Value
    Assert-Test (Test-CurrentUserIdentity $script:UserSid) 'Current SID was rejected.'
    Assert-Test (Test-CurrentUserIdentity $identity.Name) 'Current qualified account name was rejected.'
    $bareName = ($identity.Name -split '\\')[-1]
    $bareResolvesToCurrent = $false
    try {
        $bareAccount = New-Object Security.Principal.NTAccount($bareName)
        $bareResolvesToCurrent = $bareAccount.Translate([Security.Principal.SecurityIdentifier]).Value -eq $script:UserSid
    } catch { }
    Assert-Test ((Test-CurrentUserIdentity $bareName) -eq $bareResolvesToCurrent) 'Bare account alias bypassed SID resolution.'
    $differentSid = $(if ($script:UserSid -eq 'S-1-5-18') { 'S-1-5-19' } else { 'S-1-5-18' })
    Assert-Test (-not (Test-CurrentUserIdentity $differentSid)) 'Different account SID was accepted.'
} finally {
    $script:UserSid = $fixtureSid
}

$created = [DateTime]::UtcNow
$record = [pscustomobject]@{ pid = 1234; process_start_time_utc = $created.ToString('o'); installation_id = $config.installation_id; config_path = $script:ConfigPath }
$process = [pscustomobject]@{
    ProcessId = 1234
    ExecutablePath = $script:PowerShellPath
    CreationDate = $created
    CommandLine = (Get-QuotedArgument $script:PowerShellPath) + ' ' + (Get-WatcherArguments)
}
Assert-Test (Test-ProcessIdentity $record $process $config) 'Exact owned process identity did not match.'
$changedProcess = Copy-TestObject $process
$changedProcess.CommandLine += ' -Command something'
Assert-Test (-not (Test-ProcessIdentity $record $changedProcess $config)) 'Changed command line matched.'
$changedProcess = Copy-TestObject $process
$changedProcess.CreationDate = $created.AddMinutes(1)
Assert-Test (-not (Test-ProcessIdentity $record $changedProcess $config)) 'Recycled PID/start time matched.'
$changedRecord = Copy-TestObject $record
$changedRecord.installation_id = [Guid]::NewGuid().ToString('D')
Assert-Test (-not (Test-ProcessIdentity $changedRecord $process $config)) 'Foreign installation process matched.'

Assert-Test ((Get-QuotedArgument 'C:\folder with spaces\watch.ps1') -ceq '"C:\folder with spaces\watch.ps1"') 'File argument quoting failed.'
Assert-Throws { Get-QuotedArgument 'C:\path" -Command bad' } 'Quote injection was accepted.'
Assert-Throws { Get-QuotedArgument "C:\path`n-Command bad" } 'Newline injection was accepted.'
Assert-Throws { Assert-LocalPlainPath '\\server\share\watch.ps1' } 'Network path was accepted.'
Assert-Throws { Assert-LocalPlainPath 'C:\watch.ps1:stream' } 'Alternate stream was accepted.'

[IO.File]::WriteAllText($script:ConfigPath, ($config | ConvertTo-Json -Depth 5))
$read = Read-OwnedConfig
Assert-Test ($read.installation_id -eq $config.installation_id) 'Owned config was rejected.'
$changedConfig = Copy-TestObject $config
$changedConfig.owner_tag = 'foreign-installation'
[IO.File]::WriteAllText($script:ConfigPath, ($changedConfig | ConvertTo-Json -Depth 5))
Assert-Throws { Read-OwnedConfig } 'Foreign private config was accepted.'

[ordered]@{
    syntax_valid = $true
    owned_logon_task_accepted = $true
    changed_foreign_elevated_daily_tasks_refused = $true
    account_aliases_compared_by_resolved_sid = $true
    process_identity_and_recycled_pid_guards = $true
    argument_and_path_guards = $true
    owned_configuration_guard = $true
    fixture_directory = $script:PrivateRoot
    limits = 'Synthetic objects only; does not register/start/stop a task or real watcher, execute Codex, or test logon behavior.'
} | ConvertTo-Json
