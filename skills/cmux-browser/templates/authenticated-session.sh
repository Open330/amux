#!/usr/bin/env bash
set -euo pipefail

SURFACE="${1:-surface:1}"
STATE_FILE="${2:-./auth-state.json}"
DASHBOARD_URL="${3:-https://app.example.com/dashboard}"

if [ -f "$STATE_FILE" ]; then
  amux browser "$SURFACE" state load "$STATE_FILE"
fi

amux browser "$SURFACE" goto "$DASHBOARD_URL"
amux browser "$SURFACE" get url
amux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
amux browser "$SURFACE" snapshot --interactive

echo "If redirected to login, complete login flow then run:"
echo "  amux browser $SURFACE state save $STATE_FILE"
