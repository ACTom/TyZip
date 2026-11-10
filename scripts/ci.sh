#!/usr/bin/env bash
# Local CI gate: the same checks a CI job should run, in one command.
#
#   scripts/ci.sh                    # x86_64 tests/package + arm64 cross build
#   SKIP_TESTS=1 scripts/ci.sh       # only the fast static checks
#   SKIP_ARM64=1 scripts/ci.sh       # skip the arm64 cross build (faster)
#   REQUIRE_ARM64_APP=1 scripts/ci.sh # fail when lib/aarch64-darwin/TyZip is missing
#
# The arm64 checks only prove the cross build: an Intel host cannot run an
# aarch64 binary.  The arm64 executable itself is produced by
#   lazbuild --cpu=aarch64 --os=darwin ...
# (outside this script); when lib/aarch64-darwin/TyZip exists, its app bundle is
# assembled and checked here as well.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/packaging/version.txt")"
MINOS="11.0"
ARM64_TARGET="aarch64-darwin"
ARM64_DIR="$ROOT/lib/$ARM64_TARGET"

fail() { echo "FAIL: $*" >&2; exit 1; }

file_arch() {
  file -b "$1" | grep -Eo 'arm64|x86_64' | head -n 1
}

check_arch() {
  local f="$1" want="$2" arch
  [[ -f "$f" ]] || fail "missing $f"
  arch="$(file_arch "$f")"
  [[ "$arch" = "$want" ]] || fail "$f is ${arch:-unknown}, expected $want"
}

check_minos() {
  local f="$1" minos
  [[ -f "$f" ]] || fail "missing $f"
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  [[ "$minos" = "$MINOS" ]] || fail "$(basename "$f") requires macOS $minos, expected $MINOS"
}

echo "== version"
[[ -n "$VERSION" ]] || fail "packaging/version.txt is empty"

echo "== plist"
plutil -lint "$ROOT/packaging/Info.plist" >/dev/null || fail "Info.plist does not parse"
plist_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/packaging/Info.plist")"
[[ "$plist_min" = "$MINOS" ]] || fail "plist LSMinimumSystemVersion is $plist_min, expected $MINOS"

# The Finder Services menu is a published contract (Info.plist entry, selector in
# tzip.services_macos and a line in ServicesMenu.zh-Hans.strings). Keep the count
# and the message names honest: a missing entry makes the menu item vanish.
services_json="$(mktemp "${TMPDIR:-/tmp}/tyzip-services.XXXXXX")"
plutil -convert json -o "$services_json" "$ROOT/packaging/Info.plist"
python3 - "$services_json" <<'PY' || { rm -f "$services_json"; fail "Info.plist Finder services are wrong"; }
import json, sys
d = json.load(open(sys.argv[1]))
names = [s.get('NSMessage') for s in d.get('NSServices', [])]
want = ['compressDialog', 'extractDialog', 'extractHere', 'extractToFolder',
        'smartExtract', 'compressHere', 'compressEach']
if names != want:
    print('NSServices:', names, file=sys.stderr)
    sys.exit(1)
PY
rm -f "$services_json"

echo "== shell syntax"
for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$f" || fail "syntax error in $f"
done

if [[ -z "${SKIP_TESTS:-}" ]]; then
  echo "== build and tests"
  ( cd "$ROOT" && tests/run_all.sh )
fi

echo "== x86_64 deployment target"
check_arch "$ROOT/lib/7z.so" x86_64
check_minos "$ROOT/lib/7z.so"
check_arch "$ROOT/lib/libtz7z.dylib" x86_64
check_minos "$ROOT/lib/libtz7z.dylib"
check_arch "$ROOT/lib/x86_64-darwin/TyZip" x86_64
check_minos "$ROOT/lib/x86_64-darwin/TyZip"

echo "== arm64 cross build"
if [[ -n "${SKIP_ARM64:-}" ]]; then
  echo "skipped (SKIP_ARM64)"
else
  TYZIP_TARGET="$ARM64_TARGET" "$ROOT/scripts/build_7zip.sh"
  TYZIP_TARGET="$ARM64_TARGET" "$ROOT/scripts/build_backend.sh"
  check_arch "$ARM64_DIR/7z.so" arm64
  check_minos "$ARM64_DIR/7z.so"
  check_arch "$ARM64_DIR/libtz7z.dylib" arm64
  check_minos "$ARM64_DIR/libtz7z.dylib"
  otool -L "$ARM64_DIR/libtz7z.dylib" | grep -q '@loader_path/7z.so' \
    || fail "the arm64 bridge does not load 7z.so through @loader_path"

  if [[ -x "$ARM64_DIR/TyZip" ]]; then
    check_arch "$ARM64_DIR/TyZip" arm64
    check_minos "$ARM64_DIR/TyZip"
    APP_BUNDLE="$ROOT/bin/TyZip-arm64.app" TYZIP_TARGET="$ARM64_TARGET" \
      CODESIGN=0 "$ROOT/scripts/package_app.sh" >/dev/null
    APP="$ROOT/bin/TyZip-arm64.app"
    check_arch "$APP/Contents/MacOS/TyZip" arm64
    check_arch "$APP/Contents/Frameworks/7z.so" arm64
    check_arch "$APP/Contents/Frameworks/libtz7z.dylib" arm64
    [[ -f "$APP/Contents/Info.plist" ]] || fail "arm64 bundle has no Info.plist"
    packed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    [[ "$packed" = "$VERSION" ]] || fail "arm64 bundle version $packed != packaging/version.txt $VERSION"
    [[ -f "$APP/Contents/Resources/LICENSE" ]] || fail "arm64 bundle has no LICENSE"
  elif [[ "${REQUIRE_ARM64_APP:-}" = "1" ]]; then
    fail "missing $ARM64_DIR/TyZip; cross-build the app with lazbuild --cpu=aarch64 --os=darwin"
  else
    echo "note: $ARM64_DIR/TyZip is not built yet; arm64 app bundle check skipped"
    echo "      (lazbuild --cpu=aarch64 --os=darwin; set REQUIRE_ARM64_APP=1 to make this fatal)"
  fi
fi

echo "== package"
CODESIGN=0 "$ROOT/scripts/package_app.sh" >/dev/null
packed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/bin/TyZip.app/Contents/Info.plist")"
[[ "$packed" = "$VERSION" ]] || fail "bundle version $packed != packaging/version.txt $VERSION"
[[ -f "$ROOT/bin/TyZip.app/Contents/Resources/LICENSE" ]] || fail "bundle has no LICENSE"

echo "CI OK (TyZip $VERSION, macOS $MINOS+; arm64 cross build checked)"
