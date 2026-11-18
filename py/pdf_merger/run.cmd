@echo off
REM Double-clickable wrapper around run.ps1.
REM Avoids the PowerShell execution policy that blocks .ps1 by default.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

REM Pause on error so the user can read what went wrong before the window closes.
if not "%EXITCODE%"=="0" (
    echo.
    echo Exited with error code %EXITCODE%
    pause
)

exit /b %EXITCODE%
