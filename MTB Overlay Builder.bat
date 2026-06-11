@echo off
REM MTB Trail Overlay Map Builder - Windows Launcher
REM This batch file launches the PowerShell GUI application.
REM
REM If PowerShell execution policy blocks the script, it will
REM automatically bypass with -ExecutionPolicy Bypass.

cd /d "%~dp0"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0mtb-overlay-builder.ps1"

if %ERRORLEVEL% neq 0 (
    echo.
    echo PowerShell failed with error code %ERRORLEVEL%.
    echo Make sure PowerShell 5.1+ is installed (included in Windows 10/11).
    echo.
    pause
)