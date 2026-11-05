@echo off
rem Runs llm-mem-pc.ps1 in this folder (Windows PowerShell 5.1; -ExecutionPolicy Bypass for this one run only)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0llm-mem-pc.ps1"
pause
