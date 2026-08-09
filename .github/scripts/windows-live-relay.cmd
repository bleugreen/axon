@echo off
rem The forced command behind the live lane's localhost SSH key, and the whole of what that key can
rem do. It is deployed to C:\ProgramData\Axon\live-probe.cmd on the Windows live runner and named in
rem the desktop user's authorized_keys; it cannot be read from a checkout, because the key must not
rem be able to run anything a pull request could write.
rem
rem This copy is the source of that file. When either changes, deploy this one -- a runner whose
rem relay predates the staged lane refuses every stage with 126, which
rem .github/scripts/invoke-windows-live-stage.ps1 reports by name.
setlocal
set "STAGE=%SSH_ORIGINAL_COMMAND%"
if "%STAGE%"=="build" goto run
if "%STAGE%"=="park" goto run
if "%STAGE%"=="probe" goto run
if "%STAGE%"=="restore" goto run
echo unrecognized live-lane stage: %STAGE% 1>&2
exit /b 126
:run
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\actions-runner-axon\_work\axon\axon\.github\scripts\windows-live-probe.ps1" -Stage %STAGE%
exit /b %ERRORLEVEL%
