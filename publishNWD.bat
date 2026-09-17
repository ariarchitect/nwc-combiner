@echo off
setlocal

REM User-facing reminder. The publishing logic lives in publishNWD.ps1.
echo ============================================================
echo Navisworks Automatic NWD Publisher
echo ============================================================
echo Before using this script:
echo   - Open Navisworks Manage once in GUI mode.
echo   - Configure all required publish/export options.
echo   - If required, change the NWD output version from "2026" to
echo     "2016-2025" in the publish settings.
echo   - Navisworks uses the last saved GUI settings when running from
echo     the command line.
echo ============================================================
echo.

REM Resolve the PowerShell script relative to this batch file so that the
REM launcher also works from Task Scheduler and from other directories.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publishNWD.ps1" %*
set "PUBLISH_EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %PUBLISH_EXIT_CODE%
