@echo off
setlocal
rem Fujikyun 2026.10.27.7 restore.
rem Decode fujikyun.b64.txt in this folder (or the file dropped on this .bat) to a ZIP,
rem check its SHA-256 and extract the app files into this folder (overwriting them).
rem The ZIP holds only the app files: macros, settings, logs and records are left as they are.
rem build_docs.js turns "msg" lines into ASCII-only PowerShell calls: cmd misreads
rem a .bat that has both LF-only line endings and non-ASCII text.
set "EXPECTED=d41ea5a3c38f91d6b9d87cfaef06ffed912440549310a6969e4f8938b3846d9c"
set "HERE=%~dp0"
set "SRC=%~1"
if not defined SRC if exist "%HERE%fujikyun.b64.txt" set "SRC=%HERE%fujikyun.b64.txt"
if not defined SRC for %%f in ("%HERE%*.b64.txt") do if not defined SRC set "SRC=%%~ff"
if not defined SRC (
  echo [ERROR] fujikyun.b64.txt not found.
  powershell -NoProfile -Command "Write-Host ([regex]::Unescape('\u5fa9\u5143\u3059\u308b\u30d5\u30a1\u30a4\u30eb\u304c\u898b\u3064\u304b\u308a\u307e\u305b\u3093\u3002\u000abase64 \u306e\u6587\u5b57\u3092\u8cbc\u308a\u4ed8\u3051\u305f\u30d5\u30a1\u30a4\u30eb\u3092\u300cfujikyun.b64.txt\u300d\u3068\u3044\u3046\u540d\u524d\u3067\u3001\u3053\u306e\u30d5\u30a1\u30a4\u30eb\u3068\u540c\u3058\u30d5\u30a9\u30eb\u30c0\u306b\u4fdd\u5b58\u3057\u3066\u304f\u3060\u3055\u3044\u3002'))"
  pause
  exit /b 1
)
echo %SRC%
set "ZIP=%TEMP%\fujikyun-%RANDOM%.zip"
certutil -f -decode "%SRC%" "%ZIP%" >nul
if errorlevel 1 (
  echo [ERROR] base64 decode failed.
  powershell -NoProfile -Command "Write-Host ([regex]::Unescape('base64 \u306e\u6587\u5b57\u3092\u5143\u306b\u623b\u305b\u307e\u305b\u3093\u3067\u3057\u305f\u3002\u8cbc\u308a\u4ed8\u3051\u305f\u6587\u5b57\u304c\u6b20\u3051\u3066\u3044\u306a\u3044\u304b\u78ba\u304b\u3081\u3066\u304f\u3060\u3055\u3044\u3002'))"
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
set "ACTUAL="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%ZIP%" SHA256') do if not defined ACTUAL set "ACTUAL=%%h"
set "ACTUAL=%ACTUAL: =%"
if /i not "%ACTUAL%"=="%EXPECTED%" (
  echo [ERROR] SHA-256 mismatch. version 2026.10.27.7
  powershell -NoProfile -Command "Write-Host ([regex]::Unescape('\u5185\u5bb9\u304c\u4e00\u81f4\u3057\u307e\u305b\u3093\u3002\u8cbc\u308a\u4ed8\u3051\u305f\u6587\u5b57\u304c\u6b20\u3051\u3066\u3044\u308b\u304b\u3001\u3053\u306e\u5fa9\u5143\u30d5\u30a1\u30a4\u30eb\uff08\u7248 2026.10.27.7\uff09\u3068\u7248\u304c\u9055\u3044\u307e\u3059\u3002\u000a2\u3064\u3068\u3082 GitHub \u306e Raw \u8868\u793a\u304b\u3089\u8cbc\u308a\u4ed8\u3051\u76f4\u3057\u3066\u304f\u3060\u3055\u3044\u3002\u30d5\u30a1\u30a4\u30eb\u306f\u4f55\u3082\u66f8\u304d\u63db\u3048\u3066\u3044\u307e\u305b\u3093\u3002'))"
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
tar -xf "%ZIP%" -C "%HERE%."
if errorlevel 1 (
  echo [ERROR] extract failed.
  powershell -NoProfile -Command "Write-Host ([regex]::Unescape('ZIP \u3092\u5c55\u958b\u3067\u304d\u307e\u305b\u3093\u3067\u3057\u305f\u3002\u3075\u3058\u30ad\u30e5\u30f3\u3092\u958b\u3044\u3066\u3044\u305f\u3089\u9589\u3058\u3066\u304b\u3089\u3001\u3082\u3046\u4e00\u5ea6\u5b9f\u884c\u3057\u3066\u304f\u3060\u3055\u3044\u3002'))"
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
del "%ZIP%" 2>nul
echo.
echo [OK] %HERE%  version 2026.10.27.7
powershell -NoProfile -Command "Write-Host ([regex]::Unescape('\u5fa9\u5143\u3057\u307e\u3057\u305f\uff08\u7248 2026.10.27.7\uff09\u3002\u000afujikyun.bat \u3092\u30c0\u30d6\u30eb\u30af\u30ea\u30c3\u30af\u3059\u308b\u3068\u8d77\u52d5\u3057\u307e\u3059\u3002\u3075\u3058\u30ad\u30e5\u30f3\u3092\u958b\u3044\u3066\u3044\u305f\u3068\u304d\u306f\u3001\u4e00\u5ea6\u9589\u3058\u3066\u958b\u304d\u76f4\u3057\u3066\u304f\u3060\u3055\u3044\u3002\u000a\u30de\u30af\u30ed\u30fb\u8a2d\u5b9a\u30fb\u30ed\u30b0\u306a\u3069\u3001\u4f5c\u3063\u305f\u30c7\u30fc\u30bf\u306f\u305d\u306e\u307e\u307e\u6b8b\u3063\u3066\u3044\u307e\u3059\u3002'))"
pause
