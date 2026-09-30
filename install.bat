@echo off
rem ===========================================================================
rem  ClevoFanControl - P16 Pro IXA1 installer  (thin launcher)
rem
rem  All logic and every user-facing message live in install.ps1, so that
rem  Chinese text is not mangled by the console code page. This file stays
rem  pure ASCII on purpose - do not put non-ASCII characters in here.
rem
rem  Usage:
rem    double-click this file, or
rem    drag ClevoFanControl-v2.0.0-x64.zip onto this file
rem ===========================================================================

setlocal
title ClevoFanControl P16 Pro IXA1 - installer

set "HERE=%~dp0"

if not exist "%HERE%install.ps1" (
    echo.
    echo [ERROR] install.ps1 not found next to this launcher.
    echo         Expected: %HERE%install.ps1
    echo         Please keep install.bat and install.ps1 in the same folder.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%install.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Installer finished successfully.
) else (
    echo Installer exited with code %RC% - see messages above.
)
echo.
pause
exit /b %RC%
