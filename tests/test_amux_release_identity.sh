#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/cmux.xcodeproj/project.pbxproj"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "$file is missing: $text"
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fiq "$text" "$file"; then
    fail "$file still contains legacy release identity: $text"
  fi
}

require_text "$PROJECT" 'PRODUCT_BUNDLE_IDENTIFIER = com.open330.amux;'
require_text "$PROJECT" 'PRODUCT_BUNDLE_IDENTIFIER = com.open330.amux.debug;'
require_text "$PROJECT" 'PRODUCT_NAME = "amux DEV";'
require_text "$PROJECT" 'CMUX_AUTH_CALLBACK_SCHEME = amux;'
require_text "$PROJECT" 'CMUX_AUTH_CALLBACK_SCHEME = "amux-dev";'
require_text "$PROJECT" 'MARKETING_VERSION = 0.2.0;'
reject_text "$PROJECT" 'PRODUCT_NAME = "cmux DEV";'
reject_text "$PROJECT" 'cmux Dock Tile Plugin'

require_text "$ROOT_DIR/scripts/reload.sh" 'APP_NAME="amux DEV"'
require_text "$ROOT_DIR/scripts/reloads.sh" 'APP_NAME="amux STAGING"'
require_text "$ROOT_DIR/scripts/release_asset_guard.js" '"amux-macos.dmg"'
reject_text "$ROOT_DIR/scripts/release_asset_guard.js" '"cmux-macos.dmg"'
reject_text "$ROOT_DIR/scripts/build-sign-upload.sh" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/scripts/build-sign-upload.sh" 'cmux-macos.dmg'
reject_text "$ROOT_DIR/.gitea/workflows/release.yml" 'TODO:'

require_text "$ROOT_DIR/Resources/Info.plist" 'https://github.com/Open330/amux/releases/latest/download/appcast.xml'
reject_text "$ROOT_DIR/Resources/Info.plist" 'running within cmux'
reject_text "$ROOT_DIR/Resources/Info.plist" '<string>cmux Sidebar Tab Reorder</string>'
reject_text "$ROOT_DIR/Resources/Info.plist" '<string>cmux File Preview Transfer</string>'
reject_text "$ROOT_DIR/Resources/InfoPlist.xcstrings" 'within cmux'

reject_text "$ROOT_DIR/scripts/bump-version.sh" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh" 'manaflow-ai/cmux'

echo "PASS: amux release identity is canonical across app and distribution surfaces"
