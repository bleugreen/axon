#Requires -Version 7
<#
Exercises the real Windows recording acceptance with parsed run-response fixtures and stubbed
RPC/input seams, plus the probe's native UTF-8 transport using a controlled child pwsh process.
No daemon, browser, scheduled task, or desktop input is reached.
Usage: pwsh -NoProfile -File scripts/test-windows-recording-acceptance.ps1
#>
[CmdletBinding()]
param([string] $ProbeScript = (Join-Path $PSScriptRoot '../.github/scripts/windows-live-probe.ps1'))
$ErrorActionPreference = 'Stop'

# Load only the acceptance and pure helpers, never the machine-specific bootstrap or stages.
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $ProbeScript).Path, [ref] $null, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Invoke-RecordingAcceptance', 'Get-RecordingProbeTitle', 'Format-ProbeCodePoints',
        'Assert-RecordingDryRun', 'Assert-RecordingReplay', 'Find-ProbeNodes')) {
    $definitions = @($ast.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { throw "expected one production definition of $name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

function Check {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

# Execute only the production's top-level encoding assignments, not its desktop bootstrap.
$encodingAssignments = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Left.Extent.Text -in @('[Console]::OutputEncoding', '$OutputEncoding')
})
$nativePeer = @'
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8, $false)
$request = $reader.ReadToEnd() | ConvertFrom-Json
$response = @{
    request = $request.title
    response = 'native' + [char]0x200B + 'response'
} | ConvertTo-Json -Compress
$bytes = $utf8.GetBytes($response + [Environment]::NewLine)
[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
'@
$encodedPeer = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nativePeer))
$pwsh = (Get-Process -Id $PID).Path
$transportTitle = 'request' + [char]0x200B + 'title'
$transportResponse = 'native' + [char]0x200B + 'response'
$cp437 = [Text.Encoding]::GetEncoding(437)
$mojibake = [string][char]0x0393 + [char]0x00C7 + [char]0x00EF
Check ($cp437.GetString([byte[]]@(0xE2, 0x80, 0x8B)) -ceq $mojibake) 'CP437 negative control must reproduce U+0393 U+00C7 U+00EF'

function Invoke-NativeTransportRoundtrip {
    param([Text.Encoding] $PipelineEncoding, [string[]] $Omit)
    $originalConsoleEncoding = [Console]::OutputEncoding
    $originalOutputEncoding = $OutputEncoding
    try {
        [Console]::OutputEncoding = $cp437
        $OutputEncoding = $PipelineEncoding
        foreach ($assignment in $encodingAssignments) {
            if ($assignment.Left.Extent.Text -notin $Omit) {
                . ([scriptblock]::Create($assignment.Extent.Text))
            }
        }
        # Keep this a PowerShell string-to-native pipeline, as in Invoke-AxonMcp. ProcessStartInfo
        # with explicit encodings would bypass the very host settings this regression exercises.
        $request = @{ title = $transportTitle } | ConvertTo-Json -Compress
        Check ($request.Contains([char]0x200B)) 'request must contain literal Unicode, not JSON escapes'
        $rawResponse = $request | & $pwsh -NoProfile -NonInteractive -EncodedCommand $encodedPeer
        Check ($LASTEXITCODE -eq 0) "native UTF-8 peer exited with $LASTEXITCODE"
        $response = ($rawResponse -join [Environment]::NewLine) | ConvertFrom-Json
        [pscustomobject]@{
            Request = $response.request
            Response = $response.response
            NoBom = ([Console]::OutputEncoding.GetPreamble().Length -eq 0 -and
                $OutputEncoding.GetPreamble().Length -eq 0)
        }
    }
    finally {
        [Console]::OutputEncoding = $originalConsoleEncoding
        $OutputEncoding = $originalOutputEncoding
    }
}

$transportCount = 0
foreach ($pipelineEncoding in @([Text.Encoding]::ASCII, $cp437)) {
    foreach ($mutation in @('none', 'console', 'pipeline', 'both')) {
        $omit = @()
        if ($mutation -in @('console', 'both')) { $omit += '[Console]::OutputEncoding' }
        if ($mutation -in @('pipeline', 'both')) { $omit += '$OutputEncoding' }
        $result = Invoke-NativeTransportRoundtrip -PipelineEncoding $pipelineEncoding -Omit $omit
        $context = "native transport with starting pipeline $($pipelineEncoding.CodePage), mutation $mutation"
        if ($mutation -eq 'none') {
            Check ($result.Request -ceq $transportTitle) "$context corrupted the Unicode request"
            Check ($result.Response -ceq $transportResponse) "$context corrupted the Unicode response"
            Check $result.NoBom "$context must use UTF-8 without BOM"
        }
        else {
            Check (-not ($result.Request -ceq $transportTitle -and $result.Response -ceq $transportResponse)) "$context escaped detection"
            if ($mutation -in @('console', 'both')) {
                Check ($result.Response -ceq ('native' + $mojibake + 'response')) "$context did not reproduce CP437 stdout corruption"
            }
            if ($mutation -eq 'pipeline') {
                Check ($result.Request -ceq 'request?title') "$context did not expose native stdin corruption"
                Check ($result.Response -ceq $transportResponse) "$context unexpectedly corrupted correctly decoded stdout"
            }
        }
        $transportCount++
    }
}
Write-Host "$transportCount native UTF-8 transport scenarios passed"

function Write-Note { param($Message) }
function Wait-BrowserTransition {}
function Invoke-OneRecording {
    param($Scope, $X, $Y, $Text, $ActivateProcessId)
    $script:Scopes += $Scope
    Check ($Text -ceq 'axon recorded this') 'independent input must request the whole burst'
    Check ($X -eq 20 -and $Y -eq 30 -and $ActivateProcessId -eq 42) 'independent input lost its captured point/process'
    $index = $script:Scopes.Count - 1
    # The daemon parses the actual YAML in the live lane. Here the marker selects the equivalent
    # parsed trace fixture, so these tests exercise acceptance logic, not a second YAML parser.
    $quotedName = $script:CapturedName | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    $artifact = @"
# fixture-$index
version: 2
actions:
- id: click-1
  tool: click
  target:
    app: $quotedName
    name: recording-note
    locator: {role: Edit}
- id: type-1
  tool: type
  target:
    app: $quotedName
    name: recording-note
    locator: {role: Edit}
  value: axon recorded this
"@
    if ($script:Fault -eq 'locator' -and $index -eq $script:FaultScope) {
        $artifact = $artifact.Replace('locator:', 'point:')
    }
    if ($script:Fault -eq 'state' -and $index -eq $script:FaultScope) { $artifact += '    frame: {}' }
    [pscustomobject]@{
        Label = $Scope.label; actionCount = 2
        stopped = @{ result = @{ actionCount = 2; script = $artifact } }
    }
}
function Invoke-AxonRpc {
    param($Method, $Params)
    if ($Method -eq 'type') { return @{ result = @{ dispatchSuccess = $true } } }
    if ($Method -eq 'save') {
        return @{ result = @{ actionCount = 1; recordCount = 1; script = 'locator: {} # axon saved this' } }
    }
    throw "unexpected RPC $Method"
}
function Invoke-AxonMcp {
    param($Request)
    $requestData = $Request | ConvertFrom-Json
    $tool = $requestData.params.name
    if ($tool -eq 'keyboard') {
        return @{ result = @{ isError = $false; structuredContent = @{ dispatchSuccess = $true } } }
    }
    if ($tool -eq 'look') {
        return @{ result = @{ structuredContent = @{ app = @{
            name = $script:CapturedName
            windows = @(@{ root = @{
                title = 'Axon Recording Probe'; children = @(@{
                    identifier = 'note'; name = 'recording-note'; role = 'Edit'
                    frame = @{ x = 10; y = 20; width = 20; height = 20 }
                })
            } })
        } } } }
    }
    Check ($tool -eq 'run') "unexpected MCP tool $tool"
    $arguments = $requestData.params.arguments
    if ($arguments.path.EndsWith('recording-acceptance-saved.axn')) {
        return @{ result = @{ isError = $false; structuredContent = @{} } }
    }
    $source = Get-Content -LiteralPath $arguments.path -Raw -Encoding utf8
    $index = if ($source.Contains('# fixture-0')) { 0 } else { 1 }
    $script:Runs += "$index/$($arguments.dryRun)"
    Check ([regex]::Matches($source, 'deliveryPolicy: foregroundPermitted').Count -eq 2) 'both replay actions need caller delivery policy'
    Check ($arguments.continueOnError -eq $true) 'click must not truncate the replay'
    $dry = @{
        dryRun = $true
        trace = @(
            @{ index = 0; actionId = 'click-1'; tool = 'click'; success = $true
               result = @{ target = @{ app = $script:CapturedName; name = 'recording-note' } } },
            @{ index = 1; actionId = 'type-1'; tool = 'type'; success = $true
               result = @{ target = @{ app = $script:CapturedName; name = 'recording-note' }; value = 'axon recorded this' } }
        )
    }
    $real = @{
        dryRun = $false
        trace = @(
            @{ index = 0; actionId = 'click-1'; tool = 'click'; success = $false
               targetResolution = @{ status = 'unique' }; result = @{ dispatchSuccess = $true } },
            @{ index = 1; actionId = 'type-1'; tool = 'type'; success = $true
               targetResolution = @{ status = 'unique' }; result = @{ dispatchSuccess = $true } }
        )
    }
    if ($index -eq $script:FaultScope) {
        switch ($script:Fault) {
            'question' { $dry.trace[0].result.target.app = $script:CapturedName.Replace([char]0x200B, '?') }
            'stripped' { $dry.trace[1].result.target.app = $script:CapturedName.Replace([string][char]0x200B, '') }
            'case' { $dry.trace[1].result.target.app = $script:CapturedName.ToUpperInvariant() }
            'click-only' { $dry.trace[1].tool = 'click' }
            'type-only' { $dry.trace[0].tool = 'type'; $dry.trace[0].result.value = 'axon' }
            'truncated' { $dry.trace[1].result.value = 'axon' }
            'semantic' { $dry.trace[0].result.target.Remove('name') }
            'dry-missing' { $dry.trace = @($dry.trace[0]) }
            'dry-order' { $dry.trace[1].index = 0 }
            'dry-failed' { $dry.trace[1].success = $false }
            'resolution-missing' { $real.trace[0].Remove('targetResolution') }
            'ambiguous' { $real.trace[1].targetResolution.status = 'ambiguous' }
            'undelivered' { $real.trace[1].result.dispatchSuccess = $false }
            'real-missing' { $real.trace = @($real.trace[0]) }
            'real-order' { $real.trace[1].index = 0 }
        }
    }
    $batch = if ($arguments.dryRun) { $dry } else { $real }
    # Match the production ConvertFrom-Json boundary, including escaped Unicode strings.
    @{ result = @{ isError = $false; structuredContent = @{ batch = $batch } } } |
        ConvertTo-Json -Depth 30 -EscapeHandling EscapeNonAscii | ConvertFrom-Json -Depth 30
}

$LiveDirectory = Join-Path ([IO.Path]::GetTempPath()) ("axon-recording-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $LiveDirectory | Out-Null
$cases = @{
    question = 'app identity mismatch'; stripped = 'app identity mismatch'; case = 'app identity mismatch'
    'click-only' = 'complete typed text'; 'type-only' = 'complete typed text'; truncated = 'complete typed text'
    semantic = 'no semantic target name'; 'dry-missing' = 'every authored action'
    'dry-order' = 'out of order'; 'dry-failed' = 'unsuccessful'
    'resolution-missing' = 'did not resolve uniquely'; ambiguous = 'did not resolve uniquely'
    undelivered = 'was not delivered'; 'real-missing' = 'every dry-run action'
    'real-order' = 'differs from the parsed artifact'
    locator = 'no semantic target'; state = 'state-pinning field'
}
$count = 0
try {
    $title = Get-RecordingProbeTitle
    Check ($title.StartsWith('Axon Recording Probe', [StringComparison]::Ordinal)) 'fixture lost its prefix'
    Check ($title.Contains([char]0x200B)) 'fixture lacks explicitly constructed U+200B'
    Check ((Format-ProbeCodePoints $title).Contains('U+200B')) 'diagnostics must expose invisible codepoints'
    Check ((Format-ProbeCodePoints $title).Contains('E2 80 8B')) 'diagnostics must expose UTF-8 bytes'
    foreach ($scopeIndex in @(0, 1)) {
        foreach ($fault in @('none', 'capture') + @($cases.Keys)) {
            $script:CapturedName = $title + ' - Microsoft Edge'
            if ($fault -eq 'capture') { $script:CapturedName = $script:CapturedName.Replace([char]0x200B, '?') }
            $script:Scopes = @()
            $script:Runs = @()
            $script:Fault = $fault
            $script:FaultScope = $scopeIndex
            $failure = $null
            try {
                Invoke-RecordingAcceptance -Browser @{ RecordUrl = 'file:///record.html'; ProcessId = 42 } -BrowserApp 'Edge'
            }
            catch { $failure = $_.Exception.Message }
            if ($fault -eq 'none') {
                Check ($null -eq $failure) "valid paired acceptance failed: $failure"
                Check (($script:Runs -join ',') -ceq '0/True,0/False,1/True,1/False') 'both recordings must dry-run and replay'
                Check ($script:Scopes.Count -eq 2) 'paired recordings missing'
                Check ($script:Scopes[0].value.scope -ceq 'allApplications') 'first scope is not unfiltered'
                $app = $script:Scopes[1].value.app
                Check ($app.Keys.Count -eq 1 -and $app.name -ceq $script:CapturedName) 'application scope must carry only captured name'
            }
            else {
                $expected = if ($fault -eq 'capture') { 'Unicode fixture title' } else { $cases[$fault] }
                Check ($null -ne $failure -and $failure.Contains($expected)) "fault $fault scope $scopeIndex was not rejected correctly: $failure"
                if ($fault -in @('question', 'capture')) {
                    Check ($failure.Contains('U+200B') -and $failure.Contains('U+003F')) 'identity failure hides Unicode divergence'
                }
            }
            Check (-not (Test-Path (Join-Path $LiveDirectory 'recording-acceptance.axn'))) 'artifact leaked after acceptance'
            $count++
        }
    }
}
finally { Remove-Item -LiteralPath $LiveDirectory -Recurse -Force }
Write-Host "$count recording acceptance scenarios passed"
