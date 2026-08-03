$ErrorActionPreference = 'Stop'

$taskName = 'Axon Windows Daemon'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskXml = if ($null -ne $task) { Export-ScheduledTask -TaskName $taskName } else { $null }
$taskWasRunning = $null -ne $task -and $task.State -eq 'Running'
$probeExecutable = $null

try {
    $rustDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\..\rust')).Path
    Set-Location $rustDirectory
    $env:CARGO_HOME = 'C:\Users\mitch\.cargo'
    $env:RUSTUP_HOME = 'C:\Users\mitch\.rustup'
    $env:Path = "$env:CARGO_HOME\bin;$env:Path"

    cargo build --locked -p axon-win
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

    $probeExecutable = (Resolve-Path 'target\debug\axon-win.exe').Path
    & $probeExecutable daemon restart
    if ($LASTEXITCODE -ne 0) { throw "daemon restart failed with exit code $LASTEXITCODE" }

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
    if ($null -ne $probeExecutable) {
        try { & $probeExecutable shutdown *> $null }
        catch { Write-Warning "Could not stop the probe daemon: $_" }
    }

    if ($null -ne $taskXml) {
        Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
        if ($taskWasRunning) { Start-ScheduledTask -TaskName $taskName }
    }
    else {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
