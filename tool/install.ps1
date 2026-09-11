# Pear Music Installer
#
# Installs Pear Music from the extracted release zip into the user's
# local programs directory, creates Desktop and Start Menu shortcuts,
# and optionally bundles yt-dlp if found on the system.
#
# Usage:
#   Right-click this file > "Run with PowerShell"
#   or: powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'

$appName    = 'Pear Music'
$exeName    = 'peerm_app.exe'
$installDir = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host ""
Write-Host "=========================================="
Write-Host "  Pear Music Installer"
Write-Host "=========================================="
Write-Host ""
Write-Host "Install location: $installDir"
Write-Host ""

# 1. Stop any running instance
Get-Process -Name "peerm_app" -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -like "*$appName*"
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# 2. Create install directory and copy files
if (-not (Test-Path $installDir)) {
  New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

Write-Host "[install] Copying files..."
$items = Get-ChildItem -Path $scriptDir -Exclude 'install.ps1', 'Install.bat', 'install.bat'
foreach ($item in $items) {
  if ($item.PSIsContainer) {
    robocopy $item.FullName (Join-Path $installDir $item.Name) /E /NFL /NDL /NJH /NJS | Out-Null
  } else {
    Copy-Item -Path $item.FullName -Destination $installDir -Force
  }
}

# 3. Bundle yt-dlp if available on the system and not already present
$ytDlpDest = Join-Path $installDir "yt-dlp.exe"
if (-not (Test-Path $ytDlpDest)) {
  $ytDlpBin = $null
  $ytDlpCmd = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue
  if ($ytDlpCmd) { $ytDlpBin = $ytDlpCmd.Source }
  if (-not $ytDlpBin) {
    $wingetPath = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\yt-dlp.exe"
    if (Test-Path $wingetPath) { $ytDlpBin = $wingetPath }
  }
  if ($ytDlpBin -and (Test-Path $ytDlpBin)) {
    Write-Host "[install] Bundling yt-dlp from $ytDlpBin..."
    Copy-Item -Path $ytDlpBin -Destination $ytDlpDest -Force
  }
}

# 4. Create Desktop shortcut
$exePath     = Join-Path $installDir $exeName
$desktopPath = [Environment]::GetFolderPath("Desktop")
$deskShortcut = Join-Path $desktopPath "$appName.lnk"

Write-Host "[install] Creating Desktop shortcut..."
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($deskShortcut)
$sc.TargetPath        = $exePath
$sc.WorkingDirectory  = $installDir
$sc.Description       = $appName
$sc.IconLocation      = "$exePath,0"
$sc.Save()

# 5. Create Start Menu shortcut
$startMenuDir = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
$startShortcut = Join-Path $startMenuDir "$appName.lnk"

Write-Host "[install] Creating Start Menu shortcut..."
$sc2 = $wsh.CreateShortcut($startShortcut)
$sc2.TargetPath       = $exePath
$sc2.WorkingDirectory = $installDir
$sc2.Description      = $appName
$sc2.IconLocation     = "$exePath,0"
$sc2.Save()

Write-Host ""
Write-Host "=========================================="
Write-Host "  Pear Music installed successfully!"
Write-Host ""
Write-Host "  Location : $installDir"
Write-Host "  Desktop  : $deskShortcut"
Write-Host "  Start Menu: $startShortcut"
Write-Host "=========================================="
Write-Host ""
Write-Host "Press any key to launch Pear Music..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Start-Process -FilePath $exePath
