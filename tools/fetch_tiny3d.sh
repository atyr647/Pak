#!/usr/bin/env bash
# Fetch Tiny3D's headers, so tcl/tools/libdragon_symbols.tcl can tell a symbol
# that needs `tiny3d = true` from one that does not exist at all. Headers only:
# the classification compiles, it does not link.
#
#   tools/fetch_tiny3d.sh [outdir]
#
# Skips cleanly (exit 0, no tree) with no network or no git.
set -u
OUT="${1:-${TMPDIR:-/tmp}/pak-tiny3d}"
REV="9c99d5c66e1ba1e6acd2c5f0d0dcac2a1eebef15"
REPO_URL="https://github.com/HailToDodongo/tiny3d"

SRC="$OUT/tiny3d"
[ -d "$SRC/src/t3d" ] && { echo "tiny3d: already at $SRC"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "tiny3d: SKIP (no git)"; exit 0; }
mkdir -p "$OUT" || { echo "tiny3d: cannot create $OUT"; exit 0; }
if ! git clone -q "$REPO_URL" "$SRC" 2>/dev/null; then
    echo "tiny3d: SKIP (cannot clone $REPO_URL)"; rm -rf "$SRC"; exit 0
fi
( cd "$SRC" && git checkout -q "$REV" ) 2>/dev/null || echo "tiny3d: pinned revision missing, using default branch"
[ -d "$SRC/src/t3d" ] || { echo "tiny3d: SKIP (no src/t3d)"; rm -rf "$SRC"; exit 0; }
echo "tiny3d: headers at $SRC/src"
