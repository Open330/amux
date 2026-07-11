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
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fiq -- "$text" "$file"; then
    fail "$file still contains legacy release identity: $text"
  fi
}

require_missing() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "$path must not exist"
}

reject_tree_text() {
  local text="$1"
  shift
  if grep -RFiq -- "$text" "$@"; then
    fail "macOS release inputs still contain legacy identity: $text"
  fi
}

require_text "$PROJECT" 'PRODUCT_BUNDLE_IDENTIFIER = com.open330.amux;'
require_text "$PROJECT" 'PRODUCT_BUNDLE_IDENTIFIER = com.open330.amux.debug;'
require_text "$PROJECT" 'PRODUCT_NAME = "amux DEV";'
require_text "$PROJECT" 'PRODUCT_MODULE_NAME = cmux_DEV;'
require_text "$PROJECT" 'PRODUCT_MODULE_NAME = cmux;'
require_text "$PROJECT" 'CMUX_AUTH_CALLBACK_SCHEME = amux;'
require_text "$PROJECT" 'CMUX_AUTH_CALLBACK_SCHEME = "amux-dev";'
reject_text "$PROJECT" 'PRODUCT_NAME = "cmux DEV";'
reject_text "$PROJECT" 'cmux Dock Tile Plugin'
reject_text "$PROJECT" 'avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc='

require_text "$ROOT_DIR/scripts/reload.sh" 'APP_NAME="amux DEV"'
require_text "$ROOT_DIR/scripts/reloads.sh" 'APP_NAME="amux STAGING"'
require_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_NAME="amux"'
require_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_BUNDLE_ID="com.open330.amux"'
require_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_NAME="amux NIGHTLY"'
require_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_BUNDLE_ID="com.open330.amux.nightly"'
reject_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_NAME="cmux'
reject_text "$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" 'EXPECTED_BUNDLE_ID="com.cmuxterm.app'
require_text "$ROOT_DIR/scripts/release_asset_guard.js" '"amux-macos.dmg"'
reject_text "$ROOT_DIR/scripts/release_asset_guard.js" '"cmux-macos.dmg"'
reject_text "$ROOT_DIR/scripts/build-sign-upload.sh" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/scripts/build-sign-upload.sh" 'cmux-macos.dmg'
require_text "$ROOT_DIR/scripts/build-sign-upload.sh" 'HOMEBREW_GITHUB_TOKEN'
require_text "$ROOT_DIR/scripts/build-sign-upload.sh" './scripts/publish-homebrew-cask.sh'
require_text "$ROOT_DIR/scripts/finalize-amux-release.sh" '--draft=true --latest=false'
require_text "$ROOT_DIR/scripts/publish-homebrew-cask.sh" 'TAP_REPOSITORY="Open330/homebrew-tap"'
require_text "$ROOT_DIR/scripts/publish-homebrew-cask.sh" 'TAP_PATH="Casks/amux.rb"'
require_text "$ROOT_DIR/.github/workflows/release.yml" 'AMUX_HOMEBREW_GITHUB_TOKEN'
reject_text "$ROOT_DIR/.github/workflows/release.yml" 'TODO:'
require_text "$ROOT_DIR/.github/workflows/release.yml" 'tags: ["v*"]'
reject_text "$ROOT_DIR/.github/workflows/release.yml" '"amux-*"'
reject_text "$ROOT_DIR/scripts/build-signed-dmg.sh" 'warning: notarization failed'
require_text "$ROOT_DIR/scripts/build-signed-dmg.sh" 'error: notarization failed; refusing to publish an unstapled release'
require_text "$ROOT_DIR/scripts/build-signed-dmg.sh" 'ln -sfn amux "$BIN_DIR/cmux"'
require_text "$ROOT_DIR/scripts/build-signed-dmg.sh" 'error: release bundle is missing the amux CLI'

require_text "$ROOT_DIR/Resources/Info.plist" 'https://github.com/Open330/amux/releases/latest/download/appcast.xml'
reject_text "$ROOT_DIR/Resources/Info.plist" 'running within cmux'
reject_text "$ROOT_DIR/Resources/Info.plist" '<string>cmux Sidebar Tab Reorder</string>'
reject_text "$ROOT_DIR/Resources/Info.plist" '<string>cmux File Preview Transfer</string>'
reject_text "$ROOT_DIR/Resources/InfoPlist.xcstrings" 'within cmux'

reject_text "$ROOT_DIR/scripts/bump-version.sh" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh" 'manaflow-ai/cmux'

require_text "$ROOT_DIR/Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateManualDownloadRecovery.swift" 'https://github.com/Open330/amux/releases/latest/download/amux-macos.dmg'
require_text "$ROOT_DIR/Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateState.swift" 'https://github.com/Open330/amux/releases/tag/'
reject_text "$ROOT_DIR/Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateManualDownloadRecovery.swift" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateState.swift" 'manaflow-ai/cmux'
require_text "$ROOT_DIR/CLI/CMUXCLI+AgentHookCatalog.swift" 'hookMarker: "amux hooks codex"'
require_text "$ROOT_DIR/CLI/CMUXCLI+AgentHookDefinitions.swift" 'command -v amux'
require_text "$ROOT_DIR/Sources/TextBoxSubmitActions.swift" 'https://github.com/Open330/amux/blob/main/docs/configuration.md#terminaltextboxsubmitactions'
reject_text "$ROOT_DIR/Sources/TextBoxSubmitActions.swift" 'manaflow-ai/cmux'
require_text "$ROOT_DIR/Sources/cmuxApp.swift" 'static let enabledForCurrentLaunch = false'
require_text "$ROOT_DIR/CLI/CLISocketSentryTelemetry.swift" 'private static let dsn = ""'
reject_text "$ROOT_DIR/CLI/CLISocketSentryTelemetry.swift" 'ingest.us.sentry.io'
reject_text "$ROOT_DIR/Sources/AppDelegate.swift" 'ingest.us.sentry.io'
require_missing "$ROOT_DIR/Sources/PostHogAnalytics.swift"
reject_tree_text 'PostHog' \
  "$ROOT_DIR/Sources" \
  "$ROOT_DIR/CLI" \
  "$ROOT_DIR/cmuxTests" \
  "$ROOT_DIR/Resources/Localizable.xcstrings" \
  "$ROOT_DIR/THIRD_PARTY_LICENSES.md" \
  "$PROJECT"
require_text "$ROOT_DIR/Packages/iOS/CmuxMobileAnalytics/Sources/CmuxMobileAnalytics/AnalyticsConsentProviding.swift" 'as? Bool ?? false'
require_text "$ROOT_DIR/web/data/cmux.schema.json" 'Compatibility key retained by amux; telemetry is disabled.'
reject_text "$ROOT_DIR/Sources/AppDelegate.swift" 'auth.start()'
reject_text "$ROOT_DIR/Sources/Auth/AuthEnvironment.swift" 'https://cmux.com'
reject_text "$ROOT_DIR/Sources/Auth/AuthEnvironment.swift" 'https://api.cmux.sh'
reject_text "$ROOT_DIR/Sources/Auth/AuthEnvironment.swift" '9790718f-14cd-4f7e-824d-eaf527a82b82'
reject_text "$ROOT_DIR/Sources/Auth/AuthEnvironment.swift" 'pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr'
reject_text "$ROOT_DIR/Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthConfig.swift" '9790718f-14cd-4f7e-824d-eaf527a82b82'
reject_text "$ROOT_DIR/Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthConfig.swift" 'pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr'
require_text "$ROOT_DIR/Sources/cmuxApp.swift" 'self.authComposition = nil'
reject_text "$ROOT_DIR/Packages/macOS/CmuxFeedback/Sources/CmuxFeedback/Settings/FeedbackComposerSettings.swift" 'https://cmux.com/api/feedback'
reject_text "$ROOT_DIR/Packages/macOS/CmuxFeedback/Sources/CmuxFeedback/Settings/FeedbackComposerSettings.swift" 'founders@manaflow.com'
reject_text "$ROOT_DIR/Packages/macOS/CmuxFeedback/Sources/CmuxFeedback/ComposerUI/Resources/Localizable.xcstrings" 'founders@manaflow.com'
reject_text "$ROOT_DIR/Resources/Localizable.xcstrings" 'founders@manaflow.com'
reject_text "$ROOT_DIR/Sources/PricingPlansScreen.swift" 'founders@manaflow.com'
reject_text "$ROOT_DIR/Sources/ContentView.swift" 'contributions.append(contentsOf: Self.commandPaletteAuthCommandContributions()'
reject_text "$ROOT_DIR/Sources/ContentView.swift" 'registry.register(commandId: "palette.mobileConnect")'
require_text "$ROOT_DIR/Sources/AppDelegate.swift" 'sendTextWhenReady("amux welcome\n"'
reject_text "$ROOT_DIR/Sources/AppDelegate.swift" 'sendTextWhenReady("cmux welcome\n"'

require_text "$ROOT_DIR/.github/ISSUE_TEMPLATE/config.yml" 'https://github.com/Open330/amux/discussions'
require_text "$ROOT_DIR/.github/ISSUE_TEMPLATE/bug_report.yml" 'description: Report a bug in amux'
reject_text "$ROOT_DIR/.github/ISSUE_TEMPLATE/bug_report.yml" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/.github/FUNDING.yml" 'manaflow-ai/cmux'
require_text "$ROOT_DIR/skills/cmux-release/SKILL.md" 'gh run watch --repo Open330/amux'
require_text "$ROOT_DIR/skills/cmux-release/SKILL.md" '`amux-macos.dmg`'
reject_text "$ROOT_DIR/skills/cmux-release/SKILL.md" 'manaflow-ai/cmux'
reject_text "$ROOT_DIR/skills/cmux-release/SKILL.md" '`cmux-macos.dmg`'

MARKETING_VERSIONS="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$PROJECT" | sort -u)"
[[ "$(printf '%s\n' "$MARKETING_VERSIONS" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] \
  || fail "MARKETING_VERSION values are inconsistent: $MARKETING_VERSIONS"
[[ "$MARKETING_VERSIONS" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "MARKETING_VERSION is not semantic: $MARKETING_VERSIONS"

echo "PASS: amux release identity is canonical across app and distribution surfaces"
