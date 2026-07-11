#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amux-release-pipeline-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Release metadata must be dated before a tag can be proposed.
METADATA_ROOT="$WORK/metadata"
mkdir -p "$METADATA_ROOT/scripts" "$METADATA_ROOT/cmux.xcodeproj"
cp "$ROOT_DIR/scripts/check-amux-release-metadata.sh" "$METADATA_ROOT/scripts/"
PROJECT="$METADATA_ROOT/cmux.xcodeproj/project.pbxproj"
CHANGELOG="$METADATA_ROOT/CHANGELOG.md"
printf '%s\n' \
  'MARKETING_VERSION = 0.2.0;' \
  'MARKETING_VERSION = 0.2.0;' > "$PROJECT"
printf '%s\n' '# Changelog' '' '## [0.2.0] - Unreleased' > "$CHANGELOG"

if "$METADATA_ROOT/scripts/check-amux-release-metadata.sh" v0.2.0 >"$WORK/metadata.out" 2>&1; then
  fail "Unreleased changelog passed the pre-tag metadata check"
fi
grep -Fq 'still marks 0.2.0 as Unreleased' "$WORK/metadata.out" \
  || fail "Unreleased rejection did not explain the failure"

printf '%s\n' '# Changelog' '' '## [0.2.0] - 2026-07-11' > "$CHANGELOG"
"$METADATA_ROOT/scripts/check-amux-release-metadata.sh" v0.2.0 >/dev/null
if "$METADATA_ROOT/scripts/check-amux-release-metadata.sh" v0.3.0 >"$WORK/version.out" 2>&1; then
  fail "mismatched tag and MARKETING_VERSION passed metadata validation"
fi

# A Homebrew failure after publication must return the release to draft.
FINALIZE_ROOT="$WORK/finalize"
mkdir -p "$FINALIZE_ROOT/scripts" "$WORK/fake-bin"
cp "$ROOT_DIR/scripts/finalize-amux-release.sh" "$FINALIZE_ROOT/scripts/"
cat > "$FINALIZE_ROOT/scripts/publish-homebrew-cask.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo homebrew >> "$AMUX_TEST_RELEASE_LOG"
[[ "${AMUX_TEST_HOMEBREW_FAIL:-0}" != "1" ]]
SH
cat > "$WORK/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$AMUX_TEST_RELEASE_LOG"
SH
chmod +x "$FINALIZE_ROOT/scripts/"*.sh "$WORK/fake-bin/gh"

RELEASE_LOG="$WORK/release.log"
AMUX_TEST_RELEASE_LOG="$RELEASE_LOG" \
  GH_TOKEN=release-token \
  HOMEBREW_GITHUB_TOKEN=homebrew-token \
  PATH="$WORK/fake-bin:$PATH" \
  "$FINALIZE_ROOT/scripts/finalize-amux-release.sh" \
    v0.2.0 "$(printf 'a%.0s' {1..64})" stable >/dev/null
[[ "$(sed -n '1p' "$RELEASE_LOG")" == "gh release edit v0.2.0 --repo Open330/amux --draft=false --prerelease=false --latest" ]] \
  || fail "draft release was not published before Homebrew reconciliation"
[[ "$(sed -n '2p' "$RELEASE_LOG")" == "homebrew" ]] \
  || fail "Homebrew was not reconciled immediately after release publication"

: > "$RELEASE_LOG"
if AMUX_TEST_RELEASE_LOG="$RELEASE_LOG" \
    AMUX_TEST_HOMEBREW_FAIL=1 \
    GH_TOKEN=release-token \
    HOMEBREW_GITHUB_TOKEN=homebrew-token \
    PATH="$WORK/fake-bin:$PATH" \
    "$FINALIZE_ROOT/scripts/finalize-amux-release.sh" \
      v0.2.0 "$(printf 'b%.0s' {1..64})" stable >"$WORK/finalize.out" 2>&1; then
  fail "release finalization succeeded after Homebrew publication failed"
fi
grep -Fq 'gh release edit v0.2.0 --repo Open330/amux --draft=true --latest=false' "$RELEASE_LOG" \
  || fail "release was not returned to draft after Homebrew publication failed"

# The final DMG verifier must inspect the mounted artifact, not the build tree.
FIXTURE="$WORK/fixture"
APP="$FIXTURE/amux.app"
mkdir -p "$APP/Contents/Resources/bin"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>amux</string>
<key>CFBundleIdentifier</key><string>com.open330.amux</string>
<key>CMUXRemoteDaemonManifestJSON</key>
<string>{"schemaVersion":1,"entries":[{"downloadURL":"https://github.com/Open330/amux/releases/download/v0.2.0/a","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"downloadURL":"https://github.com/Open330/amux/releases/download/v0.2.0/b","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},{"downloadURL":"https://github.com/Open330/amux/releases/download/v0.2.0/c","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},{"downloadURL":"https://github.com/Open330/amux/releases/download/v0.2.0/d","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}]}</string>
</dict></plist>
PLIST
cat > "$APP/Contents/Resources/bin/amux" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo 'amux 0.2.0 (98)'
else
  echo 'amux - control amux via Unix socket'
fi
SH
chmod +x "$APP/Contents/Resources/bin/amux"
touch "$WORK/amux-macos.dmg"

cat > "$WORK/fake-bin/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "attach" ]]; then
  mount_point=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-mountpoint" ]]; then
      mount_point="$2"
      break
    fi
    shift
  done
  cp -R "$AMUX_TEST_DMG_FIXTURE/amux.app" "$mount_point/amux.app"
fi
SH
cat > "$WORK/fake-bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >> "$AMUX_TEST_DMG_LOG"
SH
cat > "$WORK/fake-bin/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "spctl $*" >> "$AMUX_TEST_DMG_LOG"
SH
chmod +x "$WORK/fake-bin/hdiutil" "$WORK/fake-bin/codesign" "$WORK/fake-bin/spctl"

DMG_LOG="$WORK/dmg.log"
AMUX_TEST_DMG_FIXTURE="$FIXTURE" AMUX_TEST_DMG_LOG="$DMG_LOG" \
  PATH="$WORK/fake-bin:$PATH" \
  "$ROOT_DIR/scripts/verify-amux-release-dmg.sh" "$WORK/amux-macos.dmg" --require-gatekeeper >/dev/null
grep -Fq 'spctl --assess --type open' "$DMG_LOG" || fail "DMG Gatekeeper assessment was not run"
grep -Fq 'spctl --assess --type execute' "$DMG_LOG" || fail "app Gatekeeper assessment was not run"
grep -Fq 'codesign --verify --deep --strict' "$DMG_LOG" || fail "mounted app signature was not verified"

ln -s amux "$APP/Contents/Resources/bin/cmux"
if AMUX_TEST_DMG_FIXTURE="$FIXTURE" AMUX_TEST_DMG_LOG="$DMG_LOG" \
    PATH="$WORK/fake-bin:$PATH" \
    "$ROOT_DIR/scripts/verify-amux-release-dmg.sh" "$WORK/amux-macos.dmg" >"$WORK/alias.out" 2>&1; then
  fail "retired cmux CLI alias passed final DMG verification"
fi
grep -Fq 'must not include the retired cmux CLI alias' "$WORK/alias.out" \
  || fail "retired alias failure was not actionable"

rm "$APP/Contents/Resources/bin/cmux"
plutil -replace CMUXRemoteDaemonManifestJSON -string '{}' "$APP/Contents/Info.plist"
if AMUX_TEST_DMG_FIXTURE="$FIXTURE" AMUX_TEST_DMG_LOG="$DMG_LOG" \
    PATH="$WORK/fake-bin:$PATH" \
    "$ROOT_DIR/scripts/verify-amux-release-dmg.sh" "$WORK/amux-macos.dmg" >"$WORK/manifest.out" 2>&1; then
  fail "invalid remote daemon manifest passed final DMG verification"
fi
grep -Fq 'no valid Open330 remote daemon manifest' "$WORK/manifest.out" \
  || fail "invalid remote daemon manifest failure was not actionable"

echo "PASS: release metadata, fail-closed publication, and final DMG verification"
