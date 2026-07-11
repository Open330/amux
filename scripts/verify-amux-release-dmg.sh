#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <amux-macos.dmg> [--require-gatekeeper]" >&2
  exit 2
fi

DMG_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
REQUIRE_GATEKEEPER=0
if [[ "${2:-}" == "--require-gatekeeper" ]]; then
  REQUIRE_GATEKEEPER=1
elif [[ -n "${2:-}" ]]; then
  echo "error: unknown option: $2" >&2
  exit 2
fi
[[ -f "$DMG_PATH" ]] || { echo "error: DMG not found: $DMG_PATH" >&2; exit 1; }

for tool in codesign hdiutil jq plutil readlink spctl; do
  command -v "$tool" >/dev/null || { echo "error: required tool not found: $tool" >&2; exit 1; }
done

WORK="$(mktemp -d)"
MOUNT_POINT="$WORK/mount"
mkdir -p "$MOUNT_POINT"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
APP="$MOUNT_POINT/amux.app"
[[ -d "$APP" ]] || { echo "error: mounted DMG does not contain amux.app" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleName raw "$PLIST")" == "amux" ]] || {
  echo "error: mounted app has a non-amux CFBundleName" >&2
  exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" == "com.open330.amux" ]] || {
  echo "error: mounted app has an unexpected bundle identifier" >&2
  exit 1
}
REMOTE_MANIFEST="$(plutil -extract CMUXRemoteDaemonManifestJSON raw "$PLIST")"
printf '%s' "$REMOTE_MANIFEST" | jq -e '
  .schemaVersion == 1 and
  (.entries | length) == 4 and
  all(.entries[];
    (.downloadURL | startswith("https://github.com/Open330/amux/releases/download/")) and
    (.sha256 | test("^[0-9a-f]{64}$"))
  )
' >/dev/null || {
  echo "error: mounted app has no valid Open330 remote daemon manifest" >&2
  exit 1
}

AMUX_CLI="$APP/Contents/Resources/bin/amux"
[[ -x "$AMUX_CLI" && ! -L "$AMUX_CLI" ]] || {
  echo "error: mounted app is missing the canonical amux CLI executable" >&2
  exit 1
}
[[ ! -e "$APP/Contents/Resources/bin/cmux" && ! -L "$APP/Contents/Resources/bin/cmux" ]] || {
  echo "error: mounted app must not include the retired cmux CLI alias" >&2
  exit 1
}
"$AMUX_CLI" --help | grep -Fq "amux - control amux via Unix socket" || {
  echo "error: mounted amux CLI failed its identity smoke test" >&2
  exit 1
}
"$AMUX_CLI" --version | grep -Eq '^amux [0-9]+\.[0-9]+\.[0-9]+' || {
  echo "error: mounted amux CLI reports a non-amux version identity" >&2
  exit 1
}
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$REQUIRE_GATEKEEPER" == "1" ]]; then
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  spctl --assess --type execute --verbose=4 "$APP"
fi

echo "Verified final amux DMG: Gatekeeper, app identity, remote assets, canonical CLI, and cmux compatibility alias"
