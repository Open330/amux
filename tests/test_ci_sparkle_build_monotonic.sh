#!/usr/bin/env bash
# Regression test for the Sparkle "stuck build number" bug that broke updates
# from v0.63.1 -> v0.63.2 (both shipped with CURRENT_PROJECT_VERSION=78, so
# Sparkle saw the same build number and refused to offer the update).
#
# Invariant: the local CURRENT_PROJECT_VERSION must be strictly greater than
# the Sparkle build number in the latest published stable appcast. Sparkle
# compares CFBundleVersion (CURRENT_PROJECT_VERSION) against <sparkle:version>
# — the marketing string is informational only.
#
# A missing appcast is accepted only when the release API confirms that amux
# has never published one. Network and parse failures otherwise fail closed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/cmux.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "FAIL: $PROJECT_FILE not found" >&2
  exit 1
fi

LOCAL_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= //;s/;.*//')
if ! [[ "$LOCAL_BUILD" =~ ^[0-9]+$ ]]; then
  echo "FAIL: could not parse CURRENT_PROJECT_VERSION (got '$LOCAL_BUILD')" >&2
  exit 1
fi

# Sanity check: every CURRENT_PROJECT_VERSION in the project must match.
# Mixed values would mean some build configs ship with a stale build number.
MISMATCHED=$(grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u | wc -l | tr -d ' ')
if [[ "$MISMATCHED" != "1" ]]; then
  echo "FAIL: CURRENT_PROJECT_VERSION values are inconsistent across build configurations:" >&2
  grep 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sort -u >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
if command -v gh >/dev/null 2>&1 && gh release download \
    --repo Open330/amux \
    --pattern appcast.xml \
    --dir "$work_dir" \
    --clobber >/dev/null 2>&1; then
  PUBLISHED_BUILD="$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$work_dir/appcast.xml" | head -n1)"
else
  PUBLISHED_BUILD=$(curl -fsSL --max-time 15 \
    https://github.com/Open330/amux/releases/latest/download/appcast.xml 2>/dev/null \
    | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
    | head -n1 || true)
fi

if ! [[ "$PUBLISHED_BUILD" =~ ^[0-9]+$ ]]; then
  releases_json="$work_dir/releases.json"
  api_available=0
  if command -v gh >/dev/null 2>&1 && gh api \
      'repos/Open330/amux/releases?per_page=100' >"$releases_json" 2>/dev/null; then
    api_available=1
  elif curl -fsSL --max-time 15 \
      'https://api.github.com/repos/Open330/amux/releases?per_page=100' \
      -o "$releases_json"; then
    api_available=1
  fi
  if [[ "$api_available" == "1" ]]; then
    if python3 - "$releases_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)
has_appcast = any(
    asset.get("name") == "appcast.xml"
    for release in releases
    for asset in release.get("assets", [])
)
raise SystemExit(0 if has_appcast else 1)
PY
    then
      echo "FAIL: a published appcast exists but the latest Sparkle build could not be parsed" >&2
      exit 1
    fi
    echo "PASS: no prior amux appcast exists; local CURRENT_PROJECT_VERSION=$LOCAL_BUILD starts the Sparkle sequence"
    exit 0
  fi
  if [[ "${AMUX_ALLOW_MISSING_PUBLISHED_APPCAST:-}" == "1" ]]; then
    echo "WARN: release API unavailable; explicit AMUX_ALLOW_MISSING_PUBLISHED_APPCAST=1 override used"
    exit 0
  fi
  echo "FAIL: could not verify the latest published Sparkle build or first-release state" >&2
  exit 1
fi

if (( LOCAL_BUILD <= PUBLISHED_BUILD )); then
  cat >&2 <<EOF
FAIL: CURRENT_PROJECT_VERSION ($LOCAL_BUILD) must be strictly greater than the
      latest published Sparkle build ($PUBLISHED_BUILD).

      Sparkle compares build numbers, not the marketing version. If you ship a
      release with the same build number as a previously-published release,
      existing users will never receive the update.

      Run \`./scripts/bump-version.sh\` (which auto-corrects the build number
      against the published appcast), commit the change, and re-push.
EOF
  exit 1
fi

echo "PASS: local CURRENT_PROJECT_VERSION=$LOCAL_BUILD > published Sparkle build=$PUBLISHED_BUILD"
