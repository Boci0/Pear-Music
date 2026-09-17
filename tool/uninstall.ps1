<#
.SYNOPSIS
  Uninstalls Pear Music from the system.
.DESCRIPTION
  Terminates active app instances, removes Desktop and Start Menu shortcuts,
  removes the Windows Registry uninstall entry, and deletes installed program files.
.PARAMETER Silent
  Runs the uninstallation non-interactively without prompts.
.PARAMETER PurgeUserData
  Also purges user application data and caches.
#>

[CmdletBinding()]
param(
  [switch]$Silent,
  [switch]$PurgeUserData
)

$appName = "Pear Music"
$defaultInstallDir = Join-Path $env:LOCALAPPDATA "Programs\Pear Music"

# Determine install directory
$installDir = $defaultInstallDir
if (Test-Path (Join-Path $PSScriptRoot "peerm_app.exe")) {
  $installDir = $PSScriptRoot
}

if (-not $Silent) {
  Write-Host "=========================================="
  Write-Host "  Uninstalling $appName"
  Write-Host "=========================================="
  Write-Host ""
  Write-Host "Target Directory: $installDir"
  Write-Host ""
  $confirm = Read-Host "Are you sure you want to uninstall $appName? [Y/n]"
  if ($confirm -and $confirm -notmatch '^[Yy]') {
    Write-Host "Uninstallation canceled."
    exit 0
  }
}

# 1. Terminate running instances
if (-not $Silent) { Write-Host "[uninstall] Stopping running $appName processes..." }
$processes = Get-Process -Name "peerm_app" -ErrorAction SilentlyContinue
if ($processes) {
  $processes | Stop-Process -Force
  Start-Sleep -Milliseconds 500
}

# 2. Remove Desktop shortcut
$desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "$appName.lnk"
if (Test-Path $desktopShortcut) {
  if (-not $Silent) { Write-Host "[uninstall] Removing Desktop shortcut..." }
  Remove-Item -Path $desktopShortcut -Force -ErrorAction SilentlyContinue
}

# 3. Remove Start Menu shortcut
$startMenuShortcut = Join-Path (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs") "$appName.lnk"
if (Test-Path $startMenuShortcut) {
  if (-not $Silent) { Write-Host "[uninstall] Removing Start Menu shortcut..." }
  Remove-Item -Path $startMenuShortcut -Force -ErrorAction SilentlyContinue
}

# 4. Remove Windows Registry Uninstall key
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PearMusic"
if (Test-Path $regPath) {
  if (-not $Silent) { Write-Host "[uninstall] Removing Windows Settings uninstall entry..." }
  Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. Purge user data if requested
if ($PurgeUserData) {
  $appDataDir = Join-Path $env:APPDATA "com.peerm\peerm_app"
  if (Test-Path $appDataDir) {
    if (-not $Silent) { Write-Host "[uninstall] Purging user data directory..." }
    Remove-Item -Path $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# 6. Remove installed files
if (Test-Path $installDir) {
  if (-not $Silent) { Write-Host "[uninstall] Cleaning installation files..." }

  $isSelfContained = ($PSScriptRoot -replace '[/\\]+$', '') -eq ($installDir -replace '[/\\]+$', '')

  if ($isSelfContained) {
    # Remove everything except running script files first
    Get-ChildItem -Path $installDir -Exclude @("uninstall.ps1", "Uninstall.bat", "uninstall.bat") |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Detach a background cleaner to remove remaining directory
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c ping 127.0.0.1 -n 2 > nul & rd /s /q `"$installDir`"" -WindowStyle Hidden
  } else {
    Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (-not $Silent) {
  Write-Host ""
  Write-Host "=========================================="
  Write-Host "  $appName was successfully uninstalled."
  Write-Host "=========================================="
}
