# Toolchain-Free ROM Path

Pak can turn a `.pk64` source into an N64 `.z64` ROM **without any external MIPS
toolchain** (`mips64-elf-gcc`, `mips64-elf-as`, `mips64-elf-ld`,
`mips64-elf-objcopy`, libdragon's `n64tool`). The compiler owns every step from
source to machine code.

## Pipeline

```
.pk64
  → Tcl MIPS codegen (tcl/mips_codegen.tcl)
      emits a structured RECORD stream alongside the assembly text
  → Tcl binary encoder (tcl/n64enc.tcl)
      records → machine-code words + relocations → .pakobj object file
  → Python flat linker (pak/tools/n64_link.py)
      .pakobj(s) → laid-out flat RDRAM image, relocations patched
  → ROM packer (pak/tools/rompack.py)
      flat image → .z64 (IPL3 stub + header + CIC-6102 CRC)
```

No GCC, no `as`, no `ld`, no `objcopy`, no `n64tool`.

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
tclsh tcl/cli.tcl objgen game.pk64 -o game.pakobj

# object(s) → .z64
python -m pak.tools.n64_link game.pakobj runtime.pakobj -o game.z64 --name GAME

# or dump just the flat binary image
python -m pak.tools.n64_link game.pakobj -o game.bin --emit-bin game.bin
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

## Memory layout (matches `pak/runtime/n64.ld`)

* Base `0x80000400` (after the IPL3 stack reservation).
* Section order: `.text` → align16 `.rodata` → align8 `.data` → align8 `.bss`.
* `.bss` reserves address space but is not stored in the ROM image (boot.S
  zero-fills it at startup). `R_MIPS_HI16`/`LO16` use the standard `+0x8000`
  carry correction.

## Current limitations

* **Runtime objects.** A real game references runtime symbols
  (`display_init`, `joypad_poll`, `rdpq_fill_rectangle`, `memcpy`, …) provided by
  `pak/runtime/` (`boot.S`, `vi.c`, `si.c`, `pak_hal.c`). Those are still C/asm.
  Until they ship as pre-encoded `.pakobj`s (a one-time step) or are ported to
  Pak, linking a full game still needs those object inputs. Self-contained
  programs (pure compute, no I/O) link end-to-end with no runtime today — see
  `tests/test_n64_link.py::test_end_to_end_pk64_to_z64`.
* **Optimization.** The peephole/scheduler/delay-slot passes in
  `tcl/optimize.tcl` operate on assembly *text*, not records. The encoded binary
  is therefore correct but **not** delay-slot-optimized (the codegen emits
  explicit `nop`s in delay slots, which are valid under `.set noreorder`).
  Porting the optimizer to operate on records is a follow-up.
* **FPU encodings.** COP1 ops (`add.s`, `cvt.*`, `mtc1`/`mfc1`) are encoded
  best-effort and not yet golden-verified.
