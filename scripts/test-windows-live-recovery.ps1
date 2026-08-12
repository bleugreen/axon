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
    'Get-DesktopRegistrationPath', 'Get-DesktopTaskState', 'Start-DesktopDaemonTask', 'Register-ProbeTask',
    'Unregister-ProbeTask', 'Start-ProbeTask', 'Invoke-Axon', 'Invoke-AxonMcp', 'Get-ExpectedVersion',
    'Invoke-CargoBuild', 'Copy-ProbeExecutable', 'Read-ParkState', 'Write-ParkState', 'Clear-ParkState'
)

# Commands that reach this machine. A stage may only get to them through a seam, so finding one in
# any other function is the census failing rather than a style note.
$MachineCommands = @(
    'Get-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Start-ScheduledTask',
    'Stop-Process', 'Get-Process', 'Get-CimInstance', 'Start-Sleep', 'Copy-Item', 'Remove-Item',
    'New-Item', 'Set-Content', 'Get-Content', 'Push-Location', 'Pop-Location', 'Write-Host',
    'Write-Warning', 'Write-Output',
    # The external equivalents, which reach the same objects without going through a cmdlet.
    'schtasks', 'taskkill', 'sc', 'reg', 'wmic', 'cargo'
)

$declaredSeams = @()
$inSeamRegion = $false
foreach ($line in Get-Content -LiteralPath $ProbeScript) {
    if ($line -match '^#region seams') { $inSeamRegion = $true; continue }
    if ($line -match '^#endregion') { $inSeamRegion = $false; continue }
    if ($inSeamRegion -and $line -match '^function\s+([\w-]+)') { $declaredSeams += $Matches[1] }
}

# One region, one end. A nested `#endregion` inside the block would end the scan early and leave
# every seam after it neither declared nor flagged.
$regionMarkers = @(Get-Content -LiteralPath $ProbeScript | Where-Object { $_ -match '^#(region|endregion)' })
if ($regionMarkers.Count -ne 2) {
    throw "expected exactly one '#region seams' and one '#endregion' in $ProbeScript, found $($regionMarkers.Count) region markers"
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

# The census above audits the seam region. This audits everything else, which is what makes the
# constraint in the docstring the one actually enforced: a helper added next to a stage that reached
# for `Stop-Process` or `Get-ScheduledTask` inline would otherwise pass through untouched and drive
# a real desktop during the pull-request job that runs this file.
$probeAst = [System.Management.Automation.Language.Parser]::ParseFile($ProbeScript, [ref] $null, [ref] $null)
$functions = $probeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($function in $functions) {
    if ($StubbedSeams -contains $function.Name) { continue }
    $commands = $function.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if ($null -eq $name) {
            # `& $something` -- an executable named by a variable, which is how this lane runs Axon.
            # Allowed in seams, never outside them.
            throw "$($function.Name) invokes a command by variable; only a seam may run an executable, or the harness would run it for real"
        }
        if ($MachineCommands -contains $name) {
            throw "$($function.Name) calls $name directly; move it behind a seam in the '#region seams' block or this harness cannot keep it off a real desktop"
        }
        # `& 'C:\...\axon-win.exe'` names its executable literally rather than through a variable, so
        # the guard above sees a command name and lets it through. Anything that looks like a path to
        # a program belongs in a seam for the same reason everything else here does.
        if ($name -match '[\\/]' -or $name -match '\.exe$') {
            throw "$($function.Name) runs $name directly; only a seam may run an executable, or this harness would run it for real"
        }
    }
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

# The lane logic that lives in the workflow file rather than in a script: the pre-checkout sweep,
# which cannot go through the relay because it runs before the checkout that would deliver it, plus
# the two steps that wrap the relay calls. Nothing else would notice a syntax error in them until a
# push to `main` had already reached the runner. Parsed rather than executed — the sweep talks to
# Task Scheduler and to processes directly, which is exactly what this file may not do. It is read
# as text so this harness needs no YAML module; a `${{ }}` expression in one of these blocks would
# fail the parse, which is the right moment to think about it rather than a false alarm.
$workflowPath = Join-Path $RepositoryRoot '.github\workflows\live.yml'
$workflowLines = @(Get-Content -LiteralPath $workflowPath)
$jobStarts = @(0..($workflowLines.Count - 1) | Where-Object { $workflowLines[$_] -eq '  windows:' })
if ($jobStarts.Count -ne 1) {
    throw "expected exactly one 'windows:' job in $workflowPath, found $($jobStarts.Count)"
}
$jobEnd = $workflowLines.Count
for ($index = $jobStarts[0] + 1; $index -lt $workflowLines.Count; $index++) {
    if ($workflowLines[$index] -match '^  \S') { $jobEnd = $index; break }
}
$jobLines = $workflowLines[$jobStarts[0]..($jobEnd - 1)]

$runBlocks = 0
$sweptRegistration = $false
for ($index = 0; $index -lt $jobLines.Count; $index++) {
    if ($jobLines[$index] -notmatch '^(\s*)run: \|\s*$') { continue }
    $indent = $Matches[1].Length + 2
    $body = @()
    for ($cursor = $index + 1; $cursor -lt $jobLines.Count; $cursor++) {
        $line = $jobLines[$cursor]
        if ($line.Trim() -and -not $line.StartsWith(' ' * $indent)) { break }
        $body += if ($line.Length -ge $indent) { $line.Substring($indent) } else { '' }
    }
    $runBlocks++
    $text = $body -join "`n"
    if ($text -match 'Axon Windows Daemon' -and $text -match 'Get-LiveProbeDaemons') { $sweptRegistration = $true }
    $blockErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $blockErrors) | Out-Null
    if ($blockErrors) {
        throw "a run: block in the windows job does not parse: line $($blockErrors[0].Extent.StartLineNumber): $($blockErrors[0].Message)"
    }
}
# Anchored to the step this exists for rather than to a count, which would drift every time a step
# moved between a block scalar and a one-liner. A pass that checked nothing would otherwise look
# exactly like a pass.
if (-not $sweptRegistration) {
    throw "the windows job's pre-checkout sweep was not among the $runBlocks run: block(s) found; the extractor has drifted from the workflow and is checking nothing"
}

# Every bound in the probe script, shrunk. A scenario that has to sit through the real one is a
# scenario nobody adds.
$ReadinessTimeoutSeconds = 1
$PipeFreeTimeoutSeconds = 1
$ProcessDiscoveryTimeoutSeconds = 1
$RestoreTimeoutSeconds = 1
$TaskInstanceTimeoutSeconds = 1
$ParkStopTimeoutSeconds = 1
# $RestoreStartAttempts and $ParkStopAttempts are deliberately left at their real values. They are
# counts rather than bounds, and how many times each stage will ask -- the restore for a daemon, the
# park for a stop -- is the behaviour under test.

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
        # A daemon that answers every `shutdown` request with the wait having expired and then keeps
        # running: the genuinely stuck daemon the park stage's retry budget exists to tell apart from
        # a slow one.
        ShutdownNeverExits = $false
        # A daemon that acknowledges `shutdown` and then does not exit: the wedged case the sweep
        # exists for, and the only way a probe stage can succeed and still leave a daemon behind.
        ShutdownLeavesProcess = $false
        # A daemon that acknowledges `shutdown` and then takes its time. The pipe goes with the
        # acknowledgement, so the first request reports the wait it performs itself having expired
        # and every request after it finds nothing to stop at all -- while the process is still
        # tearing down behind both. It finally exits during the wait that follows this many requests:
        # 1 is the 2026-08-10 park failure, where the process the stage gave up on was gone moments
        # after, and 2 is that same teardown outlasting one of this lane's own windows, where a
        # request reporting success is reporting on a pipe that went several seconds ago.
        LateExitAfterRequests = 0
        # Bookkeeping for the above rather than knobs. The exit is counted in liveness reads because
        # this harness's Wait-Tick does not sleep.
        ShutdownRequests = 0
        LateExitReads = 0
        LateExitPid = $null
        RestartFails = $false
        BuildFails = $false
        ProbeTaskStartsNothing = $false
        ProbeTaskStartsTwice = $false
        ServingProcessId = $null
        Session = @{ interactive = $true; graphical = $true }
        # Every field the probe stage asserts on is a knob, so that each of those assertions has a
        # scenario that can falsify it. A fake that can only tell the truth makes them unfalsifiable.
        SchemaVersion = 'health-v1'
        Version = $ExpectedVersion
        Platform = 'windows'
        CapabilityCount = 15
        CapabilityWithoutReason = $false
        McpIsError = $false
        StopProcessFails = $false
        # Pids the process table still lists but that are no longer alive. Real, not contrived: the
        # discovery loop reads a CIM snapshot, so a daemon can be found by image path and then be
        # gone by the time anything asks whether it is running.
        DeadPids = @()
        McpResponder = $null
        # Reads of the desktop task's state that report a running instance while nothing is running
        # from the registered path: an instance that has exited but has not finished, which is what
        # makes a start against it a silent no-op. Counted in reads rather than in seconds because
        # this harness's Wait-Tick does not sleep.
        WindingDownReads = 0
        # Starts that launch a daemon which exits before it is ready -- the daemon's own 30-second
        # UIA bound on a machine too slow to meet it.
        StartsThatDie = 0
    }
    Start-FakeDesktopDaemon
}

function Test-FakeDesktopTaskIsRunning {
    <# What Task Scheduler would report for this desktop's registration. The registered action is
    `serve`, so the task runs for exactly as long as the daemon it started is alive. #>
    if ($script:Machine.WindingDownReads -gt 0) { return $true }
    [bool] @($script:Machine.Processes | Where-Object { $_.ExecutablePath -eq $script:Machine.DesktopRegistration })
}

function New-FakeHealth {
    param([int] $ProcessId)

    $capabilities = @(1..$script:Machine.CapabilityCount | ForEach-Object {
        if ($script:Machine.CapabilityWithoutReason -and $_ -eq 1) {
            @{ capability = "capability$_"; usable = $false }
        }
        else {
            @{ capability = "capability$_"; usable = $true }
        }
    })
    @{
        schemaVersion = $script:Machine.SchemaVersion
        version = $script:Machine.Version
        platform = $script:Machine.Platform
        daemon = @{ running = $true; ready = $true; endpoint = '\\.\pipe\axon-v1'; processId = $ProcessId }
        registration = @{ registered = $true; mechanism = 'scheduledTask'; path = $script:Machine.DesktopRegistration }
        session = $script:Machine.Session
        capabilities = $capabilities
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

function Remove-FakeProcess {
    param([Parameter(Mandatory)][int] $ProcessId)

    $script:Machine.Processes = @($script:Machine.Processes | Where-Object { $_.ProcessId -ne $ProcessId })
}

function Clear-FakePipe {
    <# The pipe going while the process is still there.

    Not an edge case to be modelled but the ordinary order of events: a daemon acknowledges
    `shutdown` before its UI Automation thread joins and its COM apartment is torn down, so there is
    always a window in which nothing is answering and the process is still running. #>
    $script:Machine.Health = New-FakeHealth -ProcessId 0
    $script:Machine.Health.daemon = @{ running = $false; ready = $false; endpoint = '\\.\pipe\axon-v1'; processId = $null }
}

function Stop-FakeDaemon {
    if ($null -ne $script:Machine.Health -and $null -ne $script:Machine.Health.daemon.processId) {
        Remove-FakeProcess -ProcessId $script:Machine.Health.daemon.processId
    }
    Clear-FakePipe
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
    if ($script:Machine.DeadPids -contains $ProcessId) { return $false }
    # A daemon on its way out is alive on every read until it isn't, and the read that runs the count
    # out is the one where it is finally gone. Only the process goes here: its pipe went when it
    # acknowledged the request that started all this.
    if ($script:Machine.LateExitReads -gt 0 -and $null -ne $script:Machine.LateExitPid -and $ProcessId -eq $script:Machine.LateExitPid) {
        $script:Machine.LateExitReads--
        if ($script:Machine.LateExitReads -eq 0) { Remove-FakeProcess -ProcessId $script:Machine.LateExitPid }
    }
    [bool] @($script:Machine.Processes | Where-Object { $_.ProcessId -eq $ProcessId })
}

function Get-AxonProcess {
    @($script:Machine.Processes)
}

function Stop-ProcessById {
    param([Parameter(Mandatory)][int] $ProcessId)
    $script:Machine.Log.Add("stop-process $ProcessId")
    if ($script:Machine.StopProcessFails) { throw "Access is denied stopping pid $ProcessId" }
    $script:Machine.Processes = @($script:Machine.Processes | Where-Object { $_.ProcessId -ne $ProcessId })
    if ($null -ne $script:Machine.Health -and $script:Machine.Health.daemon.processId -eq $ProcessId) {
        Stop-FakeDaemon
    }
}

function Get-DesktopRegistrationPath {
    $script:Machine.Log.Add('read-desktop-registration')
    $script:Machine.DesktopRegistration
}

function Get-DesktopTaskState {
    $script:Machine.Log.Add('read-desktop-task-state')
    $running = Test-FakeDesktopTaskIsRunning
    if ($script:Machine.WindingDownReads -gt 0) { $script:Machine.WindingDownReads-- }
    if ($running) { 'Running' } else { 'Ready' }
}

function Start-DesktopDaemonTask {
    $script:Machine.Log.Add('start-desktop-task')
    if (Test-FakeDesktopTaskIsRunning) {
        # Task Scheduler discards a start against a task whose previous instance has not finished,
        # and `schtasks /run` reports success while discarding it. The registration carries no
        # multiple-instances policy, so the default -- IgnoreNew -- is what applies.
        $script:Machine.Log.Add('start-desktop-task-discarded')
        return
    }
    if ($script:Machine.StartsThatDie -gt 0) {
        $script:Machine.StartsThatDie--
        # Started, and gone before it was ready. Task Scheduler is finished with this instance, so
        # the next start is not discarded -- it is simply never issued unless the lane makes one.
        $script:Machine.Log.Add('start-desktop-task-exited')
        return
    }
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
            # What the real command reports when the daemon it asked to stop is still there when its
            # own ten-second wait expires (status::shutdown in rust/axon-win/src/main.rs).
            if ($script:Machine.ShutdownNeverExits) {
                return [pscustomobject]@{
                    ExitCode = 1
                    Output = "daemon process $($script:Machine.Health.daemon.processId) did not exit"
                }
            }
            if ($script:Machine.LateExitAfterRequests -gt 0) {
                $script:Machine.ShutdownRequests++
                if ($script:Machine.ShutdownRequests -eq $script:Machine.LateExitAfterRequests) {
                    # The wait that follows this request is the one the process finally exits during.
                    $script:Machine.LateExitReads = 3
                }
                if ($script:Machine.ShutdownRequests -eq 1) {
                    $script:Machine.LateExitPid = $script:Machine.Health.daemon.processId
                    $asked = $script:Machine.LateExitPid
                    Clear-FakePipe
                    return [pscustomobject]@{ ExitCode = 1; Output = "daemon process $asked did not exit" }
                }
                # And every request after the first finds no pipe at all, which the real command
                # reports as success. It is a true statement about the pipe and says nothing about
                # the process, which is the distinction the park stage has to make.
                return [pscustomobject]@{ ExitCode = 0; Output = 'no daemon was running; registration left in place' }
            }
            if ($script:Machine.ShutdownLeavesProcess) {
                Clear-FakePipe
                return [pscustomobject]@{ ExitCode = 0; Output = 'stopped' }
            }
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
        return @{ result = @{ isError = $script:Machine.McpIsError; structuredContent = @(@{ name = 'Notepad'; identifier = 4242 }) } } |
            ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
    }
    @{
        result = @{
            isError = $false
            content = @(
                @{ type = 'text'; text = '{}' },
                @{ type = 'image'; mimeType = 'image/png'; data = 'cG5n' }
            )
            structuredContent = @{
                id = 'snapshot-1'
                app = @{ windows = @(@{ root = @{ role = 'Window' } }) }
                screenshot = @{ mediaType = 'image/png'; contentTransport = 'mcp_image'; width = 800; height = 600 }
            }
        }
    } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
}

function Get-ExpectedVersion {
    $ExpectedVersion
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

function Get-Count {
    <# How many times exactly this happened. Exact rather than a match, so that a log entry which
    records a call being *discarded* cannot be counted as the call succeeding. #>
    param([Parameter(Mandatory)][string] $Entry)
    @($script:Machine.Log | Where-Object { $_ -eq $Entry }).Count
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
    Check 'it builds' (Test-Did 'cargo-build')
    Check 'it copies the build to the probe path' (Test-Did 'copy-probe-executable')
    Check 'it runs the fresh binary once' (Test-Did 'axon version')
    Check 'it reports the first-execution cost' (Test-Said 'ran it for the first time')
    Check 'it never stops this desktop' (-not (Test-Did 'axon shutdown'))
}

Test-Scenario 'build: leftovers from a killed job go before anything is built' {
    # A daemon a killed job left behind holds its image against the checkout and would answer the
    # pipe for every assertion the probe stage makes.
    Add-FakeProcess -ProcessId 5150 -ExecutablePath $ProbeExecutable
    $script:Machine.ProbeTaskRegistered = $true
    $result = Invoke-StageUnderTest -Name 'build'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the leftover task is gone' ($script:Machine.ProbeTaskRegistered -eq $false)
    Check 'the leftover daemon is gone' (@($script:Machine.Processes | Where-Object { $_.ProcessId -eq 5150 }).Count -eq 0)
    Test-Order -First 'unregister-probe-task' -Then 'cargo-build'
    Test-Order -First 'stop-process 5150' -Then 'cargo-build'
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

Test-Scenario 'park: a desktop registration inside a probe directory is refused' {
    $script:Machine.DesktopRegistration = $ProbeExecutable
    Start-FakeDesktopDaemon
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage fails' $result.Failed
    Check 'it names the repair' ($result.Error -match 'must be reinstalled from its permanent path') $result.Error
    Check 'it stopped nothing' (-not (Test-Did 'axon shutdown'))
    Check 'it recorded nothing' ($null -eq $script:Machine.ParkState)
}

Test-Scenario 'park: a debt an earlier run never paid is carried forward, not erased' {
    # The sequence this exists for: a run parks, the runner service dies before its restore, and the
    # next run arrives at a desktop with no daemon. Recording "there was nothing to put back" would
    # let that run's restore clear the debt and report success, leaving the desktop stopped for the
    # rest of the login session.
    Stop-FakeDaemon
    $script:Machine.ParkState = @{
        recordedAt = (Get-Date).ToString('o')
        desktopTaskName = 'Axon Windows Daemon'
        registrationPath = $DesktopInstallPath
        daemonWasRunning = $true
        daemonProcessId = $DesktopPid
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the debt survives' ($script:Machine.ParkState.daemonWasRunning -eq $true)
    Check 'it says so' (Test-Said 'never restored it; carrying that debt forward')
    Check 'it stopped nothing, since nothing was running' (-not (Test-Did 'axon shutdown'))

    # And the restore that follows actually pays it.
    $restore = Invoke-StageUnderTest -Name 'restore'
    Check 'the restore succeeds' (-not $restore.Failed) $restore.Error
    Check 'the desktop has its daemon back' ($script:Machine.Health.daemon.running -eq $true)
}

Test-Scenario 'park: a running desktop daemon is recorded, then stopped' {
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the state was recorded' ($null -ne $script:Machine.ParkState)
    Check 'it recorded the daemon as running' ($script:Machine.ParkState.daemonWasRunning -eq $true)
    Check 'it recorded the registration' ($script:Machine.ParkState.registrationPath -eq $DesktopInstallPath)
    Test-Order -First 'write-park-state' -Then 'axon shutdown'
    Check 'the pipe is free' ($script:Machine.Health.daemon.running -eq $false)
    Check 'it says so' (Test-Said 'no daemon is answering')
    # A request that reports success is the whole stop, and nothing waits on anything. The scenarios
    # below are what happens when one does not, and this is what says they are the exception.
    Check 'it says the request itself did the stopping' (Test-Said "this desktop's daemon is stopped")
    Check 'it waited on nothing' (-not (Test-Said 'later than the request itself waited'))
}

Test-Scenario 'park: a desktop with no daemon is recorded and left alone' {
    Stop-FakeDaemon
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it recorded the daemon as stopped' ($script:Machine.ParkState.daemonWasRunning -eq $false)
    Check 'it stopped nothing' (-not (Test-Did 'axon shutdown'))
}

Test-Scenario 'park: a daemon slower than the shutdown request is a slow park, not a red run' {
    # The 2026-08-10 failure. `shutdown` waits ten seconds for the process it asked to stop and
    # reports anything slower as a failure; on a runner that had just finished a cargo build, that
    # wait expired, the stage called the run red, and the process exited moments later. The lane's
    # verdict here is the process, not the exit code.
    $script:Machine.LateExitAfterRequests = 1
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it asked once and then waited' ((Get-Count "axon shutdown [$ProbeExecutable]") -eq 1) "asked $(Get-Count "axon shutdown [$ProbeExecutable]") time(s)"
    Check 'it says the exit outran the request' (Test-Said 'later than the request itself waited')
    Check 'the daemon really is gone' (@($script:Machine.Processes | Where-Object { $_.ProcessId -eq $DesktopPid }).Count -eq 0)
    Check 'the pipe is free' ($script:Machine.Health.daemon.running -eq $false)
    Check 'it killed nothing' (-not (Test-Did 'stop-process'))
    Check 'the restore still knows what is owed' ($script:Machine.ParkState.daemonWasRunning -eq $true)
}

Test-Scenario 'park: a request that finds no pipe is not the process this stage is waiting for' {
    # The same teardown, taking longer than one of this lane's own windows. The second request finds
    # the pipe already gone -- it went when the first was acknowledged -- and the real command reports
    # that as success. Believing it would return with the process still running and hand the probe a
    # machine where the daemon this stage set out to stop is still tearing down, which is the race
    # `shutdown`'s own wait exists to prevent.
    $script:Machine.LateExitAfterRequests = 2
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it asked twice' ((Get-Count "axon shutdown [$ProbeExecutable]") -eq 2) "asked $(Get-Count "axon shutdown [$ProbeExecutable]") time(s)"
    Check 'it did not take the second request for an answer about the process' (Test-Said 'found no daemon left to stop')
    Check 'it waited for the process instead' (Test-Said 'later than the request itself waited')
    Check 'the process really is gone' (@($script:Machine.Processes | Where-Object { $_.ProcessId -eq $DesktopPid }).Count -eq 0)
    Check 'the pipe is free' ($script:Machine.Health.daemon.running -eq $false)
    Check 'it killed nothing' (-not (Test-Did 'stop-process'))
}

Test-Scenario 'park: a daemon whose health document names no process id is waited for through the pipe' {
    # A desktop running an old enough release reports a daemon that is up with no process id at all,
    # and the restore tolerates the same gap. With no process to watch, the pipe is the only thing
    # that can say anything at all, so the wait polls the health round trip and accepts what it can
    # know: that nothing is answering.
    $script:Machine.Health.daemon.processId = $null
    $script:Machine.LateExitAfterRequests = 1
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it asked once' ((Get-Count "axon shutdown [$ProbeExecutable]") -eq 1) "asked $(Get-Count "axon shutdown [$ProbeExecutable]") time(s)"
    Check 'it does not report the failed request as a success' (Test-Said 'though the request that asked for it reported otherwise')
    Check 'the pipe is free' ($script:Machine.Health.daemon.running -eq $false)
    Check 'it recorded the pid it did not have as none' ($null -eq $script:Machine.ParkState.daemonProcessId)
    Check 'the restore still knows what is owed' ($script:Machine.ParkState.daemonWasRunning -eq $true)
}

Test-Scenario 'park: a daemon that never exits fails the stage, having already recorded the debt' {
    # The other half of the patience above: a daemon that is not slow but stuck. Every request in the
    # budget is spent, and then the stage fails as loudly as it did before there was a budget --
    # because nothing below could be evidence about this build while that daemon holds the pipe.
    $script:Machine.ShutdownNeverExits = $true
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage fails' $result.Failed
    Check 'it names the stop' ($result.Error -match "could not stop this desktop's daemon") $result.Error
    Check 'it says the daemon is still running' ($result.Error -match 'ended with it still running') $result.Error
    Check 'it spent the whole retry budget and no more' ((Get-Count "axon shutdown [$ProbeExecutable]") -eq $ParkStopAttempts) "asked $(Get-Count "axon shutdown [$ProbeExecutable]") time(s)"
    Check 'it killed nothing' (-not (Test-Did 'stop-process'))
    Check 'the restore still knows what is owed' ($script:Machine.ParkState.daemonWasRunning -eq $true)
}

Test-Scenario 'park: a daemon still answering after the stop is named rather than killed' {
    # This desktop's daemon stops exactly as asked, and something else has the pipe: a probe orphan
    # from an earlier run, still starting while the stop was requested, binding it the moment the
    # desktop's daemon lets go. The stop has nothing left to do, so what catches this is the
    # assertion that nothing is answering -- without it a probe would gather every assertion from a
    # daemon nobody built.
    $original = Get-Item function:Invoke-Axon
    function Invoke-Axon {
        param([string] $Executable, [string[]] $Arguments)
        $result = & $original -Executable $Executable -Arguments $Arguments
        if (($Arguments -join ' ') -eq 'shutdown') {
            Add-FakeProcess -ProcessId 7777 -ExecutablePath $ProbeExecutable
            $script:Machine.Health = New-FakeHealth -ProcessId 7777
        }
        $result
    }
    $result = Invoke-StageUnderTest -Name 'park'
    Check 'the stage fails' $result.Failed
    Check "this desktop's own daemon did stop" (@($script:Machine.Processes | Where-Object { $_.ProcessId -eq $DesktopPid }).Count -eq 0)
    Check 'it names the pid holding the pipe' ($result.Error -match 'still served by pid 7777') $result.Error
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

Test-Scenario 'probe: a sweep it cannot finish does not replace the reason it failed' {
    # A throw from `finally` supersedes the exception in flight. The authorship failure is the fact
    # about the build; the sweep failure is a fact about this lane's own leftovers, and losing the
    # first to the second is how a failure on a machine nobody can attach to becomes expensive to
    # reconstruct.
    Set-ParkedMachine
    $script:Machine.ServingProcessId = 9999
    $script:Machine.StopProcessFails = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it reports the authorship failure' ($result.Error -match 'not the daemon under test') $result.Error
    Check 'and it still says the sweep failed' (Test-Said 'could not remove all of its own daemons')
}

Test-Scenario 'probe: a clean probe that leaves a daemon behind is not a pass' {
    Set-ParkedMachine
    $script:Machine.ShutdownLeavesProcess = $true
    $script:Machine.StopProcessFails = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it says the probe itself succeeded' ($result.Error -match 'the probe succeeded, but this lane left') $result.Error
    Check 'it names the cost' ($result.Error -match 'against the next checkout') $result.Error
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
    $original = Get-Item function:Start-ProbeTask
    function Start-ProbeTask {
        & $original
        # Started, discovered by image path, and then gone -- what a daemon that loses the pipe bind
        # and exits looks like from here. It stays in the process table, because that is what the
        # discovery loop reads, and stops being alive, which is what the readiness loop checks.
        $script:Machine.DeadPids = @($ProbePid)
        $script:Machine.Health = $null
    }
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the exit rather than a timeout' ($result.Error -match 'exited instead of serving the pipe') $result.Error
}

Test-Scenario 'probe: a health document from another schema fails the stage' {
    Set-ParkedMachine
    $script:Machine.SchemaVersion = 'health-v2'
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the schema' ($result.Error -match 'unexpected schemaVersion health-v2') $result.Error
}

Test-Scenario 'probe: a daemon reporting a version the checkout does not expect fails the stage' {
    Set-ParkedMachine
    $script:Machine.Version = '0.0.1'
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names both versions' ($result.Error -match 'status reports version 0.0.1') $result.Error
}

Test-Scenario 'probe: a daemon reporting another platform fails the stage' {
    Set-ParkedMachine
    $script:Machine.Platform = 'linux'
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the platform' ($result.Error -match 'status reports platform linux') $result.Error
}

Test-Scenario 'probe: an unusable capability with no reason fails the stage' {
    Set-ParkedMachine
    $script:Machine.CapabilityWithoutReason = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the capability' ($result.Error -match 'is unusable without a reason') $result.Error
}

Test-Scenario 'probe: an app-list request that errors fails the stage' {
    Set-ParkedMachine
    $script:Machine.McpIsError = $true
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it names the request' ($result.Error -match 'app-list look request failed') $result.Error
}

Test-Scenario "probe: the daemon's own console window is not evidence about a desktop" {
    Set-ParkedMachine
    $script:Machine.McpResponder = {
        param($Request)
        if ($Request -notmatch '"app"') {
            # Task Scheduler runs `serve` as a console process, so the daemon under test is itself
            # an application in this list. A desktop with nothing else running looks exactly like
            # this, and must not pass.
            return @{ result = @{ isError = $false; structuredContent = @(@{ name = $ProbeExecutable }) } } |
                ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
        }
        @{
            result = @{
                isError = $false
                structuredContent = @{
                    id = 'snapshot-1'
                    app = @{ windows = @(@{ root = @{ role = 'Window' } }) }
                    screenshot = @{ mediaType = 'image/png'; base64Data = 'cG5n'; width = 800; height = 600 }
                }
            }
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 100
    }
    $result = Invoke-StageUnderTest -Name 'probe'
    Check 'the stage fails' $result.Failed
    Check 'it says what it looked at' ($result.Error -match 'no Window root with a downscaled PNG from any application this lane did not start') $result.Error
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
    Check 'it touched nothing' (-not (Test-Did '^(axon |stop-process|start-desktop-task|register-probe-task|unregister-probe-task)'))
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
    # The other half of the patience below: a budget that never expires is a lane that hangs instead
    # of reporting a machine nobody can fix from here.
    Check 'it spent the whole retry budget and no more' ((Get-Count 'start-desktop-task') -eq $RestoreStartAttempts) "started it $(Get-Count 'start-desktop-task') time(s)"
}

Test-Scenario 'restore: a start is not issued against an instance that has not finished' {
    # Run 31339688217, in the shape that burned it. A background Windows servicing operation made
    # this desktop unusably slow for three minutes; the daemon `daemon restart` started exited on its
    # own 30-second UIA readiness bound, and the lane's one fallback start landed on a task whose
    # previous instance had not finished. Task Scheduler discards a start in that window -- silently,
    # and reporting success -- so nothing started at all, and the poll that followed was waiting for
    # a daemon nobody had launched.
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    $script:Machine.WindingDownReads = 3
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'it read the task state before starting it' ((Get-Position 'read-desktop-task-state') -ge 0)
    Test-Order -First 'read-desktop-task-state' -Then 'start-desktop-task'
    Check 'it issued no start Task Scheduler would discard' ((Get-Count 'start-desktop-task-discarded') -eq 0)
    Check 'it started the task once the instance had finished' ((Get-Count 'start-desktop-task') -eq 1) "started it $(Get-Count 'start-desktop-task') time(s)"
    Check 'the desktop has its daemon back' ($script:Machine.Health.daemon.running -eq $true)
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
}

Test-Scenario 'restore: a start whose daemon dies under load is followed by another' {
    # The daemon's 30-second UIA readiness bound is fail-fast by design, so a machine slow enough to
    # blow it produces a start that launches a process and still leaves nothing answering. That is
    # the daemon behaving correctly; a lane with one start turns it into a red run.
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    $script:Machine.StartsThatDie = 1
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage succeeds' (-not $result.Failed) $result.Error
    Check 'the first start produced nothing' ((Get-Count 'start-desktop-task-exited') -eq 1)
    Check 'it says so' (Test-Said 'nothing answered within')
    Check 'it started the task again' ((Get-Count 'start-desktop-task') -eq 2) "started it $(Get-Count 'start-desktop-task') time(s)"
    Check 'the desktop has its daemon back' ($script:Machine.Health.daemon.running -eq $true)
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
}

Test-Scenario 'restore: an instance that never finishes fails rather than being started over' {
    # A task that reports a running instance while nothing answers is a machine that needs a human.
    # Every start here would be discarded, so making them would only make the failure quieter.
    Set-ParkedMachine
    $script:Machine.RestartFails = $true
    $script:Machine.WindingDownReads = [int]::MaxValue
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage fails' $result.Failed
    Check 'it asks for attention' ($result.Error -match 'needs attention before the next live run') $result.Error
    Check 'it started nothing that would have been discarded' ((Get-Count 'start-desktop-task') -eq 0)
    Check 'it says what it was waiting for' (Test-Said 'a start now would be discarded')
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

Test-Scenario 'restore: a hand-started daemon with no registration is named, not retried forever' {
    Set-ParkedMachine
    $script:Machine.ParkState = @{
        recordedAt = (Get-Date).ToString('o')
        desktopTaskName = 'Axon Windows Daemon'
        registrationPath = $null
        daemonWasRunning = $true
        daemonProcessId = $DesktopPid
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage fails' $result.Failed
    Check 'it says the daemon was started by hand' ($result.Error -match 'started by hand and this lane cannot put it back') $result.Error
    Check 'it does not wedge every future run' ($null -eq $script:Machine.ParkState)
    Check 'it started nothing' (-not (Test-Did 'start-desktop-task'))
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

Test-Scenario 'restore: a sweep that cannot finish still gives the desktop its daemon back' {
    # Remove-ProbeInstallation throws when a probe daemon survives every kill attempt. Letting that
    # propagate would end the job with this desktop stopped and a message about the leftover that
    # never mentions it.
    Set-ParkedMachine
    Add-FakeProcess -ProcessId 5150 -ExecutablePath $ProbeExecutable
    $script:Machine.StopProcessFails = $true
    $result = Invoke-StageUnderTest -Name 'restore'
    Check 'the stage still fails, because a leftover breaks the next checkout' $result.Failed
    Check 'but it says the desktop is back first' ($result.Error -match "desktop's daemon is back") $result.Error
    Check 'the desktop daemon is answering' ($script:Machine.Health.daemon.running -eq $true)
    Check 'the debt is cleared' ($null -eq $script:Machine.ParkState)
    Test-Order -First 'warning: this lane could not remove' -Then 'axon daemon restart'
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
