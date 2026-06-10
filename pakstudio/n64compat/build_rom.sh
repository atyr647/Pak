#!/usr/bin/env bash
# build_rom.sh — build a PakStudio-generated project into a real .z64 ROM
# against an installed (current) libdragon, using the pak_compat.h shim that
# bridges pak 0.1.0's older libdragon API to the current one.
#
# Usage:
#   build_rom.sh <project_dir> <rom_title> [output.z64]
#
# <project_dir> must already contain src/main.pk64 and pak.toml (as written by
# PakStudio's codegen). Requires N64_INST (default /opt/n64) with a current
# libdragon + the mips64-elf toolchain.
#
# Covers both procedural (asset-free) and asset-bound projects. PakFS builds
# cleanly against current libdragon via the pak_compat.h shim.

set -euo pipefail

PROJ="${1:?usage: build_rom.sh <project_dir> <rom_title> [output.z64]}"
TITLE="${2:?missing rom title}"
OUT="${3:-}"

N64_INST="${N64_INST:-/opt/n64}"
export N64_INST
BIN="$N64_INST/bin"
LIBDIR="$N64_INST/mips64-elf/lib"
GCC="$BIN/mips64-elf-gcc"
COMPAT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJ="$(cd "$PROJ" && pwd)"
[ -z "$OUT" ] && OUT="$PROJ/$(basename "$PROJ").z64"

echo "[1/5] pak build (Pak -> C + Makefile)"
( cd "$PROJ" && pak build >/dev/null )

MK="$PROJ/Makefile"
# Inject the compat shim into CFLAGS and drop the (unused, non-building) PakFS.
sed -i "s|CFLAGS  += -I\$(RUNTIME_DIR)|CFLAGS  += -I$COMPAT -include $COMPAT/pak_compat.h -I\$(RUNTIME_DIR)|" "$MK"

echo "[2/5] compile"
# `make` builds the object then fails at its (libdragon-incompatible) link step;
# we only need the object, then link ourselves.
( cd "$PROJ" && make >/dev/null 2>&1 ) || true
OBJ="$(find "$PROJ/build" -name 'main.o' | head -1)"
[ -f "$OBJ" ] || { echo "ERROR: compile produced no object" >&2; exit 1; }

echo "[3/5] link"
ELF="$PROJ/game.elf"
"$GCC" "$OBJ" -L"$LIBDIR" -T"$LIBDIR/n64.ld" \
    -Wl,--gc-sections -Wl,--wrap,__do_global_ctors \
    -Wl,--start-group -ldragon -lc -lm -ldragonsys -Wl,--end-group \
    -o "$ELF"

echo "[4/5] strip + compress"
"$BIN/n64sym" "$ELF" "$ELF.sym"
cp "$ELF" "$ELF.stripped"
"$BIN/mips64-elf-strip" -s "$ELF.stripped"
"$BIN/n64elfcompress" -o "$(dirname "$ELF")" -c 1 "$ELF.stripped" >/dev/null

echo "[5/5] pack ROM -> $OUT"
"$BIN/n64tool" --title "$TITLE" --toc --output "$OUT" \
    --align 256 "$ELF.stripped" --align 8 "$ELF.sym" --align 8

echo "Done -> $OUT"
