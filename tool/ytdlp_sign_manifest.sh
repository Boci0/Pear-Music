#!/usr/bin/env bash
# Builds and signs the yt-dlp mirror manifest.
#
# Usage: ytdlp_sign_manifest.sh <asset-dir> <ytdlp-version> <ed25519-private-key.pem>
#
# Reads whichever of yt-dlp.exe, yt-dlp_linux and yt-dlp_macos exist in
# <asset-dir>, then writes manifest.json and manifest.json.sig (base64 Ed25519
# signature over the exact manifest bytes) next to them, plus one self-verifying
# pearmusic-resolver-<platform>.pmyd bundle per asset (layout documented in
# app/lib/services/ytdlp_bundle.dart). MIRROR_SOURCES is an optional
# space-separated list of https base URLs to embed as extra sources, and
# BUILD_SOURCE (upstream or pypi-rebuild) is recorded in the manifest.
# The app verifies signatures against the public keys in
# app/lib/services/ytdlp_manifest.dart.
set -euo pipefail

dir="$1"; version="$2"; key="$3"
export DIR="$dir" VERSION="$version"

python3 - <<'PY'
import hashlib, json, os, datetime
d = os.environ["DIR"]
assets = {}
for name in ("yt-dlp.exe", "yt-dlp_linux", "yt-dlp_macos"):
    path = os.path.join(d, name)
    if os.path.isfile(path):
        data = open(path, "rb").read()
        assets[name] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
if not assets:
    raise SystemExit("no yt-dlp assets found in " + d)
manifest = {
    "schema": 1,
    "ytdlp_version": os.environ["VERSION"],
    "issued": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "assets": assets,
    "sources": os.environ.get("MIRROR_SOURCES", "").split(),
    # Where the binaries came from: "upstream" or "pypi-rebuild". Informational.
    "build": os.environ.get("BUILD_SOURCE", "unknown"),
}
with open(os.path.join(d, "manifest.json"), "w", newline="\n") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY

openssl pkeyutl -sign -rawin -inkey "$key" -in "$dir/manifest.json" -out "$dir/manifest.json.sigraw"
base64 -w0 "$dir/manifest.json.sigraw" > "$dir/manifest.json.sig"
rm -f "$dir/manifest.json.sigraw"

python3 - <<'PY'
import os, struct
d = os.environ["DIR"]
manifest = open(os.path.join(d, "manifest.json"), "rb").read()
sig = open(os.path.join(d, "manifest.json.sig"), "rb").read().strip()
platforms = {"yt-dlp.exe": "windows", "yt-dlp_linux": "linux", "yt-dlp_macos": "macos"}
for asset, platform in platforms.items():
    path = os.path.join(d, asset)
    if not os.path.isfile(path):
        continue
    name = asset.encode()
    with open(os.path.join(d, "pearmusic-resolver-%s.pmyd" % platform), "wb") as out:
        out.write(b"PMYD1" + bytes([10]))
        out.write(struct.pack(">I", len(manifest)) + manifest)
        out.write(struct.pack(">I", len(sig)) + sig)
        out.write(struct.pack(">H", len(name)) + name)
        out.write(open(path, "rb").read())
PY

echo "Signed $dir/manifest.json for yt-dlp $version"
