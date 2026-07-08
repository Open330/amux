#!/usr/bin/env bash
# Build/stage the amux bundled runtime (tmux + muxa binaries) into
# vendor/amux-runtime/bin. reload.sh (dev) and the release pipeline copy this
# staging dir into the app's Resources/bin so amux ships a self-contained
# tmux + muxad and never depends on the user's Homebrew tmux or a manually
# installed muxad.
#
# Usage:
#   scripts/build-amux-runtime.sh            # muxa from cargo, tmux from PATH (dev)
#   scripts/build-amux-runtime.sh --build-tmux   # also build pinned tmux from source (CI)
#
# Env:
#   MUXA_REPO   path to the muxa checkout (default: ~/personal/muxa)
#   AMUX_TMUX_VERSION  tmux tag to build with --build-tmux (default: 3.7b)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$PROJECT_DIR/vendor/amux-runtime/bin"
MUXA_REPO="${MUXA_REPO:-$HOME/personal/muxa}"
TMUX_VERSION="${AMUX_TMUX_VERSION:-3.7b}"
BUILD_TMUX=0
[[ "${1:-}" == "--build-tmux" ]] && BUILD_TMUX=1

mkdir -p "$STAGE"

# --- muxa binaries (muxad + muxa CLI), MIT/Apache, built from the pinned repo.
if [[ -d "$MUXA_REPO" ]]; then
  echo "==> building muxa release binaries from $MUXA_REPO"
  (cd "$MUXA_REPO" && cargo build --release -p muxad -p muxa-cli)
  for bin in muxad muxa; do
    if [[ -x "$MUXA_REPO/target/release/$bin" ]]; then
      cp "$MUXA_REPO/target/release/$bin" "$STAGE/$bin"
      chmod +x "$STAGE/$bin"
      echo "    staged $bin"
    fi
  done
else
  echo "warning: MUXA_REPO=$MUXA_REPO not found; skipping muxad/muxa (badges/agent layer will degrade)" >&2
fi

# --- tmux: pinned build from source (CI) or a dev placeholder from PATH.
if [[ "$BUILD_TMUX" == "1" ]]; then
  echo "==> building tmux $TMUX_VERSION from source (universal)"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tarball="tmux-$TMUX_VERSION.tar.gz"
  curl -fsSL "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/$tarball" -o "$work/$tarball"
  tar -xzf "$work/$tarball" -C "$work"
  (
    cd "$work/tmux-$TMUX_VERSION"
    # Static-link libevent so the bundled tmux has no Homebrew dylib deps.
    ./configure --enable-static >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
  cp "$work/tmux-$TMUX_VERSION/tmux" "$STAGE/tmux"
  chmod +x "$STAGE/tmux"
  echo "    staged tmux $TMUX_VERSION"
else
  # Dev placeholder: stage whatever tmux is on PATH so reload.sh can bundle a
  # working binary and localTmuxExecutablePath resolves to the bundle. CI uses
  # --build-tmux to pin the exact release.
  if src="$(command -v tmux 2>/dev/null)"; then
    cp "$src" "$STAGE/tmux"
    chmod +x "$STAGE/tmux"
    echo "==> staged dev tmux from $src ($("$src" -V)); CI pins $TMUX_VERSION via --build-tmux"
  else
    echo "warning: no tmux on PATH to stage; run with --build-tmux or install tmux" >&2
  fi
fi

echo "==> amux runtime staged in $STAGE:"
ls -1 "$STAGE" 2>/dev/null | sed 's/^/    /'
