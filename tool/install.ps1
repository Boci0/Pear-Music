# Pear Music Installer
#
# Installs Pear Music into the user's local programs directory,
# verifies/downloads all runtime dependencies (including yt-dlp resolver),
# creates Desktop & Start Menu shortcuts, and registers an uninstaller
# with Windows Settings / Add or Remove Programs.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1

param(
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'

$appName    = 'Pear Music'
$exeName    = 'peerm_app.exe'
$installDir = Join-Path $env:LOCALAPPDATA "Programs\$appName"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Resolve version
$appVersion = "3.5.5"
$pubspecPath = Join-Path $scriptDir "..\app\pubspec.yaml"
if (Test-Path $pubspecPath) {
  $match = Select-String -Path $pubspecPath -Pattern 'version:\s*([0-9.]+)'
  if ($match -and $match.Matches.Groups[1].Value) {
    $appVersion = $match.Matches.Groups[1].Value
  }
}

if (-not $Silent) {
  Write-Host ""
  Write-Host "=========================================="
  Write-Host "  Pear Music Installer (v$appVersion)"
  Write-Host "=========================================="
  Write-Host ""
  Write-Host "Install location: $installDir"
  Write-Host ""
}

# 1. Terminate any active instance
Get-Process -Name "peerm_app" -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -like "*$appName*"
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# 2. Prepare target directory
if (-not (Test-Path $installDir)) {
  New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# 3. Copy application files
if (-not $Silent) { Write-Host "[install] Copying application files..." }
$excludeList = @('install.ps1', 'Install.bat', 'install.bat', 'uninstall.ps1', 'Uninstall.bat', 'uninstall.bat')
$items = Get-ChildItem -Path $scriptDir | Where-Object { $excludeList -notcontains $_.Name }
foreach ($item in $items) {
  if ($item.PSIsContainer) {
    robocopy $item.FullName (Join-Path $installDir $item.Name) /E /NFL /NDL /NJH /NJS | Out-Null
  } else {
    Copy-Item -Path $item.FullName -Destination $installDir -Force
  }
}

# 4. Check & resolve yt-dlp dependency
$ytDlpDest = Join-Path $installDir "yt-dlp.exe"
if (-not (Test-Path $ytDlpDest)) {
  $ytDlpBin = $null

  # 4a. Check if already present in extracted package
  $localSourceYt = Join-Path $scriptDir "yt-dlp.exe"
  if (Test-Path $localSourceYt) { $ytDlpBin = $localSourceYt }

  # 4b. Check system paths
  if (-not $ytDlpBin) {
    $ytDlpCmd = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue
    if ($ytDlpCmd) { $ytDlpBin = $ytDlpCmd.Source }
  }
  if (-not $ytDlpBin) {
    $wingetPath = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\yt-dlp.exe"
    if (Test-Path $wingetPath) { $ytDlpBin = $wingetPath }
  }

  if ($ytDlpBin -and (Test-Path $ytDlpBin)) {
    if (-not $Silent) { Write-Host "[install] Bundling yt-dlp dependency from $ytDlpBin..." }
    Copy-Item -Path $ytDlpBin -Destination $ytDlpDest -Force
  } else {
    # 4c. Automated dependency download
    if (-not $Silent) { Write-Host "[install] yt-dlp resolver not found locally. Downloading official dependency..." }
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
      $dlUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
      $tempYt = "$ytDlpDest.tmp"
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add("User-Agent", "PearMusic-Installer")
      $wc.DownloadFile($dlUrl, $tempYt)

      if ((Test-Path $tempYt) -and ((Get-Item $tempYt).Length -gt 1000000)) {
        Move-Item -Path $tempYt -Destination $ytDlpDest -Force
        if (-not $Silent) {
          $sizeMb = [math]::Round((Get-Item $ytDlpDest).Length / 1MB, 2)
          Write-Host "[install] Successfully installed yt-dlp dependency ($sizeMb MB)"
        }
      } else {
        Remove-Item $tempYt -Force -ErrorAction SilentlyContinue
        if (-not $Silent) { Write-Warning "[install] Downloaded dependency was incomplete. Fallback will trigger at runtime." }
      }
    } catch {
      if (-not $Silent) { Write-Warning "[install] Could not download yt-dlp during install: $_. Fallback will trigger at runtime." }
    }
  }
}

# 4b. Check & resolve aria2c dependency (optional parallel downloader)
$ariaDest = Join-Path $installDir "aria2c.exe"
if (-not (Test-Path $ariaDest)) {
  $ariaBin = $null

  # 4b-a. Check if already present in extracted package
  $localSourceAria = Join-Path $scriptDir "aria2c.exe"
  if (Test-Path $localSourceAria) { $ariaBin = $localSourceAria }

  # 4b-b. Check system paths
  if (-not $ariaBin) {
    $ariaCmd = Get-Command aria2c.exe -ErrorAction SilentlyContinue
    if ($ariaCmd) { $ariaBin = $ariaCmd.Source }
  }
  if (-not $ariaBin) {
    $wingetAria = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\aria2c.exe"
    if (Test-Path $wingetAria) { $ariaBin = $wingetAria }
  }
  if (-not $ariaBin) {
    $scoopAria = Join-Path $env:USERPROFILE "scoop\shims\aria2c.exe"
    if (Test-Path $scoopAria) { $ariaBin = $scoopAria }
  }
  if (-not $ariaBin) {
    # Zip-type winget packages extract under Packages\aria2* and only reach
    # PATH after an environment refresh; probe the package folder directly.
    $wingetPkgRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkgRoot) {
      $wingetAriaExe = Get-ChildItem $wingetPkgRoot -Directory -Filter "aria2*" -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter "aria2c.exe" -ErrorAction SilentlyContinue } |
        Select-Object -First 1
      if ($wingetAriaExe) { $ariaBin = $wingetAriaExe.FullName }
    }
  }

  if ($ariaBin -and (Test-Path $ariaBin)) {
    if (-not $Silent) { Write-Host "[install] Bundling aria2c dependency from $ariaBin..." }
    Copy-Item -Path $ariaBin -Destination $ariaDest -Force
  } else {
    # 4b-c. Automated dependency download (GitHub API, pinned URL as fallback)
    if (-not $Silent) { Write-Host "[install] aria2c not found locally. Downloading official dependency..." }
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
      $ariaUrl = $null
      try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/aria2/aria2/releases/latest" -Headers @{ 'User-Agent' = 'PearMusic-Installer' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -match 'win-64bit.*\.zip$' } | Select-Object -First 1
        if ($asset) { $ariaUrl = $asset.browser_download_url }
      } catch {}
      if (-not $ariaUrl) {
        $ariaUrl = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
      }

      $ariaZip = Join-Path $env:TEMP "peerm-aria2.zip"
      $ariaTmp = Join-Path $env:TEMP "peerm-aria2"
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add("User-Agent", "PearMusic-Installer")
      $wc.DownloadFile($ariaUrl, $ariaZip)

      if (Test-Path $ariaTmp) { Remove-Item $ariaTmp -Recurse -Force }
      Expand-Archive -Path $ariaZip -DestinationPath $ariaTmp -Force
      $ariaExe = Get-ChildItem -Path $ariaTmp -Recurse -Filter "aria2c.exe" | Select-Object -First 1
      if ($ariaExe) {
        Copy-Item -Path $ariaExe.FullName -Destination $ariaDest -Force
        if (-not $Silent) { Write-Host "[install] Successfully installed aria2c dependency" }
      } else {
        if (-not $Silent) { Write-Warning "[install] aria2c archive did not contain aria2c.exe. Downloads will use the yt-dlp native downloader." }
      }
      Remove-Item $ariaZip -Force -ErrorAction SilentlyContinue
      Remove-Item $ariaTmp -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      if (-not $Silent) { Write-Warning "[install] Could not fetch aria2c during install: $_. Downloads will use the yt-dlp native downloader." }
    }
  }
}

# 5. Deploy uninstaller scripts into installation directory
$uninstallPs1Src = Join-Path $scriptDir "uninstall.ps1"
$uninstallBatSrc = Join-Path $scriptDir "Uninstall.bat"
if (Test-Path $uninstallPs1Src) {
  Copy-Item -Path $uninstallPs1Src -Destination (Join-Path $installDir "uninstall.ps1") -Force
}
if (Test-Path $uninstallBatSrc) {
  Copy-Item -Path $uninstallBatSrc -Destination (Join-Path $installDir "Uninstall.bat") -Force
}

# 6. Create Desktop shortcut
$exePath     = Join-Path $installDir $exeName
$desktopPath = [Environment]::GetFolderPath("Desktop")
$deskShortcut = Join-Path $desktopPath "$appName.lnk"

if (-not $Silent) { Write-Host "[install] Creating Desktop shortcut..." }
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($deskShortcut)
$sc.TargetPath        = $exePath
$sc.WorkingDirectory  = $installDir
$sc.Description       = $appName
$sc.IconLocation      = "$exePath,0"
$sc.Save()

# 7. Create Start Menu shortcuts (App + Uninstaller)
$startMenuDir = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
$startShortcut = Join-Path $startMenuDir "$appName.lnk"

if (-not $Silent) { Write-Host "[install] Creating Start Menu shortcuts..." }
$sc2 = $wsh.CreateShortcut($startShortcut)
$sc2.TargetPath       = $exePath
$sc2.WorkingDirectory = $installDir
$sc2.Description      = $appName
$sc2.IconLocation     = "$exePath,0"
$sc2.Save()

# 8. Register in Windows Settings / Add or Remove Programs
if (-not $Silent) { Write-Host "[install] Registering in Windows Add or Remove Programs..." }
$uninstallRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PearMusic"
if (-not (Test-Path $uninstallRegPath)) {
  New-Item -Path $uninstallRegPath -Force | Out-Null
}

$uninstallBatPath = Join-Path $installDir "Uninstall.bat"
$uninstallPs1Path = Join-Path $installDir "uninstall.ps1"
$totalBytes = (Get-ChildItem -Path $installDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$totalKb = [math]::Round($totalBytes / 1KB)

Set-ItemProperty -Path $uninstallRegPath -Name "DisplayName" -Value $appName -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "DisplayVersion" -Value $appVersion -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "Publisher" -Value "Boci0" -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "DisplayIcon" -Value "$exePath,0" -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "InstallLocation" -Value $installDir -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "UninstallString" -Value "`"$uninstallBatPath`"" -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "QuietUninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallPs1Path`" -Silent" -Type String
Set-ItemProperty -Path $uninstallRegPath -Name "EstimatedSize" -Value $totalKb -Type DWord
Set-ItemProperty -Path $uninstallRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallRegPath -Name "NoRepair" -Value 1 -Type DWord

if (-not $Silent) {
  Write-Host ""
  Write-Host "=========================================="
  Write-Host "  Pear Music installed successfully!"
  Write-Host ""
  Write-Host "  Location   : $installDir"
  Write-Host "  Desktop    : $deskShortcut"
  Write-Host "  Start Menu : $startShortcut"
  Write-Host "  Resolver   : $(if (Test-Path $ytDlpDest) { 'Installed' } else { 'Runtime Managed' })"
  Write-Host "  Accelerator: $(if (Test-Path $ariaDest) { 'Installed' } else { 'Not installed (optional)' })"
  Write-Host "=========================================="
  Write-Host ""
  Write-Host "Launching Pear Music..."
  Start-Process -FilePath $exePath
}
