#!/usr/bin/env bash
# Build ipl3_compat_8m.bin — libdragon's compat IPL3 with the RDRAM probe
# capped at the 8 MiB the console can address.
#
# Why a second bootcode exists at all: the stock compat blob does not boot
# mupen64plus 2.5.9. Its probe counts RDRAM chips until one fails to answer,
# which on that emulator never happens, so it reports 64 MB and mupen64plus
# refuses the ROM. See docs/ipl3-emulator-matrix.md for the evidence, including
# the two patches that rule out the osMemSize word people usually blame.
#
# This builds from libdragon's own source with one patch
# (tools/ipl3/rdram-cap-8mib.patch), rather than editing the shipped binary.
# That matters: the CIC checksums these 4032 bytes, and libdragon's build
# produces a correctly-checksummed blob. A hand-patched binary would boot
# neither console nor CIC-checking emulator.
#
#   tools/build_ipl3_8m.sh [libdragon-dir] [out-file]
#
# Needs the mips64-elf toolchain (tools/build_n64_toolchain.sh). Skips cleanly
# (exit 0, nothing written) without it, so a gate can report SKIP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${1:-${TMPDIR:-/tmp}/pak-libdragon/libdragon}"
OUT="${2:-$REPO/runtime/standalone/ipl3_compat_8m.bin}"
PATCH="$HERE/ipl3/rdram-cap-8mib.patch"
PREFIX="${N64_PREFIX:-/opt/pak-n64}"

command -v "$PREFIX/bin/mips64-elf-gcc" >/dev/null 2>&1 \
    || { echo "ipl3-8m: SKIP (no mips64-elf-gcc at $PREFIX; run tools/build_n64_toolchain.sh)"; exit 0; }
[ -f "$SRC/boot/rdram.c" ] \
    || { echo "ipl3-8m: SKIP (no libdragon source at $SRC; run tools/fetch_libdragon.sh)"; exit 0; }
[ -f "$PATCH" ] || { echo "ipl3-8m: patch missing at $PATCH"; exit 1; }

# Build in a copy: the fetched libdragon tree is a cache shared with other
# gates, and they must keep seeing stock sources.
WORK="${TMPDIR:-/tmp}/pak-ipl3-8m"
rm -rf "$WORK"
mkdir -p "$WORK" || { echo "ipl3-8m: cannot create $WORK"; exit 0; }
cp -a "$SRC" "$WORK/libdragon" || { echo "ipl3-8m: cannot copy libdragon"; exit 0; }

cd "$WORK/libdragon" || exit 1
if ! patch -p1 --fuzz=3 < "$PATCH" > "$WORK/patch.log" 2>&1; then
    echo "ipl3-8m: FAILED to apply $(basename "$PATCH") -- libdragon moved under it"
    cat "$WORK/patch.log"
    exit 1
fi

export N64_INST="$PREFIX"
export PATH="$PREFIX/bin:$PATH"
cd "$WORK/libdragon/boot" || exit 1
if ! COMPAT=1 make -j "$(nproc 2>/dev/null || echo 2)" > "$WORK/build.log" 2>&1; then
    echo "ipl3-8m: build failed"
    tail -30 "$WORK/build.log"
    exit 1
fi

ROM="$WORK/libdragon/boot/bin/ipl3_compat.z64"
[ -s "$ROM" ] || { echo "ipl3-8m: build produced no $ROM"; exit 1; }

# The bootcode is the 0x40..0xFFF region, exactly as n64rom.tcl expects.
mkdir -p "$(dirname "$OUT")"
dd if="$ROM" of="$OUT" bs=1 skip=64 count=4032 status=none || exit 1
[ "$(stat -c%s "$OUT")" = "4032" ] || { echo "ipl3-8m: wrong size"; exit 1; }
echo "ipl3-8m: wrote $OUT (4032 bytes) from patched libdragon"
