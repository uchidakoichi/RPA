@echo off
rem Fujikyun - investigation aid: copies from a window you choose many times and checks what was read.
rem Select what to copy in that window first. Results are also saved to copy_probe_log.txt next to this file.
rem -ExecutionPolicy Bypass applies to this one process only and changes no setting on the PC.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0copy_probe.ps1"
pause
endlocal
