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
# The last revision before Tiny3D typedef'd its vector and matrix types to
# libdragon's fm_vec3_t/fm_mat4_t, which the libdragon revision pinned in
# tools/fetch_libdragon.sh does not have. The two pins have to compose: a
# header set that does not compile answers every question this is used for
# with the same 250 errors.
REV="ec557373e986b5e041cc102a7ff787eb07921937"
REPO_URL="https://github.com/HailToDodongo/tiny3d"

SRC="$OUT/tiny3d"
[ -d "$SRC/src/t3d" ] && { echo "tiny3d: already at $SRC"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "tiny3d: SKIP (no git)"; exit 0; }
mkdir -p "$OUT" || { echo "tiny3d: cannot create $OUT"; exit 0; }
if ! git clone -q "$REPO_URL" "$SRC" 2>/dev/null; then
    echo "tiny3d: SKIP (cannot clone $REPO_URL)"; rm -rf "$SRC"; exit 0
fi
# A pin that silently falls back to the branch tip is not a pin. The previous
# REV here did not exist in the repository at all, so every run since it was
# written tested whatever HEAD happened to be -- which had moved past the
# libdragon pin, and the six Tiny3D demos reported 250 errors each that were
# nothing to do with Pak. Skipping outright is the honest answer: no result
# beats a wrong one.
if ! ( cd "$SRC" && git checkout -q "$REV" ) 2>/dev/null; then
    echo "tiny3d: SKIP (pinned revision $REV not in $REPO_URL)"
    rm -rf "$SRC"; exit 0
fi
[ -d "$SRC/src/t3d" ] || { echo "tiny3d: SKIP (no src/t3d)"; rm -rf "$SRC"; exit 0; }
echo "tiny3d: headers at $SRC/src"
