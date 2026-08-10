# windows_plugin_links.ps1
# -------------------------
# Recreates the Flutter Windows plugin links (.plugin_symlinks) as directory
# JUNCTIONS instead of symbolic links.
#
# Why: a real Windows symlink requires Developer Mode (or an elevated
# terminal). A directory junction does not, and CMake/MSVC follow junctions
# transparently, so `flutter build windows` works with Developer Mode OFF.
#
# Normally you do NOT need to run this manually: the local Flutter SDK has
# been patched (flutter_plugins.dart -> _createPlatformPluginSymlinks) so it
# already creates junctions on Windows. This script exists as a fallback for a
# fresh checkout or if the Flutter SDK is ever upgraded and the patch is lost
# (then run this once, and normal `flutter build windows` runs will keep the
# junctions because Flutter only recreates missing links).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool\windows_plugin_links.ps1
# (from the app/ directory, or run from anywhere - it locates app/ itself)

$ErrorActionPreference = 'Stop'

# Locate the app root: script lives at <app>/tool/windows_plugin_links.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Split-Path -Parent $scriptDir
$depsFile = Join-Path $appDir '.flutter-plugins-dependencies'
$linkDir = Join-Path $appDir 'windows\flutter\ephemeral\.plugin_symlinks'

if (-not (Test-Path $depsFile)) {
    Write-Error "Could not find $depsFile. Run 'flutter pub get' first."
    exit 1
}

$deps = Get-Content $depsFile -Raw | ConvertFrom-Json
$plugins = @($deps.plugins.windows)
if ($plugins.Count -eq 0) {
    Write-Host 'No Windows plugins found - nothing to do.'
    exit 0
}

# Wipe any existing links (real symlinks or stale junctions) and start fresh.
if (Test-Path $linkDir) {
    Remove-Item $linkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $linkDir | Out-Null

$failures = 0
foreach ($plugin in $plugins) {
    $name = $plugin.name
    $target = $plugin.path
    $link = Join-Path $linkDir $name
    try {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        Write-Host "  junction  $name  ->  $target"
    } catch {
        Write-Host "  FAILED    $name  ->  $target  ($($_.Exception.Message))" -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Error "$failures plugin link(s) failed."
    exit 1
}

Write-Host ''
Write-Host "Created $($plugins.Count) plugin junctions under $linkDir"
Write-Host 'Developer Mode is NOT required for the Windows build.'
