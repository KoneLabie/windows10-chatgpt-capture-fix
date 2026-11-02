#Requires -Version 5.1
<# Exercise timestamp conversion and the real Keep branch without installing,
   stopping processes, touching runtime files, or sending controller signals. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$controller = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\repair.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('ConvertTo-TrialDeadline', 'Invoke-Repair')) {
    $definition = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-Test([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Assert-Refused([scriptblock]$Operation, [string]$Message) {
    $refused = $false
    try { & $Operation | Out-Null } catch { $refused = $true }
    Assert-Test $refused $Message
}

# Replace only the Keep branch's external dependencies; keep its decision logic.
function Initialize-ValidatedPaths { }
function Assert-LeaseHeldElsewhere { }
function Get-ActiveTrialStatus { return $script:TestStatus }
function Get-FileDigest([string]$Path) { return $script:CandidateHash }
function Send-TrialSignal([string]$Kind, [string]$Id) {
    $script:Signals.Add("${Kind}:${Id}") | Out-Null
}
$script:Action = 'Keep'
$script:Verified = $true
$script:LivePath = 'C:\inert-deadline-test'
$script:CandidateHash = 'inert-candidate'
$script:Signals = New-Object 'System.Collections.Generic.List[string]'
$trialId = '0123456789abcdef0123456789abcdef'
$expected = [DateTimeOffset]::Parse('2031-11-02T01:07:20.9248501+00:00',
    [Globalization.CultureInfo]::InvariantCulture)
$originalCulture = [Globalization.CultureInfo]::CurrentCulture
$cases = 0
try {
    foreach ($cultureName in @('fr-FR', 'en-US', 'de-DE', 'zh-CN')) {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
        $roundTrip = @{ deadline = $expected.ToString('o') } | ConvertTo-Json | ConvertFrom-Json
        foreach ($value in @($expected, $expected.UtcDateTime, $expected.LocalDateTime,
                $expected.ToString('o'), $roundTrip.deadline)) {
            $actual = ConvertTo-TrialDeadline $value
            Assert-Test ($actual.UtcTicks -eq $expected.UtcTicks) "Timestamp changed in $cultureName for $($value.GetType().Name)."
            $cases++
        }

        foreach ($isFuture in @($true, $false)) {
            $deadline = if ($isFuture) { [DateTimeOffset]::UtcNow.AddMinutes(5) }
                        else { [DateTimeOffset]::UtcNow.AddMinutes(-5) }
            $script:TestStatus = @{
                stage = 'TrialReady'; trial_id = $trialId
                detail = @{ automatic_rollback_deadline_utc = $deadline.ToString('o') }
            } | ConvertTo-Json -Depth 3 | ConvertFrom-Json
            $script:Signals.Clear()
            if ($isFuture) {
                Invoke-Repair | Out-Null
                Assert-Test ($script:Signals.Count -eq 1 -and $script:Signals[0] -eq "keep:$trialId") "Future Keep failed in $cultureName."
            } else {
                Assert-Refused { Invoke-Repair } "Expired Keep accepted in $cultureName."
                Assert-Test ($script:Signals.Count -eq 0) 'Expired deadline sent a Keep signal.'
            }
            $cases++
        }
    }
    foreach ($invalid in @($null, 'not a timestamp', (New-Object object))) {
        Assert-Refused { ConvertTo-TrialDeadline $invalid } 'Invalid timestamp accepted.'
        $cases++
    }
} finally {
    [Globalization.CultureInfo]::CurrentCulture = $originalCulture
}
[ordered]@{ result = 'PASS'; cases = $cases; cultures = @('fr-FR', 'en-US', 'de-DE', 'zh-CN'); live_mutations = $false } | ConvertTo-Json
