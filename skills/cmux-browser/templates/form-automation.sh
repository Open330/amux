#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://example.com/form}"
SURFACE="${2:-surface:1}"

amux browser "$SURFACE" goto "$URL"
amux browser "$SURFACE" get url
amux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
amux browser "$SURFACE" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
