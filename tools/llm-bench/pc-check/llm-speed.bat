@echo off
rem Runs llm-speed.ps1 in this folder (Windows PowerShell 5.1; -ExecutionPolicy Bypass for this one run only)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0llm-speed.ps1"
pause
