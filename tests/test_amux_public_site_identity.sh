#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$ROOT_DIR/site"

fail() {
  echo "public site identity check failed: $*" >&2
  exit 1
}

[[ -f "$SITE_DIR/index.html" ]] || fail "missing English landing page"
[[ -f "$SITE_DIR/ko/index.html" ]] || fail "missing Korean landing page"
[[ -f "$SITE_DIR/ja/index.html" ]] || fail "missing Japanese landing page"
[[ -f "$SITE_DIR/assets/amux-workspaces.png" ]] || fail "missing product screenshot"

if rg -n -i 'cmux\.com|posthog|manaflow-ai/cmux/(pull|issues)' "$SITE_DIR"; then
  fail "inherited hosted identity leaked into the public site"
fi

if rg -n -i '0\.2\.0 pre-release|secrets remain to be configured' "$ROOT_DIR/README.md"; then
  fail "README still describes the published release as incomplete"
fi

for page in "$SITE_DIR/index.html" "$SITE_DIR/ko/index.html" "$SITE_DIR/ja/index.html"; do
  grep -Fq 'https://github.com/Open330/amux/releases/latest/download/amux-macos.dmg' "$page" \
    || fail "missing canonical DMG URL in ${page#$ROOT_DIR/}"
  grep -Fq 'https://open330.github.io/amux/' "$page" \
    || fail "missing public site origin in ${page#$ROOT_DIR/}"
done

echo "Public amux site identity OK"
