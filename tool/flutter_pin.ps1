# Finds the Flutter SDK that matches the version CI builds releases with.
#
# Why this exists: a Windows build made with Flutter 3.47.6 turned on Impeller (a different
# renderer) and measured 6x the RAM (1.5 GB against 230 MB), 6x the CPU and more GPU than the
# same code built with 3.44.9, the version .github/workflows/release.yml pins. Local builds
# that ship to anyone, the Beta included, must use the pinned SDK.
#
# Usage (dot-source it, then run the SDK it returns):
#   . "$PSScriptRoot\flutter_pin.ps1"
#   $flutter = Get-PinnedFlutter -RepoRoot $repoRoot
#   & $flutter build windows --release
#
# Looks, in order, at $env:PEARMUSIC_FLUTTER_BIN, C:\flutter-<pin>\bin\flutter.bat, and the
# flutter on PATH. Throws when none of them is the pinned version.

function Get-PinnedFlutterVersion {
  param([string]$RepoRoot)
  $workflow = Join-Path $RepoRoot '.github\workflows\release.yml'
  $match = Select-String -Path $workflow -Pattern 'flutter-version:\s*([0-9.]+)' | Select-Object -First 1
  if (-not $match) { throw "Could not read the pinned Flutter version from $workflow" }
  return $match.Matches[0].Groups[1].Value
}

function Get-FlutterVersionOf {
  param([string]$FlutterBin)
  $first = (& $FlutterBin --version 2>$null | Select-Object -First 1)
  if ($first -match 'Flutter\s+([0-9.]+)') { return $Matches[1] }
  return $null
}

function Get-PinnedFlutter {
  param([string]$RepoRoot)
  $pin = Get-PinnedFlutterVersion -RepoRoot $RepoRoot
  $candidates = @()
  if ($env:PEARMUSIC_FLUTTER_BIN) { $candidates += $env:PEARMUSIC_FLUTTER_BIN }
  $candidates += "C:\flutter-$pin\bin\flutter.bat"
  $onPath = Get-Command flutter -ErrorAction SilentlyContinue
  if ($onPath) { $candidates += $onPath.Source }

  $seen = @()
  foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    $v = Get-FlutterVersionOf -FlutterBin $c
    if ($v -eq $pin) { return $c }
    $seen += "$c (Flutter $v)"
  }
  $found = if ($seen) { $seen -join '; ' } else { 'no Flutter SDK found' }
  throw ("Flutter $pin is required (the version CI builds releases with); found: $found. " +
         "Install it side by side with: git clone --depth 1 --branch $pin https://github.com/flutter/flutter.git C:\flutter-$pin " +
         "or point PEARMUSIC_FLUTTER_BIN at it.")
}
