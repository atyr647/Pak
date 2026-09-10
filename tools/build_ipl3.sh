#!/usr/bin/env bash
# Rebuild libdragon's compat IPL3 from source, optionally with a patch applied.
#
# This exists because the shipped bootcode does not boot mupen64plus 2.5.9 (see
# docs/ipl3-emulator-matrix.md) and any attempt to fix that has to be built,
# not hand-edited: the CIC checksums these 4032 bytes, so a patched *binary*
# would boot neither a console nor an emulator that checks. Built from
# libdragon's own tree, the checksum comes out right.
#
#   tools/build_ipl3.sh [--patch FILE] [--src DIR] [--out FILE]
#
# With no --patch it rebuilds stock, which is the control worth running first:
# the result will NOT be byte-identical to runtime/standalone/ipl3_compat.bin
# (a different GCC lays the code out differently) but must behave identically.
# That is what makes a later behavioural difference attributable to the patch.
#
# Needs the mips64-elf toolchain (tools/build_n64_toolchain.sh). Skips cleanly
# (exit 0, nothing written) without it, so a gate can report SKIP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${TMPDIR:-/tmp}/pak-libdragon/libdragon"
OUT="$REPO/runtime/standalone/ipl3_rebuilt.bin"
PATCH=""
PREFIX="${N64_PREFIX:-/opt/pak-n64}"

while [ $# -gt 0 ]; do
    case "$1" in
        --patch) PATCH="${2:-}"; shift 2 ;;
        --src)   SRC="${2:-}";   shift 2 ;;
        --out)   OUT="${2:-}";   shift 2 ;;
        *) echo "ipl3: unknown argument $1"; exit 1 ;;
    esac
done

command -v "$PREFIX/bin/mips64-elf-gcc" >/dev/null 2>&1 \
    || { echo "ipl3: SKIP (no mips64-elf-gcc at $PREFIX; run tools/build_n64_toolchain.sh)"; exit 0; }
[ -f "$SRC/boot/rdram.c" ] \
    || { echo "ipl3: SKIP (no libdragon source at $SRC; run tools/fetch_libdragon.sh)"; exit 0; }
[ -z "$PATCH" ] || [ -f "$PATCH" ] || { echo "ipl3: patch missing at $PATCH"; exit 1; }

# Build in a copy: the fetched libdragon tree is a cache shared with other
# gates, and they must keep seeing stock sources.
WORK="${TMPDIR:-/tmp}/pak-ipl3-build"
rm -rf "$WORK"
mkdir -p "$WORK" || { echo "ipl3: cannot create $WORK"; exit 0; }
cp -a "$SRC" "$WORK/libdragon" || { echo "ipl3: cannot copy libdragon"; exit 0; }

cd "$WORK/libdragon" || exit 1
if [ -n "$PATCH" ]; then
    if ! patch -p1 --fuzz=3 < "$PATCH" > "$WORK/patch.log" 2>&1; then
        echo "ipl3: FAILED to apply $(basename "$PATCH") -- libdragon moved under it"
        cat "$WORK/patch.log"
        exit 1
    fi
fi

export N64_INST="$PREFIX"
export PATH="$PREFIX/bin:$PATH"
cd "$WORK/libdragon/boot" || exit 1
if ! COMPAT=1 make -j "$(nproc 2>/dev/null || echo 2)" > "$WORK/build.log" 2>&1; then
    echo "ipl3: build failed"
    tail -30 "$WORK/build.log"
    exit 1
fi

ROM="$WORK/libdragon/boot/bin/ipl3_compat.z64"
[ -s "$ROM" ] || { echo "ipl3: build produced no $ROM"; exit 1; }

# The bootcode is the 0x40..0xFFF region, exactly as n64rom.tcl expects.
mkdir -p "$(dirname "$OUT")"
dd if="$ROM" of="$OUT" bs=1 skip=64 count=4032 status=none || exit 1
[ "$(stat -c%s "$OUT")" = "4032" ] || { echo "ipl3: wrong size"; exit 1; }
echo "ipl3: wrote $OUT (4032 bytes)${PATCH:+ with $(basename "$PATCH")}"
