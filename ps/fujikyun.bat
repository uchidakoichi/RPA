@echo off
rem Fujikyun RPA macro builder (PowerShell edition) - launcher
rem Starts fujikyun.ps1 with Windows PowerShell 5.1 in STA mode (needed by Windows Forms), without a console window.
rem -ExecutionPolicy Bypass applies to this one process only and changes no setting on the PC.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
start "" "%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0fujikyun.ps1"
endlocal
