#!/usr/bin/env bash
# Validate tcl/n64asm.tcl against mips64-elf-as+ld (oracle) when available.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS=$(command -v mips64-elf-as || echo /opt/n64/bin/mips64-elf-as)
LD=$(command -v mips64-elf-ld || echo /opt/n64/bin/mips64-elf-ld)
OC=$(command -v mips64-elf-objcopy || echo /opt/n64/bin/mips64-elf-objcopy)
# Skipping without the oracle is right on a laptop and wrong in CI, where a
# half-failed toolchain install would turn a real disagreement into a green
# tick. CI sets PAK_REQUIRE_N64_TOOLCHAIN=1.
if [ ! -x "$AS" ]; then
    case "${PAK_REQUIRE_N64_TOOLCHAIN:-}" in
        ""|0|no|false) echo "n64asm parity: SKIP (no mips64-elf-as)"; exit 0 ;;
        *) echo "n64asm parity: FAIL (PAK_REQUIRE_N64_TOOLCHAIN set, no mips64-elf-as)"; exit 1 ;;
    esac
fi
T=$(mktemp -d); trap "rm -rf $T" EXIT
cp "$HERE/n64asm_fixture.s" "$T/t.s"
"$AS" -march=vr4300 -mabi=32 -o "$T/t.o" "$T/t.s"
cat > "$T/l.ld" <<'LD'
SECTIONS { . = 0x80000400; .text : { *(.text) } .rodata : { *(.rodata) } }
LD
"$LD" -T "$T/l.ld" -o "$T/t.elf" "$T/t.o"
"$OC" -O binary -j .text -j .rodata "$T/t.elf" "$T/t.bin"
B=$(od -An -tx1 "$T/t.bin" | tr -d ' \n')
M=$(tclsh "$HERE/n64asm_dump.tcl" "$T/t.s")
if [ "$B" = "$M" ]; then echo "n64asm parity: MATCH (byte-exact vs binutils)"; else
  echo "n64asm parity: MISMATCH"; echo "B:$B"; echo "M:$M"; exit 1; fi
