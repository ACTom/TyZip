#!/usr/bin/env bash
# Build, assemble and zip the *release* build of TyZip into dist/.
#
#   scripts/release.sh                               # host arch + arm64 cross, both zipped
#   SKIP_ARM64=1 scripts/release.sh                  # host arch only (faster)
#   TYZIP_TARGET=aarch64-darwin scripts/release.sh   # one target only
#
# bin/ and lib/ stay the debug/test outputs: lib/ is the Default build mode of
# TyZip.lpi and bin/ the .app assembled from it. This script builds the Release
# build mode (-O3, no debug info, stripped, still minos 11.0) with its own
# Lazarus config ($HOME/fpcupdeluxe/config_lazarus_release, created on demand by
# scripts/setup_release_pcp.sh) and writes everything to dist/ (git-ignored):
#
#   dist/<target>/TyZip               release executable and its units
#   dist/TyZip.app                    x86_64 bundle (ad-hoc signed)
#   dist/TyZip-arm64.app              arm64 bundle (cross build, ad-hoc signed)
#   dist/TyZip-<version>-<arch>.zip   distributable zips, one per architecture
#
# The C bridge and 7z.so are already built with -O2 and no debug info; they are
# architecture-specific and shared with the test build, so they are only built
# here when missing.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FPCUP="${FPCUP:-$HOME/fpcupdeluxe}"
PCP="${TYZIP_RELEASE_PCP:-$FPCUP/config_lazarus_release}"
DIST="$ROOT/dist"
export VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/packaging/version.txt")}"
MINOS="11.0"

fail() { echo "release.sh: $*" >&2; exit 1; }

case "$(uname -m)" in
  arm64|aarch64) HOST_TARGET=aarch64-darwin ;;
  x86_64)        HOST_TARGET=x86_64-darwin ;;
  *)             HOST_TARGET="" ;;
esac

if [[ -n "${TYZIP_TARGET:-}" ]]; then
  TARGETS="$TYZIP_TARGET"
else
  [[ -n "$HOST_TARGET" ]] || fail "unsupported host $(uname -m); set TYZIP_TARGET=<cpu>-<os>"
  TARGETS="$HOST_TARGET"
  # The publishable Apple Silicon build is cross-compiled on an Intel host;
  # an arm64 host has no x86_64 cross compiler in this setup.
  if [[ "$HOST_TARGET" = "x86_64-darwin" && -z "${SKIP_ARM64:-}" ]]; then
    TARGETS="$TARGETS aarch64-darwin"
  fi
fi

# Cross-compiling the app needs fpcupdeluxe's aarch64-darwin compiler next to
# the native one; the arm64 7-Zip/bridge libraries are clang -arch builds and do
# not need it. Check before building anything so a missing toolchain fails fast
# instead of after the Intel build.
check_cross_compiler() {
  case "$1" in
    aarch64-darwin)
      [[ -x "$FPCUP/fpc/bin/x86_64-darwin/ppca64" ]] || fail \
"missing the aarch64-darwin cross compiler: $FPCUP/fpc/bin/x86_64-darwin/ppca64
release.sh: install it with fpcupdeluxe (cross compiler for Apple Silicon), or
release.sh: build only this Mac's architecture with SKIP_ARM64=1"
      ;;
  esac
}

libdir_for() {
  case "$1" in
    aarch64-darwin|arm64-darwin) echo "$ROOT/lib/$1" ;;
    *) echo "$ROOT/lib" ;;
  esac
}

bundle_name_for() {
  case "$1" in
    x86_64-darwin)  echo "TyZip.app" ;;
    aarch64-darwin) echo "TyZip-arm64.app" ;;
    *) fail "no bundle name for $1 (use x86_64-darwin or aarch64-darwin)" ;;
  esac
}

arch_for() {
  case "$1" in
    x86_64-darwin)  echo "x86_64" ;;
    aarch64-darwin) echo "arm64" ;;
    *) fail "no zip architecture for $1 (use x86_64-darwin or aarch64-darwin)" ;;
  esac
}

ensure_backend() {
  local target="$1" libdir
  libdir="$(libdir_for "$target")"
  if [[ -f "$libdir/7z.so" && -f "$libdir/libtz7z.dylib" ]]; then
    return 0
  fi
  echo "== backend for $target (missing from $libdir)"
  TYZIP_TARGET="$target" "$ROOT/scripts/build_7zip.sh"
  TYZIP_TARGET="$target" "$ROOT/scripts/build_backend.sh"
}

check_binary() {
  local file="$1" want="$2" arch minos
  [[ -f "$file" ]] || fail "missing $file"
  arch="$(file -b "$file" | grep -Eo 'arm64|x86_64' | head -n 1)"
  [[ "$arch" = "$want" ]] || fail "$file is ${arch:-unknown}, expected $want"
  minos="$(otool -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [[ "$minos" = "$MINOS" ]] || fail "$(basename "$file") requires macOS $minos, expected $MINOS"
}

# The Release build mode uses its own Lazarus config: a copy that carries the
# compiler path and the package list (see scripts/setup_release_pcp.sh).
for target in $TARGETS; do
  check_cross_compiler "$target"
done

if [[ ! -f "$PCP/environmentoptions.xml" ]]; then
  "$ROOT/scripts/setup_release_pcp.sh"
fi

mkdir -p "$DIST"
for target in $TARGETS; do
  arch="$(arch_for "$target")"
  bundle_name="$(bundle_name_for "$target")"
  bundle="$DIST/$bundle_name"
  zip="$DIST/TyZip-$VERSION-$arch.zip"

  echo "== $target"
  ensure_backend "$target"
  TYZIP_BUILD_MODE=Release TYZIP_PCP="$PCP" TYZIP_TARGET="$target" \
    "$ROOT/scripts/build_app.sh"

  exe="$DIST/$target/TyZip"
  # STRIP=1: the Release mode cannot strip on Darwin (FPC -Xs is a no-op there),
  # and the symbol table is over a third of the executable.
  STRIP=1 TYZIP_TARGET="$target" TYZIP_EXE="$exe" APP_BUNDLE="$bundle" \
    "$ROOT/scripts/package_app.sh"

  check_binary "$exe" "$arch"
  check_binary "$bundle/Contents/MacOS/TyZip" "$arch"
  check_binary "$bundle/Contents/Frameworks/libtz7z.dylib" "$arch"
  check_binary "$bundle/Contents/Frameworks/7z.so" "$arch"
  packed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
  [[ "$packed" = "$VERSION" ]] || fail "$bundle_name has version $packed, expected $VERSION"
  [[ -f "$bundle/Contents/Resources/LICENSE" ]] || fail "$bundle_name has no LICENSE"
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 \
      || fail "$bundle_name failed codesign --verify"
  fi

  rm -f "$zip"
  # --noextattr/--norsrc: every built file carries com.apple.provenance, and
  # ditto -c -k otherwise stores extended attributes as AppleDouble "._*"
  # entries inside the zip. Distribution needs neither; the code signature lives
  # in _CodeSignature, not in xattrs (ticket 43).
  ( cd "$DIST" && ditto -c -k --keepParent --noextattr --norsrc \
      "$bundle_name" "$zip" )
  if /usr/bin/unzip -l "$zip" | grep -qE '/\._|__MACOSX'; then
    fail "$zip contains AppleDouble metadata entries"
  fi
  echo "release.sh: $bundle"
  echo "release.sh: $zip"
done

echo
echo "== dist ($VERSION)"
ls -lh "$DIST" | sed 's/^/   /'
du -sh "$DIST" | sed 's/^/   /'
