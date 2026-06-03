# Bare-metal N64 demo — toolchain-free

This example builds a bootable `.z64` **entirely with the Pak toolchain** — no
`gcc`, no `binutils`, no libdragon. It exercises the full self-hosted path:

```
main.pk64 ──(pak explain --backend mips)──▶ main.s        ┐
start.s   ───────────────────────────────────────────────┤
                                                          ├─(tcl/n64asm.tcl)─▶ program @ 0x80000400
ipl3.s    ───────────────────────────────────────────────┘─(tcl/n64asm.tcl)─▶ IPL3   @ 0xA4000040 (DMEM)
program + IPL3 ──────────────────────────(tcl/n64rom.tcl)────────────────────▶ baremetal.z64
```

`tcl/n64asm.tcl` is a self-hosted MIPS assembler + linker whose output is
byte-exact against GNU `as` (see `tcl/tools/n64asm_parity.sh`). `tcl/n64rom.tcl`
assembles the final ROM image and header.

## What the program does

`main.pk64` is pure Pak. It writes a 320×240 16-bit (RGBA5551) framebuffer
directly to RDRAM through uncached MMIO (`0xA0100000`), then programs the Video
Interface registers for NTSC scanout. No OS, no library — just the hardware.

The framebuffer write relies on `*volatile u16` pointer stores. This is exactly
the pattern that surfaced (and is now fixed) in the MIPS backend: a `*u16` store
must lower to `sh` (halfword), not `sw` (word) — a `sw` to a 2-byte-aligned
address raises an unaligned-store address-error exception on the VR4300.

## Build

From the repository root:

```sh
# 1. Pak -> MIPS assembly
pak explain --backend mips examples/baremetal/main.pk64 > examples/baremetal/main.s
# 2. assemble + link + build the ROM (pure Pak tooling)
tclsh examples/baremetal/build.tcl examples/baremetal/baremetal.z64
```

This produces a 512 KiB `.z64` with entry `0x80000400` and our own PI-DMA IPL3
(see `ipl3.s`) embedded at `0x40`.

## The IPL3

`ipl3.s` is a minimal boot stub that runs from DMEM (`0xA4000040`). It copies the
program from cartridge to RDRAM using **PI DMA** (the PI registers at
`0xA4600000`) and jumps to `0x80000400`. PI DMA is required: direct CPU loads
from cartridge space (`0xB000_0000`) are not serviced by HLE emulators, and the
real PI is the hardware-correct path.

## Status

The ROM is structurally verified: the assembler output is byte-exact against
binutils, the header/IPL3/layout disassemble correctly, and mupen64plus loads
the image and starts the R4300. Capturing a rendered screenshot in CI's headless
software-GL environment is still open — the available HLE video plugins do not
scan out a raw CPU-written framebuffer, and the LLE plugin path under `llvmpipe`
renders blank. On real hardware / an LLE-accurate emulator with a display, the
VI scanout shows the framebuffer.
