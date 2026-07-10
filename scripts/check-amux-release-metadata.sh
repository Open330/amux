#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/cmux.xcodeproj/project.pbxproj"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [vX.Y.Z[-prerelease]]" >&2
  exit 2
fi

[[ -f "$PROJECT_FILE" ]] || { echo "error: project file not found: $PROJECT_FILE" >&2; exit 1; }
[[ -f "$CHANGELOG_FILE" ]] || { echo "error: changelog not found: $CHANGELOG_FILE" >&2; exit 1; }

MARKETING_VERSIONS="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$PROJECT_FILE" | sort -u | sed '/^$/d')"
[[ "$(printf '%s\n' "$MARKETING_VERSIONS" | wc -l | tr -d ' ')" == "1" ]] || {
  echo "error: MARKETING_VERSION values are inconsistent: $MARKETING_VERSIONS" >&2
  exit 1
}
MARKETING_VERSION="$MARKETING_VERSIONS"
[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: MARKETING_VERSION is not semantic: $MARKETING_VERSION" >&2
  exit 1
}

TAG="${1:-v$MARKETING_VERSION}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
  echo "error: release tag must look like v0.2.0 or v0.2.0-alpha" >&2
  exit 1
}
TAG_VERSION="${TAG#v}"
TAG_VERSION="${TAG_VERSION%%-*}"
[[ "$TAG_VERSION" == "$MARKETING_VERSION" ]] || {
  echo "error: tag version $TAG_VERSION does not match MARKETING_VERSION $MARKETING_VERSION" >&2
  exit 1
}

if grep -Fq "## [$MARKETING_VERSION] - Unreleased" "$CHANGELOG_FILE"; then
  echo "error: CHANGELOG.md still marks $MARKETING_VERSION as Unreleased" >&2
  exit 1
fi
grep -Eq "^## \[$MARKETING_VERSION\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG_FILE" || {
  echo "error: CHANGELOG.md has no dated $MARKETING_VERSION release heading" >&2
  exit 1
}

echo "Release metadata ready: $TAG (MARKETING_VERSION=$MARKETING_VERSION)"
