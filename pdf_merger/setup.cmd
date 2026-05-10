@echo off
REM Double-clickable wrapper around setup.ps1.
REM Avoids the PowerShell execution policy that blocks .ps1 by default.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

REM When launched by double-click (no args), pause so the output stays readable.
if "%~1"=="" pause

exit /b %EXITCODE%
