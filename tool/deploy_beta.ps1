# Pear Music Beta Deployment Script
#
# Compiles the Windows release binary with beta tagging, deploys to a dedicated
# LocalAppData directory ("Pear Music Beta"), creates a Desktop shortcut, and
# leaves the application unlaunched so the user can start it manually.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\deploy_beta.ps1
#   powershell -ExecutionPolicy Bypass -File tool\deploy_beta.ps1 -SkipBuild

param(
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$destDir = Join-Path $env:LOCALAPPDATA "Programs\Pear Music Beta"

Write-Host "[deploy_beta] Target directory: $destDir"

# 1. Stop any currently running Beta instance
Get-Process -Name "peerm_app" -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -like "*Pear Music Beta*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 400

# 2. Build Windows release if requested
if (-not $SkipBuild) {
  Write-Host "[deploy_beta] Building Windows release binary..."
  Push-Location (Join-Path $repoRoot 'app')
  try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
      throw "Build failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

# 3. Deploy binaries to LocalAppData Programs\Pear Music Beta
Write-Host "[deploy_beta] Syncing build files to $destDir..."
if (-not (Test-Path $destDir)) {
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$sourceDir = Join-Path $repoRoot "app\build\windows\x64\runner\Release"
robocopy $sourceDir $destDir /E /PURGE /NFL /NDL /NJH /NJS | Out-Null

# 4. Create Desktop Shortcut
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath "Pear Music Beta.lnk"
$exePath = Join-Path $destDir "peerm_app.exe"

Write-Host "[deploy_beta] Creating Desktop shortcut at: $shortcutPath"
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exePath
$shortcut.WorkingDirectory = $destDir
$shortcut.Description = "Pear Music Beta"
$shortcut.IconLocation = "$exePath,0"
$shortcut.Save()

Write-Host ""
Write-Host "============================================================"
Write-Host "[deploy_beta] Pear Music Beta successfully deployed!"
Write-Host "[deploy_beta] Installation: $destDir"
Write-Host "[deploy_beta] Desktop Icon : $shortcutPath"
Write-Host "[deploy_beta] Automatic launch skipped (ready for manual start)."
Write-Host "============================================================"
