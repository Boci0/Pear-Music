#!/usr/bin/env bash
# Uploads the yt-dlp mirror files to a Codeberg (Gitea) release.
#
# Usage: ytdlp_publish_codeberg.sh <owner/repo> <tag> <file>...
#
# Needs CODEBERG_TOKEN (a Codeberg access token with repository write scope).
# Creates the release as a prerelease on first use, and replaces any existing
# asset of the same name. The repository must already exist and have a commit.
set -euo pipefail

repo="$1"; tag="$2"; shift 2
api="https://codeberg.org/api/v1/repos/$repo"
auth=(-H "Authorization: token ${CODEBERG_TOKEN:?CODEBERG_TOKEN is not set}")

release=$(curl -sS "${auth[@]}" -w '\n%{http_code}' "$api/releases/tags/$tag")
code=${release##*$'\n'}
body=${release%$'\n'*}
if [ "$code" = "404" ]; then
  body=$(curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
    -d "{\"tag_name\":\"$tag\",\"name\":\"yt-dlp mirror\",\"body\":\"Signed yt-dlp builds used as a fallback download source by Pear Music.\",\"prerelease\":true}" \
    "$api/releases")
elif [ "$code" != "200" ]; then
  echo "Codeberg release lookup failed: HTTP $code" >&2
  exit 1
fi

id=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

for file in "$@"; do
  name=$(basename "$file")
  old=$(printf '%s' "$body" | NAME="$name" python3 -c '
import json, os, sys
for a in json.load(sys.stdin).get("assets", []):
    if a["name"] == os.environ["NAME"]:
        print(a["id"])')
  if [ -n "$old" ]; then
    curl -fsS "${auth[@]}" -X DELETE "$api/releases/$id/assets/$old"
  fi
  curl -fsS "${auth[@]}" -F "attachment=@$file" "$api/releases/$id/assets?name=$name" > /dev/null
  echo "Uploaded $name to codeberg.org/$repo ($tag)"
done
