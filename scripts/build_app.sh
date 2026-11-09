#!/usr/bin/env bash
# Build the TyZip application.
#
#   ./scripts/build_app.sh                              # this Mac (x86_64), debug/test
#   TYZIP_TARGET=aarch64-darwin ./scripts/build_app.sh  # Apple Silicon
#
#   # release build (Release build mode in TyZip.lpi, own Lazarus config)
#   TYZIP_BUILD_MODE=Release TYZIP_PCP="$HOME/fpcupdeluxe/config_lazarus_release" \
#     ./scripts/build_app.sh
#
# The native build is what the IDE does; the Apple Silicon one cross-compiles
# with fpcupdeluxe's ppca64 and lets lazbuild build the Lazarus packages (LCL,
# SynEdit, BGRABitmap, TyControls, ...) for that target on demand.
#
# Output, by build mode (the .lpi owns the paths, this script only mirrors them):
#   Default  lib/<target>/TyZip   debug/test build -- scripts/package_app.sh, tests, ci
#   Release  dist/<target>/TyZip  optimized build   -- scripts/release.sh packages it
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FPCUP="${FPCUP:-$HOME/fpcupdeluxe}"
TARGET="${TYZIP_TARGET:-x86_64-darwin}"
MODE="${TYZIP_BUILD_MODE:-Default}"
LAZBUILD="$FPCUP/lazarus/lazbuild"
LAZARUSDIR="$FPCUP/lazarus"

case "$MODE" in
  Default)
    OUTROOT="$ROOT/lib"
    PCP="${TYZIP_PCP:-$FPCUP/config_lazarus}"
    ;;
  Release)
    # Release builds get their own Lazarus config; create it once with
    # scripts/setup_release_pcp.sh (scripts/release.sh does that on demand).
    OUTROOT="$ROOT/dist"
    PCP="${TYZIP_PCP:-$FPCUP/config_lazarus_release}"
    if [ ! -f "$PCP/environmentoptions.xml" ]; then
      echo "build_app.sh: release Lazarus config not found: $PCP" >&2
      echo "build_app.sh: run scripts/setup_release_pcp.sh first" >&2
      exit 1
    fi
    ;;
  *)
    echo "build_app.sh: unsupported TYZIP_BUILD_MODE: $MODE" >&2
    echo "build_app.sh: use Default (debug/test) or Release" >&2
    exit 2
    ;;
esac

if [ ! -x "$LAZBUILD" ]; then
  echo "build_app.sh: lazbuild not found: $LAZBUILD" >&2
  exit 1
fi

ARGS=(--lazarusdir="$LAZARUSDIR" --pcp="$PCP")
# bash 3.2 with set -u errors on an empty array expansion, so append per mode.
if [ "$MODE" = "Release" ]; then
  ARGS+=(--build-mode=Release)
fi

case "$TARGET" in
  x86_64-darwin)
    ;;
  aarch64-darwin)
    ARGS+=(--cpu=aarch64 --os=darwin --compiler="$ROOT/scripts/ppca64.sh" --build-all)
    ;;
  *)
    echo "build_app.sh: unsupported TYZIP_TARGET: $TARGET" >&2
    echo "build_app.sh: use x86_64-darwin or aarch64-darwin" >&2
    exit 2
    ;;
esac

echo "build_app.sh: building $TARGET ($MODE, config $PCP)"
"$LAZBUILD" "${ARGS[@]}" TyZip.lpi

EXE="$OUTROOT/$TARGET/TyZip"
if [ ! -x "$EXE" ]; then
  echo "build_app.sh: the build produced no $EXE" >&2
  exit 1
fi

echo "build_app.sh: $EXE"
file "$EXE"
