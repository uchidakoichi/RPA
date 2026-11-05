@echo off
rem Runs llm-bench-pc.ps1 in this folder (Windows PowerShell 5.1; -ExecutionPolicy Bypass for this one run only)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0llm-bench-pc.ps1"
pause
