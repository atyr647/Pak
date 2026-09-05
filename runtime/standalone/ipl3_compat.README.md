# `ipl3_compat.bin` — the bootcode every standalone ROM ships

The N64's PIF hands control to IPL3, 4032 bytes living at ROM `0x40..0xFFF`.
It initialises RDRAM, copies the program out of the cartridge and jumps to it.
Without it a ROM does not boot: `pak link` used to leave the region zeroed, so
every `.z64` it produced looked structurally valid and ran on nothing.

This is **libdragon's IPL3, compat build**, lifted verbatim from
`boot/bin/ipl3_compat.z64` (bytes `0x40..0xFFF`) at the revision
`tools/fetch_libdragon.sh` pins. libdragon is released into the public domain
(Unlicense), so it can ship here with no encumbrance — unlike Nintendo's
original, which is why `--ipl3` used to be the only way to get a bootable ROM
and required lifting the region out of a commercial cartridge.

The **compat** build is the right one for Pak: libdragon's own README describes
it as "a special compatibility build ... to make it easier to adapt to old
build systems producing a flat file (so that no ELF is required)", which is
exactly what `tcl/n64link.tcl` emits. The mainline build loads an ELF.

Its loader (libdragon `boot/loader_compat.c`) reads two fields out of the ROM
header:

| Offset | Field | What Pak writes |
|--------|-------|-----------------|
| `0x08` | entry point | `0x80000400`, the link base |
| `0x10` | payload size in bytes | the linked image size |

`0x10` is where a conventional ROM keeps CRC1. This IPL3 does not check the
header CRC at all — the CIC checks *it*, not the header — so the field is free
to carry the size, and the loader needs it: given a zero or out-of-range value
it falls back to copying a flat 1 MiB, which is both slower and wrong for an
image larger than that.

Override with `pak link --ipl3 other.z64` to use a different bootcode.

## Emulator compatibility

**mupen64plus 2.5.9 cannot run this IPL3**, and the failure is not Pak's. Its
RDRAM emulation is thin enough that libdragon's memory sizing walks away with
64 MB, which mupen64plus itself notices and reports:

```
Core Error: IPL3 detected 64 MB of RDRAM != 8 MB
Core Error: reserved opcode: 80000300:1
```

A ROM whose entire payload is `b .` / `nop` — two instructions that cannot be
wrong — fails in exactly the same way, so nothing above ROM `0x1000` is
involved. libdragon's own ROMs sidestep it because the *mainline* build does
not write the size it detected to `0x80000318`, where mupen64plus reads it;
the compat build does, so the emulator sees the bad number and stops.

Test standalone ROMs on hardware or on an emulator with real RDRAM emulation
(ares, simple64, or any build tracking libdragon's own CI). `pak explain`,
`pak dlist` and the MIPS simulator are the loop to use here in the meantime;
the libdragon backend is the path with an emulator-verified toolchain today.
