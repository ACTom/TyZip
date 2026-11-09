# Shared toolchain discovery for TyZip's headless test suites.
#
# The project has one supported toolchain: the fpcupdeluxe install -- its FPC,
# its Lazarus and its Lazarus config directory. The FPC wrapper loads fpcup's
# own fpc.cfg with -n, so a system-wide FPC is neither required nor used.
#
# Override only when you intentionally run a different fpcupdeluxe tree:
#   FPCUP=/path/to/fpcupdeluxe
# or point at individual pieces:
#   FPC=... LAZARUS_DIR=... LAZARUS_PCP=... BGRA_LIB=... OUT=...

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

FPCUP="${FPCUP:-$HOME/fpcupdeluxe}"

if [ -z "${FPC:-}" ]; then
  for cand in "$FPCUP"/fpc/bin/*-darwin/fpc.sh; do
    if [ -x "$cand" ]; then FPC="$cand"; break; fi
  done
fi
[ -n "${FPC:-}" ] && [ -x "$FPC" ] || die "fpcupdeluxe FPC not found under $FPCUP/fpc/bin; set FPCUP=/path/to/fpcupdeluxe"
FPCVER="$("$FPC" -iV)"
FPCARCH="$("$FPC" -iTP)"
FPCTARGET="$("$FPC" -iTO)"

lazarus_complete() {
  local l="$1"
  [ -f "$l/lcl/units/$FPCARCH-$FPCTARGET/graphics.ppu" ] &&
  [ -f "$l/lcl/units/$FPCARCH-$FPCTARGET/cocoa/interfaces.ppu" ] &&
  [ -f "$l/components/lazutils/lib/$FPCARCH-$FPCTARGET/fileutil.ppu" ] &&
  [ -f "$l/components/synedit/units/$FPCARCH-$FPCTARGET/cocoa/synedit.ppu" ]
}

LAZARUS_DIR="${LAZARUS_DIR:-$FPCUP/lazarus}"
LAZARUS_PCP="${LAZARUS_PCP:-$FPCUP/config_lazarus}"
[ -d "$LAZARUS_PCP" ] || die "fpcupdeluxe Lazarus config not found at $LAZARUS_PCP; set LAZARUS_PCP=/path/to/config_lazarus"
lazarus_complete "$LAZARUS_DIR" || die "Lazarus at $LAZARUS_DIR is missing FPC $FPCVER units; rebuild its LCL/lazutils/SynEdit packages with $FPC first"

BGRA_LIB="${BGRA_LIB:-}"
if [ -z "$BGRA_LIB" ]; then
  for cand in \
    "$FPCUP/ccr/bgrabitmap/bgrabitmap/lib/$FPCARCH-$FPCTARGET-cocoa-$FPCVER" \
    "$FPCUP/ccr/bgrabitmap/bgrabitmap/lib/$FPCARCH-$FPCTARGET-cocoa" \
    "$LAZARUS_DIR/components/bgrabitmap/lib/$FPCARCH-$FPCTARGET-cocoa-$FPCVER" \
    "$LAZARUS_DIR/components/bgrabitmap/lib/$FPCARCH-$FPCTARGET"
  do
    if [ -f "$cand/bgrabitmap.ppu" ]; then BGRA_LIB="$cand"; break; fi
  done
fi
if [ -z "$BGRA_LIB" ] || [ ! -f "$BGRA_LIB/bgrabitmap.ppu" ]; then
  die "BGRABitmap units for FPC $FPCVER not found; set BGRA_LIB=/path/to/bgrabitmap/lib/..."
fi

# TyControls units: the archive tree is a TyControls control, and the tree
# selection test drives a real TTyTreeView. The package is registered in the
# Lazarus config, so take its directory from there instead of assuming a
# checkout location; TYCONTROLS_LIB overrides.
TYCONTROLS_LIB="${TYCONTROLS_LIB:-}"
if [ -z "$TYCONTROLS_LIB" ]; then
  tycontrols_lpk="$(sed -n 's/.*<Filename Value="\([^"]*tycontrols\.lpk\)".*/\1/p' \
    "$LAZARUS_PCP/packagefiles.xml" 2>/dev/null | head -n 1)"
  if [ -n "$tycontrols_lpk" ]; then
    TYCONTROLS_LIB="$(dirname "$tycontrols_lpk")/lib/$FPCARCH-$FPCTARGET"
  fi
fi

LCL_UNIT="$LAZARUS_DIR/lcl/units/$FPCARCH-$FPCTARGET"
LCL_WIDGET="$LCL_UNIT/cocoa"
LAZUTILS="$LAZARUS_DIR/components/lazutils/lib/$FPCARCH-$FPCTARGET"
SYNEDIT="$LAZARUS_DIR/components/synedit/units/$FPCARCH-$FPCTARGET/cocoa"

# A fresh output directory per run: reusing one hides compile failures behind
# stale binaries and stale .ppu files.
OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/tyzip-${SUITE:-tests}.XXXXXX")}"
mkdir -p "$OUT"

PASS=0
FAIL=0

pass_prog() { PASS=$((PASS + 1)); }
fail_prog() { FAIL=$((FAIL + 1)); }

# build_prog <program> <compiler flags...>
build_prog() {
  local prog="$1"; shift
  if "$FPC" "$@" -FU"$OUT" -FE"$OUT" "$HERE/$prog.pas" >"$OUT/$prog.build.log" 2>&1; then
    return 0
  fi
  echo "FAIL build $prog"
  tail -n 15 "$OUT/$prog.build.log" | sed 's/^/    /'
  fail_prog
  return 1
}

# run_prog <program>
run_prog() {
  local prog="$1" rc=0
  if [ ! -x "$OUT/$prog" ]; then
    echo "FAIL run $prog (binary missing)"
    fail_prog
    return 1
  fi
  ( cd "$OUT" && "./$prog" ) || rc=$?
  if [ $rc -eq 0 ]; then
    echo "PASS $prog"
    pass_prog
  else
    echo "FAIL run $prog (exit $rc)"
    fail_prog
    return 1
  fi
}

stage_libs() {
  [ -f "$ROOT/lib/libtz7z.dylib" ] || die "missing $ROOT/lib/libtz7z.dylib -- build the backend first (scripts/build_backend.sh)"
  [ -f "$ROOT/lib/7z.so" ] || die "missing $ROOT/lib/7z.so -- build the backend first (scripts/build_backend.sh)"
  cp -f "$ROOT/lib/libtz7z.dylib" "$OUT/"
  cp -f "$ROOT/lib/7z.so" "$OUT/"
}

summary() {
  echo
  echo "== ${SUITE:-tests}: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
