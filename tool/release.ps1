# Pear Music release automation.
#
# Replaces the manual 5-step checklist in .dev_context.md:
#   1. Bump version strings (pubspec.yaml, update_service.dart, installer.iss)
#   2. Run the full test suite (aborts on any failure)
#   3. Build release binaries (Android split APKs and/or Windows x64)
#   4. Package artifacts and write SHA256SUMS at the repository root
#   5. Commit, tag vX.Y.Z, push main and the tag
#
# Default path: pushing the tag triggers .github/workflows/release.yml, which
# builds and publishes the GitHub release from hosted runners. Pass
# -LocalRelease to instead publish the release directly from locally built
# artifacts (for offline or urgent releases).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Version 2.5.8 -Build 6040 -Notes "Summary of changes"
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Version 2.5.8 -Build 6040 -Notes "Summary" -LocalRelease
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Version 2.5.8 -Build 6040 -Notes "Summary" -SkipPush
#
# Parameters:
#   -Version       Semantic version, e.g. 2.5.8 (required)
#   -Build         Numeric build number, e.g. 6040 (required)
#   -Notes         Commit message summary appended to "release: vX.Y.Z - " (required)
#   -SkipBuild     Reuse existing artifacts in the expected build output paths
#   -SkipPush      Bump, test, build and package but do not commit, tag or push
#   -LocalRelease  Also create the GitHub release from local artifacts instead
#                  of relying on the tag-triggered CI workflow

param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$Build,
  [Parameter(Mandatory = $true)][string]$Notes,
  [switch]$SkipBuild,
  [switch]$SkipPush,
  [switch]$LocalRelease
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Join-Path $repoRoot 'app\pubspec.yaml'
$updateService = Join-Path $repoRoot 'app\lib\services\update_service.dart'
$installerIss = Join-Path $repoRoot 'tool\installer.iss'
$androidOut = Join-Path $repoRoot 'app\build\app\outputs\flutter-apk'
$windowsOut = Join-Path $repoRoot 'app\build\windows\x64\runner\Release'
$shaFile = Join-Path $repoRoot 'SHA256SUMS'
$tag = "v$Version"

function Write-Step([string]$message) {
  Write-Host "[release] $message"
}

function Assert-FileContains([string]$path, [string]$needle) {
  $content = Get-Content $path -Raw
  if (-not $content.Contains($needle)) {
    throw "Version bump failed: '$needle' not found in $path"
  }
}

Set-Location $repoRoot

# ---- Step 1: version strings ----
Write-Step "Bumping version to $Version+$Build"

$pubspecContent = Get-Content $pubspec -Raw
if (-not ($pubspecContent -match '(?m)^version: \d+\.\d+\.\d+\+\d+')) {
  throw "Version bump failed: no 'version:' line matched in $pubspec"
}
$pubspecNew = $pubspecContent -replace '(?m)^version: \d+\.\d+\.\d+\+\d+', "version: $Version+$Build"
Set-Content $pubspec $pubspecNew -NoNewline

$updateContent = Get-Content $updateService -Raw
if (-not ($updateContent -match "static const String currentVersion = '[^']+';")) {
  throw "Version bump failed: currentVersion not matched in $updateService"
}
$updateNew = $updateContent -replace "static const String currentVersion = '[^']+';", "static const String currentVersion = '$Version';"
Set-Content $updateService $updateNew -NoNewline

$issContent = Get-Content $installerIss -Raw
if (-not ($issContent -match '#define MyAppVersion "[^"]+"')) {
  throw "Version bump failed: MyAppVersion not matched in $installerIss"
}
$issNew = $issContent -replace '#define MyAppVersion "[^"]+"', "#define MyAppVersion `"$Version`""
Set-Content $installerIss $issNew -NoNewline

Assert-FileContains $pubspec "version: $Version+$Build"
Assert-FileContains $updateService "currentVersion = '$Version'"
Assert-FileContains $installerIss "MyAppVersion `"$Version`""

# ---- Step 2: tests ----
Write-Step 'Running flutter test'
Push-Location (Join-Path $repoRoot 'app')
try {
  flutter test
  if ($LASTEXITCODE -ne 0) { throw "flutter test failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

# ---- Step 3: builds ----
if ($SkipBuild) {
  Write-Step 'Skipping builds (-SkipBuild), reusing existing artifacts'
  $apkArm64 = Join-Path $androidOut 'app-arm64-v8a-release.apk'
  $apkArmV7 = Join-Path $androidOut 'app-armeabi-v7a-release.apk'
  $exePath = Join-Path $windowsOut 'peerm_app.exe'
  if (-not (Test-Path $apkArm64)) { throw "Missing $apkArm64; run without -SkipBuild first" }
  if (-not (Test-Path $apkArmV7)) { throw "Missing $apkArmV7; run without -SkipBuild first" }
  if (-not (Test-Path $exePath)) { throw "Missing $exePath; run without -SkipBuild first" }
} else {
  Write-Step 'Building Android APKs (split per ABI)'
  Push-Location (Join-Path $repoRoot 'app')
  try {
    flutter build apk --split-per-abi --release
    if ($LASTEXITCODE -ne 0) { throw "Android build failed with exit code $LASTEXITCODE" }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
}

# ---- Step 4: package and checksums ----
Write-Step 'Packaging artifacts and writing SHA256SUMS'
$zipPath = Join-Path $repoRoot 'PearMusic-Windows-x64.zip'
$apkArm64Path = Join-Path $repoRoot 'PearMusic-Android-arm64.apk'
$apkArmV7Path = Join-Path $repoRoot 'PearMusic-Android-armv7.apk'

Compress-Archive -Path (Join-Path $windowsOut '*') -DestinationPath $zipPath -Force
Copy-Item (Join-Path $androidOut 'app-arm64-v8a-release.apk') $apkArm64Path -Force
Copy-Item (Join-Path $androidOut 'app-armeabi-v7a-release.apk') $apkArmV7Path -Force

$h1 = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$h2 = (Get-FileHash $apkArm64Path -Algorithm SHA256).Hash.ToLower()
$h3 = (Get-FileHash $apkArmV7Path -Algorithm SHA256).Hash.ToLower()
"$h1 *PearMusic-Windows-x64.zip`n$h2 *PearMusic-Android-arm64.apk`n$h3 *PearMusic-Android-armv7.apk" |
  Set-Content $shaFile -NoNewline
Write-Step (Get-Content $shaFile | Out-String)

if ($SkipPush) {
  Write-Step 'Done (-SkipPush): commit, tag and push manually when ready'
  return
}

# ---- Step 5: commit, tag, push ----
Write-Step "Committing and tagging $tag"
$commitMessage = "release: $tag - $Notes"
git add -A
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
git commit -m $commitMessage
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
git tag -a $tag -m $commitMessage
if ($LASTEXITCODE -ne 0) { throw "git tag $tag failed (does it already exist?)" }
git push origin main
if ($LASTEXITCODE -ne 0) { throw 'git push origin main failed' }
git push origin $tag
if ($LASTEXITCODE -ne 0) { throw "git push origin $tag failed" }

if (-not $LocalRelease) {
  Write-Step "Tag $tag pushed. The Release workflow (.github/workflows/release.yml) will build and publish the GitHub release."
  Write-Step 'Track it at: https://github.com/Boci0/Pear-Music/actions'
  return
}

# ---- Local release: publish from local artifacts ----
Write-Step "Creating GitHub release $tag from local artifacts"
gh release create $tag $apkArm64Path $apkArmV7Path $zipPath $shaFile `
  --title "Pear Music $Version" --notes $Notes
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
Write-Step "Release published: https://github.com/Boci0/Pear-Music/releases/tag/$tag"