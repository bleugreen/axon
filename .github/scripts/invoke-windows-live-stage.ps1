#Requires -Version 7

<#
.SYNOPSIS
Runs one stage of the Windows live lane in the desktop user's session.

.DESCRIPTION
The runner service is `NETWORK SERVICE` in session 0. UI Automation, the daemon's scheduled task,
and the pipe's own DACL all belong to the logged-in desktop user, so every stage crosses into that
user's context through a localhost-only SSH key whose authorized-keys entry forces
C:\ProgramData\Axon\live-probe.cmd. The stage name is the only thing that key carries, and the
relay accepts exactly four values (.github/scripts/windows-live-relay.cmd is its source).

Git for Windows' `ssh` rather than the system OpenSSH client: the system client on this machine has
a runaway-process pathology that has previously taken it down (AXN-38).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('build', 'park', 'probe', 'restore')]
    [string] $Stage
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$ssh = 'C:\Program Files\Git\usr\bin\ssh.exe'
$arguments = @(
    '-F', 'C:\actions-runner-axon\.ssh\empty_config',
    '-i', 'C:\actions-runner-axon\.ssh\axon-live-probe',
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ConnectTimeout=5',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'UserKnownHostsFile=C:\actions-runner-axon\.ssh\known_hosts',
    'mitch@localhost',
    $Stage
)

& $ssh @arguments
$code = $LASTEXITCODE

if ($code -eq 126) {
    # The relay's own refusal code. Said by name because the alternative is a bare exit code for a
    # machine-side file that no checkout can update: the runner's copy of the forced command is
    # older than this workflow.
    Write-Output "::error::the live-probe relay rejected the stage '$Stage'; C:\ProgramData\Axon\live-probe.cmd on this runner predates the staged lane and must be replaced with .github/scripts/windows-live-relay.cmd"
    exit 1
}
if ($code -ne 0) {
    Write-Output "::error::the '$Stage' stage failed with exit code $code"
    exit $code
}
