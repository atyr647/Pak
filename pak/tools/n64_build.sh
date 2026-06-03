#!/usr/bin/env bash
# n64_build.sh — Build a Pak source file into an N64 .z64 ROM
#
# Usage:
#   n64_build.sh <source.pk64> [output.z64] [options]
#
# Options:
#   --name "TITLE"        ROM title (max 20 chars, default: filename)
#   --ipl3 path/to/ipl3   IPL3 binary (emulator OK without, hardware needs it)
#   --gcc  path/to/gcc    Override mips-n64-gcc location
#   --opt  -O2            GCC optimisation flag (default -O2)
#   --keep                Keep intermediate build dir
#
# Environment variables:
#   N64_GCC    Path to mips-n64-gcc (searched in PATH if unset)
#   N64_IPL3   Path to IPL3 binary (overridden by --ipl3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/../runtime" && pwd)"

# ── Argument parsing ────────────────────────────────────────────────────────

SOURCE=""
OUTPUT=""
ROM_NAME=""
IPL3_PATH="${N64_IPL3:-}"
GCC_PATH="${N64_GCC:-}"
OPT="-O2"
KEEP=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)  ROM_NAME="$2";  shift 2 ;;
        --ipl3)  IPL3_PATH="$2"; shift 2 ;;
        --gcc)   GCC_PATH="$2";  shift 2 ;;
        --opt)   OPT="$2";       shift 2 ;;
        --keep)  KEEP=1;         shift   ;;
        -*)      echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$SOURCE" ]]; then SOURCE="$1"
            elif [[ -z "$OUTPUT" ]]; then OUTPUT="$1"
            fi
            shift ;;
    esac
done

if [[ -z "$SOURCE" ]]; then
    echo "Usage: n64_build.sh <source.pk64> [output.z64] [options]" >&2
    exit 1
fi

SOURCE="$(realpath "$SOURCE")"
BASE="$(basename "$SOURCE" .pk64)"
OUTPUT="${OUTPUT:-${BASE}.z64}"
ROM_NAME="${ROM_NAME:-${BASE}}"

# ── Locate mips-n64-gcc ─────────────────────────────────────────────────────

if [[ -z "$GCC_PATH" ]]; then
    # Common install locations for the libdragon toolchain (standalone)
    for candidate in \
        mips-n64-gcc \
        /usr/local/n64/bin/mips-n64-gcc \
        /opt/n64/bin/mips-n64-gcc \
        "$HOME/n64/bin/mips-n64-gcc"; do
        if command -v "$candidate" &>/dev/null; then
            GCC_PATH="$candidate"
            break
        fi
    done
fi

if [[ -z "$GCC_PATH" ]]; then
    echo "ERROR: mips-n64-gcc not found." >&2
    echo "  Install the standalone N64 toolchain or set N64_GCC=/path/to/mips-n64-gcc" >&2
    echo "  Get it from: https://github.com/DragonMinded/libdragon/releases" >&2
    exit 1
fi

echo "Using compiler: $GCC_PATH"

# ── Build directory ─────────────────────────────────────────────────────────

BUILD_DIR="$(mktemp -d "/tmp/pak_build_XXXXXX")"
trap '[[ $KEEP -eq 0 ]] && rm -rf "$BUILD_DIR"' EXIT
echo "Build dir: $BUILD_DIR"

# ── Step 1: Pak → C ─────────────────────────────────────────────────────────

echo "[1/4] Generating C..."
python3 -m pak codegen "$SOURCE" > "$BUILD_DIR/game.c"

# ── Step 2: C → ELF ─────────────────────────────────────────────────────────

echo "[2/4] Compiling..."
"$GCC_PATH" \
    -march=vr4300 -mabi=32 -mfix4300 \
    "$OPT" -G0 \
    -ffreestanding -nostdlib -nostdinc \
    -fno-exceptions -fno-asynchronous-unwind-tables \
    -fno-stack-protector \
    -I "$RUNTIME_DIR" \
    -T "$RUNTIME_DIR/n64.ld" \
    "$BUILD_DIR/game.c" \
    "$RUNTIME_DIR/boot.S" \
    "$RUNTIME_DIR/vi.c" \
    "$RUNTIME_DIR/si.c" \
    "$RUNTIME_DIR/pak_hal.c" \
    -o "$BUILD_DIR/game.elf" \
    -lm

# ── Step 3: ELF → raw binary ────────────────────────────────────────────────

echo "[3/4] Extracting binary..."
mips-n64-objcopy -O binary "$BUILD_DIR/game.elf" "$BUILD_DIR/game.bin"

# ── Step 4: Pack ROM ────────────────────────────────────────────────────────

echo "[4/4] Packing ROM..."
IPL3_ARG=""
[[ -n "$IPL3_PATH" ]] && IPL3_ARG="--ipl3 $IPL3_PATH"

python3 "$SCRIPT_DIR/rompack.py" \
    "$BUILD_DIR/game.bin" \
    "$OUTPUT" \
    --name "$ROM_NAME" \
    $IPL3_ARG

echo "Done → $OUTPUT"
