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
export PATH="$PWD/bin:$PATH"
pak --version          # pak 0.1.0
```

There is no build step. The compiler is written in Tcl, and `bin/pak` is a
thin wrapper that hands your arguments to `tcl/cli.tcl`. The only requirement
is **tclsh 8.6+ with tcllib**:

```bash
sudo apt-get install tcl tcllib     # Debian / Ubuntu
brew install tcl-tk                 # macOS
```

To make `pak` permanent, add `bin/` to your shell profile's `PATH`, or symlink
it: `ln -s "$PWD/bin/pak" /usr/local/bin/pak`.

### Your first ROM

```bash
pak init my_game
cd my_game
pak check src/main.pk64              # type-check only
pak explain src/main.pk64            # show the generated C
pak explain --backend mips src/main.pk64   # show the generated MIPS
pak dlist src/main.pk64              # show the RDP commands the scene builds
pak build src/main.pk64              # compile + pack assets + generate Makefile
pak run src/main.pk64                # build, then launch in the ares emulator
```

`pak build` emits C and a libdragon Makefile. To go all the way to a `.z64`
you need a libdragon toolchain (the **libdragon path** below) **or** nothing at
all (the **standalone path**).

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
  libdragon path   │           │ standalone path
    + libdragon    │           │ in-compiler:
    + make ──▶.z64 │           │  n64enc.tcl  ──▶ object
                               │  n64link.tcl ──▶ image
                               │  n64rom.tcl  ──▶ .z64
```

**The libdragon path (full-featured).**
The generated C uses the libdragon API (`display_*`, `rdpq_*`, `joypad_*`, …).
`pak build` writes a libdragon-compatible Makefile; `make` produces the ROM.
This is the path for serious games — full RDP/RSP, audio mixer, filesystem.

```bash
# libdragon path
export N64_INST=/opt/libdragon
pak build && make
```

**The standalone path (no external toolchain).**
The Tcl backend contains a complete MIPS pipeline with no external dependencies:

- **`tcl/mips_codegen.tcl`** — AST → VR4300 MIPS-III assembly (o32 ABI, with
  linear-scan register allocation and delay-slot scheduling)
- **`tcl/optimize.tcl`** — peephole + basic-block optimizer over instruction records
- **`tcl/n64enc.tcl`** — self-contained MIPS encoder; turns the assembly stream
  into a relocatable binary object without calling any assembler binary
- **`tcl/n64link.tcl`** — flat linker: merges `.pakobj` files into an RDRAM
  image laid out like `runtime/standalone/n64.ld` and patches the relocations
- **`tcl/n64rom.tcl`** — builds a bootable `.z64` (ROM header, IPL3 embedding,
  CIC-NUS-6102 CRC1/CRC2) entirely in Tcl via `binary format`

The result is a `.z64` straight from source. No `mips-n64-gcc`, no `binutils`,
no cross-compiler of any kind.

```bash
# Inspect the MIPS output
pak explain --backend mips src/main.pk64

# Compile each part to a relocatable object, then link a bootable ROM.
# The boot object goes first so _start lands at the base address.
pak asmobj runtime/standalone/boot.S       -o boot.pakobj
pak objgen runtime/standalone/runtime.pk64 -o runtime.pakobj
pak objgen src/main.pk64                   -o main.pakobj
pak link boot.pakobj runtime.pakobj main.pakobj -o game.z64 --name "MY GAME"
```

See **[docs/toolchain-free-rom.md](docs/toolchain-free-rom.md)** for the object
format, the memory layout, and what the runtime does.

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
| `pak dlist <file>`   | Run the scene against the standalone HAL and disassemble the RDP display list it builds |
| `pak objgen <file>`  | Compile `.pk64` → `.pakobj` relocatable binary (no external tools) |
| `pak run <file>`     | Build, then `make run` (launches in ares) |
| `pak init <name>`    | Scaffold a new project |
| `pak pack`           | Pack converted assets into a PakFS archive (for `pak link --fs`) |
| `pak convert <src>`  | Transpile an existing C file/directory to Pak (`c2pak`) |
| `pak clean`          | Remove build artifacts |

---

## Repository layout

```
tcl/              Primary compiler implementation (Tcl): lexer, parser,
                  typechecker, C codegen, MIPS backend — this is what `pak` runs
  mips_codegen.tcl    AST → VR4300 MIPS-III assembly (o32, linear-scan regalloc)
  optimize.tcl        Peephole + basic-block optimizer (instruction records)
  n64enc.tcl          Self-contained MIPS encoder → relocatable binary object
  n64asm.tcl          Self-contained MIPS assembler (validates against binutils)
  n64rom.tcl          Bootable .z64 ROM builder (pure Tcl, no external tools)
  codegen.tcl         C code generator
  typechecker.tcl     Type checker + semantic analysis
  checker.tcl         Lint + error diagnostics
  n64link.tcl         Flat linker: .pakobj files → RDRAM image, relocs patched
  c2pak.tcl           C → Pak transpiler (pak convert)
bin/pak           The CLI entry point: a shell wrapper around tcl/cli.tcl
runtime/          C runtime for the libdragon backend (containers, math, RNG)
runtime/standalone/  Toolchain-free runtime: the HAL in Pak + a hand-written crt0
examples/canonical/  32 gold-standard, known-correct reference programs
examples/         51 example programs total (games, std-lib middleware, baremetal)
tests/corpus/     source corpus the golden suite compiles
tests/golden/     Pinned output of every compiler stage across that corpus
tests/snapshots/  Human-readable generated C and MIPS per canonical example
```

The compiler is a single implementation in Tcl, with no build step and no
dependency beyond `tclsh` and `tcllib`. It is held in place by the **golden
suite**: `tests/golden/` pins the output of every stage — tokens, AST,
generated C, MIPS assembly, checker and typechecker diagnostics, module
headers, transpiler output, Makefile and PakFS layout — across every corpus
file. Any change in compiler behaviour surfaces there.

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
bash tools/audit.sh                       # everything, with a verdict
bash tools/audit.sh --fast                # skip the slow golden stages

tclsh tcl/tools/golden_test.tcl           # every stage over the whole corpus
tclsh tcl/tools/golden_test.tcl check tc  # just the diagnostics
VERBOSE=1 tclsh tcl/tools/golden_test.tcl # print the diff on a mismatch
REGEN=1 tclsh tcl/tools/golden_test.tcl   # re-bless the goldens (read them first)

tclsh tcl/tools/n64enc_test.tcl           # MIPS instruction encodings
tclsh tcl/tools/n64link_test.tcl          # linker + ROM packer
tclsh tcl/tools/libdragon_api_test.tcl    # generated C vs libdragon's REAL headers
tclsh tcl/tools/libdragon_symbols.tcl     # STDLIB's libdragon column is the truth
tools/build_n64_toolchain.sh /opt/pak-n64 # mips64-elf gcc (~40 min, once)
N64_INST=/opt/pak-n64 tools/build_libdragon.sh
N64_INST=/opt/pak-n64 tclsh tcl/tools/libdragon_link_test.tcl   # real ROM
tclsh tcl/tools/dlist_test.tcl            # the RDP disassembler behind `pak dlist`
tclsh tcl/tools/pixel_test.tcl            # render on angrylion, compare pixels
bash  tcl/tools/lint.sh                   # nagelfar static lint

tclsh tcl/tools/fuzz_test.tcl             # mutated sources must never crash it
ITERATIONS=50000 SEED=7 tclsh tcl/tools/fuzz_test.tcl
tclsh tcl/tools/fuzz_test.tcl --file /tmp/pak-fuzz/crash-....pk64

pak check examples/canonical/*.pk64       # all must pass
pak explain examples/canonical/01_hello.pk64
pak explain --backend mips examples/canonical/01_hello.pk64
```

CI (GitHub Actions) runs on every push: the golden suite over the whole corpus,
canonical-example validation, "invalid programs must fail" checks, the
`pak explain` snapshots, a compile of that C against libdragon's real headers,
a front-end fuzz run, the binary back end (encoder,
linker, objgen for every canonical example, the RDP display-list disassembler,
a pixel-level render against the angrylion reference, and a full
source-to-`.z64` build), and nagelfar lint.

There are three libdragon gates, and each answers a question the one before
it structurally cannot.
`tcl/tools/c_compile_test.tcl` stubs libdragon, declaring every symbol as
`long sym();` — an unprototyped declaration that accepts any argument count and
any types — so a missing header, a renamed function, the wrong arity and the
wrong argument types all compile clean there and fail at a user's `make`.
`tcl/tools/libdragon_api_test.tcl` compiles the same C against real headers
pinned by `tools/fetch_libdragon.sh`, and keeps a shrinking debt list.

That still runs the *host* compiler, so it cannot see anything the target
decides — on `mips64-elf` a `long` is 32 bits, which is why `fn abs(x: i32)`
matched C's `abs(int)` on the host and conflicted when cross-compiled — and it
never links. `tcl/tools/libdragon_link_test.tcl` builds every example with the
real `mips64-elf-gcc` under libdragon's own `-Werror` flags, then takes
`pak init` → `pak build` → `make` all the way to a bootable `.z64` and checks
its header and IPL3. `tools/build_n64_toolchain.sh` builds the toolchain
(binutils 2.45, gcc 16.2.0, newlib 4.4.0 — libdragon's own pinned versions);
both gates skip cleanly when it is absent rather than failing CI over a
40-minute build.

The fuzzer mutates the corpus and demands the compiler answer with a
diagnostic, never a Tcl stack trace: the lexer may raise `LEXERROR`, the parser
`PARSEERROR`, codegen `CGUNPORTED`/`MIPSUNPORTED`; the checker and typechecker
must return diagnostics and never raise. It is seeded, so a failure reproduces
exactly, and it reports how far mutants got — a run where nothing reaches the
parser fails rather than passing quietly.

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
