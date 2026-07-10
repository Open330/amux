#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_REPOSITORY="Open330/homebrew-tap"
TAP_PATH="Casks/amux.rb"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <vX.Y.Z[-prerelease]> <amux-macos.dmg-sha256>" >&2
  exit 2
fi

TAG="$1"
DMG_SHA256="$2"
: "${GH_TOKEN:?GH_TOKEN with push access to Open330/homebrew-tap is required}"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
  echo "error: invalid amux release tag: $TAG" >&2
  exit 1
}
[[ "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: invalid amux DMG SHA256: $DMG_SHA256" >&2
  exit 1
}

VERSION="${TAG#v}"
TEMPLATE="$ROOT_DIR/packaging/homebrew/amux.rb"
[[ -f "$TEMPLATE" ]] || {
  echo "error: Homebrew cask template not found: $TEMPLATE" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CASK="$WORK/amux.rb"
sed -E \
  -e "s/^  version \"[^\"]+\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$DMG_SHA256\"/" \
  "$TEMPLATE" > "$CASK"

grep -Fq "  version \"$VERSION\"" "$CASK" || {
  echo "error: failed to render Homebrew cask version" >&2
  exit 1
}
grep -Fq "  sha256 \"$DMG_SHA256\"" "$CASK" || {
  echo "error: failed to render Homebrew cask checksum" >&2
  exit 1
}
if [[ "${AMUX_HOMEBREW_CASK_DRY_RUN:-}" == "1" ]]; then
  echo "Validated Homebrew cask: $VERSION ($DMG_SHA256)"
  exit 0
fi

EXISTING_JSON="$(gh api "repos/$TAP_REPOSITORY/contents/$TAP_PATH" 2>/dev/null || true)"
EXISTING_SHA="$(printf '%s' "$EXISTING_JSON" | jq -r '.sha // empty' 2>/dev/null || true)"
RENDERED_GIT_SHA="$(git hash-object "$CASK")"
if [[ -n "$EXISTING_SHA" && "$EXISTING_SHA" == "$RENDERED_GIT_SHA" ]]; then
  echo "Homebrew cask is already current: $TAP_REPOSITORY/$TAP_PATH"
  exit 0
fi

CONTENT="$(base64 < "$CASK" | tr -d '\n')"
ARGS=(
  "repos/$TAP_REPOSITORY/contents/$TAP_PATH"
  --method PUT
  -f "message=chore(amux): update cask to $VERSION"
  -f "content=$CONTENT"
  -f "branch=main"
)
if [[ -n "$EXISTING_SHA" ]]; then
  ARGS+=(-f "sha=$EXISTING_SHA")
fi
gh api "${ARGS[@]}" >/dev/null
echo "Published Homebrew cask: $TAP_REPOSITORY/$TAP_PATH ($VERSION)"
