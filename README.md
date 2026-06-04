# Pak

**A modern systems language for Nintendo 64 homebrew.**

Pak (`.pk64`) is a small, statically-typed language that compiles to clean C,
links against [libdragon](https://libdragon.dev) to produce real `.z64` ROMs —
or goes fully standalone: the compiler contains its own MIPS code generator,
self-contained assembler, and ROM packer, so a `.z64` can be produced without
any external toolchain at all. It gives you Rust-flavored ergonomics (pattern
matching, variants, traits, generics, `defer`, `Result`) while staying close
enough to the hardware that the N64's DMA, cache, fixed-point, and EEPROM
quirks are first-class, compiler-checked concerns.

```pak
use n64.display
use n64.controller
use n64.rdpq

entry {
    display.init(0, 0, 2, 0, 0)
    controller.init()
    rdpq.init()

    let mut x: i32 = 160

    loop {
        controller.poll()
        let input = controller.read(0)
        if input.held.right { x += 2 }
        if input.held.left  { x -= 2 }

        let fb = display.get()
        rdpq.attach_clear(fb)
        rdpq.set_mode_fill(0xFF0000FF)
        rdpq.fill_rectangle(x, 120, x + 16, 136)
        rdpq.detach_show()
    }
}
```

---

## Why Pak?

Writing N64 homebrew in C means manually juggling cache coherency, DMA
alignment, exhaustive state handling, and fixed-point math — with the compiler
offering no help. Pak keeps the metal exposed but moves the footguns into the
type system:

- **DMA safety is checked.** A DMA from an unaligned buffer is `E202` at compile
  time; a DMA without a preceding `cache.writeback` is `E201`. The canonical
  `writeback → read → wait → invalidate` sequence is enforced, not hoped for.
- **`match` is exhaustive.** Miss a variant case and you get `E301`, not a
  silent fallthrough bug three weeks into a project.
- **Fixed-point is a real type.** `fix16.16` arithmetic, trig, and sqrt are
  built in — no accidental float drift on a CPU where floats are slow.
- **Moves are tracked.** Use-after-move is `E401`.
- **It reads like a real language.** Variants, traits with default methods,
  monomorphized generics, closures, `defer`, `Result`, named arguments, default
  parameters, multi-file modules, match guards.

Everything you write maps to predictable C or MIPS assembly. Run
`pak explain file.pk64` to see exactly what the hardware will execute.

---

## Quick Start

### Install

```bash
git clone https://github.com/kodevadam/Pak.git
cd Pak
pip install -e ".[dev]"
pak --version          # pak 0.1.0
```

The CLI entry point is Python (≥ 3.11), but all compilation subcommands delegate
to the **Tcl backend** (`tclsh tcl/cli.tcl`). Only `pak convert` (the C→Pak
transpiler) stays in Python because it depends on pycparser. You will need both
Python and `tclsh` installed.

### Your first ROM

```bash
pak init my_game
cd my_game
pak check src/main.pk64              # type-check only
pak explain src/main.pk64            # show the generated C
pak explain --backend mips src/main.pk64   # show the generated MIPS
pak build src/main.pk64              # compile + pack assets + generate Makefile
pak run src/main.pk64                # build, then launch in the ares emulator
```

`pak build` emits C and a libdragon Makefile. To go all the way to a `.z64`
you need a libdragon toolchain (Path A below) **or** nothing at all (Path B).

---

## From source to ROM

```
              ┌────────────────────┐
  .pk64  ───▶ │   Pak compiler     │
              └────────────────────┘
                   │           │
          C backend│           │MIPS backend
                   ▼           ▼
              clean C      MIPS assembly
                   │           │
    Path A         │           │ Path B
    + libdragon    │           │ in-compiler:
    + make ──▶.z64 │           │  n64enc.tcl  ──▶ object
                              │  n64rom.tcl  ──▶ .z64
```

**Path A — libdragon (full-featured).**
The generated C uses the libdragon API (`display_*`, `rdpq_*`, `joypad_*`, …).
`pak build` writes a libdragon-compatible Makefile; `make` produces the ROM.
This is the path for serious games — full RDP/RSP, audio mixer, filesystem.

```bash
# Path A
export N64_INST=/opt/libdragon
pak build && make
```

**Path B — fully standalone (no external toolchain).**
The Tcl backend contains a complete MIPS pipeline with no external dependencies:

- **`tcl/mips_codegen.tcl`** — AST → VR4300 MIPS-III assembly (o32 ABI, with
  linear-scan register allocation and delay-slot scheduling)
- **`tcl/optimize.tcl`** — peephole + basic-block optimizer over the assembly
- **`tcl/n64enc.tcl`** — self-contained MIPS encoder; turns the assembly stream
  into a relocatable binary object without calling any assembler binary
- **`tcl/n64rom.tcl`** — builds a bootable `.z64` (ROM header, IPL3 embedding,
  CRC1/CRC2) entirely in Tcl via `binary format`

The result: `pak objgen src/main.pk64` produces a `.pakobj` relocatable object
straight from source. No `mips-n64-gcc`, no `binutils`, no cross-compiler of
any kind.

```bash
# Path B — inspect the MIPS output
pak explain --backend mips src/main.pk64

# Path B — compile to a .pakobj (relocatable binary, no external tools)
pak objgen src/main.pk64 -o main.pakobj
```

> **Legacy standalone path:** `pak/tools/n64_build.sh` is the original C-based
> standalone route (`.pk64` → C → `mips-n64-gcc` → `mips-n64-objcopy` →
> `rompack.py` → `.z64`). It still works if you have `mips-n64-gcc` installed,
> but the in-compiler Tcl pipeline (Path B above) supersedes it.

---

## Language tour

```pak
-- Variants (tagged unions) with payloads + exhaustive match
variant Shape {
    circle(f32)
    rect(f32, f32)
    point
}

fn area(s: Shape) -> f32 {
    match s {
        .circle(r)  => { return r * r * 3.14159 }
        .rect(w, h) => { return w * h }
        .point      => { return 0.0 }
    }
}

-- Match guards
fn classify(n: i32) -> i32 {
    match n {
        x if x < 0  => { return -1 }
        0           => { return 0 }
        _           => { return 1 }
    }
}

-- Traits with default methods + generics (monomorphized)
trait Drawable {
    fn draw(self: *Self)
    fn is_visible(self: *Self) -> bool { return true }   -- default
}

-- Result-based error handling, no exceptions
fn load(id: i32) -> Result(Texture, Error) {
    if id < 0 { return err(Error.bad_id) }
    return ok(make_texture(id))
}

-- Module aliasing
use n64.display as disp
-- disp.init(...) resolves to display_init(...)

-- RAII-style cleanup
entry {
    rdpq.init()
    defer { rdpq.close() }
    -- ...
}
```

Other supported features: fixed-point `fix16.16`, inline `asm`, `extern "C"`
FFI, `@aligned`/`@hot`/`@cfg` annotations, slices, tuples, closures with
environment capture, `const`/`static`, built-in generic containers (`Vec`,
`FixedList`, `RingBuffer`, `FixedMap`, `Pool`), and `asset` declarations that
bake PNGs/audio into the ROM.

See **[LANGUAGE.md](LANGUAGE.md)** for the complete, source-of-truth grammar —
every feature tagged `[IMPLEMENTED]`, `[PARTIAL]`, or `[PLANNED]`.

---

## CLI reference

| Command | Description |
|---------|-------------|
| `pak check <file>`   | Type-check without building |
| `pak build <file>`   | Compile `.pk64` → C / MIPS, pack assets, generate Makefile |
| `pak explain <file>` | Print the generated C for inspection |
| `pak explain --backend mips <file>` | Print the generated MIPS assembly |
| `pak objgen <file>`  | Compile `.pk64` → `.pakobj` relocatable binary (no external tools) |
| `pak run <file>`     | Build, then `make run` (launches in ares) |
| `pak init <name>`    | Scaffold a new project |
| `pak pack`           | Pack converted assets into a PakFS archive |
| `pak convert <src>`  | Transpile an existing C file/directory to Pak (`c2pak`) |
| `pak clean`          | Remove build artifacts |

---

## Repository layout

```
tcl/              Primary compiler implementation (Tcl): lexer, parser,
                  typechecker, C codegen, MIPS backend — this is what `pak` runs
  mips_codegen.tcl    AST → VR4300 MIPS-III assembly (o32, linear-scan regalloc)
  optimize.tcl        Peephole + basic-block optimizer
  n64enc.tcl          Self-contained MIPS encoder → relocatable binary object
  n64asm.tcl          Self-contained MIPS assembler (validates against binutils)
  n64rom.tcl          Bootable .z64 ROM builder (pure Tcl, no external tools)
  codegen.tcl         C code generator
  typechecker.tcl     Type checker + semantic analysis
  checker.tcl         Lint + error diagnostics
pak/              Reference compiler implementation (Python): same stages, kept
                  at byte-for-byte parity with the Tcl primary; also hosts the
                  c2pak transpiler (Python-only, needs pycparser)
pak/runtime/      Legacy bare-metal N64 runtime + libdragon shim (used by the
                  old n64_build.sh C-based standalone path)
pak/tools/        rompack.py + n64_build.sh (legacy standalone pipeline,
                  requires mips-n64-gcc; superseded by the in-Tcl pipeline)
examples/canonical/  29 gold-standard, known-correct reference programs
examples/         51 example programs total (games, std-lib middleware, baremetal)
tests/            728 unit + integration + snapshot tests
runtime/          Shared C runtime headers (containers, math, RNG, PakFS)
```

Pak ships **two independent compiler implementations** — a Tcl primary and a
Python reference — held in lockstep by parity harnesses in CI. Every lexer
token, parser AST, checker diagnostic, and chunk of generated C/MIPS is
cross-verified between the two on every push: 75/75 AST, 29/29 C, 29/29 MIPS.

---

## Documentation

| File | What's in it |
|------|--------------|
| **[LANGUAGE.md](LANGUAGE.md)**       | Canonical syntax reference (generated from the implementation) |
| **[GRAMMAR.ebnf](GRAMMAR.ebnf)**     | Formal EBNF grammar |
| **[STDLIB.md](STDLIB.md)**           | Every builtin + N64 API module signature |
| **[N64_HARDWARE.md](N64_HARDWARE.md)** | Hardware facts, register values, required call sequences |
| **[IDIOMS.md](IDIOMS.md)**           | Canonical patterns: game loop, DMA, audio, EEPROM, fixed-point |
| **[NOT_SUPPORTED.md](NOT_SUPPORTED.md)** | Hard list of what Pak deliberately does *not* have |
| **[CURRENTLY_SUPPORTED.md](CURRENTLY_SUPPORTED.md)** | Current implementation-status snapshot |
| **[examples/canonical/](examples/canonical/)** | 29 small, verified, single-concept programs |

---

## Development

```bash
pytest tests/                       # run the full suite (728 tests)
pak check examples/canonical/*.pk64 # all must pass
pak explain examples/canonical/01_hello.pk64
pak explain --backend mips examples/canonical/01_hello.pk64
# Parity gates (Tcl vs Python):
bash tcl/tools/ast_parity.sh        # 75/75 AST
bash tcl/tools/cg_parity.sh         # 29/29 C codegen
bash tcl/tools/mips_parity.sh       # 29/29 MIPS
```

CI (GitHub Actions) runs on every push: the Python test suite across 3.11/3.12,
canonical-example validation, "invalid programs must fail" checks, golden
`pak explain` snapshots, and the full Tcl-vs-Python parity gate.

---

## Status

Pak is **0.1.0** — actively developed and already capable of compiling real,
playable N64 programs. The language surface is largely stable; see the
`[IMPLEMENTED]` / `[PARTIAL]` / `[PLANNED]` tags throughout `LANGUAGE.md` for
the precise current boundary.

The compiler is entirely self-contained. The Tcl backend drives the full
pipeline end-to-end: lexer → parser → typechecker → C or MIPS codegen →
optimizer → binary encoder → ROM packer. No MIPS transpiler, no external
assembler, no cross-compiler required for the standalone path. All silent
fallbacks have been eliminated — unimplemented constructs raise explicit errors
(`MIPSUNPORTED`, `CGUNPORTED`) rather than producing wrong output. Key recent
additions: the in-compiler MIPS pipeline (`n64enc.tcl`, `n64rom.tcl`) replacing
the `mips-n64-gcc`-based build script; MIPS named-field variant construction;
complete compound-assign coverage (`/=`, `%=`, `<<=`, `>>=`). See
**[CURRENTLY_SUPPORTED.md](CURRENTLY_SUPPORTED.md)** for the full
implementation-status snapshot.

## License

MIT — see [LICENSE](LICENSE).
