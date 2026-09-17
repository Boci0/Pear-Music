@echo off
setlocal
cd /d "%~dp0"
echo ==========================================
echo   Starting Pear Music Uninstaller...
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Uninstallation finished with errors (code %ERRORLEVEL%).
    pause
)
