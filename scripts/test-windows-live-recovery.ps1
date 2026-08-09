#Requires -Version 7

<#
.SYNOPSIS
Drives the Windows live lane's build, park, probe, and restore stages against a stubbed machine.

.DESCRIPTION
These four stages decide what happens to a shared desktop when a probe fails, and they are the one
part of the live workflow that cannot be rehearsed before it runs: the lane has no `pull_request`
trigger, and its failure branches only execute when something has already gone wrong on the runner.
A mistake in them is discovered by a developer machine losing its start-at-login daemon, which is
exactly the failure the stages exist to prevent. This is the Windows counterpart of
scripts/test-macos-live-recovery.

The stage bodies are dot-sourced from .github/scripts/windows-live-probe.ps1 -- never copied -- and
every function in that file's `#region seams` block is replaced with one that talks to a fake
machine instead. The fake behaves rather than answering from a script: stopping a daemon really
removes it, starting a task really adds a process, and a health document is really serialized and
parsed. What is asserted is the branch each scenario lands on, the message it produces, and in
several cases the order it did things in, because a restore that silently takes the wrong branch is
the whole hazard.

A constraint on every scenario added here, not merely a property that happens to hold today: the
probe script must reach the machine only through those seams. The `Test` workflow's Windows job runs
on the same machine as the live lane and shares no concurrency group with it, so a scenario that
reached a real `Get-ScheduledTask`, `Stop-Process`, or `axon-win` would be doing so on somebody's
desktop, possibly mid-live-run. The seam census below fails the run when the probe script grows a
seam this file does not stub, rather than letting the new one through to the real machine.

And a warning for whoever extends this. The only way to know a scenario asserts anything is to break
the stage and watch it fail. Verify that the mutation landed before reading its verdict: a mutation
that silently fails to apply reports exactly what a vacuous assertion reports.

Usage: pwsh -NoProfile -File scripts/test-windows-live-recovery.ps1
#>

[CmdletBinding()]
param(
    [string] $ProbeScript
)

$ErrorActionPreference = 'Stop'

if (-not $ProbeScript) {
    $ProbeScript = Join-Path $PSScriptRoot '..\.github\scripts\windows-live-probe.ps1'
}
$ProbeScript = (Resolve-Path $ProbeScript).Path

. $ProbeScript

# ---------------------------------------------------------------------------------------------
# Seam census
# ---------------------------------------------------------------------------------------------

$StubbedSeams = @(
    'Write-Note', 'Wait-Tick', 'Test-ProcessIsRunning', 'Get-AxonProcess', 'Stop-ProcessById',
    'Get-DesktopRegistrationPath', 'Start-DesktopDaemonTask', 'Register-ProbeTask',
    'Unregister-ProbeTask', 'Start-ProbeTask', 'Invoke-Axon', 'Invoke-AxonMcp', 'Invoke-CargoBuild',
    'Copy-ProbeExecutable', 'Read-ParkState', 'Write-ParkState', 'Clear-ParkState'
)

$declaredSeams = @()
$inSeamRegion = $false
foreach ($line in Get-Content -LiteralPath $ProbeScript) {
    if ($line -match '^#region seams') { $inSeamRegion = $true; continue }
    if ($line -match '^#endregion') { $inSeamRegion = $false; continue }
    if ($inSeamRegion -and $line -match '^function\s+([\w-]+)') { $declaredSeams += $Matches[1] }
}

$unstubbed = @($declaredSeams | Where-Object { $StubbedSeams -notcontains $_ })
$phantom = @($StubbedSeams | Where-Object { $declaredSeams -notcontains $_ })
if ($declaredSeams.Count -eq 0) {
    throw "found no seams in $ProbeScript; the '#region seams' marker has moved and this harness would be talking to the real machine"
}
if ($unstubbed.Count -ne 0) {
    throw "the probe script declares seams this harness does not stub: $($unstubbed -join ', '); stub them here in the same change or every scenario reaches the real machine through them"
}
if ($phantom.Count -ne 0) {
    throw "this harness stubs functions the probe script no longer declares as seams: $($phantom -join ', ')"
}

# Every PowerShell file this lane runs, parsed. The scenarios below exercise the probe script by
# dot-sourcing it, but nothing would notice a syntax error in the runner-side stage invoker until a
# push to `main` had already reached the runner.
foreach ($file in Get-ChildItem -Path (Join-Path $RepositoryRoot '.github\scripts') -Filter '*.ps1') {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $parseErrors) | Out-Null
    if ($parseErrors) {
        throw "$($file.Name) does not parse: line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"
    }
}

# Every bound in the probe script, shrunk. A scenario that has to sit through the real one is a
# scenario nobody adds.
$ReadinessTimeoutSeconds = 1
$PipeFreeTimeoutSeconds = 1
$ProcessDiscoveryTimeoutSeconds = 1
$RestoreTimeoutSeconds = 1

$ExpectedVersion = (Get-Content (Join-Path $RepositoryRoot 'VERSION')).Trim()
$DesktopInstallPath = 'C:\Users\mitch\AppData\Local\Axon\0.2.1\axon-win-0.2.1-windows-x86_64\axon-win.exe'
$DesktopPid = 4388
$ProbePid = 12592

# ---------------------------------------------------------------------------------------------
# The fake machine
# ---------------------------------------------------------------------------------------------

$script:Machine = $null

function Reset-Machine {
    $script:Machine = @{
        Log = [System.Collections.Generic.List[string]]::new()
        Notes = [System.Collections.Generic.List[string]]::new()
        DesktopRegistration = $DesktopInstallPath
        ParkState = $null
        ProbeTaskRegistered = $false
        Processes = @()
        Quarantined = @()
        Health = $null
        VersionOutput = $ExpectedVersion
        ShutdownFails = $false
        RestartFails = $false
        BuildFails = $false
        ProbeTaskStartsNothing = $false
        ProbeTaskStartsTwice = $false
        ServingProcessId = $null
        Session = @{ interactive = $true; graphical = $true }
        CapabilityCount = 15
        McpResponder = $null
    }
    Start-FakeDesktopDaemon
}

function New-FakeHealth {
    param([int] $ProcessId)

    @{
        schemaVersion = 'health-v1'
        version = $ExpectedVersion
        platform = 'windows'
        daemon = @{ running = $true; ready = $true; endpoint = '\\.\pipe\axon-v1'; processId = $ProcessId }
        registration = @{ registered = $true; mechanism = 'scheduledTask'; path = $script:Machine.DesktopRegistration }
        session = $script:Machine.Session
        capabilities = @(1..$script:Machine.CapabilityCount | ForEach-Object { @{ capability = "capability$_"; usable = $true } })
    }
}

function Add-FakeProcess {
    param([int] $ProcessId, [string] $ExecutablePath)

    $script:Machine.Processes += [pscustomobject]@{ ProcessId = $ProcessId; ExecutablePath = $ExecutablePath }
}

function Start-FakeDesktopDaemon {
    Add-FakeProcess -ProcessId $DesktopPid -ExecutablePath $script:Machine.DesktopRegistration
    $script:Machine.Health = New-FakeHealth -ProcessId $DesktopPid
}

function Stop-FakeDaemon {
    if ($null -ne $script:Machine.Health -and $null -ne $script:Machine.Health.daemon.processId) {
        $serving = $script:Machine.Health.daemon.processId
        $script:Machine.Processes = @($script:Machine.Processes | Where-Object { $_.ProcessId -ne $serving })
    }
    $script:Machine.Health = @{
        schemaVersion = 'health-v1'
        version = $ExpectedVersion
        platform = 'windows'
        daemon = @{ running = $false; ready = $false; endpoint = '\\.\pipe\axon-v1'; processId = $null }
        registration = @{ registered = $true; mechanism = 'scheduledTask'; path = $script:Machine.DesktopRegistration }
        session = $script:Machine.Session
        capabilities = @(1..$script:Machine.CapabilityCount | ForEach-Object { @{ capability = "capability$_"; usable = $true } })
    }
}

# ---------------------------------------------------------------------------------------------
# The seams
# ---------------------------------------------------------------------------------------------

function Write-Note {
    param([Parameter(Mandatory)][string] $Message)
    $script:Machine.Notes.Add($Message)
    $script:Machine.Log.Add("note: $Message")
}

function Wait-Tick { }

function Test-ProcessIsRunning {
    param([Parameter(Mandatory)][int] $ProcessId)
    [bool] @($script:Machine.Processes | Where-Object { $_.ProcessId -eq $ProcessId })
}

function Get-AxonProcess {
    @($script:Machine.Processes)
}

function Stop-ProcessById {
    param([Parameter(Mandatory)][int] $ProcessId)
    $script:Machine.Log.Add("stop-process $ProcessId")
    $script:Machine.Processes = @($script:Machine.Processes | Where-Object { $_.ProcessId -ne $ProcessId })
    if ($null -ne $script:Machine.Health -and $script:Machine.Health.daemon.processId -eq $ProcessId) {
        Stop-FakeDaemon
    }
}

function Get-DesktopRegistrationPath {
    $script:Machine.Log.Add('read-desktop-registration')
    $script:Machine.DesktopRegistration
}

function Start-DesktopDaemonTask {
    $script:Machine.Log.Add('start-desktop-task')
    Start-FakeDesktopDaemon
}

function Register-ProbeTask {
    $script:Machine.Log.Add('register-probe-task')
    $script:Machine.ProbeTaskRegistered = $true
}

function Unregister-ProbeTask {
    $script:Machine.Log.Add('unregister-probe-task')
    $script:Machine.ProbeTaskRegistered = $false
}

function Start-ProbeTask {
    $script:Machine.Log.Add('start-probe-task')
    if ($script:Machine.ProbeTaskStartsNothing) { return }
    Add-FakeProcess -ProcessId $ProbePid -ExecutablePath $ProbeExecutable
    if ($script:Machine.ProbeTaskStartsTwice) {
        Add-FakeProcess -ProcessId ($ProbePid + 1) -ExecutablePath $ProbeExecutable
    }
    $serving = if ($null -ne $script:Machine.ServingProcessId) { $script:Machine.ServingProcessId } else { $ProbePid }
    $script:Machine.Health = New-FakeHealth -ProcessId $serving
}

function Invoke-Axon {
    param([Parameter(Mandatory)][string] $Executable, [Parameter(Mandatory)][string[]] $Arguments)

    $joined = $Arguments -join ' '
    $script:Machine.Log.Add("axon $joined [$Executable]")
    if ($script:Machine.Quarantined -contains $Executable) {
        return [pscustomobject]@{
            ExitCode = -1
            Output = 'Operation did not complete successfully because the file contains a virus or potentially unwanted software.'
        }
    }
    switch ($joined) {
        'status --json' {
            if ($null -eq $script:Machine.Health) { return [pscustomobject]@{ ExitCode = 1; Output = 'nothing answered' } }
            return [pscustomobject]@{ ExitCode = 0; Output = ($script:Machine.Health | ConvertTo-Json -Depth 10) }
        }
        'version' { return [pscustomobject]@{ ExitCode = 0; Output = $script:Machine.VersionOutput } }
        'shutdown' {
            if ($script:Machine.ShutdownFails) { return [pscustomobject]@{ ExitCode = 1; Output = 'a daemon is still answering' } }
            Stop-FakeDaemon
            return [pscustomobject]@{ ExitCode = 0; Output = 'stopped' }
        }
        'daemon restart' {
            if ($script:Machine.RestartFails) { return [pscustomobject]@{ ExitCode = 1; Output = 'restart failed' } }
            Start-FakeDesktopDaemon
            return [pscustomobject]@{ ExitCode = 0; Output = 'restarted' }
        }
        default { return [pscustomobject]@{ ExitCode = 1; Output = "unexpected command $joined" } }
    }
}

function Invoke-AxonMcp {
    param([Parameter(Mandatory)][string] $Request)

    $script:Machine.Log.Add('mcp')
    if ($null -ne $script:Machine.McpResponder) { return & $script:Machine.McpResponder $Request }
    if ($Request -notmatch '"app"') {
        return @{ result = @{ isError = $false; structuredContent = @(@{ name = 'Notepad' }) } } |
            ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
    }
    @{
        result = @{
            isError = $false
            structuredContent = @{ id = 'snapshot-1'; app = @{ windows = @(@{ root = @{ role = 'Window' } }) } }
        }
    } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
}

function Invoke-CargoBuild {
    $script:Machine.Log.Add('cargo-build')
    if ($script:Machine.BuildFails) { throw 'cargo build failed with exit code 101' }
}

function Copy-ProbeExecutable {
    $script:Machine.Log.Add('copy-probe-executable')
}

function Read-ParkState {
    $script:Machine.ParkState
}

function Write-ParkState {
    param([Parameter(Mandatory)][hashtable] $State)
    $script:Machine.Log.Add('write-park-state')
    # Round-tripped through JSON exactly as the real state file is, so a scenario cannot depend on
    # a hashtable property the restore stage would not actually get back.
    $script:Machine.ParkState = $State | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}

function Clear-ParkState {
    $script:Machine.Log.Add('clear-park-state')
    $script:Machine.ParkState = $null
}

# ---------------------------------------------------------------------------------------------
# Scenario plumbing
# ---------------------------------------------------------------------------------------------

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:ScenarioName = ''
$script:ScenarioCount = 0

function Test-Scenario {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][scriptblock] $Body)

    $script:ScenarioName = $Name
    $script:ScenarioCount++
    Reset-Machine
    & $Body
}

function Check {
    param([Parameter(Mandatory)][string] $Description, [Parameter(Mandatory)][bool] $Condition, [string] $Detail = '')

    if (-not $Condition) {
        $suffix = if ($Detail) { " -- $Detail" } else { '' }
        $script:Failures.Add("$($script:ScenarioName): $Description$suffix")
    }
}

function Invoke-StageUnderTest {
    param([Parameter(Mandatory)][string] $Name)

    try {
        Invoke-Stage -Name $Name | Out-Null
        [pscustomobject]@{ Failed = $false; Error = '' }
    }
    catch {
        [pscustomobject]@{ Failed = $true; Error = $_.Exception.Message }
    }
}

function Test-Said {
    param([string] $Pattern)
    [bool] @($script:Machine.Notes | Where-Object { $_ -match $Pattern })
}

function Test-Did {
    param([string] $Pattern)
    [bool] @($script:Machine.Log | Where-Object { $_ -match $Pattern })
}

function Get-Position {
    param([string] $Pattern)
    for ($index = 0; $index -lt $script:Machine.Log.Count; $index++) {
        if ($script:Machine.Log[$index] -match $Pattern) { return $index }
    }
    -1
}

function Test-Order {
    <# Both calls happened, and in this order.

    Both halves are required. A bare position comparison passes vacuously when the earlier call
    never happened at all -- `-1` is less than everything -- so a mutation that deletes the sweep
    reads exactly like a mutation that kept it in the right place. #>
    param([Parameter(Mandatory)][string] $First, [Parameter(Mandatory)][string] $Then)

    $firstAt = Get-Position $First
    $thenAt = Get-Position $Then
    Check "'$First' happened" ($firstAt -ge 0)
    Check "'$Then' happened" ($thenAt -ge 0)
    Check "'$First' came before '$Then'" ($firstAt -ge 0 -and $thenAt -ge 0 -and $firstAt -lt $thenAt)
}

# ---------------------------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------------------------

Test-Scenario 'build: a clean machine builds, copies, and proves the copy runs' {
    $result = Invoke-StageUnderTest -Name 'build'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it builds and copies' (Test-Did 'cargo-build') 
    Check 'it runs the fresh binary once' (Test-Did 'axon version')
    Check 'it reports the first-execution cost' (Test-Said 'ran it for the first time')
    Check 'it never stops this desktop' (-not (Test-Did 'axon shutdown'))
}

Test-Scenario 'build: a quarantined build fails before this desktop is touched' {
    $script:Machine.Quarantined = @($ProbeExecutable)
    $result = Invoke-StageUnderTest -Name 'build'
    Check 'the stage fails' $result.Failed
    Check 'it names the real reason' ($result.Error -match 'virus') $result.Error
    Check 'this desktop still has its daemon' ($script:Machine.Health.daemon.running -eq $true)
    Check 'nothing was stopped' (-not (Test-Did 'axon shutdown'))
}

Test-Scenario 'build: a version the checkout does not expect fails the stage' {
    $script:Machine.VersionOutput = '0.0.1'
    $result = Invoke-StageUnderTest -Name 'build'
    Check 'the stage fails' $result.Failed
    Check 'it names both versions' ($result.Error -match "0.0.1.*$([regex]::Escape($ExpectedVersion))") $result.Error
}

Test-Scenario 'build: a desktop registration inside a probe directory is refused, not swept' {
    $script:Machine.DesktopRegistration = $ProbeExecutable
    Start-FakeDesktopDaemon
    $result = Invoke-StageUnderTest -Name 'build'
    Check 'the stage fails' $result.Failed
    Check 'it names the repair' ($result.Error -match 'must be reinstalled from its permanent path') $result.Error
    Check 'it kills nothing' (-not (Test-Did 'stop-process'))
}

# ---------------------------------------------------------------------------------------------
# park
# ---------------------------------------------------------------------------------------------

Test-Scenario 'park: a running desktop daemon is recorded, then stopped' {
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the state was recorded' ($null -ne $script:Machine.ParkState)
    Check 'it recorded the daemon as running' ($script:Machine.ParkState.daemonWasRunning -eq $true)
    Check 'it recorded the registration' ($script:Machine.ParkState.registrationPath -eq $DesktopInstallPath)
    Test-Order -First 'write-park-state' -Then 'axon shutdown'
    Check 'the pipe is free' ($script:Machine.Health.daemon.running -eq $false)
    Check 'it says so' (Test-Said 'no daemon is answering')
}

Test-Scenario 'park: a desktop with no daemon is recorded and left alone' {
    Stop-FakeDaemon
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it recorded the daemon as stopped' ($script:Machine.ParkState.daemonWasRunning -eq $false)
    Check 'it stopped nothing' (-not (Test-Did 'axon shutdown'))
}

Test-Scenario 'park: a stop that does not take fails the stage, having already recorded the debt' {
    $script:Machine.ShutdownFails = $true
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage fails' $result.Failed
    Check 'it names the stop' ($result.Error -match "could not stop this desktop's daemon") $result.Error
    Check 'the restore still knows what is owed' ($script:Machine.ParkState.daemonWasRunning -eq $true)
}

Test-Scenario 'park: a daemon still answering after the stop is named rather than killed' {
    # `shutdown` reports success while something else keeps the pipe -- the case where a probe would
    # otherwise gather every assertion from a daemon nobody built.
    $script:Machine.ShutdownFails = $false
    $original = Get-Item function:Invoke-Axon
    function Invoke-Axon {
        param([string] $Executable, [string[]] $Arguments)
        if (($Arguments -join ' ') -eq 'shutdown') {
            $script:Machine.Log.Add('axon shutdown')
            return [pscustomobject]@{ ExitCode = 0; Output = 'stopped' }
        }
        & $original -Executable $Executable -Arguments $Arguments
    }
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage fails' $result.Failed
    Check 'it names the pid holding the pipe' ($result.Error -match "still served by pid $DesktopPid") $result.Error
    Check 'it killed nothing' (-not (Test-Did 'stop-process'))
}

Test-Scenario 'park: the desktop registration is never written' {
    Invoke-StageUnderTest -Name 'park' | Out-Null
    Check 'the registration was only read' (-not (Test-Did 'register-probe-task|start-desktop-task'))
    Check 'the registration is unchanged' ($script:Machine.DesktopRegistration -eq $DesktopInstallPath)
}

# ---------------------------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------------------------

function Set-ParkedMachine {
    param([bool] $DaemonWasRunning = $true)

    Stop-FakeDaemon
    $script:Machine.ParkState = @{
        recordedAt = (Get-Date).ToString('o')
        desktopTaskName = 'Axon Windows Daemon'
        registrationPath = $script:Machine.DesktopRegistration
        daemonWasRunning = $DaemonWasRunning
        daemonProcessId = $DesktopPid
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
}

Test-Scenario 'probe: the daemon it started is the one it reports on' {
    Set-ParkedMachine
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it registered its own task' (Test-Did 'register-probe-task')
    Check 'it proved authorship' (Test-Said "pid $ProbePid\) is serving")
    Check 'it read a real window' (Test-Said 'root=Window')
    Check 'it removed its own registration afterwards' ($script:Machine.ProbeTaskRegistered -eq $false)
    Check 'it left no probe daemon behind' (@($script:Machine.Processes | Where-Object { $_.ExecutablePath -eq $ProbeExecutable }).Count -eq 0)
}

Test-Scenario 'probe: another daemon answering the pipe fails the stage' {
    Set-ParkedMachine
    $script:Machine.ServingProcessId = 9999
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names both pids' ($result.Error -match "served by pid 9999, not the daemon under test \(pid $ProbePid\)") $result.Error
    Check 'it still removed its own registration' ($script:Machine.ProbeTaskRegistered -eq $false)
}

Test-Scenario 'probe: a task that starts nothing fails by name' {
    Set-ParkedMachine
    $script:Machine.ProbeTaskStartsNothing = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the task' ($result.Error -match 'never launched the daemon under test') $result.Error
}

Test-Scenario 'probe: two daemons at the probe path are refused rather than chosen between' {
    Set-ParkedMachine
    $script:Machine.ProbeTaskStartsTwice = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it refuses to guess' ($result.Error -match 'is a guess') $result.Error
}

Test-Scenario 'probe: a daemon that exits instead of serving is named' {
    Set-ParkedMachine
    $script:Machine.ServingProcessId = 0
    $original = Get-Item function:Start-ProbeTask
    function Start-ProbeTask {
        & $original
        # Registered, discovered, and then gone -- what a daemon that cannot bind the pipe looks like.
        $script:Machine.Health = $null
    }
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names readiness or exit' ($result.Error -match 'never became ready|exited instead of serving') $result.Error
}

Test-Scenario 'probe: a registration that moved during the run fails the stage' {
    Set-ParkedMachine
    $script:Machine.DesktopRegistration = 'C:\ProgramData\Axon\live\axon-win.exe'
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it says the lane must never repoint' ($result.Error -match 'must never repoint') $result.Error
}

Test-Scenario 'probe: a session-0 daemon is not evidence about a desktop' {
    Set-ParkedMachine
    $script:Machine.Session = @{ interactive = $false; graphical = $false }
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the desktop' ($result.Error -match 'not on the interactive desktop') $result.Error
}

Test-Scenario 'probe: an incomplete capability vocabulary fails the stage' {
    Set-ParkedMachine
    $script:Machine.CapabilityCount = 14
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the vocabulary' ($result.Error -match 'complete capability vocabulary') $result.Error
}

Test-Scenario 'probe: refusing to run when this desktop was never parked' {
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it says why' ($result.Error -match 'never parked') $result.Error
    Check 'it registered nothing' (-not (Test-Did 'register-probe-task'))
}

# ---------------------------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------------------------

Test-Scenario 'restore: a job that never parked leaves the machine alone' {
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it says so' (Test-Said 'never parked')
    Check 'it touched nothing' (-not (Test-Did 'axon|stop-process|start-desktop-task'))
}

Test-Scenario 'restore: the desktop gets its daemon back and the verdict is a health round trip' {
    Set-ParkedMachine
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it restarted the desktop registration' (Test-Did 'axon daemon restart')
    Check 'the daemon is answering' ($script:Machine.Health.daemon.running -eq $true)
    Check 'it reports the pid it verified' (Test-Said "answering again \(pid $DesktopPid")
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
    Test-Order -First 'unregister-probe-task' -Then 'axon daemon restart'
}

Test-Scenario 'restore: a quarantined build still gives the desktop its daemon back' {
    # The 2026-08-08 failure, in the shape that matters: the binary this lane built is gone, and the
    # machine must still end the job with its own daemon serving.
    Set-ParkedMachine
    $script:Machine.Quarantined = @($ProbeExecutable)
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it fell back to Task Scheduler' (Test-Did 'start-desktop-task')
    Check 'it says why' (Test-Said 'through Task Scheduler instead')
    Check 'the daemon is answering' ($script:Machine.Health.daemon.running -eq $true)
    Check 'the registration is untouched' ($script:Machine.Health.registration.path -eq $DesktopInstallPath)
}

Test-Scenario 'restore: a restart that reports failure but works is not a failed restore' {
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it recorded the status' (Test-Said 'daemon restart exited 1')
    Check 'it started the task anyway' (Test-Did 'start-desktop-task')
}

Test-Scenario 'restore: a desktop whose daemon never comes back fails loudly' {
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    function Start-DesktopDaemonTask { $script:Machine.Log.Add('start-desktop-task') }
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage fails' $result.Failed
    Check 'it asks for attention' ($result.Error -match 'needs attention before the next live run') $result.Error
    Check 'the debt is not cleared' ($null -ne $script:Machine.ParkState)
}

Test-Scenario 'restore: a daemon answering from somewhere else is not this desktop back' {
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    function Start-DesktopDaemonTask {
        $script:Machine.Log.Add('start-desktop-task')
        # A probe orphan that was still starting during the sweep, answered nothing while it was
        # swept, and bound the pipe immediately afterwards. The restored task then loses the bind
        # and dies while the orphan answers this step's health check -- which is why an answer alone
        # is not the verdict.
        Add-FakeProcess -ProcessId 7777 -ExecutablePath $ProbeExecutable
        $script:Machine.Health = New-FakeHealth -ProcessId 7777
    }
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage fails' $result.Failed
    Check 'it names the impostor' ($result.Error -match 'answered by pid 7777') $result.Error
}

Test-Scenario 'restore: a registration that moved is a damaged machine even with a daemon answering' {
    Set-ParkedMachine
    $script:Machine.DesktopRegistration = 'C:\ProgramData\Axon\live\axon-win.exe'
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage fails' $result.Failed
    Check 'it names both paths' ($result.Error -match 'now points at') $result.Error
}

Test-Scenario 'restore: a desktop that had no daemon is left stopped' {
    Set-ParkedMachine -DaemonWasRunning $false
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it says so' (Test-Said 'leaving it stopped')
    Check 'it started nothing' (-not (Test-Did 'axon daemon restart|start-desktop-task'))
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
}

Test-Scenario 'restore: a health document too old to name a process is tolerated' {
    Set-ParkedMachine
    function Start-DesktopDaemonTask {
        $script:Machine.Log.Add('start-desktop-task')
        Add-FakeProcess -ProcessId $DesktopPid -ExecutablePath $script:Machine.DesktopRegistration
        $script:Machine.Health = New-FakeHealth -ProcessId $DesktopPid
        $script:Machine.Health.daemon.processId = $null
    }
    $script:Machine.RestartFails = $true
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
}

Test-Scenario 'restore: the probe registration goes before the desktop task is started' {
    Set-ParkedMachine
    $script:Machine.ProbeTaskRegistered = $true
    Add-FakeProcess -ProcessId $ProbePid -ExecutablePath $ProbeExecutable
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the probe task is gone' ($script:Machine.ProbeTaskRegistered -eq $false)
    Check 'the probe daemon is gone' (@($script:Machine.Processes | Where-Object { $_.ExecutablePath -eq $ProbeExecutable }).Count -eq 0)
    Test-Order -First 'stop-process' -Then 'axon daemon restart'
    Test-Order -First 'unregister-probe-task' -Then 'axon daemon restart'
}

# ---------------------------------------------------------------------------------------------

if ($script:Failures.Count -ne 0) {
    Write-Host "`n$($script:Failures.Count) failed assertion(s) across $script:ScenarioCount scenarios:`n"
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" }
    exit 1
}

Write-Host "$script:ScenarioCount scenarios passed"
