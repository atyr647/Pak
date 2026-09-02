# Toolchain-Free ROM Path

Pak can turn a `.pk64` source into an N64 `.z64` ROM **without any external MIPS
toolchain** (`mips64-elf-gcc`, `mips64-elf-as`, `mips64-elf-ld`,
`mips64-elf-objcopy`, libdragon's `n64tool`). The compiler owns every step from
source to machine code.

## Pipeline

```
.pk64  (game + runtime/runtime.pk64)      boot.S (hand-written crt0)
  → Tcl MIPS codegen (tcl/mips_codegen.tcl)     → Tcl asm front-end
      structured RECORD stream                       (tcl/n64enc.tcl parse_asm)
  → Tcl binary encoder (tcl/n64enc.tcl) ───────────────┘
      records → machine-code words + relocations → .pakobj object file
  → Tcl flat linker (tcl/n64link.tcl)
      .pakobj(s) → laid-out flat RDRAM image, relocations patched
  → Tcl ROM packer (tcl/n64rom.tcl)
      flat image → .z64 (IPL3 stub + header + CIC-6102 CRC)
```

No GCC, no `as`, no `ld`, no `objcopy`, no `n64tool`.

## The runtime is Pak + a tiny hand-written crt0

* **`runtime/runtime.pk64`** — the HAL (display, framebuffers, software
  `rdpq` fill, `memset`/`memcpy`) written entirely in Pak. Free functions emit
  bare symbol names (`display_init`, `rdpq_fill_rectangle`, …) matching the
  calls the codegen lowers game code into. MMIO is done with
  `(0xA4400000 as *volatile u32)` writes; framebuffers live in uncached KSEG1
  RDRAM so CPU writes are immediately visible to the Video Interface.
* **`runtime/boot.S`** — the crt0 (~12 instructions). It needs CP0 access
  (`mfc0`/`mtc0`) which Pak cannot express, so it stays hand-written assembly
  and is assembled by the encoder's `.s` front-end (`pak asmobj`). The linker
  supplies `__bss_start`/`__bss_end` so boot can zero `.bss`, and boot's
  `jal main` is resolved to the game's `entry` block across objects.

A full ROM is three objects linked in order — **boot first** so `_start` lands
at `0x80000400`:

```sh
pak asmobj runtime/boot.S        -o boot.pakobj      # crt0
pak objgen runtime/runtime.pk64  -o runtime.pakobj   # HAL
pak objgen game.pk64             -o game.pakobj      # the game
pak link boot.pakobj runtime.pakobj game.pakobj -o game.z64 --name GAME
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

The text output (`pak explain --backend mips`, snapshots) is byte-for-byte
unchanged; records are purely additive. The encoder consumes records, so there
is a single source of truth and no fragile operand-string parsing.

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

## Memory layout (matches `runtime/n64.ld`)

* Base `0x80000400` (after the IPL3 stack reservation).
* Section order: `.text` → align16 `.rodata` → align8 `.data` → align8 `.bss`.
* `.bss` reserves address space but is not stored in the ROM image (boot.S
  zero-fills it at startup). `R_MIPS_HI16`/`LO16` use the standard `+0x8000`
  carry correction.

## Current limitations

* **Optimization.** The peephole/scheduler/delay-slot passes in
  `tcl/optimize.tcl` operate on assembly *text*, not records. The encoded binary
  is therefore correct but **not** delay-slot-optimized (the codegen emits
  explicit `nop`s in delay slots, which are valid under `.set noreorder`).
  Porting the optimizer to operate on records is a follow-up.
* **FPU encodings.** COP1 ops (`add.s`/`sub.s`/`mul.s`/`div.s`, the
  `mov`/`neg`/`abs`/`sqrt` unary group, `cvt.*`, the `c.<cond>.s` compare
  family, `bc1t`/`bc1f`, `mtc1`/`mfc1`) all have golden encodings in
  `tcl/tools/n64enc_test.tcl`.
