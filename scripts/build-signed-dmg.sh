#!/usr/bin/env bash
# Build a signed (and, when requested, notarized) amux-macos.dmg.
#
# Signing material is pulled from Vaultwarden at runtime (never written to the
# repo, never printed). A temporary keychain holds the imported identity and
# is deleted on exit. Requires: an unlocked bw session (~/.bw_session), Xcode,
# create-dmg (npm), and the staged amux runtime (scripts/build-amux-runtime.sh).
# Release artifacts currently target Apple Silicon; bundled tmux and muxa
# binaries are validated against that architecture before signing.
#
# Usage: scripts/build-signed-dmg.sh [--notarize]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
NOTARIZE=0
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [--notarize]" >&2
  exit 2
fi
if [[ "${1:-}" == "--notarize" ]]; then
  NOTARIZE=1
elif [[ -n "${1:-}" ]]; then
  echo "error: unknown option: $1" >&2
  exit 2
fi

: "${SPARKLE_PUBLIC_KEY:?Set SPARKLE_PUBLIC_KEY to the amux Sparkle EdDSA public key}"
: "${AMUX_REMOTE_DAEMON_MANIFEST_PATH:?Set AMUX_REMOTE_DAEMON_MANIFEST_PATH to the release manifest}"
RELEASE_ARCHS="${AMUX_RELEASE_ARCHS:-arm64}"
[[ -f "$AMUX_REMOTE_DAEMON_MANIFEST_PATH" ]] || {
  echo "error: remote daemon manifest not found: $AMUX_REMOTE_DAEMON_MANIFEST_PATH" >&2
  exit 1
}
python3 -m json.tool "$AMUX_REMOTE_DAEMON_MANIFEST_PATH" >/dev/null

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BW_SESSION_VALUE="$(cat ~/.bw_session)"
CERT_ITEM="Developer ID Application (Jiun Bae)"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/amux-signing.keychain-db"
KEYCHAIN_PW="$(openssl rand -hex 16)"
ORIG_KEYCHAINS=()
cleanup() {
  if [[ ${#ORIG_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" 2>/dev/null || true
  fi
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> fetching Developer ID cert from Vault"
vault-get() { BW_SESSION="$BW_SESSION_VALUE" bw get item "$1" 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(f['value'] for f in d['fields'] if f['name']=='$2'))"; }
P12_PW="$(vault-get "$CERT_ITEM" p12_password)"
TEAM_ID="$(vault-get "$CERT_ITEM" team_id)"
vault-get "$CERT_ITEM" p12_b64 | base64 --decode > "$WORK/cert.p12"

echo "==> creating temporary signing keychain"
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
# Prepend our keychain to the search list so codesign finds the identity.
while IFS= read -r keychain_path; do
  keychain_path="${keychain_path#\"}"
  keychain_path="${keychain_path%\"}"
  [[ -n "$keychain_path" ]] && ORIG_KEYCHAINS+=("$keychain_path")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*//')
security list-keychains -d user -s "$KEYCHAIN" "${ORIG_KEYCHAINS[@]}"
rm -f "$WORK/cert.p12"

IDENTITY="$(
  security find-identity -v -p codesigning "$KEYCHAIN" \
    | sed -n 's/^[^"]*"\([^"]*Developer ID Application[^"]*\)".*/\1/p' \
    | head -n 1
)"
echo "==> signing identity: ${IDENTITY:-<none found>}"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity imported" >&2; exit 1; }
[[ "$IDENTITY" == *"($TEAM_ID)"* ]] || {
  echo "error: signing identity does not match Vault team $TEAM_ID" >&2
  exit 1
}

echo "==> staging amux runtime (tmux + muxa)"
env -u SPARKLE_PRIVATE_KEY -u GH_TOKEN \
  CMUX_SKIP_AMUX_RUNTIME= ./scripts/build-amux-runtime.sh --build-tmux
for runtime in tmux muxad muxa; do
  runtime_path="vendor/amux-runtime/bin/$runtime"
  [[ -x "$runtime_path" ]] || { echo "error: required runtime is missing: $runtime_path" >&2; exit 1; }
  if ! lipo -archs "$runtime_path" | tr ' ' '\n' | grep -Fxq "$RELEASE_ARCHS"; then
    echo "error: $runtime_path does not contain required architecture $RELEASE_ARCHS" >&2
    exit 1
  fi
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *) echo "error: $runtime has non-portable dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$runtime_path" | tail -n +2 | awk '{print $1}')
done

echo "==> building Release ($RELEASE_ARCHS, unsigned — Developer ID is applied manually)"
# Build unsigned so xcodebuild does not demand a provisioning profile for the
# keychain-access-groups entitlement. Developer ID direct distribution applies
# entitlements at codesign time instead — no profile needed.
rm -rf build-signed
env -u SPARKLE_PRIVATE_KEY -u GH_TOKEN -u BW_SESSION \
  CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux \
  -configuration Release -derivedDataPath build-signed \
  -destination 'generic/platform=macOS' \
  ARCHS="$RELEASE_ARCHS" ONLY_ACTIVE_ARCH=NO \
  SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build-signed/Build/Products/Release/amux.app"
[[ -d "$APP" ]] || { echo "error: amux.app not produced" >&2; exit 1; }

echo "==> embedding remote daemon release manifest"
plutil -replace CMUXRemoteDaemonManifestJSON \
  -string "$(cat "$AMUX_REMOTE_DAEMON_MANIFEST_PATH")" \
  "$APP/Contents/Info.plist"

echo "==> bundling runtime into the app"
BIN_DIR="$APP/Contents/Resources/bin"; mkdir -p "$BIN_DIR"
if [[ -d vendor/amux-runtime/bin ]]; then
  for rt in vendor/amux-runtime/bin/*; do cp "$rt" "$BIN_DIR/"; chmod +x "$BIN_DIR/$(basename "$rt")"; done
fi
if [[ ! -x "$BIN_DIR/amux" || -L "$BIN_DIR/amux" ]]; then
  echo "error: release bundle is missing the amux CLI" >&2
  exit 1
fi

echo "==> signing (Developer ID, hardened runtime, inside-out)"
# Deliberately sign WITHOUT the keychain-access-groups entitlement. It is a
# *restricted* entitlement that requires an embedded provisioning profile to
# authorize; applying it to a Developer ID build with no profile makes launchd
# refuse to spawn the app (RBS "Launchd job spawn failed", POSIX 163 — the app
# is signed + notarized yet won't open). The declared group was just the app's
# own default group ($(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)), which
# every app gets implicitly, so dropping it is a no-op for keychain behavior.
# (Verified: re-signing the failing app without it → launches.) If amux ever
# needs a *shared* keychain group, create a Developer ID provisioning profile
# for com.open330.amux and embed it instead.
#
# The direct-distribution entitlement intentionally omits application-identifier,
# team-identifier, and keychain-access-groups. The shared signer preserves the
# app's functional hardened-runtime entitlements and never applies --deep to the
# main bundle.
CMUX_HELPER_ENTITLEMENTS="$PROJECT_DIR/cmux-helper.entitlements" \
  "$PROJECT_DIR/scripts/sign-cmux-bundle.sh" \
  "$APP" \
  "$PROJECT_DIR/amux.release.entitlements" \
  "$IDENTITY"

echo "==> creating dmg"
command -v create-dmg >/dev/null 2>&1 || npm install --global create-dmg@6 >/dev/null 2>&1
rm -f amux-macos.dmg ./*.dmg 2>/dev/null || true
create-dmg "$APP" "$PROJECT_DIR"
DMG="$(ls -t "$PROJECT_DIR"/*.dmg 2>/dev/null | head -1)"
[[ -n "$DMG" ]] || { echo "error: dmg not created" >&2; exit 1; }
mv "$DMG" amux-macos.dmg
codesign --force --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" amux-macos.dmg
echo "==> signed dmg: amux-macos.dmg ($(du -h amux-macos.dmg | cut -f1))"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> notarizing (App Store Connect API key)"
  API_ITEM="App Store Connect API Key - file-stack"
  KEY_ID="$(vault-get "$API_ITEM" key_id)"
  ISSUER_ID="$(vault-get "$API_ITEM" issuer_id)"
  vault-get "$API_ITEM" private_key_p8_b64 | base64 --decode > "$WORK/api.p8"
  if ! xcrun notarytool submit amux-macos.dmg \
      --key "$WORK/api.p8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait; then
    echo "error: notarization failed; refusing to publish an unstapled release" >&2
    exit 1
  fi
  if ! xcrun stapler staple amux-macos.dmg; then
    echo "error: stapling failed; refusing to publish an unstapled release" >&2
    exit 1
  fi
  xcrun stapler validate amux-macos.dmg
  echo "==> notarized + stapled"
  rm -f "$WORK/api.p8"
fi

VERIFY_ARGS=(amux-macos.dmg)
if [[ "$NOTARIZE" == "1" ]]; then
  VERIFY_ARGS+=(--require-gatekeeper)
fi
"$PROJECT_DIR/scripts/verify-amux-release-dmg.sh" "${VERIFY_ARGS[@]}"

echo "==> done: $PROJECT_DIR/amux-macos.dmg"
