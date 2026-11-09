#!/usr/bin/env bash
# Build 7-Zip's Format7zF shared library with the deployment target TyZip ships.
#
# Default target: x86_64-darwin (the host build used by the tests).  Cross:
#
#   TYZIP_TARGET=aarch64-darwin scripts/build_7zip.sh
#
# The arm64 build happens in a private object directory and is copied to
# lib/aarch64-darwin/7z.so; the vendored x86_64 _o/7z.so is never touched.  The
# stock makefile lets clang stamp the SDK's macOS version into LC_BUILD_VERSION,
# which made the libraries require macOS 15 even though the app claims 11+.
# MACOSX_DEPLOYMENT_TARGET is inherited by every clang call and by the final
# link, so one variable fixes both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/7zip-26.03"
TARGET="${TYZIP_TARGET:-x86_64-darwin}"
TARGET_MIN="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
JOBS="${MAKE_JOBS:-4}"

case "$TARGET" in
  x86_64-darwin)
    OUT="$VENDOR/CPP/7zip/Bundles/Format7zF/_o/7z.so"
    cd "$VENDOR/CPP/7zip/Bundles/Format7zF"
    make -f makefile.gcc clean >/dev/null 2>&1 || true
    MACOSX_DEPLOYMENT_TARGET="$TARGET_MIN" make -f makefile.gcc
    [[ -f "$OUT" ]] || { echo "Build finished without $OUT" >&2; exit 1; }
    echo "Built $OUT (macOS $TARGET_MIN+)"
    ;;
  aarch64-darwin)
    OUTDIR="$ROOT/lib/aarch64-darwin"
    mkdir -p "$OUTDIR"
    OBJ="$(mktemp -d "${TMPDIR:-/tmp}/tz7z-arm64-objects.XXXXXX")"
    trap 'rm -rf "$OBJ"' EXIT
    cd "$VENDOR/CPP/7zip/Bundles/Format7zF"
    # O=<private dir> keeps every arm64 object (and the output) out of the
    # vendored x86 tree.  MY_ARCH reaches the compile and link lines so the
    # cross arch and the deployment target apply to the whole build.
    MACOSX_DEPLOYMENT_TARGET="$TARGET_MIN" \
      make -f makefile.gcc O="$OBJ" \
        MY_ARCH="-arch arm64 -mmacosx-version-min=$TARGET_MIN" -j"$JOBS"
    [[ -f "$OBJ/7z.so" ]] || { echo "Build finished without $OBJ/7z.so" >&2; exit 1; }
    # Give the library the same install name the x86 build has, so the bridge
    # recipe (-change _o/7z.so @loader_path/7z.so) is identical for both archs.
    install_name_tool -id _o/7z.so "$OBJ/7z.so"
    cp -f "$OBJ/7z.so" "$OUTDIR/7z.so"
    echo "Built $OUTDIR/7z.so (arm64, macOS $TARGET_MIN+)"
    ;;
  *)
    echo "error: unsupported TYZIP_TARGET=$TARGET (use x86_64-darwin or aarch64-darwin)" >&2
    exit 1
    ;;
esac
