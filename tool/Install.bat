@echo off
setlocal
cd /d "%~dp0"
echo ==========================================
echo   Starting Pear Music Installer...
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Installation finished with errors (code %ERRORLEVEL%).
    pause
)
