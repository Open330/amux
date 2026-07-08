#!/usr/bin/env bash
# Build a signed (and, if creds allow, notarized) amux-macos.dmg.
#
# Signing material is pulled from Vaultwarden at runtime (never written to the
# repo, never printed). A temporary keychain holds the imported identity and
# is deleted on exit. Requires: an unlocked bw session (~/.bw_session), Xcode,
# create-dmg (npm), and the staged amux runtime (scripts/build-amux-runtime.sh).
#
# Usage: scripts/build-signed-dmg.sh [--notarize]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export BW_SESSION="$(cat ~/.bw_session)"
CERT_ITEM="Developer ID Application (Jiun Bae)"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/amux-signing.keychain-db"
KEYCHAIN_PW="$(openssl rand -hex 16)"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> fetching Developer ID cert from Vault"
vault-get() { bw get item "$1" 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(next(f['value'] for f in d['fields'] if f['name']=='$2'))"; }
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
ORIG_KEYCHAINS="$(security list-keychains -d user | sed 's/"//g' | xargs)"
security list-keychains -d user -s "$KEYCHAIN" $ORIG_KEYCHAINS
rm -f "$WORK/cert.p12"

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/{print $2; exit}')"
echo "==> signing identity: ${IDENTITY:-<none found>}"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity imported" >&2; exit 1; }

echo "==> staging amux runtime (tmux + muxa)"
CMUX_SKIP_AMUX_RUNTIME= ./scripts/build-amux-runtime.sh || true

echo "==> building Release (universal, unsigned — Developer ID is applied manually)"
# Build unsigned so xcodebuild does not demand a provisioning profile for the
# keychain-access-groups entitlement. Developer ID direct distribution applies
# entitlements at codesign time instead — no profile needed.
rm -rf build-signed
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux \
  -configuration Release -derivedDataPath build-signed \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build-signed/Build/Products/Release/amux.app"
[[ -d "$APP" ]] || { echo "error: amux.app not produced" >&2; exit 1; }

echo "==> bundling runtime into the app"
BIN_DIR="$APP/Contents/Resources/bin"; mkdir -p "$BIN_DIR"
if [[ -d vendor/amux-runtime/bin ]]; then
  for rt in vendor/amux-runtime/bin/*; do cp "$rt" "$BIN_DIR/"; chmod +x "$BIN_DIR/$(basename "$rt")"; done
fi

echo "==> resolving entitlements + signing (Developer ID, hardened runtime)"
# Resolve the entitlement build-setting variables to concrete values.
ENT="$WORK/amux.entitlements"
sed -e "s/\$(AppIdentifierPrefix)/${TEAM_ID}./g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.open330.amux/g" \
    Resources/cmux.entitlements > "$ENT"
# Sign the bundled runtime in Resources/bin explicitly (a --deep pass does
# NOT descend into non-bundle executables there), then one --deep pass signs
# the app plus every nested bundle (Frameworks, PlugIns/*.plugin, Extensions/
# *.appex) inside-out. --entitlements applies to the main executable only;
# nested bundles are signed without the keychain-access-groups entitlement.
find "$BIN_DIR" -type f -perm +111 -exec \
  codesign --force --options runtime --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" {} \;
codesign --force --deep --options runtime --timestamp --keychain "$KEYCHAIN" \
  --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> codesign verified"

echo "==> creating dmg"
command -v create-dmg >/dev/null 2>&1 || npm install --global create-dmg@6 >/dev/null 2>&1
rm -f amux-macos.dmg ./*.dmg 2>/dev/null || true
create-dmg "$APP" "$PROJECT_DIR" 2>/dev/null || true
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
  if xcrun notarytool submit amux-macos.dmg \
      --key "$WORK/api.p8" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait; then
    xcrun stapler staple amux-macos.dmg && echo "==> notarized + stapled"
  else
    echo "warning: notarization failed (the file-stack API key may lack scope); dmg is signed but not notarized" >&2
  fi
  rm -f "$WORK/api.p8"
fi

echo "==> done: $PROJECT_DIR/amux-macos.dmg"
