#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if rg -q '454ecd03-1db2-4050-845e-4ce5b0cd9895|pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g' \
  scripts Sources CLI Resources Packages/macOS Packages/Shared \
  --glob '!**/Tests/**' --glob '!**/.build/**'; then
  fail "inherited Stack credentials remain in shipped source or tooling"
fi

rg -q '\["auth", "login", "logout", "vm", "cloud", "remotes", "remote", "ai-accounts", "mobile"\]' CLI/cmux.swift \
  || fail "the canonical CLI does not reject the inherited mobile command"

rg -q 'inheritedHostedServicePrefixes = \["auth\\.", "vm\\.", "remotes\\.", "aiAccounts\\.", "mobile\\.", "dogfood\\."\]' Sources/TerminalController.swift \
  || fail "the socket dispatcher does not share the full hosted-service denylist"

rg -q 'methods\.removeAll\(where: Self\.isInheritedHostedV2Method\)' Sources/TerminalController.swift \
  || fail "system.capabilities can still advertise inherited hosted methods"

if rg -q '"dogfood\.v1"' Sources/Mobile/MobileHostService+Capabilities.swift; then
  fail "the release mobile capability set still advertises inherited dogfood feedback"
fi

echo "amux hosted-service boundary checks passed"
