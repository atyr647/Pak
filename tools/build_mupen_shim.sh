#!/usr/bin/env bash
# Build a mupen64plus core that can run Pak ROMs.
#
# Stock mupen64plus 2.5.9 does not boot them: two bugs in its RDRAM emulation
# stop libdragon's IPL3 detecting any memory, so the loader never copies the
# game in and the CPU falls into the boot-config block. The failure looks like
#
#   Core Error: IPL3 detected 64 MB of RDRAM != 8 MB
#   Core Error: reserved opcode: 80000300:1
#
# and the first of those two lines is a red herring. See
# docs/ipl3-emulator-matrix.md for the full trace, and
# tools/mupen/rdram-libdragon-compat.patch for what is wrong and why.
#
#   tools/build_mupen_shim.sh [--src DIR] [--out DIR]
#
# With no --src it fetches the Debian/Ubuntu source package, which needs
# deb-src enabled:
#   sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
#   apt-get update
#
# Prints the --corelib argument to use. Skips cleanly (exit 0) when it cannot
# get the source or lacks a compiler, so a gate can report SKIP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PATCH="$HERE/mupen/rdram-libdragon-compat.patch"
SRC=""
OUT="${TMPDIR:-/tmp}/pak-mupen-shim"

while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        *) echo "mupen-shim: unknown argument $1"; exit 1 ;;
    esac
done

command -v gcc >/dev/null 2>&1 || { echo "mupen-shim: SKIP (no gcc)"; exit 0; }
[ -f "$PATCH" ] || { echo "mupen-shim: patch missing at $PATCH"; exit 1; }

mkdir -p "$OUT" || { echo "mupen-shim: cannot create $OUT"; exit 0; }

if [ -z "$SRC" ]; then
    ( cd "$OUT" && apt-get source mupen64plus-core ) > "$OUT/fetch.log" 2>&1
    SRC=$(find "$OUT" -maxdepth 1 -type d -name 'mupen64plus-core-*' | head -1)
    if [ -z "$SRC" ]; then
        echo "mupen-shim: SKIP (could not fetch mupen64plus-core source;"
        echo "                  enable deb-src, or pass --src DIR)"
        exit 0
    fi
fi
[ -f "$SRC/src/device/rdram/rdram.c" ] \
    || { echo "mupen-shim: $SRC does not look like mupen64plus-core"; exit 1; }

# Build in a copy so a --src tree the caller cares about is left alone, and so
# a re-run always starts from unpatched sources.
WORK="$OUT/build"
rm -rf "$WORK"
cp -a "$SRC" "$WORK" || { echo "mupen-shim: cannot copy source"; exit 0; }

if ! ( cd "$WORK" && patch -p1 --fuzz=3 < "$PATCH" ) > "$OUT/patch.log" 2>&1; then
    echo "mupen-shim: FAILED to apply the patch -- mupen64plus moved under it"
    cat "$OUT/patch.log"
    exit 1
fi

# NO_ASM/interpreter-friendly flags: the point is correctness, not speed, and
# this keeps the build working on hosts without the x86 assembler paths.
if ! ( cd "$WORK/projects/unix" && make all -j "$(nproc 2>/dev/null || echo 2)" \
        OPTFLAGS="-O2" NO_ASM=1 OSD=0 NEW_DYNAREC=0 DEBUGGER=0 ) > "$OUT/build.log" 2>&1; then
    echo "mupen-shim: build failed"
    tail -30 "$OUT/build.log"
    exit 1
fi

LIB="$WORK/projects/unix/libmupen64plus.so.2.0.0"
[ -s "$LIB" ] || { echo "mupen-shim: build produced no core library"; exit 1; }

echo "mupen-shim: built $LIB"
echo "mupen-shim: run Pak ROMs with"
echo "    mupen64plus --corelib $LIB game.z64"
