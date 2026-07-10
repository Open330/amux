#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="Open330/amux"
HOMEBREW_PUBLISHER="$ROOT_DIR/scripts/publish-homebrew-cask.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <vX.Y.Z[-prerelease]> <amux-macos.dmg-sha256> <stable|prerelease>" >&2
  exit 2
fi

TAG="$1"
DMG_SHA256="$2"
CHANNEL="$3"
: "${GH_TOKEN:?GH_TOKEN with release access to Open330/amux is required}"
: "${HOMEBREW_GITHUB_TOKEN:?HOMEBREW_GITHUB_TOKEN is required}"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
  echo "error: invalid amux release tag: $TAG" >&2
  exit 1
}
[[ "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: invalid amux DMG SHA256: $DMG_SHA256" >&2
  exit 1
}
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "prerelease" ]] || {
  echo "error: release channel must be stable or prerelease" >&2
  exit 1
}

if [[ "$CHANNEL" == "stable" ]]; then
  GH_TOKEN="$GH_TOKEN" gh release edit "$TAG" \
    --repo "$REPOSITORY" --draft=false --prerelease=false --latest
else
  GH_TOKEN="$GH_TOKEN" gh release edit "$TAG" \
    --repo "$REPOSITORY" --draft=false --prerelease --latest=false
fi

if ! GH_TOKEN="$HOMEBREW_GITHUB_TOKEN" "$HOMEBREW_PUBLISHER" "$TAG" "$DMG_SHA256"; then
  echo "error: Homebrew publication failed; returning $REPOSITORY $TAG to draft" >&2
  if ! GH_TOKEN="$GH_TOKEN" gh release edit "$TAG" \
      --repo "$REPOSITORY" --draft=true --latest=false; then
    echo "error: failed to return $REPOSITORY $TAG to draft; manual intervention is required" >&2
  fi
  exit 1
fi

echo "Published $REPOSITORY $TAG and reconciled the Homebrew cask."
