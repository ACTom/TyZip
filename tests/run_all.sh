#!/usr/bin/env bash
# One verification command for TyZip: build the application, then run every
# headless suite. Exits non-zero if any step fails.
#
#   tests/run_all.sh                    # build + both suites
#   SKIP_APP_BUILD=1 tests/run_all.sh   # suites only
#
# Uses the fpcupdeluxe toolchain by default (FPC + Lazarus + config_lazarus).
# Point elsewhere only when needed: FPCUP=... or FPC=/LAZARUS_DIR=/LAZARUS_PCP=...
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SUITE=all
. "$HERE/testenv.sh"

# Child suites discover the same toolchain; they must get their own OUT.
unset OUT
export FPC LAZARUS_DIR LAZARUS_PCP BGRA_LIB

status=0

# Several owners may run this at once; lazbuild writes into the shared lib/
# directory, so the app build is serialised. Test suites use private $OUT dirs
# and stay parallel.
LOCKDIR="$ROOT/.tyzip-build.lock"
acquire_build_lock() {
  local waited=0 owner
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    owner="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    # A killed run leaves the directory behind; its PID tells us it is stale.
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCKDIR"
      continue
    fi
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 300 ]; then
      echo "warning: stale build lock at $LOCKDIR; taking over" >&2
      rm -rf "$LOCKDIR"
    fi
  done
  echo $$ > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
}

if [ -z "${SKIP_APP_BUILD:-}" ]; then
  acquire_build_lock
  LAZBUILD="${LAZBUILD:-$LAZARUS_DIR/lazbuild}"
  [ -x "$LAZBUILD" ] || die "lazbuild not found at $LAZBUILD; set LAZBUILD=... or SKIP_APP_BUILD=1"
  echo "== build app ($LAZBUILD, config $LAZARUS_PCP)"
  if ! ( cd "$ROOT" && "$LAZBUILD" --pcp="$LAZARUS_PCP" --lazarusdir="$LAZARUS_DIR" TyZip.lpi ); then
    echo "FAIL app build" >&2
    status=1
  fi
  # Release before the suites: they only read the tree and use private $OUT
  # directories, so holding the lock through both would serialise every run.
  rm -rf "$LOCKDIR"
  trap - EXIT INT TERM
fi

bash "$HERE/run_engine_tests.sh" || status=1
bash "$HERE/run_preview_tests.sh" || status=1

echo
if [ $status -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "FAILURES -- see the FAIL lines above"
fi
exit $status
