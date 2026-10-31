@echo off
setlocal
rem Fujikyun @VERSION@ restore.
rem Decode fujikyun.b64.txt in this folder (or the file dropped on this .bat) to a ZIP,
rem check its SHA-256 and extract the app files into this folder (overwriting them).
rem The ZIP holds only the app files: macros, settings, logs and records are left as they are.
rem build_docs.js turns "msg" lines into ASCII-only PowerShell calls: cmd misreads
rem a .bat that has both LF-only line endings and non-ASCII text.
set "EXPECTED=@SHA256@"
set "HERE=%~dp0"
set "SRC=%~1"
if not defined SRC if exist "%HERE%fujikyun.b64.txt" set "SRC=%HERE%fujikyun.b64.txt"
if not defined SRC for %%f in ("%HERE%*.b64.txt") do if not defined SRC set "SRC=%%~ff"
if not defined SRC (
  echo [ERROR] fujikyun.b64.txt not found.
  msg 復元するファイルが見つかりません。\nbase64 の文字を貼り付けたファイルを「fujikyun.b64.txt」という名前で、このファイルと同じフォルダに保存してください。
  pause
  exit /b 1
)
echo %SRC%
set "ZIP=%TEMP%\fujikyun-%RANDOM%.zip"
certutil -f -decode "%SRC%" "%ZIP%" >nul
if errorlevel 1 (
  echo [ERROR] base64 decode failed.
  msg base64 の文字を元に戻せませんでした。貼り付けた文字が欠けていないか確かめてください。
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
set "ACTUAL="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%ZIP%" SHA256') do if not defined ACTUAL set "ACTUAL=%%h"
set "ACTUAL=%ACTUAL: =%"
if /i not "%ACTUAL%"=="%EXPECTED%" (
  echo [ERROR] SHA-256 mismatch. version @VERSION@
  msg 内容が一致しません。貼り付けた文字が欠けているか、この復元ファイル（版 @VERSION@）と版が違います。\n2つとも GitHub の Raw 表示から貼り付け直してください。ファイルは何も書き換えていません。
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
tar -xf "%ZIP%" -C "%HERE%."
if errorlevel 1 (
  echo [ERROR] extract failed.
  msg ZIP を展開できませんでした。ふじキュンを開いていたら閉じてから、もう一度実行してください。
  del "%ZIP%" 2>nul
  pause
  exit /b 1
)
del "%ZIP%" 2>nul
echo.
echo [OK] %HERE%  version @VERSION@
msg 復元しました（版 @VERSION@）。\nfujikyun.bat をダブルクリックすると起動します。ふじキュンを開いていたときは、一度閉じて開き直してください。\nマクロ・設定・ログなど、作ったデータはそのまま残っています。
pause
