@echo off
rem Runs the PowerShell edition's core tests with Windows PowerShell 5.1 (maintainers only)
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-FujiTest.ps1"
echo.
pause
endlocal
