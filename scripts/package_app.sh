#!/usr/bin/env bash
# Assemble a self-contained macOS .app from an existing build.
#
# Host build (x86_64-darwin, libraries in lib/):
#   scripts/package_app.sh
#
# Cross build (arm64 executable and libraries under lib/aarch64-darwin/):
#   TYZIP_TARGET=aarch64-darwin scripts/package_app.sh
#
# Release build (Release build mode; the executable lives in dist/<target>/):
#   TYZIP_EXE="$PWD/dist/x86_64-darwin/TyZip" APP_BUNDLE="$PWD/dist/TyZip.app" \
#     scripts/package_app.sh
# scripts/release.sh does exactly that for both architectures.
#
# APP_BUNDLE overrides the output bundle path (useful to keep an arm64 bundle
# from replacing the host one). TYZIP_EXE overrides the executable to bundle;
# the target (and therefore the libraries) is then taken from its directory.
#
# STRIP=1 strips the bundled executable before signing. FPC's -Xs (Lazarus's
# "Strip symbols" option, which the Release build mode does not set) does not
# strip on Darwin, and the symbol table is most of the binary, so release
# packages are stripped here: scripts/release.sh passes STRIP=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP_BUNDLE:-$ROOT/bin/TyZip.app}"

# The .lpi writes the executable to lib/<cpu>-<os>/ (debug/test build) or
# dist/<cpu>-<os>/ (Release build).  A host build keeps its two libraries in
# lib/ (the tests load them from there); a cross build keeps the executable and
# both libraries together in lib/<target>/.
find_host_target() {
  if [[ -n "${TYZIP_TARGET:-}" ]]; then
    echo "$TYZIP_TARGET"
    return
  fi
  case "$(uname -m)" in
    arm64|aarch64) echo "aarch64-darwin" ;;
    x86_64) echo "x86_64-darwin" ;;
    *) echo "" ;;
  esac
}

TARGET="$(find_host_target)"
if [[ -n "${TYZIP_EXE:-}" ]]; then
  EXE="$TYZIP_EXE"
  # dist/<target>/ and lib/<target>/ both name the target in the parent dir.
  if [[ -z "${TYZIP_TARGET:-}" ]]; then
    TARGET="$(basename "$(dirname "$EXE")")"
  fi
elif [[ -n "$TARGET" ]]; then
  EXE="$ROOT/lib/$TARGET/TyZip"
else
  shopt -s nullglob
  candidates=("$ROOT"/lib/*-*/TyZip)
  shopt -u nullglob
  if [[ ${#candidates[@]} -eq 1 ]]; then
    TARGET="$(basename "$(dirname "${candidates[0]}")")"
    EXE="${candidates[0]}"
  else
    EXE=""
  fi
fi
[[ -n "$EXE" ]] || {
  echo "Cannot find the built executable under lib/. Set TYZIP_TARGET=<cpu>-<os> or TYZIP_EXE=<path>." >&2
  exit 1
}
[[ -x "$EXE" ]] || { echo "Build TyZip.lpi first ($EXE missing); read the header for the release path" >&2; exit 1; }

# The host build keeps its libraries in lib/; lib/<target>/ is the cross build.
case "$TARGET" in
  aarch64-darwin|arm64-darwin) LIBDIR="$ROOT/lib/$TARGET" ;;
  *) LIBDIR="$ROOT/lib" ;;
esac
[[ -f "$LIBDIR/libtz7z.dylib" && -f "$LIBDIR/7z.so" ]] || {
  echo "Build the backend for $TARGET first (expected $LIBDIR/libtz7z.dylib and $LIBDIR/7z.so)" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/TyZip"
if [[ "${STRIP:-0}" = "1" ]]; then
  command -v strip >/dev/null 2>&1 || { echo "STRIP=1 but strip is not available" >&2; exit 1; }
  # Before codesign: stripping after signing would break the signature.
  strip "$APP/Contents/MacOS/TyZip"
fi
cp "$LIBDIR/libtz7z.dylib" "$LIBDIR/7z.so" "$APP/Contents/Frameworks/"
cp "$ROOT/assets/TyZip.icns" "$APP/Contents/Resources/TyZip.icns"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"

# One version number for the whole project: packaging/version.txt. The plist is
# a template, so stamp the assembled bundle instead of editing the template.
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/packaging/version.txt")}"
[[ -n "$VERSION" ]] || { echo "packaging/version.txt is empty" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Redistribution requires the project license and the third-party notices next
# to the binary: TyZip itself is GPL-3.0, 7-Zip and TyControls are LGPL.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
if [[ -d "$ROOT/licenses" ]]; then
  shopt -s nullglob
  LICENSES=("$ROOT/licenses/"*)
  shopt -u nullglob
  if [[ ${#LICENSES[@]} -gt 0 ]]; then
    mkdir -p "$APP/Contents/Resources/licenses"
    cp "${LICENSES[@]}" "$APP/Contents/Resources/licenses/"
  else
    echo "warning: licenses/ is empty; the bundle has no third-party license texts" >&2
  fi
else
  echo "warning: licenses/ is missing; the bundle has no third-party license texts" >&2
fi

# Copy the language packs. An empty languages/ is a valid English-only bundle, so
# warn instead of failing; any other copy error (permissions, missing source)
# still aborts the script.
if [[ -d "$ROOT/languages" ]]; then
  shopt -s nullglob
  MOS=("$ROOT/languages/"*.mo)
  shopt -u nullglob
  if [[ ${#MOS[@]} -eq 0 ]]; then
    echo "warning: no .mo language packs in languages/; the bundle will be English-only" >&2
  else
    mkdir -p "$APP/Contents/Resources/languages"
    cp "${MOS[@]}" "$APP/Contents/Resources/languages/"
  fi
else
  echo "warning: languages/ is missing; the bundle will be English-only" >&2
fi

# Finder Services menu titles are localized separately from the app UI: macOS
# looks for ServicesMenu.strings inside <lang>.lproj (ticket 37).
shopt -s nullglob
for STR in "$ROOT/languages/"ServicesMenu.*.strings; do
  LANGTAG="$(basename "$STR")"
  LANGTAG="${LANGTAG#ServicesMenu.}"
  LANGTAG="${LANGTAG%.strings}"
  mkdir -p "$APP/Contents/Resources/$LANGTAG.lproj"
  cp "$STR" "$APP/Contents/Resources/$LANGTAG.lproj/ServicesMenu.strings"
done
shopt -u nullglob

chmod +x "$APP/Contents/MacOS/TyZip"

if [[ "${CODESIGN:-1}" = "1" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "Assembled $APP (TyZip $VERSION, $TARGET)"
