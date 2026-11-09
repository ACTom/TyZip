#!/usr/bin/env bash
# Reproduce the PROPVARIANT use-after-free that lived in
# backend/tz7z.cpp:SetCommonProperties (ticket 03, P0 #1), by comparing a known
# defective revision with the working tree under AddressSanitizer.
#
# The "extra options" retry path copied the PROPVARIANT array shallowly, freed
# the BSTRs with VariantClear, then handed the dangling pointers to the handler.
# It only triggers when an extra option is rejected AND another option uses a
# BSTR (method / dictionary / match finder), which is what this driver does.
#
# The baseline is pinned to a commit that predates the fix (ac1e314 by default)
# so the script keeps documenting the defect; compare against another revision
# with BASE=<commit>.  Each side is compiled with the tz7z.h from ITS OWN commit
# (the ABI changed in the meantime), and the driver fills the ABI version fields
# when the header has them.
#
# Expected: the baseline reports "AddressSanitizer: heap-use-after-free"; the
# working tree prints create=0 with no sanitizer error.  The exit status covers
# the working tree only -- if the baseline revision no longer reproduces the
# bug, the script prints a note but does not fail, because the baseline is
# evidence, not the thing under test.
#
# It is deliberately NOT part of tests/run_all.sh: it needs clang++ with the
# AddressSanitizer runtime and the vendored 7-Zip object/shlib, while the normal
# suites only need FPC.  Run it by hand after touching the bridge:
#
#   tests/backend_p0_asan.sh              # ac1e314 vs working tree
#   BASE=<commit> tests/backend_p0_asan.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/7zip-26.03"
SEVEN="$VENDOR/CPP/7zip/Bundles/Format7zF/_o/7z.so"
CXX="${CXX:-clang++}"
# ac1e314 predates the ticket 03 fix and is known to reproduce the UAF.
BASE="${BASE:-ac1e314}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tz7z-asan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SEVEN" ]; then
  echo "Missing $SEVEN -- build 7-Zip's Format7zF target first." >&2
  exit 1
fi

mkdir -p "$WORK/_o" "$WORK/inc-base" "$WORK/inc-fixed"
cp -f "$SEVEN" "$WORK/_o/7z.so"
( cd "$ROOT" && git show "$BASE:backend/tz7z.cpp" ) > "$WORK/tz7z-base.cpp"
( cd "$ROOT" && git show "$BASE:backend/tz7z.h" ) > "$WORK/inc-base/tz7z.h"
cp -f "$ROOT/backend/tz7z.cpp" "$WORK/tz7z-fixed.cpp"
cp -f "$ROOT/backend/tz7z.h" "$WORK/inc-fixed/tz7z.h"

cat > "$WORK/driver.cpp" <<'DRIVER'
#include "tz7z.h"
#include <cstdio>
#include <cstring>
int main()
{
  FILE *f = fopen("in.txt", "wb");
  if (!f) return 2;
  fputs("retry-path", f);
  fclose(f);
  tz7z_create_options opt;
  memset(&opt, 0, sizeof(opt));
  opt.format = "7z";
  opt.level = 5;
  opt.method = "LZMA2";                  /* BSTR-valued option */
  opt.solid = -1;
  opt.extra_options = "this-is-not-a-property=99"; /* rejected -> retry path */
#ifdef TZ7Z_ABI_VERSION
  opt.struct_size = sizeof(opt);
  opt.abi_version = TZ7Z_ABI_VERSION;
#endif
  tz7z_input in;
  memset(&in, 0, sizeof(in));
  in.disk_path = "in.txt";
  in.arc_path = "in.txt";
  in.is_dir = 0;
#ifdef TZ7Z_ABI_VERSION
  in.struct_size = sizeof(in);
  in.abi_version = TZ7Z_ABI_VERSION;
#endif
  char err[1024] = {0};
  int r = tz7z_create("out.7z", &opt, &in, 1, 0, 0, err, sizeof(err));
  printf("create=%d err=%s\n", r, err);
  return 0;
}
DRIVER

# build <cpp> <include-dir> <output>
build() {
  "$CXX" -std=c++11 -g -O1 -fPIC -fsanitize=address \
    -DENV_MACOSX -DENV_UNIX -DENV_HAVE_WCHAR__H -DENV_HAVE_WCTYPE_H \
    -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_REENTRANT \
    -I"$2" -I"$VENDOR/CPP" \
    "$WORK/driver.cpp" "$1" \
    "$VENDOR/CPP/Common/UTFConvert.cpp" "$VENDOR/CPP/Common/MyString.cpp" \
    "$VENDOR/CPP/7zip/Common/MultiOutStream.cpp" "$VENDOR/CPP/7zip/Common/FileStreams.cpp" \
    "$VENDOR/CPP/7zip/Archive/Common/MultiStream.cpp" "$SEVEN" \
    -o "$3" -ldl
}

( cd "$WORK" && build tz7z-base.cpp inc-base repro-base )
( cd "$WORK" && build tz7z-fixed.cpp inc-fixed repro-fixed )

status=0
echo "== $BASE (baseline; expected: AddressSanitizer heap-use-after-free)"
base_out="$(cd "$WORK" && rm -f out.7z && ASAN_OPTIONS=detect_leaks=0 ./repro-base 2>&1 || true)"
printf '%s\n' "$base_out" | head -n 20
if ! printf '%s' "$base_out" | grep -q 'AddressSanitizer'; then
  echo "NOTE: $BASE did not trip AddressSanitizer; the pinned baseline no longer" >&2
  echo "      demonstrates the bug (the working tree is what this script checks)." >&2
fi
echo
echo "== working tree (expected: create=0, no sanitizer error)"
fixed_out="$(cd "$WORK" && rm -f out.7z && ASAN_OPTIONS=detect_leaks=0 ./repro-fixed 2>&1)"
printf '%s\n' "$fixed_out"
if printf '%s' "$fixed_out" | grep -q 'AddressSanitizer'; then
  echo "FAIL: the working tree still trips AddressSanitizer" >&2
  status=1
elif ! printf '%s' "$fixed_out" | grep -q 'create=0'; then
  echo "FAIL: the working tree did not create the archive" >&2
  status=1
fi
exit $status
