#!/usr/bin/env bash
# Writes the release notes for a release tag (default RELEASE_NOTES.md).
#
# Usage: TAG=v4.6.0 GITHUB_REPOSITORY=Boci0/Pear-Music release_notes.sh [out-file]
#
# Run from the repository root, with SHA256SUMS next to it. The notes are the
# tag's message plus the commit subjects since the previous tag. Commits whose
# subject starts with build:, ci:, chore:, test: or docs: are left out: they are
# about the project's tooling, and the notes also end up in the signed
# app-update.json that the in-app update dialog shows.
#
# Used by .github/workflows/release.yml and republish-update-notes.yml, so a
# release and a re-signed manifest cannot disagree.
set -euo pipefail

: "${TAG:?TAG is not set}" "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
out="${1:-RELEASE_NOTES.md}"
[ -f SHA256SUMS ] || { echo "SHA256SUMS not found in $(pwd)" >&2; exit 1; }

INTERNAL='^(build|ci|chore|test|docs)(\([^)]*\))?!?:'

# Subjects for the change list, internal ones dropped. A filter that matches
# everything must not fail the pipeline.
changes() {
  local lines
  lines=$({ git log "$@" --no-merges --pretty=format:"%s (%h)" | grep -viE "$INTERNAL" || true; } | sed 's/^/* /')
  printf '%s' "$lines"
}

# actions/checkout leaves the pushed tag as a lightweight ref, which makes
# %(contents) read the tip commit's message instead of the tag's.
git fetch --force origin "refs/tags/${TAG}:refs/tags/${TAG}"
PREV_TAG=$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo "")
TAG_SUBJECT=$(git tag -l --format='%(contents:subject)' "$TAG")
TAG_BODY=$(git tag -l --format='%(contents:body)' "$TAG" | sed -E '/^(Co-Authored-By|Claude-Session|Signed-off-by):/Id')
CLEAN_SUBJECT=$(echo "$TAG_SUBJECT" | sed -E 's/^release:[[:space:]]*v?[0-9.]+[[:space:]]*-[[:space:]]*//I')

{
  echo "## Overview"
  if [ -n "$CLEAN_SUBJECT" ]; then
    echo "$CLEAN_SUBJECT"
  else
    echo "Pear Music ${TAG#v} release."
  fi

  if [ -n "$TAG_BODY" ]; then
    echo ""
    echo "$TAG_BODY"
  fi
  echo ""

  echo "## Key Changes"
  if [ -n "$PREV_TAG" ]; then
    changes "${PREV_TAG}..${TAG}"
    echo ""
    echo ""
    echo "**Full Changelog**: https://github.com/${GITHUB_REPOSITORY}/compare/${PREV_TAG}...${TAG}"
  else
    changes -n 15 "$TAG"
  fi
  echo ""
  echo ""
  echo "## Verification (SHA-256)"
  echo '```'
  cat SHA256SUMS
  echo '```'
} > "$out"
