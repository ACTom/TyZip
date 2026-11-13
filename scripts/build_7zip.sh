#!/usr/bin/env bash
# Build 7-Zip's Format7zF shared library with the deployment target TyZip ships.
#
# The vendored source is the official 7-Zip 26.03. TyZip needs ZIP entry names
# in legacy code pages (GBK, Big5, ...) to be readable and writable, which the
# official POSIX build has no code page tables for. scripts/patches/ holds that
# patch; this script applies it to a private copy under lib/build/ so vendor/
# stays byte-identical to upstream, then builds from the copy.
#
# Default target: x86_64-darwin (the host build used by the tests). Cross:
#
#   TYZIP_TARGET=aarch64-darwin scripts/build_7zip.sh
#
# Outputs: lib/7z.so (x86_64) or lib/aarch64-darwin/7z.so (arm64). The library
# links the system libiconv for the code page conversion.
#
# The stock makefile would let clang stamp the SDK's macOS version into
# LC_BUILD_VERSION, which made the library require macOS 15 even though the app
# claims 11+. MACOSX_DEPLOYMENT_TARGET is inherited by every clang call and by
# the final link, so one variable fixes both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/7zip-26.03"
PATCH="$ROOT/scripts/patches/7zip-26.03/0001-zip-name-codepage.patch"
SRC="$ROOT/lib/build/7zip-26.03-src"
TARGET="${TYZIP_TARGET:-x86_64-darwin}"
TARGET_MIN="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
JOBS="${MAKE_JOBS:-4}"
OBJ=""
trap '[[ -z "$OBJ" ]] || rm -rf "$OBJ"' EXIT

[[ -f "$PATCH" ]] || { echo "error: missing $PATCH" >&2; exit 1; }

# A fresh patched copy every run: a stale copy would hide a patch that no longer
# applies after a vendor upgrade.
mkdir -p "$ROOT/lib/build"
rm -rf "$SRC"
cp -R "$VENDOR" "$SRC"
# Object files left in the vendored tree are not source; O=<private dir> below
# writes elsewhere, so drop a stale one from the copy.
rm -rf "$SRC/CPP/7zip/Bundles/Format7zF/_o"
( cd "$SRC" && patch -p3 --batch < "$PATCH" )

build_target() {
  local out="$1" my_arch="$2"
  OBJ="$(mktemp -d "${TMPDIR:-/tmp}/tz7z-objects.XXXXXX")"
  (
    cd "$SRC/CPP/7zip/Bundles/Format7zF"
    # MY_ARCH is empty for the host build and carries the cross arch plus the
    # deployment target for arm64; bash 3.2 + set -u cannot expand an empty
    # array, so it is always passed as a plain variable.
    MACOSX_DEPLOYMENT_TARGET="$TARGET_MIN" \
      make -f makefile.gcc O="$OBJ" MY_LIBS="-liconv" MY_ARCH="$my_arch" -j"$JOBS"
  )
  [[ -f "$OBJ/7z.so" ]] || { echo "Build finished without $OBJ/7z.so" >&2; exit 1; }
  # The bridge links this id and later rewrites the dependency to
  # @loader_path/7z.so; keep the id identical for both architectures.
  install_name_tool -id _o/7z.so "$OBJ/7z.so"
  mkdir -p "$(dirname "$out")"
  cp -f "$OBJ/7z.so" "$out"
  echo "Built $out ($TARGET, macOS $TARGET_MIN+)"
}

case "$TARGET" in
  x86_64-darwin)
    build_target "$ROOT/lib/7z.so" ""
    ;;
  aarch64-darwin)
    build_target "$ROOT/lib/aarch64-darwin/7z.so" \
      "-arch arm64 -mmacosx-version-min=$TARGET_MIN"
    ;;
  *)
    echo "error: unsupported TYZIP_TARGET=$TARGET (use x86_64-darwin or aarch64-darwin)" >&2
    exit 1
    ;;
esac
