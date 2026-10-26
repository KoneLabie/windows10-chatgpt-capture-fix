# Synthetic event/state tests. Never starts the watcher or invokes the Codex CLI.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$watcherFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\capture-update-watch\scripts\Watch-CaptureUpdates.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($watcherFile,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$allowed = @('Get-Sha256Text','Test-PathInside','Get-CaptureSnapshot','Test-KnownRepairTransition','Get-SnapshotAction','Test-RelevantUpdatePath','New-WatchState','Update-StateForSnapshot','ConvertTo-WindowsArgument','Invoke-BoundedProcess')
foreach($name in $allowed) {
    $functions = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false))
    if($functions.Count -ne 1) { throw ('Expected one safe test function: '+$name) }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}

$script:checks = 0
function Assert-True([bool]$Condition,[string]$Message) {
    if(-not $Condition) { throw ('FAILED: '+$Message) }
    $script:checks++
}

function New-SyntheticSnapshot([string]$Fingerprint,[string]$Hash,[string]$Version='1.0') {
    return [pscustomobject]@{
        fingerprint=$Fingerprint;package_versions=@($Version)
        helpers=@([pscustomobject]@{relative_path='runtime1\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe';sha256=$Hash;size=1551152})
    }
}

$script:deliveries = 0
$script:saves = @()
$save = {param($value) $script:saves += ($value | ConvertTo-Json -Depth 8 -Compress)}
$dispatch = {param($snapshot) $script:deliveries++; [pscustomobject]@{status='queued';detail='Synthetic dispatch only.'}}
$state = New-WatchState
$first = New-SyntheticSnapshot 'first' ('1'*64)
Assert-True ((Update-StateForSnapshot $state $first $save $dispatch) -eq 'baseline') 'first startup must quietly record a baseline'
Assert-True ($script:deliveries -eq 0) 'baseline must not queue'
Assert-True ((Update-StateForSnapshot $state $first $save $dispatch) -eq 'unchanged') 'repeated baseline event must not queue'
$original = New-SyntheticSnapshot 'original' '11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8'
Assert-True ((Update-StateForSnapshot $state $original $save $dispatch) -eq 'queued') 'new original helper should queue'
Assert-True ($script:deliveries -eq 1) 'one event fingerprint should produce one delivery'
Assert-True ((Update-StateForSnapshot $state $original $save $dispatch) -eq 'unchanged') 'repeated event must not duplicate delivery'
$repaired = New-SyntheticSnapshot 'repaired' '1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5'
Assert-True ((Update-StateForSnapshot $state $repaired $save $dispatch) -eq 'repair-observed') 'known original-to-repair transition should be suppressed'
Assert-True ($script:deliveries -eq 1) 'self repair should not loop'
Assert-True ((Update-StateForSnapshot $state $original $save $dispatch) -eq 'queued') 'original reappearing after repair should queue again'
Assert-True ($script:deliveries -eq 2) 'reverted repair must not be hidden by earlier delivered fingerprint'
$newPackage = New-SyntheticSnapshot 'new-package' $repaired.helpers[0].sha256 '2.0'
Assert-True (-not (Test-KnownRepairTransition $original $newPackage)) 'package-version change must not be suppressed as self repair'

$unknown = New-SyntheticSnapshot 'delivery-unknown' ('9'*64)
$unknownDispatch = {param($snapshot) $script:deliveries++; [pscustomobject]@{status='unknown';detail='Synthetic ambiguous exit.'}}
$deliveredBefore = $state.last_delivered_fingerprint
Assert-True ((Update-StateForSnapshot $state $unknown $save $unknownDispatch) -eq 'unknown') 'unknown delivery outcome should be recorded'
Assert-True ($state.last_delivered_fingerprint -eq $deliveredBefore) 'unknown delivery must not advance last delivered'
$countAfterUnknown = $script:deliveries
Assert-True ((Update-StateForSnapshot $state $unknown $save $dispatch) -eq 'ambiguous') 'ambiguous fingerprint must not automatically duplicate'
Assert-True ($script:deliveries -eq $countAfterUnknown) 'ambiguous delivery must remain unsent'
$pending = New-SyntheticSnapshot 'cli-missing' ('8'*64)
$notAttempted = {param($snapshot) [pscustomobject]@{status='not-attempted';detail='Synthetic missing CLI.'}}
Assert-True ((Update-StateForSnapshot $state $pending $save $notAttempted) -eq 'not-attempted') 'pre-dispatch error should retain pending fingerprint'
Assert-True ($state.pending_fingerprint -eq $pending.fingerprint) 'pending retry should persist'
Assert-True ((Update-StateForSnapshot $state $pending $save $dispatch) -eq 'queued') 'later real event may retry a dispatch never attempted'
Assert-True (($script:saves | Where-Object { $_ -match '"last_result":"dispatching"' -and $_ -match '"dispatch_in_progress_fingerprint":"original"' }).Count -gt 0) 'dispatch intent must be saved before attempting queue'

$vendor = Join-Path ([IO.Path]::GetTempPath()) 'synthetic-openai-codex'
Assert-True (Test-RelevantUpdatePath (Join-Path $vendor 'runtimes\cua_node\abc\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe') $vendor) 'exact helper event should match'
Assert-True (Test-RelevantUpdatePath (Join-Path $vendor 'runtimes\cua_node\abc\bin\node_modules\@oai\sky\package.json') $vendor) 'package metadata event should match'
Assert-True (Test-RelevantUpdatePath (Join-Path $vendor 'runtimes\cua_node\abc') $vendor) 'whole runtime rename should match'
Assert-True (-not (Test-RelevantUpdatePath (Join-Path $vendor 'logs\unrelated.log') $vendor)) 'unrelated logs must not trigger reconciliation'
Assert-True (-not (Test-RelevantUpdatePath (Join-Path ($vendor+'-other') 'bin\codex.exe') $vendor)) 'similar sibling paths must not match vendor root'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('capturewatch-test-'+[Guid]::NewGuid().ToString('N'))
$eventId = 'CaptureWatchTest.'+[Guid]::NewGuid().ToString('N')
$fsw = $null
try {
    $runtime = Join-Path $fixtureRoot 'runtimes'
    $helper = Join-Path $runtime 'abc\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $helper) -Force | Out-Null
    $fsw = New-Object IO.FileSystemWatcher($runtime,'codex-computer-use.exe')
    $fsw.IncludeSubdirectories=$true
    Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier $eventId | Out-Null
    $fsw.EnableRaisingEvents=$true
    [IO.File]::WriteAllText($helper,'synthetic fixture; not executable')
    $observedEvent = Wait-Event -SourceIdentifier $eventId -Timeout 5
    Assert-True ($null -ne $observedEvent) 'a native filesystem event must wake the test'
    $snapshot1 = Get-CaptureSnapshot $runtime @('1.0','2.0')
    $snapshot2 = Get-CaptureSnapshot $runtime @('2.0','1.0')
    Assert-True ($snapshot1.fingerprint -eq $snapshot2.fingerprint) 'version order must not affect normalized fingerprint'
    Assert-True (@($snapshot1.helpers).Count -eq 1) 'only the exact helper layout is fingerprinted'
    $ignored = Join-Path $runtime 'codex-computer-use.exe'
    [IO.File]::WriteAllText($ignored,'unrelated layout')
    $snapshot3 = Get-CaptureSnapshot $runtime @('1.0','2.0')
    Assert-True ($snapshot3.fingerprint -eq $snapshot1.fingerprint) 'helper-like filename outside expected layout must be ignored'
    [IO.File]::WriteAllText($helper,'')
    $emptyRefused = $false
    try { Get-CaptureSnapshot $runtime @('1.0') | Out-Null } catch { $emptyRefused=$true }
    Assert-True $emptyRefused 'in-flight empty helper must not produce a candidate snapshot'

    # Build an inert local argv/sleep stub. No download, CLI, runtime helper,
    # scheduled task, or installed watcher is launched by these tests.
    $stub = Join-Path $fixtureRoot 'argv-stub.exe'
    Add-Type -OutputAssembly $stub -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
public static class CaptureWatchArgvStub {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "sleep") { Thread.Sleep(5000); return 0; }
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        return 0;
    }
}
'@
    $argumentFixture = @('plain','two words','','a"b','trailing\','C:\folder with spaces\','\\\"','$()&;')
    $roundTrip = Invoke-BoundedProcess $stub $argumentFixture 3000
    Assert-True ($roundTrip.started -and -not $roundTrip.timed_out -and $roundTrip.exit_code -eq 0) 'quoted argv stub should exit successfully'
    $received = @([regex]::Split($roundTrip.stdout.TrimEnd([char]13,[char]10),'\r?\n') | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
    Assert-True ($received.Count -eq $argumentFixture.Count) 'empty argv element must survive quoting'
    for($index=0;$index -lt $argumentFixture.Count;$index++) {
        Assert-True ($received[$index] -ceq $argumentFixture[$index]) ('argv should round-trip exactly at index '+$index)
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timeout = Invoke-BoundedProcess $stub @('sleep') 150
    $timer.Stop()
    Assert-True ($timeout.started -and $timeout.timed_out) 'a hung child should be classified as a timed-out ambiguous delivery'
    Assert-True ($timer.ElapsedMilliseconds -lt 4000) 'timeout must bound the call instead of waiting for the five-second stub'
} finally {
    Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    if($null -ne $fsw) { $fsw.EnableRaisingEvents=$false; $fsw.Dispose() }
    # Remove only this uniquely named fixture, after validating its absolute root.
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^capturewatch-test-[a-f0-9]{32}$') { throw 'Fixture cleanup path validation failed.' }
    if(Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

Write-Output ('PASS: '+$script:checks+' watcher assertions; native synthetic event observed; no watcher started or CLI invoked.')
