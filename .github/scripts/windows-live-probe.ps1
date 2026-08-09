#Requires -Version 7

<#
.SYNOPSIS
One stage of the Windows live desktop verification lane.

.DESCRIPTION
A live runner is also somebody's desktop. This lane borrows exactly one thing from it -- the
single named pipe one daemon at a time can hold -- and it borrows nothing else. It never
unregisters, rewrites, or repoints `Axon Windows Daemon`, the machine's own start-at-login
registration. The daemon under test runs from a scheduled task of the probe's own, and the
desktop's task is read, started, and otherwise left exactly where it was found.

That rule is not fastidiousness. The earlier probe registered the machine's task at a freshly
built binary under C:\ProgramData\Axon\live, and on 2026-08-08 Defender's behavioural detection
classified that binary as execution and persistence malware. Remediation quarantined the exe
mid-run; on an earlier detection it removed C:\Windows\System32\Tasks\Axon Windows Daemon and its
TaskCache registry keys as well. A registration that names a never-seen binary is a registration a
security product may delete, so the desktop's own must never name one. Every fresh CI build is a
never-seen binary.

The stages are separate steps so that the restore is reachable when the probe is not. Each is one
`ssh` call across the forced-command relay, and the restore step runs under `if: always()` -- which
a `finally` block inside a single remote call cannot substitute for, because a cancelled job kills
the `ssh` client and the remote shell with it.

  build    sweep leftovers, compile axon-win, copy it to the permanent probe path, and prove the
           copy runs -- all before anything on this desktop is touched
  park     record what this desktop looks like, then stop its daemon so the pipe is free
  probe    register and start the probe's own task, prove the daemon answering is the one it
           started, and read a real window off the interactive desktop
  restore  remove everything the probe registered and give the desktop its daemon back, with a
           health round trip as the verdict

The stage bodies are driven against stubbed seams by scripts/test-windows-live-recovery.ps1, which
dot-sources this file. Anything that touches the machine therefore lives in a named function rather
than inline, and the entry point at the bottom runs only when this file is executed as a script.
#>

[CmdletBinding()]
param(
    [ValidateSet('build', 'park', 'probe', 'restore')]
    [string] $Stage
)

$ErrorActionPreference = 'Stop'
# Native command failures are read from $LASTEXITCODE at each call site rather than thrown, because
# the restore stage deliberately records one command's status instead of trusting it: whatever
# starts a daemon reports on starting it, and the health round trip is the verdict.
$PSNativeCommandUseErrorActionPreference = $false

# The machine's own registration, written by `axon-win daemon install` (TASK_NAME in
# rust/axon-win/src/lifecycle.rs). Named here only so this lane can read it and start it back.
$DesktopTaskName = 'Axon Windows Daemon'
# The probe's own, and deliberately a different name: a probe task Defender removes as persistence
# is a probe task, and `status`, `daemon restart`, and `daemon uninstall` cannot see it at all.
# It carries no trigger, so a logon during or after a run can never start the build under test as
# somebody's start-at-login daemon.
$ProbeTaskName = 'Axon Live Probe Daemon'
$LiveDirectory = 'C:\ProgramData\Axon\live'
# Outside the runner workspace on purpose: a running process locks its image on Windows, so a
# daemon started from the checkout survives its job and breaks the next checkout (AXN-38).
$ProbeExecutable = Join-Path $LiveDirectory 'axon-win.exe'
$StateFile = Join-Path $LiveDirectory 'park-state.json'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BuildDirectory = Join-Path $RepositoryRoot 'rust\target\debug'
# Where a daemon this lane started can be running from. The sweep is scoped to these rather than to
# the process name so it can never reach the release the desktop user installed. The runner
# workspace is named literally as well as derived, so a daemon leaked by an older checkout is still
# in scope.
$ProbeRoots = @($LiveDirectory, $BuildDirectory, 'C:\actions-runner-axon\_work')

# Named rather than inline so scripts/test-windows-live-recovery.ps1 can shrink them; every one of
# them bounds a wait on a machine, and a scenario that has to sit through the real bound would be a
# scenario nobody adds.
$ReadinessTimeoutSeconds = 90
$PipeFreeTimeoutSeconds = 30
$ProcessDiscoveryTimeoutSeconds = 60
$RestoreTimeoutSeconds = 60

#region seams -- everything below this line that touches the machine

function Write-Note {
    <# Every human-readable line this lane emits.

    A function rather than `Write-Output` because these lines are a log, not a return value: a stage
    helper that both reports and answers would otherwise hand its caller the report as part of the
    answer. It is also the seam the recovery harness reads what each scenario said through. #>
    param([Parameter(Mandatory)][string] $Message)

    Write-Host $Message
}

function Wait-Tick {
    Start-Sleep -Milliseconds 250
}

function Test-ProcessIsRunning {
    param([Parameter(Mandatory)][int] $ProcessId)

    $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-AxonProcess {
    <# Every axon-win process on this machine, this lane's and this desktop's alike. #>
    @(Get-CimInstance Win32_Process -Filter "Name = 'axon-win.exe'")
}

function Stop-ProcessById {
    param([Parameter(Mandatory)][int] $ProcessId)

    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
}

function Get-DesktopRegistrationPath {
    <# The executable Task Scheduler will run for this desktop, or $null when nothing is registered. #>
    $task = Get-ScheduledTask -TaskName $DesktopTaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    $execute = @($task.Actions)[0].Execute
    if ([string]::IsNullOrWhiteSpace($execute)) { return $null }
    $execute.Trim().Trim('"')
}

function Start-DesktopDaemonTask {
    Start-ScheduledTask -TaskName $DesktopTaskName
}

function Register-ProbeTask {
    $action = New-ScheduledTaskAction -Execute $ProbeExecutable -Argument 'serve'
    # `Interactive` is what puts the daemon on the logged-in desktop. This script runs in session 0
    # -- the relay is an SSH shell -- where UI Automation can bind the pipe and answer requests
    # while being structurally unable to see a single window, which is the failure mode that makes a
    # remote-shell launch look like it worked. No trigger is registered: the task exists only to be
    # started on demand by the stage below.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $ProbeTaskName -Action $action -Principal $principal -Force | Out-Null
}

function Unregister-ProbeTask {
    Unregister-ScheduledTask -TaskName $ProbeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-ProbeTask {
    Start-ScheduledTask -TaskName $ProbeTaskName
}

function Invoke-Axon {
    <# Runs an Axon command and returns its exit code and output instead of throwing.

    Output is deliberately not redirected. `*> $null` on a native command that fails to *start*
    makes PowerShell report "StandardOutputEncoding is only supported when standard output is
    redirected" in place of the real reason -- which on 2026-08-08 hid "the file contains a virus or
    potentially unwanted software" behind a message about encoding. #>
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    if (-not (Test-Path -LiteralPath $Executable)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "$Executable does not exist" }
    }
    try {
        $output = & $Executable @Arguments
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    catch {
        [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    }
}

function Invoke-AxonMcp {
    <# One MCP request through the daemon under test, as a parsed response. #>
    param([Parameter(Mandatory)][string] $Request)

    $Request | & $ProbeExecutable mcp | ConvertFrom-Json -Depth 100
}

function Invoke-CargoBuild {
    Push-Location (Join-Path $RepositoryRoot 'rust')
    try {
        if (-not $env:CARGO_HOME) { $env:CARGO_HOME = Join-Path $env:USERPROFILE '.cargo' }
        if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = Join-Path $env:USERPROFILE '.rustup' }
        $env:Path = "$env:CARGO_HOME\bin;$env:Path"
        cargo build --locked -p axon-win
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

function Copy-ProbeExecutable {
    New-Item -ItemType Directory -Path $LiveDirectory -Force | Out-Null
    Copy-Item (Join-Path $BuildDirectory 'axon-win.exe') $ProbeExecutable -Force
}

function Read-ParkState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}

function Write-ParkState {
    param([Parameter(Mandatory)][hashtable] $State)

    New-Item -ItemType Directory -Path $LiveDirectory -Force | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding utf8
}

function Clear-ParkState {
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

#endregion

function Get-ProbeDaemonProcess {
    <# Live axon-win processes running from a directory this lane owns.

    Scoped by path rather than by process name so the sweep below can never reach the release the
    desktop user installed, which runs under the same name from a directory this lane never writes. #>
    $roots = $ProbeRoots | ForEach-Object { if ($_.EndsWith('\')) { $_ } else { "$_\" } }
    @(Get-AxonProcess |
        Where-Object {
            $path = $_.ExecutablePath
            $null -ne $path -and ($roots | Where-Object {
                $path.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            })
        } |
        Where-Object { Test-ProcessIsRunning -ProcessId $_.ProcessId })
}

function Get-ProcessByExecutable {
    param([Parameter(Mandatory)][string] $Executable)

    @(Get-AxonProcess |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($Executable, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Get-AxonStatus {
    <# The first candidate that answers with a health document, or $null.

    More than one candidate because the restore stage must work when the build under test has
    vanished mid-run: the executable the desktop's own registration names is always the fallback,
    and it is the one release guaranteed to be able to read its own daemon's reply. #>
    param([Parameter(Mandatory)][string[]] $Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $result = Invoke-Axon -Executable $candidate -Arguments @('status', '--json')
        if ($result.ExitCode -ne 0) { continue }
        try { return $result.Output | ConvertFrom-Json -Depth 100 }
        catch { continue }
    }
    $null
}

function Stop-ProbeDaemonProcess {
    <# Leaves no axon-win running from a directory this lane owns.

    `shutdown` cannot be the whole answer: it stops a daemon by asking it to, so it can neither see
    nor stop a probe daemon that never bound the pipe -- and one that bound and then wedged would
    still hold it against the restored desktop daemon. #>
    foreach ($attempt in 1..5) {
        foreach ($process in Get-ProbeDaemonProcess) {
            Write-Note "stopping live-probe daemon pid=$($process.ProcessId) path=$($process.ExecutablePath)"
            try { Stop-ProcessById -ProcessId $process.ProcessId }
            catch { Write-Note "warning: could not stop pid=$($process.ProcessId) on attempt ${attempt}: $_" }
        }
        if ((Get-ProbeDaemonProcess).Count -eq 0) { return }
        Wait-Tick
    }

    $remaining = Get-ProbeDaemonProcess
    if ($remaining.Count -ne 0) {
        throw "live-probe daemons remain: $(($remaining | ForEach-Object { "pid=$($_.ProcessId) $($_.ExecutablePath)" }) -join ', ')"
    }
}

function Assert-DesktopRegistrationIsNotAProbePath {
    <# Refuses to sweep when the desktop's registration points into a directory this lane owns.

    That state means an earlier run repointed it -- the defect this lane is built to make
    impossible -- and sweeping by path would then stop the desktop's own daemon and call it a
    leftover. Naming it is the repair instruction; guessing would hide it. #>
    param([string] $RegistrationPath)

    if ([string]::IsNullOrWhiteSpace($RegistrationPath)) { return }
    foreach ($root in $ProbeRoots) {
        $prefix = if ($root.EndsWith('\')) { $root } else { "$root\" }
        if ($RegistrationPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$DesktopTaskName is registered at $RegistrationPath, inside this lane's own $root; an earlier run repointed this desktop's start-at-login registration and it must be reinstalled from its permanent path before this lane can run again"
        }
    }
}

function Assert-DaemonUnderTest {
    <# The pipe is a rendezvous, not a proof of authorship.

    Every subcommand except `serve` is a client, so a probe that starts its own daemon and then
    talks to the pipe is answered by whichever daemon holds it -- routinely the release the desktop
    user already runs, which on this machine is built from this repository and reports a version
    string a comparison cannot tell apart. The health reply carries the serving process's own id, so
    requiring it to equal the process this stage started is the exact check: it fails when the bind
    was lost, when the daemon died after binding, and when a stale daemon answered in its place.

    The bash sibling scripts/assert-daemon-under-test does this for the Linux and macOS lanes. It
    cannot be reused here: the relay's environment is PowerShell in session 0, with no jq. #>
    param([Parameter(Mandatory)][int] $ExpectedProcessId)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = $null
    while ($timer.Elapsed.TotalSeconds -lt $ReadinessTimeoutSeconds) {
        if (-not (Test-ProcessIsRunning -ProcessId $ExpectedProcessId)) {
            throw "the daemon under test (pid $ExpectedProcessId) exited instead of serving the pipe"
        }
        $status = Get-AxonStatus -Candidates @($ProbeExecutable)
        if ($null -ne $status -and $status.daemon.running -and $status.daemon.ready) { break }
        $status = $null
        Wait-Tick
    }
    if ($null -eq $status) {
        throw "the daemon under test (pid $ExpectedProcessId) never became ready within $ReadinessTimeoutSeconds seconds"
    }
    if ($status.daemon.processId -ne $ExpectedProcessId) {
        throw "$($status.daemon.endpoint) is served by pid $($status.daemon.processId), not the daemon under test (pid $ExpectedProcessId); every assertion after this would describe that daemon instead of this build"
    }
    Write-Note "the daemon under test (pid $ExpectedProcessId) is serving $($status.daemon.endpoint) after $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds"
    $status
}

function Invoke-BuildStage {
    # Leftovers first. A daemon left by a job the runner killed holds its image file open, which
    # breaks the next checkout, and it would answer the pipe for every assertion below.
    Assert-DesktopRegistrationIsNotAProbePath -RegistrationPath (Get-DesktopRegistrationPath)
    Unregister-ProbeTask
    Stop-ProbeDaemonProcess

    Invoke-CargoBuild
    Copy-ProbeExecutable

    # The first execution of a never-seen binary, run here on purpose: Defender's block-at-first-
    # sight holds it for up to a minute and can escalate to quarantine, and this is the last moment
    # at which that costs nothing -- this desktop still has its own daemon and nothing has been
    # borrowed. It also keeps the readiness measurement in the probe stage honest, since the scan is
    # paid here rather than being counted as daemon startup.
    $expectedVersion = (Get-Content (Join-Path $RepositoryRoot 'VERSION')).Trim()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $version = Invoke-Axon -Executable $ProbeExecutable -Arguments @('version')
    $timer.Stop()
    if ($version.ExitCode -ne 0) {
        throw "the freshly built $ProbeExecutable could not be run: $($version.Output)"
    }
    if ($version.Output.Trim() -ne $expectedVersion) {
        throw "version reports $($version.Output.Trim()), expected $expectedVersion"
    }
    Write-Note "built $ProbeExecutable and ran it for the first time in $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds (version $expectedVersion)"
}

function Invoke-ParkStage {
    # What this desktop looks like before anything is borrowed. The registration is recorded to be
    # asserted unchanged later, never to be rewritten: this stage does not unregister, disable, or
    # repoint it.
    $registrationPath = Get-DesktopRegistrationPath
    Assert-DesktopRegistrationIsNotAProbePath -RegistrationPath $registrationPath
    $status = Get-AxonStatus -Candidates @($ProbeExecutable, $registrationPath)
    $wasRunning = $null -ne $status -and $status.daemon.running

    # Written before the daemon is stopped, so a park that dies halfway still tells the restore what
    # it owes. A park that dies before this point has taken nothing.
    Write-ParkState -State @{
        recordedAt = (Get-Date).ToString('o')
        desktopTaskName = $DesktopTaskName
        registrationPath = $registrationPath
        daemonWasRunning = $wasRunning
        daemonProcessId = if ($wasRunning) { $status.daemon.processId } else { $null }
    }
    Write-Note "found this desktop as: registration=$(if ($registrationPath) { $registrationPath } else { 'none' }), daemon running=$wasRunning$(if ($wasRunning) { " (pid $($status.daemon.processId))" })"

    if (-not $wasRunning) {
        Write-Note 'no daemon is answering on the Axon pipe'
        return
    }

    # The build under test does the stopping, and deliberately not the installed release: a runner's
    # installed CLI is whichever release it last installed, so a verb that release predates fails
    # there. Untolerated, because `shutdown` exits non-zero while anything is still answering, which
    # is what makes its success the pipe-is-free guarantee the probe stage depends on.
    $shutdown = Invoke-Axon -Executable $ProbeExecutable -Arguments @('shutdown')
    if ($shutdown.ExitCode -ne 0) {
        throw "could not stop this desktop's daemon: $($shutdown.Output)"
    }

    # Stopping is asynchronous, and anything still answering here would answer the probe too. This
    # names it rather than killing a process the job has no way to put back.
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $PipeFreeTimeoutSeconds) {
        $status = Get-AxonStatus -Candidates @($ProbeExecutable, $registrationPath)
        if ($null -ne $status -and -not $status.daemon.running) {
            Write-Note 'no daemon is answering on the Axon pipe'
            return
        }
        Wait-Tick
    }
    if ($null -eq $status) {
        throw "nothing on this machine could report whether the Axon pipe is free after this desktop's daemon was stopped"
    }
    throw "$($status.daemon.endpoint) is still served by pid $($status.daemon.processId) after this desktop's daemon was stopped; nothing below could be evidence about this build while it holds the pipe"
}

function Invoke-ProbeStage {
    $state = Read-ParkState
    if ($null -eq $state) {
        throw 'this desktop was never parked; refusing to start a daemon on a machine whose own may still hold the pipe'
    }
    $expectedVersion = (Get-Content (Join-Path $RepositoryRoot 'VERSION')).Trim()

    try {
        # The probe's own registration, at its own name. `daemon install` is deliberately not used:
        # it writes the machine's name, which is what repointed this desktop's start-at-login
        # registration at a quarantined build and left it with nothing to start.
        Register-ProbeTask
        Write-Note "registered $ProbeTaskName -> $ProbeExecutable"
        Start-ProbeTask

        # Task Scheduler reports nothing about the process it launched, so the daemon under test is
        # found by its image path -- which no installed copy shares. Exactly one is required: a
        # second would be a leftover from an earlier run, and choosing between them would be a guess.
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $processes = @()
        while ($timer.Elapsed.TotalSeconds -lt $ProcessDiscoveryTimeoutSeconds) {
            $processes = Get-ProcessByExecutable -Executable $ProbeExecutable
            if ($processes.Count -ge 1) { break }
            Wait-Tick
        }
        if ($processes.Count -eq 0) {
            throw "nothing is running $ProbeExecutable; $ProbeTaskName never launched the daemon under test"
        }
        if ($processes.Count -ne 1) {
            throw "$ProbeExecutable is running as pids $(($processes.ProcessId) -join ', '); an earlier run left one behind, and which of them answers the pipe is a guess"
        }
        $daemonProcessId = [int] $processes[0].ProcessId

        # Everything below is a client of the pipe, so this is what makes the document evidence
        # about the daemon this stage started rather than about whichever one is listening.
        $status = Assert-DaemonUnderTest -ExpectedProcessId $daemonProcessId

        # The published contract, checked against a real interactive desktop rather than a fixture.
        if ($status.schemaVersion -ne 'health-v1') { throw "unexpected schemaVersion $($status.schemaVersion)" }
        if ($status.version -ne $expectedVersion) { throw "status reports version $($status.version), expected $expectedVersion" }
        if ($status.platform -ne 'windows') { throw "status reports platform $($status.platform)" }
        if (-not $status.session.interactive -or -not $status.session.graphical) {
            throw "the daemon is not on the interactive desktop: $($status.session | ConvertTo-Json -Compress)"
        }
        # The registration this document reports is the desktop's own, because the probe's task
        # carries a different name. Requiring it to be exactly what the park stage recorded is what
        # proves this lane did not repoint the machine while borrowing its pipe.
        if ($status.registration.path -ne $state.registrationPath) {
            throw "$DesktopTaskName now points at $($status.registration.path), but this desktop was parked with $($state.registrationPath); this lane must never repoint the machine's registration"
        }
        # The complete vocabulary, so 'unusable here' stays distinguishable from 'older than yours'.
        if ($status.capabilities.Count -ne 15) {
            throw "expected the complete capability vocabulary, got $($status.capabilities.Count)"
        }
        foreach ($capability in $status.capabilities) {
            if (-not $capability.usable -and [string]::IsNullOrEmpty($capability.reason)) {
                throw "$($capability.capability) is unusable without a reason"
            }
        }
        Write-Note "status ok: version=$($status.version) ready=$($status.daemon.ready) capabilities=$($status.capabilities.Count) registration=$($status.registration.path)"

        $listRequest = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"look","arguments":{}}}'
        $listResponse = Invoke-AxonMcp -Request $listRequest
        if ($listResponse.result.isError -ne $false) { throw 'the app-list look request failed' }

        $verified = $null
        foreach ($app in $listResponse.result.structuredContent) {
            $request = @{
                jsonrpc = '2.0'
                id = 1
                method = 'tools/call'
                params = @{ name = 'look'; arguments = @{ app = $app.name } }
            } | ConvertTo-Json -Compress -Depth 10
            $response = Invoke-AxonMcp -Request $request
            $window = $response.result.structuredContent.app.windows |
                ForEach-Object root | Where-Object role -eq 'Window' | Select-Object -First 1
            if ($response.result.isError -eq $false -and $null -ne $window) {
                $verified = @{ response = $response; window = $window; app = $app.name }
                break
            }
        }
        if ($null -eq $verified) { throw 'look did not return a Window root from the interactive desktop' }
        Write-Note "isError:false snapshot=$($verified.response.result.structuredContent.id) root=$($verified.window.role) app=$($verified.app)"
    }
    finally {
        # The probe's own registration and daemon go now rather than in the restore stage, so that a
        # job which never reaches the restore still leaves nothing of this lane's registered. The
        # restore repeats both, because a stage that dies here reaches neither.
        Remove-ProbeInstallation
    }
}

function Remove-ProbeInstallation {
    <# Everything this lane registered or started, removed idempotently. #>
    $shutdown = Invoke-Axon -Executable $ProbeExecutable -Arguments @('shutdown')
    if ($shutdown.ExitCode -ne 0) {
        # Tolerated here alone: a probe daemon that already exited and one that never started look
        # the same to `shutdown`, and the sweep below is what actually guarantees the outcome.
        Write-Note "the probe daemon did not answer shutdown: $($shutdown.Output)"
    }
    Unregister-ProbeTask
    Stop-ProbeDaemonProcess
}

function Invoke-RestoreStage {
    $state = Read-ParkState
    if ($null -eq $state) {
        Write-Note 'this desktop was never parked; leaving it alone'
        return
    }

    # Anything of this lane's still here belongs to the probe, because the desktop's own daemon was
    # stopped at park. It has to go before the desktop's task is started, or the restored daemon
    # starts into a pipe that is already taken.
    Remove-ProbeInstallation

    if (-not $state.daemonWasRunning) {
        Write-Note 'this desktop had no Axon daemon when the job arrived; leaving it stopped'
        Clear-ParkState
        return
    }

    # `daemon restart` restarts the registration that is on disk without rewriting it
    # (rust/axon-win/src/main.rs), so it cannot repoint this desktop even though it is being run
    # from the build under test. Its status is recorded rather than acted on: it ends with a
    # readiness wait that parses the reply with *this* build's decoder, so a desktop running an
    # older release could fail it while coming back perfectly.
    $restart = Invoke-Axon -Executable $ProbeExecutable -Arguments @('daemon', 'restart')
    Write-Note "daemon restart exited $($restart.ExitCode): $($restart.Output)"
    if ($restart.ExitCode -ne 0) {
        # The build under test can be gone -- quarantined mid-run is exactly how this lane's worst
        # day started -- and this desktop's daemon must come back regardless. Task Scheduler starts
        # the registration at its own path and needs no Axon binary at all.
        Write-Note "starting $DesktopTaskName through Task Scheduler instead"
        Start-DesktopDaemonTask
    }

    # Neither command is trusted on its exit code: both report on starting a daemon, not on one
    # serving. The verdict is a health round trip, read through the build under test when it can
    # still run and through the executable this desktop's own registration names when it cannot.
    $candidates = @($ProbeExecutable, $state.registrationPath)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = $null
    while ($timer.Elapsed.TotalSeconds -lt $RestoreTimeoutSeconds) {
        $status = Get-AxonStatus -Candidates $candidates
        if ($null -ne $status -and $status.daemon.running) { break }
        $status = $null
        Wait-Tick
    }
    if ($null -eq $status) {
        throw "this desktop's Axon daemon did not come back; this runner needs attention before the next live run"
    }

    # The registration has to be what it was, or this lane damaged the machine even though a daemon
    # is answering.
    if (-not $status.registration.registered -or $status.registration.path -ne $state.registrationPath) {
        throw "$DesktopTaskName now points at $($status.registration.path), but this desktop was parked with $($state.registrationPath)"
    }

    # A daemon answering is not this desktop's daemon answering. A probe orphan can be mid-startup
    # during the sweep, answer nothing, and bind immediately afterwards -- at which point the
    # restored task loses the pipe and dies while the orphan answers this check. Requiring the
    # serving pid to be a process running from the registered path is what rules that out. A missing
    # pid is tolerated rather than required: a desktop running an older release can report a daemon
    # that is up with no process id at all.
    if ($null -ne $status.daemon.processId) {
        $registered = @(Get-ProcessByExecutable -Executable $state.registrationPath |
            Where-Object { $_.ProcessId -eq $status.daemon.processId })
        if ($registered.Count -eq 0) {
            throw "$($status.daemon.endpoint) is answered by pid $($status.daemon.processId), which is not running $($state.registrationPath); this desktop's own daemon is still not back"
        }
    }

    Clear-ParkState
    Write-Note "this desktop's Axon daemon is answering again (pid $($status.daemon.processId), version $($status.version), registration $($status.registration.path))"
}

function Invoke-Stage {
    param([Parameter(Mandatory)][ValidateSet('build', 'park', 'probe', 'restore')][string] $Name)

    switch ($Name) {
        'build' { Invoke-BuildStage }
        'park' { Invoke-ParkStage }
        'probe' { Invoke-ProbeStage }
        'restore' { Invoke-RestoreStage }
    }
}

# Runs only when this file is executed. scripts/test-windows-live-recovery.ps1 dot-sources it to
# drive the stages against stubbed seams, and must not run one on import.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Stage)) {
        Write-Note '::error::windows-live-probe.ps1 requires -Stage <build|park|probe|restore>'
        exit 2
    }
    try {
        Invoke-Stage -Name $Stage
    }
    catch {
        Write-Note "::error::$($_.Exception.Message)"
        exit 1
    }
}
