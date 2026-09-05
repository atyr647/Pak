#!/usr/bin/env bash
# Build and install libdragon with the mips64-elf toolchain, so
# tcl/tools/libdragon_link_test.tcl can link a real ROM.
#
#   N64_INST=/opt/pak-n64 tools/build_libdragon.sh
#
# Needs tools/build_n64_toolchain.sh to have run first. Installs libdragon.a,
# n64.ld, the headers and the host tools (n64tool, n64sym, n64elfcompress,
# mkdfs) into $N64_INST -- the ROM rule in n64.mk needs all four.
#
# The revision is the one tools/fetch_libdragon.sh pins, so the library that
# gets linked is the same one libdragon_api_test.tcl compiles against.
#
# Skips cleanly without the toolchain or the sources.
set -u
N64_INST="${N64_INST:-/opt/pak-n64}"
CACHE="${TMPDIR:-/tmp}"
SRC="$CACHE/pak-libdragon/libdragon"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$N64_INST/mips64-elf/lib/libdragon.a" ] && [ -x "$N64_INST/bin/n64sym" ] && {
    echo "libdragon: already installed at $N64_INST"; exit 0; }

[ -x "$N64_INST/bin/mips64-elf-gcc" ] || {
    echo "libdragon: SKIP (no toolchain at $N64_INST -- run tools/build_n64_toolchain.sh)"; exit 0; }
[ -x "$N64_INST/bin/mips64-elf-g++" ] || {
    echo "libdragon: SKIP (toolchain has no C++ compiler; libdragon needs it for debugcpp.cpp)"; exit 0; }

[ -d "$SRC" ] || bash "$HERE/fetch_libdragon.sh" "$CACHE/pak-libdragon"
[ -d "$SRC" ] || { echo "libdragon: SKIP (no sources)"; exit 0; }

export N64_INST PATH="$N64_INST/bin:$PATH"
cd "$SRC"
set -e
make -j"${JOBS:-$(nproc 2>/dev/null || echo 2)}" libdragon
make install
make tools-install
echo "libdragon: installed to $N64_INST"
