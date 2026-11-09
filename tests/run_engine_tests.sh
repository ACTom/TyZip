#!/usr/bin/env bash
# Build and run the engine/API test programs.
#
# These exercise tzip.api and tzip.engine directly -- no LCL form, no window --
# and cover the archive formats the create dialog can offer, the compound
# (".tar.gz") path, extraction round trips, encryption, volumes and nesting.
#
# The engine library is located through the executable's own directory, so the
# test binaries are run from $OUT next to a copy of the dylib.
#
# Exit code is 0 only when every program built and every program exited 0.
set -euo pipefail

SUITE=engine
. "$(cd "$(dirname "$0")" && pwd)/testenv.sh"

# tzip.i18n uses LCLTranslator, so even a headless test needs the LCL base
# units on the search path.
# The language install lives in tzip.i18n.lcl, so the engine programs stay
# headless: only the source tree and LazUtils are on the search path.
FLAGS=(
  -Mobjfpc -Sh -O-
  -Fu"$ROOT/src"
  -Fu"$LAZUTILS"
)

# Discovered, not listed: adding a test program must not need a script edit.
# api_test.pas is the manual diagnostic tool (takes a path argument), not a test.
PROGS=()
for f in "$HERE"/unit_*.pas "$HERE"/api_*.pas; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .pas)"
  case "$base" in
    api_test) continue ;;      # manual diagnostic tool, takes a path argument
    unit_preview) continue ;;  # preview-suite program: needs LCL/SynEdit
    unit_services_paths) continue ;;  # preview-suite program: needs LCL/Cocoa
  esac
  PROGS+=("$base")
done
[ "${#PROGS[@]}" -gt 0 ] || die "no test programs found under $HERE"

stage_libs

for prog in "${PROGS[@]}"; do
  echo "== $prog"
  build_prog "$prog" "${FLAGS[@]}" || continue
  run_prog "$prog" || true
done

summary
