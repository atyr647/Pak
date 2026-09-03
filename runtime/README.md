# Pak Runtimes

Two runtimes live here, for the two backends.

## `runtime/` — the libdragon runtime (`--backend c`, the default)

Headers and support code the generated C `#include`s, copied into a project by
`pak build`. It assumes libdragon and (when the project enables it) Tiny3D are
present, and is compiled by `mips64-elf-gcc` through the generated Makefile.

* `pak_math.h` — Vec2/Vec3/Mat4 helpers over libdragon and Tiny3D types
* `pak_containers.h` — FixedMap and Pool helpers (FixedList and RingBuffer are
  inlined directly into the generated code)
* `pak_rand.h` — seedable xorshift32 PRNG
* `pakfs.c` / `pakfs.h` — PakFS archive reader
* `pak_mips_rt.s` — assembly helpers (panic, fixed-point divide, arena) for
  projects built with `--backend mips` against a real MIPS toolchain

## `runtime/standalone/` — the toolchain-free runtime

The HAL for the path that needs no external tools at all: no GCC, no `as`, no
`ld`, no libdragon. See `docs/toolchain-free-rom.md`.

* `runtime.pk64` — the HAL written in Pak itself: display and framebuffer
  setup, the software `rdpq` fill, `memset`/`memcpy`, SI controller polling.
  Compiled with `pak objgen`.
* `boot.S` — the crt0. It needs CP0 access (`mfc0`/`mtc0`), which Pak cannot
  express, so it stays hand-written and is assembled by `pak asmobj`.
* `n64.ld` — the memory layout the flat linker reproduces.
* `pak_hal.c` / `pak_hal.h`, `vi.c`, `si.c` — the C form of the same HAL, for
  building this runtime with a real toolchain instead.
* The libdragon-named headers (`rdpq.h`, `joypad.h`, `display.h`, …) are
  stubs that redirect to `pak_hal.h`, so generated code that includes them
  builds without libdragon installed.

### What the standalone runtime provides

| Area | Status |
|------|--------|
| Video Interface | 320x240 16bpp, triple buffered, vblank wait, flip |
| RDP | full display list: fills, copies, texturing, flat triangles, all modes, colour registers, syncs — see `docs/toolchain-free-rom.md` |
| Controller | SI/PIF polling for port 0, held/pressed/released + stick |
| PI DMA | cartridge to and from RDRAM, with the busy wait |
| Timer | COP0 Count, `get_ticks`, frame delta in seconds |
| Memory | bump allocator, `memset`, `memcpy`, `memcmp` |
| Strings | `strlen`, `strcmp`, `strncmp`, `strstr` |
| Cache | hit-writeback, hit-invalidate, and both together |

Not provided, so a program using these needs the libdragon path (`--backend c`)
or its own implementation: **audio** (the AI), **EEPROM / SRAM / FlashRAM
saves**, **Controller Pak and Transfer Pak**, **rumble**, **sprite loading and
blitting** (`sprite_load`, `rdpq_sprite_blit` — the RDP texturing primitives
underneath them are all here), **rspq blocks**, and **Tiny3D**. They are
declared as externs, so a program that calls one fails at link time with an
undefined symbol rather than silently doing nothing.
