$ErrorActionPreference = 'Stop'

$taskName = 'Axon Windows Daemon'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskXml = if ($null -ne $task) { Export-ScheduledTask -TaskName $taskName } else { $null }
$taskWasRunning = $null -ne $task -and $task.State -eq 'Running'
$workspaceRoot = 'C:\actions-runner-axon\_work\'
$liveDirectory = 'C:\ProgramData\Axon\live'
$probeExecutable = Join-Path $liveDirectory 'axon-win.exe'

function Get-LiveProbeDaemons {
    @(Get-CimInstance Win32_Process -Filter "Name = 'axon-win.exe'" |
        Where-Object {
            $path = $_.ExecutablePath
            $null -ne $path -and (
                $path.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith("$liveDirectory\", [System.StringComparison]::OrdinalIgnoreCase)
            )
        })
}

function Get-LiveProbeDaemonProcesses {
    @(Get-LiveProbeDaemons | Where-Object {
        $null -ne (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue)
    })
}

function Stop-LiveProbeDaemons {
    foreach ($attempt in 1..5) {
        foreach ($process in Get-LiveProbeDaemonProcesses) {
            Write-Output "Stopping live-probe daemon pid=$($process.ProcessId) path=$($process.ExecutablePath)"
            try {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            }
            catch {
                if ($null -ne (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {
                    Write-Warning "Could not stop pid=$($process.ProcessId) on attempt ${attempt}: $_"
                }
            }
        }

        if ((Get-LiveProbeDaemonProcesses).Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }

    $remaining = Get-LiveProbeDaemonProcesses
    if ($remaining.Count -eq 0) { return }

    throw "Scoped live-probe daemons remain: $($remaining.ExecutablePath -join ', ')"
}

try {
    Stop-LiveProbeDaemons
    $rustDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\..\rust')).Path
    Set-Location $rustDirectory
    $env:CARGO_HOME = 'C:\Users\mitch\.cargo'
    $env:RUSTUP_HOME = 'C:\Users\mitch\.rustup'
    $env:Path = "$env:CARGO_HOME\bin;$env:Path"

    cargo build --locked -p axon-win
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

    New-Item -ItemType Directory -Path $liveDirectory -Force | Out-Null
    Copy-Item (Resolve-Path 'target\debug\axon-win.exe').Path $probeExecutable -Force

    $restartTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $probeExecutable daemon restart
        if ($LASTEXITCODE -ne 0) { throw "daemon restart failed with exit code $LASTEXITCODE" }
    }
    finally {
        $restartTimer.Stop()
        Write-Output "Daemon readiness completed after $([Math]::Round($restartTimer.Elapsed.TotalSeconds, 2)) seconds"
    }

    # The published contract, checked against a real interactive desktop rather than a fixture.
    $expectedVersion = (Get-Content (Join-Path $PSScriptRoot '..\..\VERSION')).Trim()
    $reportedVersion = (& $probeExecutable version).Trim()
    if ($reportedVersion -ne $expectedVersion) {
        throw "version reports $reportedVersion, expected $expectedVersion"
    }

    $status = & $probeExecutable status --json | ConvertFrom-Json -Depth 100
    if ($LASTEXITCODE -ne 0) { throw "status --json failed with exit code $LASTEXITCODE" }
    if ($status.schemaVersion -ne 'health-v1') { throw "unexpected schemaVersion $($status.schemaVersion)" }
    if ($status.version -ne $expectedVersion) { throw "status reports version $($status.version)" }
    if ($status.platform -ne 'windows') { throw "status reports platform $($status.platform)" }
    if (-not $status.daemon.running -or -not $status.daemon.ready) {
        throw "daemon is not ready after restart: $($status.daemon | ConvertTo-Json -Compress)"
    }
    if (-not $status.session.interactive -or -not $status.session.graphical) {
        throw "the daemon is not on the interactive desktop: $($status.session | ConvertTo-Json -Compress)"
    }
    # The registration must point at the permanent probe path, not at the build output it was
    # copied from. Registering an ephemeral path is the failure this assertion exists to catch.
    if ($status.registration.path -ne $probeExecutable) {
        throw "registration points at $($status.registration.path), expected $probeExecutable"
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
    Write-Output "status ok: version=$($status.version) ready=$($status.daemon.ready) capabilities=$($status.capabilities.Count)"

    $listRequest = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"look","arguments":{}}}'
    $listResponse = $listRequest | & $probeExecutable mcp | ConvertFrom-Json -Depth 100
    if ($listResponse.result.isError -ne $false) { throw 'the app-list look request failed' }

    $verified = $null
    foreach ($app in $listResponse.result.structuredContent) {
        $request = @{
            jsonrpc = '2.0'
            id = 1
            method = 'tools/call'
            params = @{ name = 'look'; arguments = @{ app = $app.name } }
        } | ConvertTo-Json -Compress -Depth 10
        $response = $request | & $probeExecutable mcp | ConvertFrom-Json -Depth 100
        $window = $response.result.structuredContent.app.windows |
            ForEach-Object root | Where-Object role -eq 'Window' | Select-Object -First 1
        if ($response.result.isError -eq $false -and $null -ne $window) {
            $verified = @{ response = $response; window = $window; app = $app.name }
            break
        }
    }
    if ($null -eq $verified) { throw 'look did not return a Window root from the interactive desktop' }
    Write-Output "isError:false snapshot=$($verified.response.result.structuredContent.id) root=$($verified.window.role) app=$($verified.app)"
}
finally {
    $cleanupError = $null
    if (Test-Path $probeExecutable) {
        try { & $probeExecutable shutdown *> $null }
        catch { Write-Warning "Could not stop the probe daemon: $_" }
    }
    try { Stop-LiveProbeDaemons }
    catch {
        $cleanupError = $_
        Write-Warning "Could not clean up live-probe daemon processes: $_"
    }

    if ($null -ne $taskXml) {
        Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
        if ($taskWasRunning) { Start-ScheduledTask -TaskName $taskName }
    }
    else {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($null -ne $cleanupError) { throw $cleanupError }
}
