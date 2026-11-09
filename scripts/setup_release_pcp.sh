#!/usr/bin/env bash
# Give release builds their own Lazarus primary config directory.
#
#   scripts/setup_release_pcp.sh            # create $HOME/fpcupdeluxe/config_lazarus_release
#   FORCE=1 scripts/setup_release_pcp.sh    # recreate it from the dev config
#
# Release builds run lazbuild with --pcp=$HOME/fpcupdeluxe/config_lazarus_release
# (scripts/build_app.sh does that for TYZIP_BUILD_MODE=Release), so the release
# toolchain state never touches the config_lazarus the IDE and the test build
# use. The directory is a copy of the dev config because it has to carry the two
# things a build cannot guess: the compiler path in environmentoptions.xml and
# the package list in packagefiles.xml (tycontrols lives outside the Lazarus
# directory, so a fresh empty config cannot find it).
#
# The compile flags themselves are not stored here: they are the Release build
# mode in TyZip.lpi. This directory is the *config*, not the flags.
set -euo pipefail

FPCUP="${FPCUP:-$HOME/fpcupdeluxe}"
SRC="${TYZIP_DEV_PCP:-$FPCUP/config_lazarus}"
DST="${TYZIP_RELEASE_PCP:-$FPCUP/config_lazarus_release}"

warn() { echo "setup_release_pcp.sh: $*" >&2; }

[[ -f "$SRC/environmentoptions.xml" ]] || {
  warn "no Lazarus config at $SRC"
  warn "run the IDE once (fpcupdeluxe) or set TYZIP_DEV_PCP=<config_lazarus>"
  exit 1
}

if [[ -f "$DST/environmentoptions.xml" && "${FORCE:-}" != "1" ]]; then
  echo "setup_release_pcp.sh: $DST already exists (FORCE=1 recreates it)"
  exit 0
fi

mkdir -p "$DST"
# Copy the config, not the IDE's live caches: projectsessions/ and the input
# history only hold the last GUI session. Everything a build reads (compiler
# path, package list, compiler defines) is kept.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude 'projectsessions/' \
    --exclude 'inputhistory.xml' \
    "$SRC/" "$DST/"
else
  rm -rf "$DST"
  mkdir -p "$DST"
  cp -R "$SRC/." "$DST/"
fi

[[ -f "$DST/environmentoptions.xml" ]] || {
  warn "the copy has no environmentoptions.xml"
  exit 1
}

compiler="$(sed -n 's/.*<CompilerFilename Value="\([^"]*\)".*/\1/p' \
  "$DST/environmentoptions.xml" | head -n 1)"
if [[ -z "$compiler" ]]; then
  warn "$DST/environmentoptions.xml has no CompilerFilename; lazbuild would fall back to a compiler on PATH"
  exit 1
fi
echo "setup_release_pcp.sh: release config $DST (compiler $compiler)"
