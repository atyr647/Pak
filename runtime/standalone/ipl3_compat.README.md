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

**ares runs it.** `tcl/tools/ares_test.tcl` boots two ROMs on ares headless
under Xvfb and checks the pixels that come out; `tools/build_ares.sh` builds
the emulator. Note that the Debian and Ubuntu `ares` packages have the
Nintendo 64 core removed, and that package is on PATH ahead of a locally built
one -- it opens a window, loads nothing, and shows a black screen, which looks
exactly like a ROM that will not boot. The gate checks which systems the ares
it found actually has.

## What the game has to do: terminate the boot process

Something must write `8` to the last word of PIF RAM (`0xBFC007FC`) after
boot. If nobody does, the PIF halts the CPU five seconds in -- ares says so
outright:

```
[unusual] [PIF::main] boot timeout: CPU has not sent the boot termination
          command within 5 seconds. Halting the CPU
```

Official IPL3 left this to the game. libdragon's *mainline* loader does it
itself (`boot/loader.c`, `pif_terminate_boot`); the **compat** loader Pak ships
deliberately does not, because the build systems it targets have a crt0 that
already does. So it is `runtime/standalone/boot.S`'s job, and it does it before
calling `main`.

This is worth knowing about because the failure is invisible on a lenient
emulator: mupen64plus does not implement the timeout at all, and even on ares
the picture draws correctly for five seconds before the freeze. Only the log
line names it.
