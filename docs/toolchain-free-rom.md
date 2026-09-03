# Toolchain-Free ROM Path

Pak can turn a `.pk64` source into an N64 `.z64` ROM **without any external MIPS
toolchain** (`mips64-elf-gcc`, `mips64-elf-as`, `mips64-elf-ld`,
`mips64-elf-objcopy`, libdragon's `n64tool`). The compiler owns every step from
source to machine code.

## Pipeline

```
.pk64  (game + runtime/standalone/runtime.pk64)      boot.S (hand-written crt0)
  → Tcl MIPS codegen (tcl/mips_codegen.tcl)     → Tcl asm front-end
      structured RECORD stream                       (tcl/n64enc.tcl parse_asm)
  → Tcl optimizer (tcl/optimize.tcl) on records
  → Tcl binary encoder (tcl/n64enc.tcl) ───────────────┘
      records → machine-code words + relocations → .pakobj object file
  → Tcl flat linker (tcl/n64link.tcl)
      .pakobj(s) → laid-out flat RDRAM image, relocations patched
  → Tcl ROM packer (tcl/n64rom.tcl)
      flat image → .z64 (IPL3 stub + header + CIC-6102 CRC)
```

No GCC, no `as`, no `ld`, no `objcopy`, no `n64tool`.

## The runtime is Pak + a tiny hand-written crt0

* **`runtime/standalone/runtime.pk64`** — the HAL written entirely in Pak:
  display and framebuffer setup, SI controller polling, EEPROM via SI/PIF
  Joybus channel 4, PI DMA, `memset`/`memcpy`, and a real RDP driver. Free
  functions emit bare symbol names (`display_init`, `rdpq_fill_rectangle`,
  `eeprom_present`, …) matching the calls the codegen lowers game code into.
  MMIO is done with `(0xA4400000 as *volatile u32)` writes; framebuffers
  live in uncached KSEG1 RDRAM so CPU writes are immediately visible to the
  Video Interface.
* **`runtime/standalone/boot.S`** — the crt0. It needs CP0 access
  (`mfc0`/`mtc0`) and `cache` which Pak cannot express, so it stays
  hand-written assembly and is assembled by the encoder's `.s` front-end
  (`pak asmobj`). After zeroing `.bss` it copies an 8-byte trampoline to
  0x80000000 / 0x80 / 0x100 / 0x180 (KSEG1 stores + I-cache hit-invalidate)
  so a CPU exception `jal`s `exception_paint`. The linker supplies
  `__bss_start`/`__bss_end`; boot's `jal main` is resolved to the game's
  `entry` block across objects.

A full ROM is three objects linked in order — **boot first** so `_start` lands
at `0x80000400`:

```sh
pak asmobj runtime/standalone/boot.S        -o boot.pakobj      # crt0
pak objgen runtime/standalone/runtime.pk64  -o runtime.pakobj   # HAL
pak objgen game.pk64             -o game.pakobj      # the game
pak link boot.pakobj runtime.pakobj game.pakobj -o game.z64 --name GAME --size 4

# or, from a pak.toml project:
pak build --backend mips -o game.z64
```

## Why records instead of re-parsing assembly text

The codegen already builds every instruction as a structured method call on the
`pak::Emitter` (`addu $d, $s1, $s2`). Rather than format that to text and have
the encoder parse it back, the Emitter keeps a parallel **record** for each
emitted item:

| Record | Example |
|--------|---------|
| instruction | `{i addu $t1 $t2 $t3}`, `{i lw $t1 4($sp)}`, `{i la $a0 .Lstr0}` |
| label | `{label main}` |
| directive | `{d section .text}`, `{d word 0x10}`, `{d asciiz {Hello}}` |

The unoptimized text dump (`mips_generate`, snapshots) is unchanged; records
are the IR. The encoder consumes records after `pak::optimize_records`, so
there is a single source of truth and no fragile operand-string parsing.
`pak explain --backend mips` dumps that same optimized stream as text.

## Commands

```sh
# .pk64 → relocatable object
pak objgen game.pk64 -o game.pakobj

# object(s) → .z64
pak link boot.pakobj runtime.pakobj game.pakobj -o game.z64 --name GAME

# or dump just the flat binary image
pak link boot.pakobj runtime.pakobj game.pakobj --emit-bin game.bin
```

## Object file format (`.pakobj`)

Line-oriented text, sections in first-seen order:

```
# pak object v1
section .text
sym main 0
reloc 164 R_MIPS_26 compute
reloc 24 R_MIPS_HI16 .Lstr0
reloc 28 R_MIPS_LO16 .Lstr0
data 27bdff00 afbf00fc ...
section .rodata
sym .Lstr0 0
data 48656c6c 6f000000
```

* `sym NAME BYTEOFF` — symbol at a byte offset within its section.
* `reloc BYTEOFF KIND SYMBOL` — link-time fixup; `KIND` ∈
  `R_MIPS_26` (j/jal), `R_MIPS_HI16`/`R_MIPS_LO16` (`la` pair), `R_MIPS_32`
  (`.word` of a symbol).
* `data` — big-endian 32-bit words, hex. Sections are 4-byte padded.

The encoder resolves PC-relative branches (`beq`/`bne` family) locally; absolute
references (`la`, `j`/`jal`, `.word sym`) become relocations the linker patches.

## Memory layout (matches `runtime/standalone/n64.ld`)

Cached KSEG0. Uncached KSEG1 is `addr | 0xA0000000` (how the runtime names
framebuffers and the display list).

| Region | Address | Size |
|--------|---------|------|
| `.text` / `.rodata` / `.data` / `.bss` | `0x80000400` | grows up; **must stay 64 bytes below FB0** |
| 64-byte gap | | linker error on overlap |
| FB0 / FB1 / FB2 | `0x80200000` / `0x80225800` / `0x8024B000` | 320×240×16bpp each (`0x25800`) |
| Z buffer | `0x80271000` | 320×240×16-bit (`0x25800`) |
| RDP display list | `0x80297000` | 8 KB |
| AI PCM ring | `0x80299000` | 28 KB (up to 8 stereo buffers) |
| bump heap | `0x802A0000`–`0x803C0000` | |
| stack top | `0x80400000` | grows down |

Cart images are padded to 4/8/16/32/64 MiB
(`pak link --size 4`, default 4); a 2.9 MB `.z64` crashes on flashcarts.

The linker exports `__fb0`, `__fb1`, `__fb2`, `__zb`, `__dl_base`, `__ab`,
`__heap_start`, `__heap_end`, `__stack_top` so a program can read the map instead of
hard-coding it. `.bss` still reserves address space but is not stored in the
ROM image (boot.S zero-fills it at startup). `R_MIPS_HI16`/`LO16` use the
standard `+0x8000` carry correction.

## The RDP does the drawing

Nothing is rasterized on the CPU. `rdpq_*` builds a display list of 64-bit RDP
commands in uncached RDRAM at `0xA0297000` and hands it to the Display
Processor by writing `DPC_START`/`DPC_END`, then polls `DPC_STATUS` until the
pipe, command and DMA engines are all idle. Uncached KSEG1 means a CPU write
lands in RDRAM immediately, so the DP reads exactly what was written with no
cache-writeback step to get wrong.

What the runtime drives:

| Area | Commands |
|------|----------|
| Render target | `SET_COLOR_IMAGE`, `SET_Z_IMAGE`, `SET_SCISSOR` |
| Modes | `SET_OTHER_MODES` (FILL / COPY / 1-cycle), `SET_COMBINE` |
| Colour registers | fill, blend, fog, env, prim |
| Fills | `FILL_RECTANGLE` in FILL cycle — four bytes per cycle |
| Texturing | `SET_TEXTURE_IMAGE` (writeback of KSEG0 sources), `SET_TILE` / `SET_TILE` clamp+mirror+mask, `SET_TILE_SIZE`, `LOAD_TILE`, `LOAD_BLOCK`, `LOAD_TLUT`, `TEXTURE_RECTANGLE` |
| Geometry | `TRIANGLE` (0x08), `TRI_TEX` (0x0A), `TRI_SHADE` (0x0C), `TRI_SHADE_Z` (0x0D). Edges s15.16; shade RGBA s15.16; Z 15.16 of 0..32767. |
| Sync | `SYNC_PIPE`, `SYNC_TILE`, `SYNC_LOAD`, `SYNC_FULL` |

A full-screen clear is one `FILL_RECTANGLE` instead of 76 800 uncached
halfword stores.

## How the hardware path is verified

There is no N64 and no emulator in CI, so `tcl/tools/rdp_test.tcl` proves the
encodings the only way that means anything: it compiles the runtime together
with a driver program, **executes the resulting MIPS** in `tcl/mips_sim.tcl`,
and reads the display list the runtime built out of simulated RDRAM. Every
command word is compared against the RDP command reference, and the DP kick
(`DPC_START`/`DPC_END`/`DPC_STATUS`) and the VI flip are checked too.

It runs the whole pipeline — codegen, register allocation, the optimizer — so
a miscompile shows up as a wrong command word rather than as a
plausible-looking instruction stream. The optimized and unoptimized builds are
both run and must agree.

The simulator models the two registers the runtime spins on (`DPC_STATUS` and
`VI_V_CURRENT`) via a preset that can return a sequence of values, so hardware
wait loops terminate instead of hanging.

## Current limitations

* **Optimization.** The peephole/scheduler/delay-slot passes in
  `tcl/optimize.tcl` operate on instruction records. `pak objgen` and
  `pak build --backend mips -o game.z64` run them before encode, so the
  binary is delay-slot-filled. `pak explain --backend mips` dumps the same
  optimized stream as text. Encoded-byte call/MMIO goldens live in
  `tcl/tools/enc_exec_test.tcl`.
* **Shade+tex.** `rdpq.triangle_shade_tex` is Gouraud + affine ST (0x0E).
  `rdpq.set_tri_z` then `rdpq.triangle_shade_tex_z` adds Z (0x0F). Same
  s15.16 coefficients as `triangle_tex` / `triangle_shade`.
* **Exception paint.** `boot.S` copies an 8-byte trampoline to the four VR4300
  exception vectors and `jal`s `exception_paint`, which fills FB0/FB1/FB2 with
  RGBA5551 `0xF801` and programs the VI. `assert` / `__pak_panic` take the same
  path. Goldens live in `tcl/tools/exception_test.tcl`.
* **Audio PCM.** `audio.init` programs the AI (NTSC DACRATE/BITRATE, DMA
  enable). Buffers sit at `0x80299000`; `get_buffer` returns `none` when
  `AI_STATUS.FULL` is set, and a fill-only loop kicks the previous buffer.
  Goldens live in `tcl/tools/audio_test.tcl`.
* **Array address.** `&arr` of a static or local array is the first-element
  address (`la` / `addiu $sp`). Indexing `[N]u8` emits `sb`/`lbu` at `base+i`.
  `as` binds looser than unary `&`, so `&buf as u32` is the label, not a stack
  slot. `&s.field` and `p.x =` on a value struct use the object's address
  (pointer receivers still load the pointer). Method `self` follows the same
  rule; `g.player.init()` is a method, not a module call. Goldens live in
  `tcl/tools/array_addr_test.tcl`.
* **FPU encodings.** COP1 ops (`add.s`/`sub.s`/`mul.s`/`div.s`, the
  `mov`/`neg`/`abs`/`sqrt` unary group, `cvt.*`, the `c.<cond>.s` compare
  family, `bc1t`/`bc1f`, `mtc1`/`mfc1`) all have golden encodings in
  `tcl/tools/n64enc_test.tcl`.
