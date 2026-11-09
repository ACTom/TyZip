#!/bin/sh
# The Free Pascal compiler lazbuild uses to cross-compile for Apple Silicon.
#
# fpcupdeluxe keeps the aarch64 cross compiler next to the native one and its
# fpc.cfg already carries the aarch64-darwin unit and linker paths, so the
# wrapper only has to select ppca64 and that configuration. lazbuild still
# passes --cpu=aarch64 --os=darwin itself.
set -eu

FPCUP="${FPCUP:-$HOME/fpcupdeluxe}"
PPCA64="$FPCUP/fpc/bin/x86_64-darwin/ppca64"
FPC_CFG="$FPCUP/fpc/bin/x86_64-darwin/fpc.cfg"

if [ ! -x "$PPCA64" ]; then
  echo "ppca64.sh: cross compiler not found: $PPCA64" >&2
  echo "ppca64.sh: install the aarch64 cross compiler with fpcupdeluxe first" >&2
  exit 1
fi
if [ ! -f "$FPC_CFG" ]; then
  echo "ppca64.sh: fpc.cfg not found: $FPC_CFG" >&2
  exit 1
fi

exec "$PPCA64" -n "@$FPC_CFG" "$@"
