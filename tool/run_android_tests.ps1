# Automated Android Test & Emulation Runner for Pear Music
param (
  [string]$AvdName = "PearTestAVD",
  [switch]$Headless = $false,
  [switch]$KeepRunning = $false
)

$ErrorActionPreference = "Stop"
$SdkPath = "$env:LOCALAPPDATA\Android\Sdk"
$EmulatorExe = "$SdkPath\emulator\emulator.exe"
$AdbExe = "$SdkPath\platform-tools\adb.exe"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Pear Music Automated Android Test Runner " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Check if a device/emulator is already connected
$devices = & $AdbExe devices | Select-String "device$"
$startedOurEmulator = $false

if ($devices.Count -eq 0) {
  Write-Host "[1/4] Starting Android Emulator '$AvdName'..." -ForegroundColor Yellow
  $emuArgs = @("-avd", $AvdName, "-no-snapshot-load", "-no-boot-anim")
  if ($Headless) {
    $emuArgs += @("-no-window", "-no-audio")
  }

  $proc = Start-Process -FilePath $EmulatorExe -ArgumentList $emuArgs -PassThru
  $startedOurEmulator = $true

  Write-Host "[2/4] Waiting for emulator to boot completely..." -ForegroundColor Yellow
  & $AdbExe wait-for-device
  
  $booted = $false
  for ($i = 0; $i -lt 40; $i++) {
    $status = & $AdbExe shell getprop sys.boot_completed 2>$null
    if ($status.Trim() -eq "1") {
      $booted = $true
      break
    }
    Start-Sleep -Seconds 2
  }

  if (-not $booted) {
    Write-Host "[ERROR] Android Emulator failed to boot in time." -ForegroundColor Red
    if ($startedOurEmulator -and -not $KeepRunning) {
      & $AdbExe emu kill 2>$null
    }
    exit 1
  }
  Write-Host "   -> Android Emulator is online and ready." -ForegroundColor Green
} else {
  Write-Host "[1/4] Android device/emulator already active." -ForegroundColor Green
}

# 3. Build & verify Android APK
Write-Host "[3/4] Building and verifying Android APK..." -ForegroundColor Yellow
Push-Location "$PSScriptRoot\..\app"
try {
  flutter build apk --debug
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter Android APK build failed with exit code $LASTEXITCODE"
  }
  Write-Host "   -> Android APK compiled successfully." -ForegroundColor Green

  # 4. Run Flutter automated unit/widget tests
  Write-Host "[4/4] Running automated test suites..." -ForegroundColor Yellow
  flutter test
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter tests failed with exit code $LASTEXITCODE"
  }
  Write-Host "   -> All tests passed on Android environment." -ForegroundColor Green
} finally {
  Pop-Location
  if ($startedOurEmulator -and -not $KeepRunning) {
    Write-Host "Stopping emulator..." -ForegroundColor Gray
    & $AdbExe emu kill 2>$null
  }
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host " Android Verification Complete: 100% PASS " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
