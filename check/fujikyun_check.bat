@echo off
rem Fujikyun RPA (PowerShell edition) - pre-check launcher
rem Runs fujikyun_check.ps1 with Windows PowerShell 5.1 in STA mode (needed by Windows Forms).
rem -ExecutionPolicy Bypass applies to this one process only and changes no setting on the PC.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0fujikyun_check.ps1"
if errorlevel 1 (
    echo.
    echo Pre-check stopped with an error. Please send the message above.
    pause
)
endlocal
