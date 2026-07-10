#!/usr/bin/env bash
set -euo pipefail

# Canonical amux release entrypoint: build, sign, notarize, generate the
# Sparkle appcast, and publish immutable assets to Open330/amux.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="Open330/amux"
ALLOW_OVERWRITE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sign-upload.sh <vX.Y.Z[-prerelease]> [--allow-overwrite]

Required environment:
  SPARKLE_PUBLIC_KEY    amux Sparkle EdDSA public key
  SPARKLE_PRIVATE_KEY   matching private key
  GH_TOKEN              token allowed to publish Open330/amux releases
  HOMEBREW_GITHUB_TOKEN token allowed to update Open330/homebrew-tap

The signing certificate and notarization key are read by
scripts/build-signed-dmg.sh from the configured Vaultwarden session.
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-overwrite)
      ALLOW_OVERWRITE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done

[[ ${#POSITIONAL[@]} -eq 1 ]] || { usage >&2; exit 1; }
TAG="${POSITIONAL[0]}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
  echo "error: release tag must look like v0.2.0 or v0.2.0-alpha" >&2
  exit 1
}

: "${SPARKLE_PUBLIC_KEY:?SPARKLE_PUBLIC_KEY is required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${HOMEBREW_GITHUB_TOKEN:?HOMEBREW_GITHUB_TOKEN is required}"

SPARKLE_PRIVATE_KEY_VALUE="$SPARKLE_PRIVATE_KEY"
GH_TOKEN_VALUE="$GH_TOKEN"
HOMEBREW_GITHUB_TOKEN_VALUE="$HOMEBREW_GITHUB_TOKEN"
unset SPARKLE_PRIVATE_KEY GH_TOKEN HOMEBREW_GITHUB_TOKEN

for tool in gh git go jq node plutil python3 shasum swift xmllint; do
  command -v "$tool" >/dev/null || { echo "error: required tool not found: $tool" >&2; exit 1; }
done

canonicalize_base64() {
  local value
  value="$(printf '%s' "$1" | tr -d '[:space:]')"
  while (( ${#value} % 4 != 0 )); do value="${value}="; done
  printf '%s' "$value"
}

gh_with_token() {
  GH_TOKEN="$GH_TOKEN_VALUE" gh "$@"
}

cd "$ROOT_DIR"
AMUX_RELEASE_GITHUB_TOKEN="$GH_TOKEN_VALUE" ./scripts/release-pretag-guard.sh "$TAG"

git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1 || {
  echo "error: local tag $TAG does not exist; create and push the reviewed tag first" >&2
  exit 1
}
LOCAL_TAG_COMMIT="$(git rev-parse "$TAG^{commit}")"
HEAD_COMMIT="$(git rev-parse HEAD)"
[[ "$HEAD_COMMIT" == "$LOCAL_TAG_COMMIT" ]] || {
  echo "error: HEAD $HEAD_COMMIT does not match local $TAG commit $LOCAL_TAG_COMMIT" >&2
  exit 1
}
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || {
  echo "error: tracked worktree changes are present; refusing to release an uncommitted tree" >&2
  exit 1
}
REMOTE_TAG_COMMIT="$(gh_with_token api "repos/$REPOSITORY/commits/$TAG" --jq .sha 2>/dev/null || true)"
[[ "$REMOTE_TAG_COMMIT" == "$LOCAL_TAG_COMMIT" ]] || {
  echo "error: GitHub $TAG commit ${REMOTE_TAG_COMMIT:-<missing>} does not match local $LOCAL_TAG_COMMIT" >&2
  exit 1
}

MARKETING_VERSION="${TAG#v}"
MARKETING_VERSION="${MARKETING_VERSION%%-*}"

DERIVED_SPARKLE_PUBLIC_KEY="$(printf '%s' "$SPARKLE_PRIVATE_KEY_VALUE" | swift scripts/derive_sparkle_public_key.swift -)"
CANONICAL_SPARKLE_PUBLIC_KEY="$(canonicalize_base64 "$SPARKLE_PUBLIC_KEY")"
[[ "$(canonicalize_base64 "$DERIVED_SPARKLE_PUBLIC_KEY")" == "$CANONICAL_SPARKLE_PUBLIC_KEY" ]] || {
  echo "error: SPARKLE_PRIVATE_KEY does not match SPARKLE_PUBLIC_KEY" >&2
  exit 1
}

RELEASE_JSON="$(gh_with_token release view "$TAG" --repo "$REPOSITORY" --json assets,isDraft 2>/dev/null || true)"
RELEASE_EXISTS=0
RELEASE_IS_DRAFT=0
EXISTING_ASSETS=""
if [[ -n "$RELEASE_JSON" ]]; then
  RELEASE_EXISTS=1
  EXISTING_ASSETS="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[].name')"
  [[ "$(printf '%s' "$RELEASE_JSON" | jq -r '.isDraft')" == "true" ]] && RELEASE_IS_DRAFT=1
fi
IMMUTABLE_ASSETS=()
while IFS= read -r asset; do
  [[ -n "$asset" ]] && IMMUTABLE_ASSETS+=("$asset")
done < <(node -e 'for (const asset of require("./scripts/release_asset_guard").IMMUTABLE_RELEASE_ASSETS) console.log(asset)')
[[ "${#IMMUTABLE_ASSETS[@]}" -gt 0 ]] || {
  echo "error: immutable release asset list is empty" >&2
  exit 1
}
EXISTING_REQUIRED_COUNT=0
for asset in "${IMMUTABLE_ASSETS[@]}"; do
  printf '%s\n' "$EXISTING_ASSETS" | grep -Fxq "$asset" && EXISTING_REQUIRED_COUNT=$((EXISTING_REQUIRED_COUNT + 1))
done
if [[ "$RELEASE_IS_DRAFT" == "1" ]]; then
  ALLOW_OVERWRITE=1
elif [[ "$EXISTING_REQUIRED_COUNT" == "${#IMMUTABLE_ASSETS[@]}" && "$ALLOW_OVERWRITE" != "1" ]]; then
  EXISTING_DMG_DIGEST="$(printf '%s' "$RELEASE_JSON" | jq -r '.assets[] | select(.name == "amux-macos.dmg") | .digest // empty')"
  EXISTING_DMG_SHA256="${EXISTING_DMG_DIGEST#sha256:}"
  [[ "$EXISTING_DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "error: existing amux DMG has no usable SHA256 digest" >&2
    exit 1
  }
  GH_TOKEN="$HOMEBREW_GITHUB_TOKEN_VALUE" ./scripts/publish-homebrew-cask.sh "$TAG" "$EXISTING_DMG_SHA256"
  echo "Release $TAG already has the immutable amux assets; Homebrew cask reconciled."
  exit 0
elif [[ "$EXISTING_REQUIRED_COUNT" != "0" && "$ALLOW_OVERWRITE" != "1" ]]; then
  echo "error: release $TAG has a partial immutable asset set; inspect it and rerun with --allow-overwrite" >&2
  exit 1
fi

REMOTE_ASSET_DIR="$ROOT_DIR/build-release-assets"
rm -rf "$REMOTE_ASSET_DIR"
mkdir -p "$REMOTE_ASSET_DIR"
./scripts/build_remote_daemon_release_assets.sh \
  --version "$MARKETING_VERSION" \
  --release-tag "$TAG" \
  --repo "$REPOSITORY" \
  --output-dir "$REMOTE_ASSET_DIR"
REMOTE_MANIFEST="$REMOTE_ASSET_DIR/cmuxd-remote-manifest.json"
for asset in "${IMMUTABLE_ASSETS[@]}"; do
  case "$asset" in
    amux-macos.dmg|appcast.xml) ;;
    *) [[ -f "$REMOTE_ASSET_DIR/$asset" ]] || { echo "error: missing remote daemon release asset: $asset" >&2; exit 1; } ;;
  esac
done

AMUX_REMOTE_DAEMON_MANIFEST_PATH="$REMOTE_MANIFEST" \
  SPARKLE_PUBLIC_KEY="$CANONICAL_SPARKLE_PUBLIC_KEY" \
  ./scripts/build-signed-dmg.sh --notarize

APP="build-signed/Build/Products/Release/amux.app"
APP_PLIST="$APP/Contents/Info.plist"
[[ -d "$APP" ]] || { echo "error: release build did not produce amux.app" >&2; exit 1; }

ACTUAL_NAME="$(plutil -extract CFBundleName raw "$APP_PLIST")"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PLIST")"
ACTUAL_FEED="$(plutil -extract SUFeedURL raw "$APP_PLIST")"
ACTUAL_SPARKLE_KEY="$(canonicalize_base64 "$(plutil -extract SUPublicEDKey raw "$APP_PLIST")")"
ACTUAL_REMOTE_MANIFEST="$(plutil -extract CMUXRemoteDaemonManifestJSON raw "$APP_PLIST")"
[[ "$ACTUAL_NAME" == "amux" ]] || { echo "error: release app name is $ACTUAL_NAME" >&2; exit 1; }
[[ "$ACTUAL_BUNDLE_ID" == "com.open330.amux" ]] || { echo "error: release bundle id is $ACTUAL_BUNDLE_ID" >&2; exit 1; }
[[ "$ACTUAL_FEED" == "https://github.com/Open330/amux/releases/latest/download/appcast.xml" ]] || {
  echo "error: release feed points at $ACTUAL_FEED" >&2
  exit 1
}
[[ "$ACTUAL_SPARKLE_KEY" == "$CANONICAL_SPARKLE_PUBLIC_KEY" ]] || {
  echo "error: built app does not contain the requested amux Sparkle public key" >&2
  exit 1
}
[[ "$(printf '%s' "$ACTUAL_REMOTE_MANIFEST" | jq -cS .)" == "$(jq -cS . "$REMOTE_MANIFEST")" ]] || {
  echo "error: built app does not contain the release remote daemon manifest" >&2
  exit 1
}

rm -f appcast.xml
SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY_VALUE" \
  ./scripts/sparkle_generate_appcast.sh amux-macos.dmg "$TAG" appcast.xml
grep -Fq "github.com/Open330/amux/releases/download/$TAG/amux-macos.dmg" appcast.xml || {
  echo "error: generated appcast does not point at the amux release asset" >&2
  exit 1
}

if [[ "$RELEASE_EXISTS" == "0" ]]; then
  gh_with_token release create "$TAG" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --draft \
    --title "$TAG" \
    --notes "See CHANGELOG.md for details."
  RELEASE_IS_DRAFT=1
fi

UPLOAD_ASSETS=(amux-macos.dmg appcast.xml)
for asset in "${IMMUTABLE_ASSETS[@]}"; do
  case "$asset" in
    amux-macos.dmg|appcast.xml) ;;
    *) UPLOAD_ASSETS+=("$REMOTE_ASSET_DIR/$asset") ;;
  esac
done
if [[ "$ALLOW_OVERWRITE" == "1" ]]; then
  gh_with_token release upload "$TAG" "${UPLOAD_ASSETS[@]}" --repo "$REPOSITORY" --clobber
else
  gh_with_token release upload "$TAG" "${UPLOAD_ASSETS[@]}" --repo "$REPOSITORY"
fi

DMG_SHA256="$(shasum -a 256 amux-macos.dmg | awk '{print $1}')"
if [[ "$RELEASE_IS_DRAFT" == "1" ]]; then
  if [[ "$TAG" == "v$MARKETING_VERSION" ]]; then
    RELEASE_CHANNEL=stable
  else
    RELEASE_CHANNEL=prerelease
  fi
  GH_TOKEN="$GH_TOKEN_VALUE" HOMEBREW_GITHUB_TOKEN="$HOMEBREW_GITHUB_TOKEN_VALUE" \
    ./scripts/finalize-amux-release.sh "$TAG" "$DMG_SHA256" "$RELEASE_CHANNEL"
else
  GH_TOKEN="$HOMEBREW_GITHUB_TOKEN_VALUE" ./scripts/publish-homebrew-cask.sh "$TAG" "$DMG_SHA256"
fi

echo "Published $REPOSITORY $TAG"
echo "amux-macos.dmg sha256: $DMG_SHA256"
echo "Published Open330/homebrew-tap Casks/amux.rb"
