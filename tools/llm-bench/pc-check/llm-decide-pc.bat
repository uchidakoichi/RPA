@echo off
rem Decision reading on this PC (run llm-check.bat and llm-speed.bat first in this folder).
rem Put Invoke-LlmDecide.ps1, decide.json, cases.json and cases2.json next to this file. The report is result_decide_pc.txt.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-LlmDecide.ps1" -Model "%~dp0qwen35-q4.gguf" -Dir "%~dp0." -Bin llama-x64 -Threads 8 -Out "%~dp0result_decide_pc.json"
pause
