#!/usr/bin/env bash
# Builds and signs the app's own update manifest for a release.
#
# Usage: app_update_sign_manifest.sh <asset-dir> <version> <ed25519-private-key.pem>
#
# Reads whichever of PearMusic-Windows-x64.zip, PearMusic-Windows-Setup.exe,
# PearMusic-Android-arm64.apk and PearMusic-Android-armv7.apk exist in
# <asset-dir>, then writes app-update.json and app-update.json.sig (base64
# Ed25519 signature over the exact manifest bytes) next to them.
#
# Environment:
#   TAG           release tag the GitHub copy lives under, for example v4.3.5
#   REPO          owner/name of the GitHub repository, for example Boci0/Pear-Music
#   MIRROR_BASES  optional space separated https base URLs that also hold each file
#   NOTES_FILE    optional text file with the release notes shown in the update dialog
#
# The app verifies the signature against the public keys in
# app/lib/services/signing_keys.dart and only installs files whose SHA-256 is
# listed here, from any of the listed URLs.
set -euo pipefail

dir="$1"; version="$2"; key="$3"
export DIR="$dir" VERSION="$version"
: "${TAG:?TAG is not set}" "${REPO:?REPO is not set}"
export TAG REPO MIRROR_BASES="${MIRROR_BASES:-}" NOTES_FILE="${NOTES_FILE:-}"

python3 - <<'PY'
import datetime, hashlib, json, os

d = os.environ["DIR"]
repo, tag = os.environ["REPO"], os.environ["TAG"]
mirrors = [b.rstrip("/") for b in os.environ["MIRROR_BASES"].split() if b.startswith("https://")]

assets = {}
for name in (
    "PearMusic-Windows-x64.zip",
    "PearMusic-Windows-Setup.exe",
    "PearMusic-Android-arm64.apk",
    "PearMusic-Android-armv7.apk",
):
    path = os.path.join(d, name)
    if not os.path.isfile(path):
        continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    urls = ["https://github.com/%s/releases/download/%s/%s" % (repo, tag, name)]
    urls += ["%s/%s" % (m, name) for m in mirrors]
    assets[name] = {"sha256": h.hexdigest(), "size": os.path.getsize(path), "urls": urls}
if not assets:
    raise SystemExit("no app release files found in " + d)

notes = ""
nf = os.environ["NOTES_FILE"]
if nf and os.path.isfile(nf):
    notes = open(nf, encoding="utf-8").read().strip()[:4000]

manifest = {
    "schema": 1,
    "kind": "app-update",
    "version": os.environ["VERSION"],
    "issued": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notes": notes,
    "page": "https://github.com/%s/releases/tag/%s" % (repo, tag),
    "assets": assets,
}
with open(os.path.join(d, "app-update.json"), "w", newline="\n", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY

openssl pkeyutl -sign -rawin -inkey "$key" -in "$dir/app-update.json" -out "$dir/app-update.json.sigraw"
base64 -w0 "$dir/app-update.json.sigraw" > "$dir/app-update.json.sig"
rm -f "$dir/app-update.json.sigraw"
echo "Signed $dir/app-update.json for Pear Music $version"
