#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_GITHUB_TOKEN="${AMUX_RELEASE_GITHUB_TOKEN:-${GH_TOKEN:-}}"
unset AMUX_RELEASE_GITHUB_TOKEN GH_TOKEN

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [vX.Y.Z[-prerelease]]" >&2
  exit 2
fi
PROPOSED_TAG="${1:-}"

echo "Running release pre-tag checks..."
if [[ -n "$PROPOSED_TAG" ]]; then
  "$ROOT_DIR/scripts/check-amux-release-metadata.sh" "$PROPOSED_TAG"
else
  "$ROOT_DIR/scripts/check-amux-release-metadata.sh"
fi
"$ROOT_DIR/tests/test_amux_release_identity.sh"
"$ROOT_DIR/tests/test_amux_release_pipeline.sh"
if [[ -n "$RELEASE_GITHUB_TOKEN" ]]; then
  GH_TOKEN="$RELEASE_GITHUB_TOKEN" "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
else
  "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
fi
node "$ROOT_DIR/scripts/release_asset_guard.test.js"
bash -n \
  "$ROOT_DIR/scripts/build-amux-runtime.sh" \
  "$ROOT_DIR/scripts/check-amux-release-metadata.sh" \
  "$ROOT_DIR/scripts/finalize-amux-release.sh" \
  "$ROOT_DIR/scripts/build-signed-dmg.sh" \
  "$ROOT_DIR/scripts/build-sign-upload.sh" \
  "$ROOT_DIR/scripts/sparkle_generate_appcast.sh" \
  "$ROOT_DIR/scripts/verify-amux-release-dmg.sh"
echo "Release pre-tag checks passed."
