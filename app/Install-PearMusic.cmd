@echo off
title Installing Pear Music...
echo ========================================================
echo   Installing Pear Music
echo ========================================================
echo.

set "TARGET_DIR=%LOCALAPPDATA%\Programs\Pear Music"
echo Copying application files to %TARGET_DIR%...
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"

xcopy /E /Y /I "%~dp0*" "%TARGET_DIR%" > NUL

echo Creating Start Menu and Desktop shortcuts...
powershell -Command "$s=(New-Object -COM WScript.Shell).CreateShortcut('%APPDATA%\Microsoft\Windows\Start Menu\Programs\Pear Music.lnk'); $s.TargetPath='%TARGET_DIR%\peerm_app.exe'; $s.IconLocation='%TARGET_DIR%\peerm_app.exe,0'; $s.Save()"
powershell -Command "$s=(New-Object -COM WScript.Shell).CreateShortcut('%USERPROFILE%\Desktop\Pear Music.lnk'); $s.TargetPath='%TARGET_DIR%\peerm_app.exe'; $s.IconLocation='%TARGET_DIR%\peerm_app.exe,0'; $s.Save()"

echo Configuring Windows Defender Firewall...
powershell -NoProfile -Command "Get-NetFirewallRule -DisplayName 'Pear Music*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Pear Music (TCP-In)' -Direction Inbound -Program '%TARGET_DIR%\peerm_app.exe' -Protocol TCP -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null; New-NetFirewallRule -DisplayName 'Pear Music (UDP-In)' -Direction Inbound -Program '%TARGET_DIR%\peerm_app.exe' -Protocol UDP -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null" > NUL 2>&1

echo.
echo Launching Pear Music...
start "" "%TARGET_DIR%\peerm_app.exe"

set "SRC_DIR=%~dp0"
if /i not "%SRC_DIR:~0,-1%"=="%TARGET_DIR%" (
  echo Cleaning up temporary setup files...
  start /b cmd /c "timeout /t 2 /nobreak >nul & rmdir /s /q \"%SRC_DIR:~0,-1%\""
)
