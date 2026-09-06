# Pear Music Beta Automated Test Script
#
# Runs the automated self-test diagnostics suite on the deployed Windows release
# executable (%LOCALAPPDATA%\Programs\Pear Music Beta\peerm_app.exe).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\run_beta_test.ps1

$ErrorActionPreference = 'Stop'

$appDir = Join-Path $env:LOCALAPPDATA "Programs\Pear Music Beta"
$exePath = Join-Path $appDir "peerm_app.exe"

if (-not (Test-Path $exePath)) {
  Write-Error "[test_beta] Executable not found at $exePath. Please run tool\deploy_beta.ps1 first."
  exit 1
}

Write-Host "[test_beta] Stopping any active Pear Music Beta instances..."
Get-Process -Name "peerm_app" -ErrorAction SilentlyContinue | Where-Object {
  $_.Path -like "*Pear Music Beta*"
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 500

Write-Host "[test_beta] Invoking $exePath --self-test..."
$process = Start-Process -FilePath $exePath -ArgumentList "--self-test" -NoNewWindow -PassThru -Wait

$exitCode = $process.ExitCode
Write-Host "[test_beta] Process exited with code $exitCode"

# Look for self_test_report.json in Roaming app data
$reportPath = Join-Path $env:APPDATA "com.example\peerm_app\self_test_report.json"
if (-not (Test-Path $reportPath)) {
  # Fallback search in LocalAppData or AppData
  $found = Get-ChildItem -Path (Join-Path $env:APPDATA "..\") -Filter "self_test_report.json" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) {
    $reportPath = $found.FullName
  }
}

if (Test-Path $reportPath) {
  Write-Host "[test_beta] Test Report found at: $reportPath"
  Write-Host "==================== TEST REPORT ===================="
  Get-Content $reportPath | Write-Host
  Write-Host "====================================================="
} else {
  Write-Host "[test_beta] No report file generated."
}

if ($exitCode -eq 0) {
  Write-Host "[test_beta] ALL AUTOMATED DESKTOP TESTS PASSED."
  exit 0
} else {
  Write-Error "[test_beta] DESKTOP SELF-TEST FAILED."
  exit 1
}
