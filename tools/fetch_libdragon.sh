#!/usr/bin/env bash
# Fetch the libdragon headers tcl/tools/libdragon_api_test.tcl compiles against.
#
# Every other check on the libdragon path is blind to whether Pak's generated C
# matches libdragon's actual API. tcl/tools/c_compile_test.tcl declares each
# symbol from MODULE_API as `long sym();` -- an unprototyped declaration that
# accepts any argument count and any types -- so a call with the wrong arity, a
# renamed function, or an #include of a header that does not exist all compile
# clean there and then fail at a user's `make`.
#
# Only the headers are needed. The gate compiles, it does not link, so no MIPS
# toolchain and no libdragon build are required.
#
#   tools/fetch_libdragon.sh [outdir]
#
# Produces <outdir>/libdragon/include. Skips cleanly (exit 0, no tree) with no
# network or no git, so the gate reports SKIP rather than failing for a reason
# that is not the code.
set -u
OUT="${1:-${TMPDIR:-/tmp}/pak-libdragon}"
# Pinned: a moving API reference is not a reference. Bump deliberately, and
# expect the debt list to move when you do -- that is the gate working.
REV="c4a7e119eff1cfad07adcfa892a2910c40d8bdb8"
REPO_URL="https://github.com/DragonMinded/libdragon"

SRC="$OUT/libdragon"
[ -d "$SRC/include" ] && {
    have=$(cd "$SRC" && git rev-parse HEAD 2>/dev/null || echo "")
    [ "$have" = "$REV" ] && { echo "libdragon: already at $REV"; exit 0; }
    rm -rf "$SRC"
}

command -v git >/dev/null 2>&1 || { echo "libdragon: SKIP (no git)"; exit 0; }
mkdir -p "$OUT" || { echo "libdragon: cannot create $OUT"; exit 0; }

# A full clone, because the pinned revision is usually not the branch tip and
# --depth 1 cannot reach it.
if ! git clone -q "$REPO_URL" "$SRC" 2>/dev/null; then
    echo "libdragon: SKIP (cannot clone $REPO_URL)"
    rm -rf "$SRC"
    exit 0
fi
if ! ( cd "$SRC" && git checkout -q "$REV" ) 2>/dev/null; then
    echo "libdragon: SKIP (revision $REV missing)"
    rm -rf "$SRC"
    exit 0
fi
[ -d "$SRC/include" ] || { echo "libdragon: SKIP (no include/ at $REV)"; rm -rf "$SRC"; exit 0; }
echo "libdragon: headers at $SRC/include ($REV)"
