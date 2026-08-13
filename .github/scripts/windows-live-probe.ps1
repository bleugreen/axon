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

  build    sweep leftovers, compile the CLI and daemon, copy both to the permanent probe path, and
           prove the CLI runs -- all before anything on this desktop is touched
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
$ProbeBrowserTaskName = 'Axon Live Probe Browser'
$ProbeActivationTaskName = 'Axon Live Probe Prior Activation'
$ProbeForegroundTaskName = 'Axon Live Probe Foreground Sweep'
$LiveDirectory = 'C:\ProgramData\Axon\live'
# Outside the runner workspace on purpose: a running process locks its image on Windows, so a
# daemon started from the checkout survives its job and breaks the next checkout (AXN-38).
$ProbeCliExecutable = Join-Path $LiveDirectory 'axon-win.exe'
$ProbeDaemonExecutable = Join-Path $LiveDirectory 'axon-win-daemon.exe'
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
# How long one start of this desktop's own registration is given to produce a daemon that answers,
# and how many such starts the restore will make before it gives up. Three of them, because the
# machine underneath is somebody's desktop and can be busy for minutes at a time: on 2026-08-09 a
# background Windows servicing operation made this one 10 to 100 times slower for three minutes, and
# a restore with a single fallback start failed on a machine that answered a start in 40
# milliseconds four minutes later.
$RestoreTimeoutSeconds = 60
$RestoreStartAttempts = 3
# How long the park stage waits for a daemon that outlived its own shutdown request to be gone, and
# how many such requests it will make before calling that daemon stuck. `shutdown` carries a
# ten-second wait of its own (status::shutdown in rust/axon-win/src/main.rs) and reports a process
# slower than that as a failure, which is fail-fast behaviour worth keeping in the daemon and worth
# not believing here: on 2026-08-10 that wait expired on a runner that had just finished a cargo
# build, the process exited seconds later, and the lane went red while the desktop was healthy. The
# patience belongs in this lane for the same reason the restore's does.
$ParkStopTimeoutSeconds = 20
$ParkStopAttempts = 3
# How long a start waits for an instance of the task that has not finished. A start issued in that
# window is discarded rather than queued, so waiting is the only thing that makes the next one real.
$TaskInstanceTimeoutSeconds = 30

#region seams -- everything below this line that touches the machine

function Write-Note {
    <# Every human-readable line this lane emits.

    A function rather than `Write-Output` because these lines are a log, not a return value: a stage
    helper that both reports and answers would otherwise hand its caller the report as part of the
    answer. It is also the seam the recovery harness reads what each scenario said through. #>
    param([Parameter(Mandatory)][string] $Message)

    Write-Host $Message
}

function Register-ProbeForegroundTask {
    param([Parameter(Mandatory)][int] $TargetProcessId, [Parameter(Mandatory)][string] $ResultPath)
    $escapedExecutable = $ProbeCliExecutable.Replace("'", "''")
    $escapedResultPath = $ResultPath.Replace("'", "''")
    $escapedTemporaryPath = ("$ResultPath.tmp").Replace("'", "''")
    $command = @"
`$start = [System.Diagnostics.ProcessStartInfo]::new()
`$start.FileName = '$escapedExecutable'
# The Interactive task intentionally uses Windows PowerShell 5.1. Its .NET Framework
# ProcessStartInfo has Arguments but not the newer ArgumentList collection.
`$start.Arguments = 'probe foreground $TargetProcessId'
`$start.UseShellExecute = `$false
`$start.RedirectStandardOutput = `$true
`$start.RedirectStandardError = `$true
`$process = [System.Diagnostics.Process]::Start(`$start)
`$stdoutTask = `$process.StandardOutput.ReadToEndAsync()
`$stderrTask = `$process.StandardError.ReadToEndAsync()
`$process.WaitForExit()
`$stdout = `$stdoutTask.Result
`$stderr = `$stderrTask.Result
`$result = `$null
if (`$process.ExitCode -eq 0) { `$result = `$stdout | ConvertFrom-Json }
@{ stdout = `$stdout; stderr = `$stderr; exitCode = `$process.ExitCode; result = `$result } | ConvertTo-Json -Compress -Depth 100 | Set-Content -LiteralPath '$escapedTemporaryPath' -Encoding utf8
Move-Item -LiteralPath '$escapedTemporaryPath' -Destination '$escapedResultPath' -Force
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -EncodedCommand $encodedCommand"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $ProbeForegroundTaskName -Action $action -Principal $principal -Force | Out-Null
}

function Start-ProbeForegroundTask {
    Start-ScheduledTask -TaskName $ProbeForegroundTaskName
}

function Wait-ForProbeForegroundTask {
    param([Parameter(Mandatory)][string] $ResultPath)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $ResultPath) {
            return Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
        }
        $task = Get-ScheduledTask -TaskName $ProbeForegroundTaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { throw 'the foreground probe task disappeared before reporting its result' }
        Wait-Tick
    } while ($timer.Elapsed.TotalSeconds -lt $ProcessDiscoveryTimeoutSeconds)
    throw 'the foreground probe task did not report completion before the timeout'
}

function Unregister-ProbeForegroundTask {
    Unregister-ScheduledTask -TaskName $ProbeForegroundTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-ProbeBrowserTask {
    param(
        [Parameter(Mandatory)][string] $EdgeExecutable,
        [Parameter(Mandatory)][string] $ProfilePath
    )

    $action = New-ScheduledTaskAction -Execute $EdgeExecutable -Argument (
        "--new-window --no-first-run --user-data-dir=`"$ProfilePath`" about:blank"
    )
    # Match the daemon's execution context: the SSH relay runs in session 0, while this task must
    # receive the logged-in user's desktop token to create a window the daemon can inspect.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $ProbeBrowserTaskName -Action $action -Principal $principal -Force | Out-Null
}

function Unregister-ProbeBrowserTask {
    Unregister-ScheduledTask -TaskName $ProbeBrowserTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-ProbeBrowserTask {
    Start-ScheduledTask -TaskName $ProbeBrowserTaskName
}

function Register-ProbeActivationTask {
    param(
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][string] $ResultPath
    )

    $escapedResultPath = $ResultPath.Replace("'", "''")
    $escapedTemporaryPath = ("$ResultPath.tmp").Replace("'", "''")
    $command = @"
Add-Type @'
using System.Runtime.InteropServices;
public static class AxonForegroundOwner {
    [DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr window, out uint processId);
}
'@
`$shell = New-Object -ComObject WScript.Shell
`$activated = `$shell.AppActivate($ProcessId)
Start-Sleep -Milliseconds 250
[uint32]`$foregroundProcessId = 0
[void][AxonForegroundOwner]::GetWindowThreadProcessId([AxonForegroundOwner]::GetForegroundWindow(), [ref]`$foregroundProcessId)
@{ requestedProcessId = $ProcessId; foregroundProcessId = `$foregroundProcessId; activated = `$activated } | ConvertTo-Json -Compress | Set-Content -LiteralPath '$escapedTemporaryPath' -Encoding utf8
Move-Item -LiteralPath '$escapedTemporaryPath' -Destination '$escapedResultPath' -Force
if (-not `$activated) { exit 1 }
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -EncodedCommand $encodedCommand"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $ProbeActivationTaskName -Action $action -Principal $principal -Force | Out-Null
}

function Start-ProbeActivationTask {
    Start-ScheduledTask -TaskName $ProbeActivationTaskName
}

function Wait-ForProbeActivationTask {
    param([Parameter(Mandatory)][string] $ResultPath)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $ResultPath) {
            $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
            if ($result.activated -eq $true -and [uint32]$result.foregroundProcessId -ne 0) { return $result }
            throw "could not foreground prior application pid $($result.requestedProcessId) for the hand-back sweep"
        }
        $task = Get-ScheduledTask -TaskName $ProbeActivationTaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { throw 'the prior-activation task disappeared before reporting its result' }
        Wait-Tick
    } while ($timer.Elapsed.TotalSeconds -lt $ProcessDiscoveryTimeoutSeconds)
    throw 'the prior-activation task did not report completion before the timeout'
}

function Unregister-ProbeActivationTask {
    Unregister-ScheduledTask -TaskName $ProbeActivationTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-HandBackSweep {
    param(
        [Parameter(Mandatory)][int] $PriorProcessId,
        [Parameter(Mandatory)][int] $TargetProcessId
    )
    $activationResultPath = Join-Path $LiveDirectory 'prior-activation.json'
    $probeResultPath = Join-Path $LiveDirectory 'foreground-sweep.json'
    try {
        Remove-Item -LiteralPath $activationResultPath, "$activationResultPath.tmp", $probeResultPath, "$probeResultPath.tmp" -Force -ErrorAction SilentlyContinue
        Register-ProbeActivationTask -ProcessId $PriorProcessId -ResultPath $activationResultPath
        Start-ProbeActivationTask
        $activation = Wait-ForProbeActivationTask -ResultPath $activationResultPath
        Register-ProbeForegroundTask -TargetProcessId $TargetProcessId -ResultPath $probeResultPath
        Start-ProbeForegroundTask
        $run = Wait-ForProbeForegroundTask -ResultPath $probeResultPath
        if ($run.exitCode -ne 0) { throw "hand-back sweep exited $($run.exitCode): $($run.stderr)" }
        $run.result | Add-Member -NotePropertyName requestedPriorProcess -NotePropertyValue ([uint32]$activation.requestedProcessId) -PassThru |
            Add-Member -NotePropertyName activatedPriorProcess -NotePropertyValue ([uint32]$activation.foregroundProcessId) -PassThru
    }
    finally {
        Unregister-ProbeForegroundTask
        Unregister-ProbeActivationTask
        Remove-Item -LiteralPath $activationResultPath, "$activationResultPath.tmp", $probeResultPath, "$probeResultPath.tmp" -Force -ErrorAction SilentlyContinue
    }
}

function Start-ProbeBrowser {
    <# Launches an isolated Edge instance on the interactive desktop and returns the process that owns its top-level window.

    The process returned by Start-Process is only a launcher on some Edge builds. Targeting that pid
    reproduced AXN-155's false activation failures, so readiness is the appearance of a new,
    window-owning process associated with this probe's unique profile. #>
    $edgeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    $edge = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Microsoft Edge is not installed in either standard location' }

    $profile = Join-Path $LiveDirectory ("edge-profile-{0}" -f [guid]::NewGuid().ToString('N'))
    $pages = Join-Path $profile 'pages'
    New-Item -ItemType Directory -Path $pages -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pages 'start.html') -Encoding utf8 -Value @'
<!doctype html><title>Axon Foreground Probe</title>
<main><h1>Axon Foreground Probe</h1><a href="complete.html">Continue</a></main>
'@
    Set-Content -LiteralPath (Join-Path $pages 'complete.html') -Encoding utf8 -Value @'
<!doctype html><title>Axon Foreground Click Complete</title>
<main><h1>Axon Foreground Click Complete</h1></main>
'@
    $url = ([uri](Join-Path $pages 'start.html')).AbsoluteUri
    $browser = [pscustomobject]@{ ProcessId = 0; ProfilePath = $profile; PageUrl = $url }
    try {
        # This script is invoked through the runner's SSH relay in session 0. Starting Edge from
        # that shell creates a real process which is nevertheless unable to own a window on the
        # desktop where the daemon is inspecting. The probe browser must cross the same Interactive
        # Task Scheduler boundary as the daemon, or a successful daemon health reply and an empty
        # window list describe two different sessions.
        Register-ProbeBrowserTask -EdgeExecutable $edge -ProfilePath $profile
        Start-ProbeBrowserTask
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            # The unique profile path identifies every process in this browser instance. A successful
            # Axon capture then proves which candidate actually owns the top-level window.
            $candidates = @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) })
            foreach ($candidate in $candidates) {
                $lookRequest = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{
                    name = 'look'; arguments = @{ app = [string]$candidate.ProcessId; screenshot = $false }
                } } | ConvertTo-Json -Compress -Depth 10
                $look = Invoke-AxonMcp -Request $lookRequest
                if ($look.result.isError -eq $false -and
                    @($look.result.structuredContent.app.windows).Count -gt 0) {
                    $browser.ProcessId = [int]$candidate.ProcessId
                    return $browser
                }
            }
            Wait-Tick
        } while ($timer.Elapsed.TotalSeconds -lt $ProcessDiscoveryTimeoutSeconds)
        throw 'the probe-owned Edge instance produced no window-owning process'
    }
    catch {
        # The caller cannot receive cleanup state from a function that throws, so startup owns every
        # resource created before successful window discovery.
        Stop-ProbeBrowser -Browser $browser
        throw
    }
}

function Stop-ProbeBrowser {
    param([Parameter(Mandatory)] $Browser)

    try {
        Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Browser.ProfilePath) } |
            ForEach-Object {
                if (Test-ProcessIsRunning -ProcessId $_.ProcessId) {
                    Stop-ProcessById -ProcessId $_.ProcessId
                }
            }
    }
    finally {
        # Task removal and profile cleanup must not depend on every Edge child accepting a kill.
        # In particular, startup calls this path before it can return browser state to its caller.
        Unregister-ProbeBrowserTask
        Remove-Item -LiteralPath $Browser.ProfilePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-EdgeIsRunning {
    [bool] (Get-Process msedge -ErrorAction SilentlyContinue)
}

function Wait-Tick {
    Start-Sleep -Milliseconds 250
}

function Test-ProcessIsRunning {
    param([Parameter(Mandatory)][int] $ProcessId)

    $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-AxonProcess {
    <# Every legacy combined or split daemon process on this machine. #>
    @(Get-CimInstance Win32_Process -Filter "Name = 'axon-win.exe' OR Name = 'axon-win-daemon.exe'")
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

function Get-DesktopTaskState {
    <# Task Scheduler's own word for what this desktop's registration is doing, or $null when nothing
    is registered.

    `Running` is not a transient here. The registered action is `serve`, so the task runs for as long
    as its daemon lives, and a desktop with a healthy daemon reads `Running` forever. What makes the
    state worth reading at all is the opposite case: an instance that has exited but not finished
    still reads `Running`, and a start issued against it is discarded. #>
    $task = Get-ScheduledTask -TaskName $DesktopTaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    [string] $task.State
}

function Start-DesktopDaemonTask {
    <# Asks Task Scheduler to run this desktop's registration. Not a promise that it did: the task
    carries an explicit IgnoreNew multiple-instances policy from the COM registration, so Task
    Scheduler discards a start whose predecessor is still running while reporting success. Whether
    a daemon is answering is the only
    thing that answers that, which is what the callers below do. #>
    Start-ScheduledTask -TaskName $DesktopTaskName
}

function Register-ProbeTask {
    $action = New-ScheduledTaskAction -Execute $ProbeDaemonExecutable
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
    $edge = $null
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

    $Request | & $ProbeCliExecutable mcp | ConvertFrom-Json -Depth 100
}

function Get-ExpectedVersion {
    (Get-Content (Join-Path $RepositoryRoot 'VERSION')).Trim()
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
        if ($null -ne $edge) {
            & taskkill.exe /PID $edge.Id /T /F *> $null
        }
        Pop-Location
    }
}

function Copy-ProbeExecutable {
    New-Item -ItemType Directory -Path $LiveDirectory -Force | Out-Null
    Copy-Item (Join-Path $BuildDirectory 'axon-win.exe') $ProbeCliExecutable -Force
    Copy-Item (Join-Path $BuildDirectory 'axon-win-daemon.exe') $ProbeDaemonExecutable -Force
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

function Get-CliForRegistration {
    param([string] $RegistrationPath)

    if ([string]::IsNullOrWhiteSpace($RegistrationPath)) { return $null }
    if ([System.IO.Path]::GetFileName($RegistrationPath).Equals('axon-win-daemon.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path ([System.IO.Path]::GetDirectoryName($RegistrationPath)) 'axon-win.exe'
    }
    # Pre-split releases served and handled CLI commands from the same executable.
    $RegistrationPath
}

function Get-AxonStatus {
    <# The first candidate that answers with a health document, or $null.

    More than one candidate because the restore stage must work when the build under test has
    vanished mid-run: the CLI beside the desktop's registered daemon is the fallback, and it is the
    release guaranteed to be able to read its own daemon's reply. #>
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
        $status = Get-AxonStatus -Candidates @($ProbeCliExecutable)
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
    Unregister-ProbeActivationTask
    Unregister-ProbeForegroundTask
    Unregister-ProbeBrowserTask
    Unregister-ProbeTask
    Stop-ProbeDaemonProcess

    Invoke-CargoBuild
    Copy-ProbeExecutable

    # The first execution of a never-seen binary, run here on purpose: Defender's block-at-first-
    # sight holds it for up to a minute and can escalate to quarantine, and this is the last moment
    # at which that costs nothing -- this desktop still has its own daemon and nothing has been
    # borrowed. It also keeps the readiness measurement in the probe stage honest, since the scan is
    # paid here rather than being counted as daemon startup.
    $expectedVersion = Get-ExpectedVersion
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $version = Invoke-Axon -Executable $ProbeCliExecutable -Arguments @('version')
    $timer.Stop()
    if ($version.ExitCode -ne 0) {
        throw "the freshly built $ProbeCliExecutable and $ProbeDaemonExecutable could not be run: $($version.Output)"
    }
    if ($version.Output.Trim() -ne $expectedVersion) {
        throw "version reports $($version.Output.Trim()), expected $expectedVersion"
    }
    Write-Note "built $ProbeCliExecutable and $ProbeDaemonExecutable and ran it for the first time via the CLI in $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds (version $expectedVersion)"
}

function Test-DesktopDaemonHasStopped {
    <# Whether the daemon the park stage asked to stop is gone.

    The process is the signal this poll exists for. A daemon that outran its shutdown request's own
    wait has already stopped answering the request that would say so, and the process table is the
    only thing left that knows when it finally exits.

    The health round trip is the fallback for a daemon whose document names no process id, which a
    desktop running an old enough release can report; the restore tolerates the same gap for the same
    reason. It is weaker evidence -- nothing answering is not the same as nothing running -- and it
    is used only when there is no pid to watch. #>
    param(
        [Parameter(Mandatory)][string[]] $Candidates,
        [int] $ProcessId = 0
    )

    if ($ProcessId -gt 0) { return -not (Test-ProcessIsRunning -ProcessId $ProcessId) }
    $status = Get-AxonStatus -Candidates $Candidates
    ($null -ne $status -and -not $status.daemon.running)
}

function Stop-DesktopDaemon {
    <# Asks this desktop's daemon to stop, and keeps asking for as long as it keeps running.

    An exit code is not the verdict here, in either direction, so the process is asked after every
    request. A request that reports failure need not mean the daemon is still there: `shutdown` waits
    ten seconds for the process it asked to stop and reports anything slower as a failure, and a
    desktop that has just finished a cargo build can take longer than that to tear down a UI
    Automation apartment without anything being wrong with it. Such a request opens a wait rather
    than ending the stage.

    And a request that reports success need not mean the daemon is gone. The pipe goes when a daemon
    acknowledges the request, and the process goes when it has finished tearing down, so once one
    request has been acknowledged every request after it finds no pipe and says exactly that --
    `no daemon was running` is a fact about the pipe, and treating it as one about the process is the
    race the command's own wait exists to prevent.

    What fails is a daemon that is still running after every request in the budget, which is a stuck
    daemon and is reported exactly as loudly as before -- and it is reported by this stage rather
    than acted on, because a daemon this lane kills is a daemon it cannot put back. #>
    param(
        [Parameter(Mandatory)][string[]] $Candidates,
        [int] $ProcessId = 0
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastOutput = ''
    foreach ($attempt in 1..$ParkStopAttempts) {
        $shutdown = Invoke-Axon -Executable $ProbeCliExecutable -Arguments @('shutdown')
        $lastOutput = $shutdown.Output
        # Asked before the exit code is read, and asked the same way every time round: a request that
        # succeeded because the daemon exited during its own wait ends here immediately, which is the
        # ordinary park and costs one process check.
        if (Test-DesktopDaemonHasStopped -Candidates $Candidates -ProcessId $ProcessId) {
            if ($shutdown.ExitCode -eq 0) {
                Write-Note "this desktop's daemon is stopped: $lastOutput"
            }
            else {
                # Reachable with no process id to wait on, where the pipe is all there is to read and
                # it has already gone quiet. Said differently from the line above so that a log never
                # implies a request succeeded when it did not.
                Write-Note "this desktop's daemon is stopped, though the request that asked for it reported otherwise: $lastOutput"
            }
            return
        }
        if ($shutdown.ExitCode -eq 0) {
            Write-Note "attempt $attempt of ${ParkStopAttempts}: the shutdown request found no daemon left to stop ($lastOutput), but the one it was asked about is still running; the pipe goes when a daemon acknowledges the request and the process goes when it has finished tearing down"
        }
        else {
            Write-Note "attempt $attempt of ${ParkStopAttempts}: the shutdown request's own wait expired with this desktop's daemon still running: $lastOutput"
        }

        $waited = [System.Diagnostics.Stopwatch]::StartNew()
        while ($waited.Elapsed.TotalSeconds -lt $ParkStopTimeoutSeconds) {
            if (Test-DesktopDaemonHasStopped -Candidates $Candidates -ProcessId $ProcessId) {
                Write-Note "this desktop's daemon stopped $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds after it was asked to, later than the request itself waited"
                return
            }
            Wait-Tick
        }
    }

    throw "could not stop this desktop's daemon: $ParkStopAttempts shutdown requests over $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds each ended with it still running (last request: $lastOutput)"
}

function Invoke-ParkStage {
    # What this desktop looks like before anything is borrowed. The registration is recorded to be
    # asserted unchanged later, never to be rewritten: this stage does not unregister, disable, or
    # repoint it.
    $registrationPath = Get-DesktopRegistrationPath
    Assert-DesktopRegistrationIsNotAProbePath -RegistrationPath $registrationPath
    $status = Get-AxonStatus -Candidates @($ProbeCliExecutable, (Get-CliForRegistration -RegistrationPath $registrationPath))
    $isServing = $null -ne $status -and $status.daemon.running

    # A debt this machine is owed outlives the job that took it on, and the state file is the only
    # part of this lane that survives a killed runner -- `if: always()` runs nothing when the runner
    # service itself dies. Without this, the next job finds a desktop with no daemon, records that
    # there was never one to put back, and clears the record: a temporary outage becomes a permanent
    # one, reported by a green job. An unpaid debt is therefore carried forward, never overwritten.
    $previous = Read-ParkState
    $owesADaemon = $isServing
    if (-not $isServing -and $null -ne $previous -and $previous.daemonWasRunning) {
        Write-Note 'an earlier run parked this desktop and never restored it; carrying that debt forward'
        $owesADaemon = $true
    }

    # Written before the daemon is stopped, so a park that dies halfway still tells the restore what
    # it owes. A park that dies before this point has taken nothing.
    Write-ParkState -State @{
        recordedAt = (Get-Date).ToString('o')
        desktopTaskName = $DesktopTaskName
        registrationPath = $registrationPath
        daemonWasRunning = $owesADaemon
        daemonProcessId = if ($isServing) { $status.daemon.processId } else { $null }
    }
    Write-Note "found this desktop as: registration=$(if ($registrationPath) { $registrationPath } else { 'none' }), daemon running=$isServing$(if ($isServing) { " (pid $($status.daemon.processId))" })"

    if (-not $isServing) {
        Write-Note 'no daemon is answering on the Axon pipe'
        return
    }

    # The build under test does the stopping, and deliberately not the installed release: a runner's
    # installed CLI is whichever release it last installed, so a verb that release predates fails
    # there. The pid comes from the health document rather than from the process table, so that what
    # is waited on is the process this stage just found serving the pipe.
    Stop-DesktopDaemon -Candidates @($ProbeCliExecutable, (Get-CliForRegistration -RegistrationPath $registrationPath)) -ProcessId ([int] $status.daemon.processId)

    # Stopping is asynchronous, and anything still answering here would answer the probe too. This
    # names it rather than killing a process the job has no way to put back.
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $PipeFreeTimeoutSeconds) {
        $status = Get-AxonStatus -Candidates @($ProbeCliExecutable, (Get-CliForRegistration -RegistrationPath $registrationPath))
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
    $expectedVersion = Get-ExpectedVersion
    $stageError = $null
    $sweepError = $null
    $browser = $null

    try {
        # The probe's own registration, at its own name. `daemon install` is deliberately not used:
        # it writes the machine's name, which is what repointed this desktop's start-at-login
        # registration at a quarantined build and left it with nothing to start.
        Register-ProbeTask
        Write-Note "registered $ProbeTaskName -> $ProbeDaemonExecutable"
        Start-ProbeTask

        # Task Scheduler reports nothing about the process it launched, so the daemon under test is
        # found by its image path -- which no installed copy shares. Exactly one is required: a
        # second would be a leftover from an earlier run, and choosing between them would be a guess.
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $processes = @()
        while ($timer.Elapsed.TotalSeconds -lt $ProcessDiscoveryTimeoutSeconds) {
            $processes = Get-ProcessByExecutable -Executable $ProbeDaemonExecutable
            if ($processes.Count -ge 1) { break }
            Wait-Tick
        }
        if ($processes.Count -eq 0) {
            throw "nothing is running $ProbeDaemonExecutable; $ProbeTaskName never launched the daemon under test"
        }
        if ($processes.Count -ne 1) {
            throw "$ProbeDaemonExecutable is running as pids $(($processes.ProcessId) -join ', '); an earlier run left one behind, and which of them answers the pipe is a guess"
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

        # The same isolated Interactive-task Edge instance serves both paging and foreground
        # acceptance. Starting a second browser directly from the SSH/session-0 shell would make the
        # two checks observe different desktops.
        $browser = Start-ProbeBrowser
        $browserApp = [string]$browser.ProcessId
        Write-Note "probe-owned Edge window pid=$browserApp profile=$($browser.ProfilePath)"

        $listRequest = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"look","arguments":{}}}'
        $listResponse = Invoke-AxonMcp -Request $listRequest
        if ($listResponse.result.isError -ne $false) { throw 'the app-list look request failed' }

        # The browser discovery above proved which process owns this isolated profile's window.
        # Keep every later semantic and foreground request pinned to that process: a name-only Edge
        # lookup may resolve an unrelated persistent window from the interactive runner desktop.
        $request = @{
            jsonrpc = '2.0'
            id = 1
            method = 'tools/call'
            params = @{ name = 'look'; arguments = @{ app = $browserApp } }
        } | ConvertTo-Json -Compress -Depth 10
        $response = Invoke-AxonMcp -Request $request
        $window = $response.result.structuredContent.app.windows |
            ForEach-Object root | Select-Object -First 1
        $screenshot = $response.result.structuredContent.screenshot
        $image = @($response.result.content | Where-Object {
            $_.type -eq 'image' -and $_.mimeType -eq 'image/png' -and $_.data.Length -gt 0
        })
        $screenshotOk = $null -ne $screenshot -and
            $screenshot.mediaType -eq 'image/png' -and
            $screenshot.contentTransport -eq 'mcp_image' -and
            $image.Count -eq 1 -and
            [Math]::Max([int]$screenshot.width, [int]$screenshot.height) -le 1280
        $verified = if ($response.result.isError -eq $false -and $null -ne $window -and $screenshotOk) {
            @{ response = $response; window = $window; app = $browserApp }
        } else {
            $null
        }
        if ($null -eq $verified) {
            throw "look returned no accessibility root with a downscaled PNG from probe-owned Edge pid $browserApp"
        }
        Write-Note "isError:false snapshot=$($verified.response.result.structuredContent.id) root=$($verified.window.role) app=$($verified.app)"

        $parentName = $verified.window.name
        if ([string]::IsNullOrWhiteSpace($parentName)) {
            throw 'the Edge window root did not expose a reusable semantic name'
        }

        $offset = 0
        $seen = 0
        $pageNumber = 0
        do {
            $pageNumber += 1
            $pageRequest = @{
                jsonrpc = '2.0'
                id = 100 + $pageNumber
                method = 'tools/call'
                params = @{
                    name = 'look'
                    arguments = @{
                        target = @{ app = $verified.app; name = $parentName }
                        offset = $offset
                        limit = 1
                        direct = $true
                    }
                }
            } | ConvertTo-Json -Compress -Depth 10
            $page = Invoke-AxonMcp -Request $pageRequest
            if ($page.result.isError -ne $false) { throw "Edge child page $pageNumber failed" }
            $children = $page.result.structuredContent.children
            $payloadBytes = [Text.Encoding]::UTF8.GetByteCount(($page | ConvertTo-Json -Compress -Depth 100))
            Write-Note "Edge paging page=$pageNumber offset=$($children.offset) limit=$($children.limit) total=$($children.total) nextOffset=$($children.nextOffset) payloadBytes=$payloadBytes"
            if ([int]$children.offset -ne [int]$offset -or [int]$children.limit -gt 1) {
                throw "Edge child page $pageNumber did not honor offset/limit: requested offset=$offset limit=1; returned offset=$($children.offset) limit=$($children.limit)"
            }
            $next = $children.nextOffset
            if ($null -ne $next -and $next -le $offset) { throw 'Edge paging did not advance' }
            $seen += [Math]::Min([int]$children.limit, [Math]::Max(0, [int]$children.total - $offset))
            $offset = $next
        } while ($null -ne $offset)
        if ($seen -ne [int]$children.total) {
            throw "Edge paging covered $seen children but reported total $($children.total)"
        }
        $handBackCandidates = @($listResponse.result.structuredContent.apps | Where-Object {
            $null -ne $_.identifier -and [int]$_.identifier -ne $daemonProcessId -and
                [int]$_.identifier -ne [int]$browser.ProcessId
        })
        $measuredPriorCount = 0
        foreach ($prior in $handBackCandidates) {
            if ($measuredPriorCount -eq 2) { break }
            $priorSweeps = @()
            try {
                foreach ($repetition in 1..2) {
                    $priorSweeps += Invoke-HandBackSweep -PriorProcessId ([int]$prior.identifier) -TargetProcessId ([int]$browser.ProcessId)
                }
            }
            catch {
                Write-Note "hand-back sweep skipped prior pid $($prior.identifier): $_"
                continue
            }
            for ($index = 0; $index -lt $priorSweeps.Count; $index++) {
                $repetition = $index + 1
                $sweep = $priorSweeps[$index]
                $serializedSweep = $sweep | ConvertTo-Json -Compress -Depth 20
                # Preserve the measurement even when its schema is incomplete. Validation used to run
                # first, which turned the first real malformed result into an opaque failure and forced
                # another live desktop run merely to discover which field was absent.
                Write-Note "hand-back sweep prior=$($prior.identifier) repetition=${repetition}: $serializedSweep"
                $missing = @()
                if ($null -eq $sweep.foregroundLockTimeoutMs) { $missing += 'foregroundLockTimeoutMs' }
                if ([int]$sweep.requestedPriorProcess -ne [int]$prior.identifier) { $missing += 'requestedPriorProcess' }
                if ([int]$sweep.activatedPriorProcess -eq 0) { $missing += 'activatedPriorProcess' }
                if ([int]$sweep.priorForegroundProcess -eq 0) { $missing += 'priorForegroundProcess' }
                if ([int]$sweep.priorForegroundProcess -eq [int]$browser.ProcessId) { $missing += 'priorForegroundProcess[target]' }
                if (@($sweep.results).Count -ne 8) { $missing += "results[count=$(@($sweep.results).Count)]" }
                foreach ($result in @($sweep.results)) {
                    $strategy = if ($null -eq $result.strategy) { '?' } else { [string]$result.strategy }
                    foreach ($field in 'activator.returnValue','activator.getLastError','immediate.window','after250Ms.window','settled.window','cursor','elapsedMs') {
                        $value = $result
                        foreach ($part in $field.Split('.')) { $value = $value.$part }
                        if ($null -eq $value) { $missing += "$strategy.$field" }
                    }
                    if ($result.activationProved -ne $true) { $missing += "$strategy.activationProved" }
                }
                if (@($sweep.results | Where-Object strategy -eq 'H' | Where-Object measurementOnly -eq $true).Count -ne 1) {
                    $missing += 'H.measurementOnly'
                }
                if ($missing.Count -ne 0) {
                    throw "hand-back sweep evidence was incomplete for prior pid $($prior.identifier), repetition $repetition (missing: $($missing -join ', '))"
                }
            }
            $measuredPriorCount++
        }
        if ($measuredPriorCount -ne 2) {
            throw "the hand-back sweep requires two foregroundable unrelated prior applications; measured $measuredPriorCount"
        }

        $foregroundCalls = @(
            @{ name = 'keyboard'; arguments = @{ app = $browserApp; key = 'ctrl+l'; deliveryPolicy = 'foregroundPermitted' } },
            @{ name = 'keyboard'; arguments = @{ app = $browserApp; text = $browser.PageUrl; deliveryPolicy = 'foregroundPermitted' } },
            @{ name = 'keyboard'; arguments = @{ app = $browserApp; key = 'Return'; deliveryPolicy = 'foregroundPermitted' } }
        )
        foreach ($call in $foregroundCalls) {
            $request = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = $call } |
                ConvertTo-Json -Compress -Depth 10
            $response = Invoke-AxonMcp -Request $request
            $evidence = $response.result.structuredContent
            Write-Note "foreground acceptance $($call.name): $($evidence | ConvertTo-Json -Compress -Depth 20)"
            if ($response.result.isError -ne $false -or $evidence.delivery -ne 'foreground' -or
                $evidence.dispatchSuccess -ne $true -or $null -eq $evidence.foreground -or
                $null -eq $evidence.foreground.restored) {
                throw "$($call.name) did not return foreground dispatch and restoration evidence"
            }
            # Browser chrome applies Ctrl+L and navigation asynchronously. Keep the three real input
            # transactions distinct so the next batch cannot overtake the UI state created by the
            # previous one on a busy interactive runner.
            Start-Sleep -Milliseconds 250
        }

        $loadedRequest = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{
            name = 'look'; arguments = @{ app = $browserApp }
        } } | ConvertTo-Json -Compress -Depth 10
        $loaded = Invoke-AxonMcp -Request $loadedRequest
        if (($loaded.result.structuredContent | ConvertTo-Json -Compress -Depth 100) -notmatch 'Axon Foreground Probe') {
            throw 'Ctrl+L, text, and Return did not load the probe page in the targeted Edge window'
        }

        $clickRequest = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{
            name = 'click'; arguments = @{ target = @{ app = $browserApp; name = 'Continue' }; deliveryPolicy = 'foregroundPermitted' }
        } } | ConvertTo-Json -Compress -Depth 10
        $click = Invoke-AxonMcp -Request $clickRequest
        $clickEvidence = $click.result.structuredContent
        Write-Note "foreground acceptance click: $($clickEvidence | ConvertTo-Json -Compress -Depth 20)"
        if ($click.result.isError -ne $false -or $clickEvidence.delivery -ne 'foreground' -or
            $clickEvidence.dispatchSuccess -ne $true -or $null -eq $clickEvidence.foreground.restored) {
            throw 'the page-content click did not return foreground dispatch and restoration evidence'
        }
        $clicked = Invoke-AxonMcp -Request $loadedRequest
        if (($clicked.result.structuredContent | ConvertTo-Json -Compress -Depth 100) -notmatch 'Axon Foreground Click Complete') {
            throw 'the page-content click did not navigate the targeted Edge window'
        }
        Write-Note 'foreground keyboard and page-content click acceptance verified from page state'

        # The interactive desktop survives between jobs, including Edge's scroll position. First
        # drive the document to the top without requiring movement, then use a large opposite delta
        # to deterministically reach the bottom while still exercising the same bounded ScrollPattern
        # increments as ordinary wheel-sized requests. Position readback is the action's postcondition:
        # that request must move, while repeating it at the edge must remain a dispatch-only result
        # rather than claiming goal success.
        $resetScrollArguments = @{
            target = @{ app = $verified.app; name = $parentName }
            deltaY = 100000
        }
        $resetScrollRequest = @{
            jsonrpc = '2.0'
            id = 89
            method = 'tools/call'
            params = @{ name = 'scroll'; arguments = $resetScrollArguments }
        } | ConvertTo-Json -Compress -Depth 10
        $reset = Invoke-AxonMcp -Request $resetScrollRequest
        $resetAction = $reset.result.structuredContent
        if ($reset.result.isError -ne $false -or
            $resetAction.dispatch.mechanism -ne 'UIA ScrollPattern.Scroll' -or
            $resetAction.dispatch.success -ne $true -or
            $resetAction.verification.after.verticalPercent -ne 0.0) {
            throw "Edge scroll-position reset did not reach the top through ScrollPattern: $($reset | ConvertTo-Json -Compress -Depth 20)"
        }
        Write-Note "Edge scroll-position reset response=$($resetAction | ConvertTo-Json -Compress -Depth 20)"

        $scrollArguments = @{
            target = @{ app = $verified.app; name = $parentName }
            deltaY = -100000
        }
        $scrollRequest = @{
            jsonrpc = '2.0'
            id = 90
            method = 'tools/call'
            params = @{ name = 'scroll'; arguments = $scrollArguments }
        } | ConvertTo-Json -Compress -Depth 10
        $moved = Invoke-AxonMcp -Request $scrollRequest
        $movedAction = $moved.result.structuredContent
        if ($moved.result.isError -ne $false -or
            $movedAction.dispatch.mechanism -ne 'UIA ScrollPattern.Scroll' -or
            $movedAction.success -ne $true -or
            $movedAction.verification.verified -ne $true -or
            $movedAction.verification.before.verticalPercent -eq $movedAction.verification.after.verticalPercent) {
            throw "Edge delta scroll did not produce verified ScrollPattern movement: $($moved | ConvertTo-Json -Compress -Depth 20)"
        }
        Write-Note "Edge delta scroll response=$($movedAction | ConvertTo-Json -Compress -Depth 20)"

        $unchanged = Invoke-AxonMcp -Request $scrollRequest
        $unchangedAction = $unchanged.result.structuredContent
        if ($unchanged.result.isError -ne $false -or
            $unchangedAction.dispatch.mechanism -ne 'UIA ScrollPattern.Scroll' -or
            $unchangedAction.dispatch.success -ne $true -or
            $unchangedAction.success -ne $false -or
            $unchangedAction.verification.verified -ne $false -or
            $unchangedAction.verification.before.verticalPercent -ne $unchangedAction.verification.after.verticalPercent) {
            throw "Edge unchanged-position scroll claimed goal success or lost dispatch evidence: $($unchanged | ConvertTo-Json -Compress -Depth 20)"
        }
        Write-Note "Edge unchanged-position response=$($unchangedAction | ConvertTo-Json -Compress -Depth 20)"

    }
    catch {
        # Held rather than propagated, because a throw from the `finally` below would supersede it.
        # The sweep failing is a fact about this lane's leftovers; whatever brought the stage here is
        # the fact about the build, and losing it to a cleanup error is how a failure on a machine
        # nobody can attach to becomes expensive to reconstruct.
        $stageError = $_
    }
    finally {
        # The probe's own registration and daemon go now rather than in the restore stage, so that a
        # job which never reaches the restore still leaves nothing of this lane's registered. The
        # restore repeats both, because a stage that dies here reaches neither.
        if ($null -ne $browser) {
            try { Stop-ProbeBrowser -Browser $browser }
            catch {
                $sweepError = $_.Exception.Message
                Write-Note "warning: this lane could not remove its probe-owned browser: $sweepError"
            }
        }
        try { Remove-ProbeInstallation }
        catch {
            $sweepError = $_.Exception.Message
            Write-Note "warning: this lane could not remove all of its own daemons: $sweepError"
        }
    }

    if ($null -ne $stageError) { throw $stageError }
    if ($null -ne $sweepError) {
        throw "the probe succeeded, but this lane left one of its own daemons running and could not stop it: $sweepError; it will hold its image against the next checkout"
    }
}

function Remove-ProbeInstallation {
    <# Everything this lane registered or started, removed idempotently. #>
    $shutdown = Invoke-Axon -Executable $ProbeCliExecutable -Arguments @('shutdown')
    if ($shutdown.ExitCode -ne 0) {
        # Tolerated here alone: a probe daemon that already exited and one that never started look
        # the same to `shutdown`, and the sweep below is what actually guarantees the outcome.
        Write-Note "the probe daemon did not answer shutdown: $($shutdown.Output)"
    }
    Unregister-ProbeBrowserTask
    Unregister-ProbeActivationTask
    Unregister-ProbeForegroundTask
    Unregister-ProbeTask
    Stop-ProbeDaemonProcess
}

function Get-ServingDaemon {
    <# The health document of whatever daemon is answering the pipe, or $null when none is.

    More than one candidate for the reason Get-AxonStatus takes a list: the restore must work when
    the build under test has vanished mid-run, and the CLI beside this desktop's registered daemon
    is the release guaranteed to be able to read its own daemon's reply. #>
    param([Parameter(Mandatory)][string[]] $Candidates)

    $status = Get-AxonStatus -Candidates $Candidates
    if ($null -ne $status -and $status.daemon.running) { return $status }
    $null
}

function Wait-ForDesktopDaemon {
    <# The same round trip, polled until a daemon answers or the bound expires. #>
    param(
        [Parameter(Mandatory)][string[]] $Candidates,
        [Parameter(Mandatory)][double] $TimeoutSeconds
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $status = Get-ServingDaemon -Candidates $Candidates
        if ($null -ne $status) { return $status }
        Wait-Tick
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $null
}

function Start-DesktopDaemonWithRetries {
    <# Starts this desktop's own registration until a daemon answers, or gives up loudly.

    Task Scheduler starts the registration at its own path and needs no Axon binary at all, which is
    what keeps this reachable when the build under test has been quarantined mid-run.

    One start is not enough, and the reason is a fact about the machine rather than about the lane.
    On 2026-08-09 a background Windows servicing operation made this desktop 10 to 100 times slower
    for three minutes; the daemon a restart had started spent longer than its own 30-second UIA
    readiness bound getting a UI Automation client and exited, which is that bound doing its job. The
    lane's single fallback start then landed on a task whose previous instance had not finished, Task
    Scheduler discarded it, and the restore failed on a desktop that answered a start in 40
    milliseconds four minutes later. The patience belongs here and not in the daemon's bound.

    Which is also why the task's state is read before every start rather than after. A start issued
    against an instance that has not finished is not a failed attempt, it is no attempt at all, and
    nothing says so: `schtasks /run` reports success while discarding it. The wait for that instance
    polls the health round trip throughout, because `Running` is equally what a healthy daemon looks
    like -- the registered action is `serve` -- so the answer that usually ends the wait is this
    desktop's daemon already being back. #>
    param([Parameter(Mandatory)][string[]] $Candidates)

    Write-Note "nothing is answering the pipe; recovering $DesktopTaskName through Task Scheduler instead"
    foreach ($attempt in 1..$RestoreStartAttempts) {
        $taskState = $null
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $status = Get-ServingDaemon -Candidates $Candidates
            if ($null -ne $status) { return $status }
            $taskState = Get-DesktopTaskState
            if ($taskState -ne 'Running' -and $taskState -ne 'Queued') { break }
            if ($timer.Elapsed.TotalSeconds -ge $TaskInstanceTimeoutSeconds) { break }
            Wait-Tick
        }
        if ($taskState -eq 'Running' -or $taskState -eq 'Queued') {
            Write-Note "attempt $attempt of ${RestoreStartAttempts}: $DesktopTaskName is $taskState and nothing is answering; a start now would be discarded, so this attempt waited for that instance instead"
            continue
        }

        try { Start-DesktopDaemonTask }
        catch {
            # Recorded rather than thrown, like every other start in this stage: what is owed here is
            # a verdict on whether a daemon is answering, and a start that could not be issued is one
            # attempt's worth of that verdict rather than the verdict.
            Write-Note "attempt $attempt of ${RestoreStartAttempts}: could not start ${DesktopTaskName}: $($_.Exception.Message)"
            continue
        }
        $status = Wait-ForDesktopDaemon -Candidates $Candidates -TimeoutSeconds $RestoreTimeoutSeconds
        if ($null -ne $status) { return $status }
        Write-Note "attempt $attempt of ${RestoreStartAttempts}: nothing answered within $RestoreTimeoutSeconds seconds of starting $DesktopTaskName"
    }
    $null
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
    #
    # A sweep that cannot finish is recorded rather than fatal. An orphan that will not die is a real
    # obstacle -- it may hold the pipe against the daemon being restored, and it locks its image
    # against the next checkout -- but abandoning the restore here is how a desktop ends the job with
    # no daemon at all, reported by a message that never mentions it. The restart is attempted
    # anyway, and the leftover is reported at the end alongside whatever the restart achieved.
    $sweepError = $null
    try { Remove-ProbeInstallation }
    catch {
        $sweepError = $_.Exception.Message
        Write-Note "warning: this lane could not remove all of its own daemons: $sweepError"
    }

    if (-not $state.daemonWasRunning) {
        Write-Note 'this desktop had no Axon daemon when the job arrived; leaving it stopped'
        Clear-ParkState
        return
    }

    # A daemon with no registration behind it was started by hand, and Task Scheduler has nothing to
    # start. The record is cleared even so: repeating this failure on every future run would tell
    # nobody anything the first report did not, and would wedge the lane on a machine it cannot fix.
    if ([string]::IsNullOrWhiteSpace($state.registrationPath)) {
        Clear-ParkState
        throw "this desktop had a daemon when the job arrived but no $DesktopTaskName registration to start it from; it was started by hand and this lane cannot put it back"
    }

    # `daemon restart` restarts the registration that is on disk without rewriting it
    # (rust/axon-win/src/main.rs), so it cannot repoint this desktop even though it is being run
    # from the build under test. Its status is recorded rather than acted on: it ends with a
    # readiness wait that parses the reply with *this* build's decoder, so a desktop running an
    # older release could fail it while coming back perfectly.
    $restart = Invoke-Axon -Executable $ProbeCliExecutable -Arguments @('daemon', 'restart')
    Write-Note "daemon restart exited $($restart.ExitCode): $($restart.Output)"

    # Nothing that starts a daemon is trusted on its exit code, because all of them report on
    # starting one rather than on one serving. The verdict is a health round trip, read through the
    # build under test when it can still run and through the executable this desktop's own
    # registration names when it cannot.
    #
    # A restart that exited zero has already waited for readiness itself, so this window confirms
    # rather than waits. A restart that exited non-zero gets no window of its own: the ladder below
    # opens with the same round trip, and a wait here would only ask the same question twice before
    # the recovery that can actually change the answer.
    $candidates = @($ProbeCliExecutable, (Get-CliForRegistration -RegistrationPath $state.registrationPath))
    $status = $null
    if ($restart.ExitCode -eq 0) {
        $status = Wait-ForDesktopDaemon -Candidates $candidates -TimeoutSeconds $RestoreTimeoutSeconds
    }
    if ($null -eq $status) {
        # The build under test can be gone -- quarantined mid-run is exactly how this lane's worst
        # day started -- and this desktop's daemon must come back regardless.
        $status = Start-DesktopDaemonWithRetries -Candidates $candidates
    }
    if ($null -eq $status) {
        throw "this desktop's Axon daemon did not come back after $RestoreStartAttempts attempts to start $DesktopTaskName; this runner needs attention before the next live run$(if ($sweepError) { " (this lane also left a daemon of its own behind: $sweepError)" })"
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

    # Cleared before the leftover is reported: the debt this stage owed has been paid, and a
    # leftover of this lane's own is the next run's problem rather than a reason to make the next
    # park think this desktop is still owed a daemon.
    Clear-ParkState
    Write-Note "this desktop's Axon daemon is answering again (pid $($status.daemon.processId), version $($status.version), registration $($status.registration.path))"
    if ($sweepError) {
        throw "this desktop's daemon is back, but this lane left one of its own running and could not stop it: $sweepError; it will hold its image against the next checkout"
    }
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
