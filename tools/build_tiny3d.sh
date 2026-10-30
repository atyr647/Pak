#!/usr/bin/env bash
# tools/build_tiny3d.sh — build Tiny3D (libt3d.a + the glTF->t3dm importer) against an installed libdragon.
#
# Unreal64 (atyr647/unreal64) converts Unreal levels to Tiny3D assets and needs both products:
#   $N64_INST/lib/libt3d.a (+ headers)   and   $N64_INST/bin/gltf_to_t3d
#
#   N64_INST=/opt/pak-n64 tools/build_tiny3d.sh
set -u
N64_INST="${N64_INST:-/opt/pak-n64}"
CACHE="${TMPDIR:-/tmp}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$CACHE/pak-tiny3d/tiny3d"

[ -f "$N64_INST/mips64-elf/lib/libdragon.a" ] || {
    echo "tiny3d: SKIP (libdragon not installed at $N64_INST -- run tools/build_libdragon.sh)"; exit 0; }
[ -f "$N64_INST/bin/gltf_to_t3d" ] && [ -f "$N64_INST/mips64-elf/lib/libt3d.a" ] && {
    echo "tiny3d: already installed at $N64_INST"; exit 0; }

[ -d "$SRC/src/t3d" ] || bash "$HERE/fetch_tiny3d.sh" "$CACHE/pak-tiny3d"
[ -d "$SRC/src/t3d" ] || { echo "tiny3d: SKIP (no sources)"; exit 0; }

export N64_INST PATH="$N64_INST/bin:$PATH"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
cd "$SRC"
set -e
make -j"$JOBS"
make -C tools/gltf_importer -j"$JOBS"
install -d "$N64_INST/bin"
install -m 755 tools/gltf_importer/gltf_to_t3d "$N64_INST/bin/gltf_to_t3d"
# t3d-inst.mk is Tiny3D's own install rule for the library and headers.
make install
echo "tiny3d: installed to $N64_INST"
