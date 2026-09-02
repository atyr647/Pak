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
