#!/usr/bin/env bash
# Builds a standalone yt-dlp executable for THIS operating system from the
# packages on PyPI, for use when upstream's GitHub release assets are not
# available. The mirror workflow calls this on Windows and Linux runners; it
# also works by hand on any machine with Python 3.10+.
#
# Usage: ytdlp_build_from_pypi.sh <out-dir> [version]
#
# Writes <out-dir>/yt-dlp.exe (Windows) or <out-dir>/yt-dlp_linux (Linux) and a
# build-info.txt listing every package version that went into it. The binary's
# own `--version` output is checked against [version] when one is given. macOS
# is not built: upstream ships a universal binary this recipe cannot match.
#
# This is not upstream's exact build recipe, so treat the result as a fallback:
# it is a plain PyInstaller one-file build of the PyPI release with the
# `default` extras and curl-cffi when it installs.
set -euo pipefail

out="$1"; want="${2:-}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) asset="yt-dlp.exe"; bindir="Scripts" ;;
  Linux)                asset="yt-dlp_linux"; bindir="bin" ;;
  *) echo "Unsupported platform $(uname -s): only Windows and Linux are built." >&2; exit 1 ;;
esac

py="${PYTHON:-}"
if [ -z "$py" ]; then
  for c in python3 python; do command -v "$c" > /dev/null && { py="$c"; break; }; done
fi
[ -n "$py" ] || { echo "No Python found" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$py" -m venv "$work/venv"
vpy="$work/venv/$bindir/python"
[ -x "$vpy" ] || vpy="$work/venv/$bindir/python.exe"

pin=""
[ -n "$want" ] && pin="==$want"
"$vpy" -m pip install --quiet --upgrade pip
# curl-cffi (browser impersonation) matches upstream's build; if it will not
# install on this runner, build without it.
if ! "$vpy" -m pip install --quiet "yt-dlp[default,curl-cffi]$pin" pyinstaller; then
  echo "::warning::curl-cffi did not install here, building without it"
  "$vpy" -m pip install --quiet "yt-dlp[default]$pin" pyinstaller
fi

cat > "$work/entry.py" <<'PY'
import yt_dlp

if __name__ == '__main__':
    yt_dlp.main()
PY

"$vpy" -m PyInstaller --onefile --name yt-dlp --noconfirm --log-level WARN \
  --distpath "$work/dist" --workpath "$work/build" --specpath "$work" \
  --collect-submodules yt_dlp --collect-data yt_dlp_ejs --collect-data certifi \
  --hidden-import yt_dlp_ejs "$work/entry.py"

built="$work/dist/yt-dlp"
[ -f "$built.exe" ] && built="$built.exe"
[ -f "$built" ] || { echo "PyInstaller produced no executable" >&2; exit 1; }
chmod +x "$built"

reported="$("$built" --version)"
if [ -n "$want" ]; then
  # PyPI normalises 2026.08.19 to 2026.8.19, so compare as numbers.
  WANT="$want" GOT="$reported" "$py" - <<'PY'
import os, sys
w = [int(x) for x in os.environ["WANT"].split(".")]
g = [int(x) for x in os.environ["GOT"].split(".")]
if w != g:
    sys.exit("built binary reports %s, expected %s" % (os.environ["GOT"], os.environ["WANT"]))
PY
fi

cp "$built" "$out/$asset"
{
  echo "asset: $asset"
  echo "reported version: $reported"
  echo "python: $("$vpy" --version)"
  "$vpy" -m pip freeze
} > "$out/build-info.txt"
echo "Built $asset (yt-dlp $reported) from PyPI"
