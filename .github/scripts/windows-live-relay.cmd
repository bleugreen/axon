@echo off
rem The forced command behind the live lane's localhost SSH key. It is deployed to
rem C:\ProgramData\Axon\live-probe.cmd on the Windows live runner and named in the desktop user's
rem authorized_keys; this copy is its source, so that the file is reviewable rather than machine
rem lore. Deploy it whenever either file changes -- a runner whose relay predates the staged lane
rem refuses every stage with 126, which .github/scripts/invoke-windows-live-stage.ps1 reports by
rem name.
rem
rem What the key constrains is WHICH STAGE runs, not what code runs: the stage it names executes the
rem probe script from the runner's checkout, which is a file a pull request can write. The boundary
rem that matters for untrusted changes is therefore the repository's Actions approval policy for
rem outside contributors, not this file.
rem
rem Delayed expansion is load-bearing. %SSH_ORIGINAL_COMMAND% is substituted into the line before
rem cmd tokenizes it, so a value containing `&` is parsed as a command separator and runs before the
rem allowlist below is ever consulted. `!SSH_ORIGINAL_COMMAND!` is substituted after tokenizing, so
rem the value stays one string.
setlocal enabledelayedexpansion
set "STAGE=!SSH_ORIGINAL_COMMAND!"
if "!STAGE!"=="build" goto run
if "!STAGE!"=="park" goto run
if "!STAGE!"=="probe" goto run
if "!STAGE!"=="restore" goto run
echo unrecognized live-lane stage 1>&2
exit /b 126
:run
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\actions-runner-axon\_work\axon\axon\.github\scripts\windows-live-probe.ps1" -Stage !STAGE!
exit /b %ERRORLEVEL%
