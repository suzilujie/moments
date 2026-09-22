@echo off
rem ============================================================
rem start.bat - double-click entry point for start.ps1
rem
rem Why we cd first and then call start.ps1 by a RELATIVE name:
rem   this project lives in a path that contains non-ASCII characters,
rem   and passing such paths as arguments to external processes is known
rem   to corrupt them on Windows. A relative, pure-ASCII name avoids
rem   handing the path over at all.
rem
rem Line endings are CRLF and only simple if/goto forms are used,
rem both required for reliable cmd parsing.
rem ============================================================

setlocal
cd /d "%~dp0"

set "PS=powershell.exe"
where pwsh >nul 2>nul
if %errorlevel% equ 0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "start.ps1" %*
set "CODE=%errorlevel%"

if not "%CODE%"=="0" goto failed

echo.
echo [start] finished successfully.
pause
exit /b 0

:failed
echo.
echo [start] FAILED with exit code %CODE%.
echo If the path above looks garbled, run start.ps1 directly from
echo PowerShell instead of double-clicking this file.
pause
exit /b %CODE%
