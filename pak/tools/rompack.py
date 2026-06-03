#!/usr/bin/env python3
"""
rompack.py — Pack a MIPS binary into an N64 .z64 ROM image.

Usage:
    python rompack.py <input.bin> <output.z64> [--name "GAME NAME"] [--ipl3 path/to/ipl3.bin]

The script:
  1. Reads a raw big-endian MIPS binary (output of mips-n64-objcopy -O binary)
  2. Prepends the 64-byte ROM header
  3. Embeds an IPL3 bootstrap (4032 bytes at offset 0x40)
  4. Calculates and patches CRC1 + CRC2
  5. Writes a .z64 (big-endian) ROM image

IPL3 source
-----------
This tool does not bundle an IPL3 because the reference implementations are
under various licences. You have two options:

  a) Extract from an existing homebrew ROM:
       dd if=some_homebrew.z64 bs=1 skip=64 count=4032 of=ipl3.bin

  b) Build the open-source IPL3 from n64brew:
       https://github.com/jago85/n64brew-ipl3
     Produces a ~4032-byte binary you can pass with --ipl3.

If --ipl3 is omitted the script writes 4032 zero bytes, which will boot on
most emulators but not on real hardware (the real hardware CIC check fails).
"""

import argparse
import struct
import sys
from pathlib import Path

# ── ROM header constants ───────────────────────────────────────────────────

HEADER_SIZE  = 0x40      # 64 bytes
IPL3_SIZE    = 0xFC0     # 4032 bytes  (0x40 .. 0xFFF)
HEADER_TOTAL = HEADER_SIZE + IPL3_SIZE   # 0x1000 = 4096 bytes before user code

ROM_COUNTRY_US   = 0x45   # 'E'
ROM_MEDIA_CART   = 0x4E   # 'N'

# ── N64 CRC algorithm (CIC-NUS-6102 / CIC-NUS-7101) ──────────────────────

def _ror32(v: int, b: int) -> int:
    b &= 31
    return ((v >> b) | (v << (32 - b))) & 0xFFFF_FFFF

def n64_crc(rom: bytes) -> tuple[int, int]:
    """
    Calculate N64 ROM CRC1 and CRC2 for CIC-NUS-6102.
    Operates on the 1 MB region starting at ROM offset 0x1000.
    """
    SEED = 0xF8CA4DDC
    M    = 0xFFFF_FFFF

    t1 = t2 = t3 = t4 = t5 = t6 = SEED

    for i in range(0, 0x10_0000, 4):
        off = 0x1000 + i
        if off + 4 <= len(rom):
            d = struct.unpack_from(">I", rom, off)[0]
        else:
            d = 0

        old_t6 = t6
        t6 = (t6 + d) & M
        if t6 < old_t6:       # carry
            t4 = (t4 + 1) & M

        t3 = (t3 ^ d) & M
        r  = _ror32(d, d & 31)
        t5 = (t5 + r) & M

        if t2 > d:
            t2 = (t2 ^ r) & M
        else:
            t2 = (t2 ^ (t6 ^ d)) & M

        t1 = (t1 + (((i >> 2) & 0xFF) ^ d)) & M

    crc1 = (t6 ^ t4 ^ t3) & M
    crc2 = (t5 ^ t2 ^ t1) & M
    return crc1, crc2

# ── Header builder ────────────────────────────────────────────────────────

def build_header(name: str, boot_addr: int = 0x8000_0400) -> bytes:
    """
    Build the 64-byte N64 ROM header.
    CRC fields are initially zero; patch_crc() fills them in.
    """
    hdr = bytearray(HEADER_SIZE)

    # PI BSD config (identifies this as a valid N64 ROM)
    hdr[0] = 0x80
    hdr[1] = 0x37
    hdr[2] = 0x12
    hdr[3] = 0x40

    # Clock rate (0x000F0000 = use default)
    struct.pack_into(">I", hdr,  4, 0x000F_0000)

    # PC on entry (where IPL3 jumps after copying code to RDRAM)
    struct.pack_into(">I", hdr,  8, boot_addr)

    # Release: 0
    struct.pack_into(">I", hdr, 12, 0)

    # CRC1 / CRC2 — patched later
    struct.pack_into(">I", hdr, 16, 0)
    struct.pack_into(">I", hdr, 20, 0)

    # Unknown (bytes 24-31)
    struct.pack_into(">Q", hdr, 24, 0)

    # Game name: 20 bytes, space-padded, ASCII
    name_bytes = name.encode("ascii", errors="replace")[:20]
    name_field = name_bytes.ljust(20, b" ")
    hdr[32:52] = name_field

    # Bytes 52-55: manufacturer + game code placeholder
    hdr[52:56] = b"\x00\x00\x00\x00"

    # Media type + cartridge ID + country code + version
    hdr[56] = 0x00
    hdr[57] = ROM_MEDIA_CART     # 'N'
    hdr[58] = 0x50               # 'P' — placeholder cart ID
    hdr[59] = 0x4B               # 'K' (PK for Pak)
    hdr[60] = ROM_COUNTRY_US     # 'E' — US/NTSC
    hdr[61] = 0x00               # mask ROM version
    hdr[62] = 0x00
    hdr[63] = 0x00

    return bytes(hdr)

def patch_crc(rom: bytearray) -> None:
    """Write CRC1 and CRC2 into the header of a complete ROM image."""
    crc1, crc2 = n64_crc(bytes(rom))
    struct.pack_into(">I", rom, 16, crc1)
    struct.pack_into(">I", rom, 20, crc2)

# ── Main ──────────────────────────────────────────────────────────────────

def pack_rom(binary: bytes, ipl3: bytes, name: str, output: Path) -> None:
    if len(ipl3) > IPL3_SIZE:
        print(f"WARNING: IPL3 is {len(ipl3)} bytes, truncating to {IPL3_SIZE}")
        ipl3 = ipl3[:IPL3_SIZE]

    # Pad IPL3 to exactly IPL3_SIZE bytes
    ipl3_padded = ipl3.ljust(IPL3_SIZE, b"\x00")

    header = build_header(name)

    # Assemble ROM: header | ipl3 | code
    rom = bytearray(header) + bytearray(ipl3_padded) + bytearray(binary)

    # Pad to multiple of 4 bytes
    while len(rom) % 4:
        rom += b"\x00"

    # Pad entire ROM to at least 0x101000 so CRC covers a full 1 MB window
    while len(rom) < 0x101000:
        rom += b"\x00"

    patch_crc(rom)

    output.write_bytes(rom)
    crc1, crc2 = struct.unpack_from(">II", rom, 16)
    print(f"ROM: {output}  ({len(rom):,} bytes)  CRC1={crc1:08X}  CRC2={crc2:08X}")

def main() -> None:
    ap = argparse.ArgumentParser(description="Pack a MIPS binary into an N64 .z64 ROM")
    ap.add_argument("input",        help="Raw MIPS binary (big-endian)")
    ap.add_argument("output",       help="Output .z64 path")
    ap.add_argument("--name",       default="PAK GAME", help="ROM name (max 20 chars)")
    ap.add_argument("--ipl3",       default=None,       help="Path to IPL3 binary (4032 bytes)")
    ap.add_argument("--boot-addr",  default="0x80000400",
                    help="MIPS virtual entry point (default 0x80000400)")
    args = ap.parse_args()

    binary = Path(args.input).read_bytes()

    if args.ipl3:
        ipl3 = Path(args.ipl3).read_bytes()
    else:
        print("NOTE: No --ipl3 supplied. Using zero-padded IPL3 (emulator only).")
        ipl3 = b"\x00" * IPL3_SIZE

    boot_addr = int(args.boot_addr, 0)
    pack_rom(binary, ipl3, args.name, Path(args.output))

if __name__ == "__main__":
    main()
