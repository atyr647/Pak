#!/usr/bin/env python3
"""
Build a headless N64 test ROM from a C source file.

The ROM uses a minimal soft-copy IPL3 (no libdragon) that:
  1. Initialises the RDRAM interface.
  2. Software-copies ROM[0x1000..] → RDRAM[0x400..] (1 MB).
  3. Jumps to 0x80000400.

Code is compiled with mips64-elf-gcc (no libdragon dependency).

ROM test protocol expected by tools/n64_test_runner.py:
  *(0x80300000) = 0xDEADBEEF  — entry reached
  *(0x80300010 + i*4) = result_i
  *(0x80300000) = 0xC0FFEE00  — done

Usage:
  python3 tools/n64_build_rom.py  input.c  output.z64
  python3 tools/n64_build_rom.py  input.c  output.z64  --title "MyTest"
"""
import argparse, os, struct, subprocess, sys, tempfile

# ── Toolchain ───────────────────────────────────────────────────────────────
MIPS_GCC = "mips64-elf-gcc"
MIPS_OCP = "mips64-elf-objcopy"
MIPS_AS  = "mips64-elf-as"
MIPS_LD  = "mips64-elf-ld"

TOOLCHAIN_PATH = "/opt/n64/bin"

# ── Embedded IPL3 source ─────────────────────────────────────────────────────
# Assembled at runtime from this source; cached to /tmp/pak_softcopy_ipl3.bin
_SOFTCOPY_IPL3_SRC = r"""
/* Minimal N64 soft-copy IPL3 — runs at DMEM 0xa4000040.
 * 1. Minimal RI init (enable RDRAM in mupen64plus).
 * 2. Software loop: copy 1 MB from ROM[0x1000] → RDRAM[0x400].
 * 3. Set $sp and jump to entry 0x80000400.
 */
.set noreorder
.set noat
_start:
    lui   $t0, 0xa470
    li    $t1, 0xE;        sw $t1,  0($t0)   /* RI_MODE    */
    li    $t1, 0x40;       sw $t1,  4($t0)   /* RI_CONFIG  */
    sw    $zero, 8($t0)                       /* RI_CURR_LOAD */
    li    $t1, 0x14;       sw $t1, 12($t0)   /* RI_SELECT  */
    lui   $t1, 0x6; ori $t1,$t1,0x3634
    sw    $t1, 16($t0)                        /* RI_REFRESH */
    li    $t1, 0x88;       sw $t1, 20($t0)   /* RI_LATENCY */

    lui   $a0, 0xB000; ori $a0,$a0,0x1000    /* src: ROM[0x1000] uncached */
    lui   $a1, 0x8000; ori $a1,$a1,0x0400    /* dst: RDRAM[0x400] */
    lui   $a2, 0x0010                         /* 0x10000 words = 256KB */

copy:
    lw    $t0, 0($a0)
    sw    $t0, 0($a1)
    addiu $a0, $a0, 4
    addiu $a1, $a1, 4
    addiu $a2, $a2, -1
    bnez  $a2, copy
    nop

    lui   $sp, 0x8007; ori $sp,$sp,0xFFF0    /* stack at ~8 MB mark */
    lui   $t0, 0x8000; ori $t0,$t0,0x0400
    jr    $t0
    nop
"""

# Minimal crt0 that sets GP and calls main()
_CRT0_SRC = r"""
.set noreorder
.section .boot, "ax", @progbits
.global _start
_start:
    lui   $gp, %hi(__gnu_local_gp)
    addiu $gp, $gp, %lo(__gnu_local_gp)
    lui   $sp, 0x8007; ori $sp,$sp,0xFFF0
    jal   main
    nop
_hang:
    j   _hang
    nop
"""

# Linker script: code at VMA 0x80000400, LMA 0 (binary starts at file offset 0)
_LINKER_SCRIPT = r"""
ENTRY(_start)
OUTPUT_FORMAT("elf32-bigmips","elf32-bigmips","elf32-littlemips")
OUTPUT_ARCH(mips)
SECTIONS {
    .boot 0x80000400 : AT(0) { *(.boot) }
    .text  : { *(.text*) *(.rodata*) . = ALIGN(4); }
    .data  : { *(.data*) *(.sdata*) . = ALIGN(4); }
    .bss   : { *(.bss*)  *(.sbss*)  . = ALIGN(8); }
    __gnu_local_gp = .;
}
"""


# ── Helpers ──────────────────────────────────────────────────────────────────

def _tool(name):
    p = os.path.join(TOOLCHAIN_PATH, name)
    return p if os.path.exists(p) else name


def _build_ipl3(cache="/tmp/pak_softcopy_ipl3.bin"):
    if os.path.exists(cache):
        return cache
    td = tempfile.mkdtemp(prefix="pak_ipl3_")
    src = os.path.join(td, "ipl3.S")
    obj = os.path.join(td, "ipl3.o")
    elf = os.path.join(td, "ipl3.elf")
    with open(src, "w") as f:
        f.write(_SOFTCOPY_IPL3_SRC)
    subprocess.run([_tool(MIPS_AS), "-march=vr4300", "-mabi=32", "-EB",
                    "-o", obj, src], check=True, capture_output=True)
    subprocess.run([_tool(MIPS_LD), "-Ttext=0x0", "-o", elf, obj],
                   check=True, capture_output=True)
    subprocess.run([_tool(MIPS_OCP), "-O", "binary", "--only-section=.text",
                    elf, cache], check=True, capture_output=True)
    return cache


def build_rom(c_source, output_z64, title="PakTest"):
    """Compile c_source to a headless N64 test ROM at output_z64."""
    td = tempfile.mkdtemp(prefix="pak_n64rom_")

    # Write crt0 and linker script
    crt0 = os.path.join(td, "crt0.S")
    ld_s = os.path.join(td, "n64mini.ld")
    elf  = os.path.join(td, "prog.elf")
    bin_ = os.path.join(td, "prog.bin")

    with open(crt0, "w") as f: f.write(_CRT0_SRC)
    with open(ld_s, "w") as f: f.write(_LINKER_SCRIPT)

    # Compile
    ret = subprocess.run(
        [_tool(MIPS_GCC),
         "-march=vr4300", "-mtune=vr4300", "-mabi=32", "-EB",
         "-O2", "-G0", "-ffreestanding", "-nostdlib", "-nostartfiles",
         f"-Wl,-T,{ld_s}",
         crt0, c_source,
         "-o", elf],
        capture_output=True, text=True
    )
    if ret.returncode != 0:
        print(ret.stderr, file=sys.stderr)
        raise RuntimeError(f"Compilation failed: {c_source}")

    subprocess.run([_tool(MIPS_OCP), "-O", "binary", elf, bin_],
                   check=True, capture_output=True)

    with open(bin_, "rb") as f: code = f.read()

    # Build IPL3
    ipl3_bin = _build_ipl3()
    with open(ipl3_bin, "rb") as f: ipl3 = f.read()

    # Assemble ROM
    _write_rom(output_z64, ipl3, code, title)
    return output_z64


def _write_rom(path, ipl3, code, title):
    """Assemble the final .z64 ROM file."""
    title_bytes = title.encode("ascii")[:20].ljust(20)

    header = bytearray(64)
    struct.pack_into(">I", header,  0, 0x80371240)   # magic
    struct.pack_into(">I", header,  4, 0x0000000F)   # clock
    struct.pack_into(">I", header,  8, 0x80000400)   # entry PC
    header[32:52] = title_bytes
    header[56]    = 0x4E   # 'N' — N64 Game Pak
    header[62]    = 0x45   # 'E' — North America

    ipl3_region = bytes(ipl3) + b"\x00" * (0x1000 - 0x40 - len(ipl3))
    content = bytes(header) + ipl3_region + code

    # Minimum 1 MiB, 512-byte aligned
    pad = max(0, 1024 * 1024 - len(content))
    content += b"\x00" * pad
    rem = len(content) % 512
    if rem:
        content += b"\x00" * (512 - rem)

    with open(path, "wb") as f:
        f.write(content)


# ── CLI ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("c_source")
    ap.add_argument("output_z64")
    ap.add_argument("--title", default="PakTest")
    args = ap.parse_args()

    os.environ["PATH"] = TOOLCHAIN_PATH + ":" + os.environ.get("PATH", "")
    build_rom(args.c_source, args.output_z64, args.title)
    print(f"Built: {args.output_z64}")


if __name__ == "__main__":
    main()
