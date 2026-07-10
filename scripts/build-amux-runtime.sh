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
TMUX_SHA256="${AMUX_TMUX_SHA256:-87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96}"
MUXA_VERSION="${AMUX_MUXA_VERSION:-0.8.19}"
MUXA_COMMIT="${AMUX_MUXA_COMMIT:-5ca6c34d1598fee83a35d69ce21a555e760f7ffb}"
BUILD_TMUX=0
if [[ $# -gt 1 ]] || [[ $# -eq 1 && "$1" != "--build-tmux" ]]; then
  echo "usage: $0 [--build-tmux]" >&2
  exit 2
fi
[[ "${1:-}" == "--build-tmux" ]] && BUILD_TMUX=1

mkdir -p "$STAGE"

stage_binary() {
  local source_path="$1"
  local name="$2"
  local temporary_path="$STAGE/.${name}.tmp.$$"
  install -m 755 "$source_path" "$temporary_path"
  mv -f "$temporary_path" "$STAGE/$name"
}

# --- muxa binaries (muxad + muxa CLI), MIT/Apache, built from the pinned repo.
if [[ -d "$MUXA_REPO" ]]; then
  if [[ "$BUILD_TMUX" == "1" ]]; then
    actual_muxa_commit="$(git -C "$MUXA_REPO" rev-parse HEAD)"
    tagged_muxa_commit="$(git -C "$MUXA_REPO" rev-parse "v$MUXA_VERSION^{commit}")"
    [[ "$actual_muxa_commit" == "$MUXA_COMMIT" ]] || {
      echo "error: muxa checkout is $actual_muxa_commit; expected pinned $MUXA_COMMIT (v$MUXA_VERSION)" >&2
      exit 1
    }
    [[ "$tagged_muxa_commit" == "$MUXA_COMMIT" ]] || {
      echo "error: muxa v$MUXA_VERSION resolves to $tagged_muxa_commit; expected $MUXA_COMMIT" >&2
      exit 1
    }
    git -C "$MUXA_REPO" diff --quiet
    git -C "$MUXA_REPO" diff --cached --quiet
  fi
  echo "==> building muxa release binaries from $MUXA_REPO"
  (cd "$MUXA_REPO" && cargo build --release --locked -p muxad -p muxa-cli)
  for bin in muxad muxa; do
    if [[ -x "$MUXA_REPO/target/release/$bin" ]]; then
      stage_binary "$MUXA_REPO/target/release/$bin" "$bin"
      echo "    staged $bin"
    fi
  done
else
  if [[ "$BUILD_TMUX" == "1" ]]; then
    echo "error: pinned MUXA_REPO=$MUXA_REPO not found" >&2
    exit 1
  fi
  echo "warning: MUXA_REPO=$MUXA_REPO not found; skipping muxad/muxa (badges/agent layer will degrade)" >&2
fi

# --- tmux: pinned build from source (CI) or a dev placeholder from PATH.
if [[ "$BUILD_TMUX" == "1" ]]; then
  echo "==> building pinned tmux $TMUX_VERSION from source"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tarball="tmux-$TMUX_VERSION.tar.gz"
  curl -fsSL "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/$tarball" -o "$work/$tarball"
  printf '%s  %s\n' "$TMUX_SHA256" "$work/$tarball" | shasum -a 256 -c -
  tar -xzf "$work/$tarball" -C "$work"
  command -v brew >/dev/null || { echo "error: Homebrew is required to build portable tmux dependencies" >&2; exit 1; }
  libevent_prefix="$(brew --prefix libevent)"
  ncurses_prefix="$(brew --prefix ncurses)"
  [[ -f "$libevent_prefix/lib/libevent_core.a" ]] || { echo "error: static libevent_core.a not found" >&2; exit 1; }
  [[ -f "$ncurses_prefix/lib/libncursesw.a" ]] || { echo "error: static libncursesw.a not found" >&2; exit 1; }
  (
    cd "$work/tmux-$TMUX_VERSION"
    LIBEVENT_CORE_CFLAGS="-I$libevent_prefix/include" \
    LIBEVENT_CORE_LIBS="$libevent_prefix/lib/libevent_core.a" \
    LIBTINFOW_CFLAGS="-I$ncurses_prefix/include" \
    LIBTINFOW_LIBS="$ncurses_prefix/lib/libncursesw.a" \
      ./configure --disable-utf8proc >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
  )
  stage_binary "$work/tmux-$TMUX_VERSION/tmux" tmux
  echo "    staged tmux $TMUX_VERSION"
else
  # Dev placeholder: stage whatever tmux is on PATH so reload.sh can bundle a
  # working binary and localTmuxExecutablePath resolves to the bundle. CI uses
  # --build-tmux to pin the exact release.
  if src="$(command -v tmux 2>/dev/null)"; then
    stage_binary "$src" tmux
    echo "==> staged dev tmux from $src ($("$src" -V)); CI pins $TMUX_VERSION via --build-tmux"
  else
    echo "warning: no tmux on PATH to stage; run with --build-tmux or install tmux" >&2
  fi
fi

if [[ "$BUILD_TMUX" == "1" ]]; then
  for runtime in tmux muxad muxa; do
    runtime_path="$STAGE/$runtime"
    [[ -x "$runtime_path" ]] || { echo "error: required pinned runtime is missing: $runtime_path" >&2; exit 1; }
    while IFS= read -r dependency; do
      case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
        *) echo "error: $runtime has non-portable dependency: $dependency" >&2; exit 1 ;;
      esac
    done < <(otool -L "$runtime_path" | tail -n +2 | awk '{print $1}')
  done
fi

echo "==> amux runtime staged in $STAGE:"
ls -1 "$STAGE" 2>/dev/null | sed 's/^/    /'
