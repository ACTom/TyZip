#!/usr/bin/env bash
# Build the C ABI bridge to the 7-Zip shared library.
#
# Default target: x86_64-darwin (the libraries the tests load).  Cross:
#
#   TYZIP_TARGET=aarch64-darwin scripts/build_7zip.sh
#   TYZIP_TARGET=aarch64-darwin scripts/build_backend.sh
#
# The cross build writes lib/aarch64-darwin/libtz7z.dylib and expects the arm64
# lib/aarch64-darwin/7z.so that build_7zip.sh produces there; the x86_64 lib/
# output is left alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/7zip-26.03"
TARGET="${TYZIP_TARGET:-x86_64-darwin}"
CXX="${CXX:-clang++}"
# The app claims macOS 11+, so the bridge must not require a newer dyld: the
# default SDK would stamp the current macOS (15.x) into LC_BUILD_VERSION.
MACOSX_MIN="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

case "$TARGET" in
  x86_64-darwin)
    ARCH_FLAGS=""
    OUTDIR="$ROOT/lib"
    SEVEN="$VENDOR/CPP/7zip/Bundles/Format7zF/_o/7z.so"
    BUILD_7ZIP_HINT="scripts/build_7zip.sh"
    ;;
  aarch64-darwin)
    ARCH_FLAGS="-arch arm64"
    OUTDIR="$ROOT/lib/aarch64-darwin"
    SEVEN="$OUTDIR/7z.so"
    BUILD_7ZIP_HINT="TYZIP_TARGET=aarch64-darwin scripts/build_7zip.sh"
    ;;
  *)
    echo "error: unsupported TYZIP_TARGET=$TARGET (use x86_64-darwin or aarch64-darwin)" >&2
    exit 1
    ;;
esac

# lib/ holds build output and is not in the repository, so a fresh clone has no
# such directory.
mkdir -p "$OUTDIR"

if [[ ! -f "$SEVEN" ]]; then
  echo "Missing $SEVEN" >&2
  echo "Build 7-Zip's Format7zF target first: $BUILD_7ZIP_HINT" >&2
  exit 1
fi

cd "$ROOT/backend"
# Word-split on purpose: ARCH_FLAGS is empty for x86_64 and "-arch arm64" for
# the cross build.  (An array would be safer, but bash 3.2 + set -u treats an
# empty array expansion as an unbound variable.)
# shellcheck disable=SC2086
"$CXX" $ARCH_FLAGS -std=c++11 -O2 -fPIC -dynamiclib \
  -mmacosx-version-min="$MACOSX_MIN" \
  -DENV_MACOSX -DENV_UNIX -DENV_HAVE_WCHAR__H -DENV_HAVE_WCTYPE_H \
  -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_REENTRANT \
  -I. -I"$VENDOR/CPP" \
  tz7z.cpp \
  "$VENDOR/CPP/Common/UTFConvert.cpp" \
  "$VENDOR/CPP/Common/MyString.cpp" \
  "$VENDOR/CPP/7zip/Common/MultiOutStream.cpp" \
  "$VENDOR/CPP/7zip/Common/FileStreams.cpp" \
  "$VENDOR/CPP/7zip/Archive/Common/MultiStream.cpp" \
  "$SEVEN" \
  -o "$OUTDIR/libtz7z.dylib" -ldl

# The id the bridge was linked against differs per target (the vendored x86
# library is _o/7z.so; the arm64 build sets the same id), but resolve it instead
# of assuming: the dependency is always rewritten to @loader_path/7z.so.
OLD_ID="$(otool -D "$SEVEN" | tail -n 1)"
[[ -n "$OLD_ID" ]] || OLD_ID="_o/7z.so"
if [[ "$OLD_ID" != "$SEVEN" ]]; then
  install_name_tool -change "$OLD_ID" @loader_path/7z.so "$OUTDIR/libtz7z.dylib"
fi
install_name_tool -id @rpath/libtz7z.dylib "$OUTDIR/libtz7z.dylib"

# The bridge loads 7z.so from its own directory, and the packaging script and the
# tests both take it from there.  For x86_64 that is lib/ (the tests stage it
# next to the bridge); the arm64 build already has 7z.so in its own directory.
if [[ "$TARGET" = "x86_64-darwin" ]]; then
  cp -f "$SEVEN" "$ROOT/lib/7z.so"
fi

echo "Built $OUTDIR/libtz7z.dylib ($TARGET, macOS $MACOSX_MIN+)"
