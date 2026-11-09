#!/usr/bin/env bash
# Build and run the LCL-level checks: the preview pane (highlighters + a headless
# TSynEdit) and the archive tree's selection contract (a real TTyTreeView).
#
# Uses the same compiler and unit directories as the application: pass
# LAZARUS_DIR / FPC / BGRA_LIB when yours live somewhere else.
#
# Exit code is 0 only when every program built and every program exited 0.
set -euo pipefail

SUITE=preview
. "$(cd "$(dirname "$0")" && pwd)/testenv.sh"

# tzip.ui.arctree binds the archive tree; the tree-selection test drives a real
# TyControls control, so the package units have to be on the search path.
[ -f "$TYCONTROLS_LIB/tyControls.TreeView.ppu" ] \
  || die "TyControls units not found (looked in ${TYCONTROLS_LIB:-<unset>}); set TYCONTROLS_LIB=/path/to/TyControls/lib/<cpu>-<os>"

FLAGS=(
  -Mobjfpc -Sh -O- -dLCL -dLCLcocoa
  -Fu"$ROOT/src"
  -Fu"$BGRA_LIB"
  -Fu"$TYCONTROLS_LIB"
  -Fu"$SYNEDIT"
  -Fu"$LAZUTILS"
  -Fu"$LCL_UNIT"
  -Fu"$LCL_WIDGET"
  -Fu"$LAZARUS_DIR/packager/units/$FPCARCH-$FPCTARGET"
  # LCL's Cocoa widgets pull these in; the app links them through the LCL package.
  -k-framework -kUserNotifications -k-framework -kAppKit -k-framework -kFoundation
)

PROGS=(
  preview_syntax_check
  editor_integration
  unit_preview
  unit_services_paths
  tree_selection_events
)

for prog in "${PROGS[@]}"; do
  echo "== $prog"
  build_prog "$prog" "${FLAGS[@]}" || continue
  run_prog "$prog" || true
done

summary
