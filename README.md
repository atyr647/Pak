# Pak

**A modern systems language for Nintendo 64 homebrew.**

Pak (`.pk64`) is a small, statically-typed language that compiles to clean C and
links against [libdragon](https://libdragon.dev) to produce real `.z64` ROMs —
or compiles fully standalone, with its own bare-metal N64 runtime, requiring
nothing but a MIPS cross-compiler. It gives you Rust-flavored ergonomics
(pattern matching, variants, traits, generics, `defer`, `Result`) while staying
close enough to the hardware that the N64's DMA, cache, fixed-point, and EEPROM
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

Everything you write maps to predictable C. Run `pak explain file.pk64` to see
exactly what the hardware will execute.

---

## Quick Start

### Install

```bash
git clone https://github.com/kodevadam/Pak.git
cd Pak
pip install -e ".[dev]"
pak --version          # pak 0.1.0
```

The CLI entry point is Python (≥ 3.11), but all compilation subcommands delegate to the
**Tcl backend** (`tclsh tcl/cli.tcl`). Only `pak convert` (the C→Pak transpiler) stays in
Python because it depends on pycparser. You will need both Python and `tclsh` installed.

### Your first ROM

```bash
pak init my_game
cd my_game
pak check src/main.pk64        # type-check only
pak explain src/main.pk64      # show the generated C
pak build src/main.pk64        # compile + pack assets + generate Makefile
pak run src/main.pk64          # build, then launch in the ares emulator
```

`pak build` emits C and a libdragon Makefile. To go all the way to a `.z64` you
need either a libdragon toolchain (the default path) **or** just a
`mips-n64-gcc` cross-compiler (the standalone path, below).

---

## Two ways to a ROM

```
              ┌──────────────┐
  .pk64  ───▶ │  Pak compiler │ ───▶  clean C
              └──────────────┘          │
                                        ├──▶ Path A:  + libdragon  ──▶ make ──▶ .z64
                                        │
                                        └──▶ Path B:  + pak/runtime ──▶ mips-n64-gcc ──▶ rompack ──▶ .z64
```

**Path A — libdragon (full-featured).**
The generated C uses the libdragon API (`display_*`, `rdpq_*`, `joypad_*`, …).
`pak build` writes a libdragon-compatible Makefile; `make` produces the ROM.
This is the path for serious games — full RDP/RSP, audio mixer, filesystem.

**Path B — standalone runtime (no libdragon).**
`pak/runtime/` ships a drop-in libdragon *shim* plus bare-metal drivers: a
boot/crt0 (`boot.S`), linker script (`n64.ld`), VI video init (`vi.c`), SI/PIF
controller DMA (`si.c`), a software framebuffer renderer, and a libdragon header
shim that shadows the real one via `-I pak/runtime/`. The generated C is
**unchanged** — you just compile it against the shim. `pak/tools/rompack.py`
then prepends a valid N64 header and CIC-NUS-6102 checksum to produce a bootable
`.z64`. The whole standalone pipeline is `pak/tools/n64_build.sh`, and its only
external dependency is a `mips-n64-gcc` cross-compiler.

```bash
# Path B, end to end:
pak/tools/n64_build.sh src/main.pk64 my_game.z64
```

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
| `pak explain <file>` | Print the generated C (or MIPS) for inspection |
| `pak run <file>`     | Build, then `make run` (launches in ares) |
| `pak init <name>`    | Scaffold a new project |
| `pak pack`           | Pack converted assets into a PakFS archive |
| `pak convert <src>`  | Transpile an existing C file/directory to Pak (`c2pak`) |
| `pak clean`          | Remove build artifacts |

---

## Repository layout

```
tcl/              Primary compiler implementation (Tcl): lexer, parser, typechecker,
                  C codegen, MIPS backend — this is what `pak` runs
pak/              Reference compiler implementation (Python): same stages, kept at
                  byte-for-byte parity with the Tcl primary; also hosts the c2pak
                  transpiler (Python-only, needs pycparser)
pak/runtime/      Standalone bare-metal N64 runtime + libdragon shim (Path B)
pak/tools/        rompack.py (.z64 packer) + n64_build.sh (standalone pipeline)
examples/canonical/  29 gold-standard, known-correct reference programs
examples/         51 example programs total (games, std-lib middleware, baremetal)
tests/            728 unit + integration + snapshot tests
runtime/          Shared C runtime headers (containers, math, RNG, PakFS)
```

Pak ships **two independent compiler implementations** — a Tcl primary and a
Python reference — held in lockstep by parity harnesses in CI. Every lexer token,
parser AST, checker diagnostic, and chunk of generated C/MIPS is cross-verified
between the two on every push: 75/75 AST, 29/29 C, 29/29 MIPS.

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
`[IMPLEMENTED]` / `[PARTIAL]` / `[PLANNED]` tags throughout `LANGUAGE.md` for the
precise current boundary.

The compiler has been through multiple hardening passes. All silent fallbacks
have been eliminated — unimplemented constructs raise explicit errors (`MIPSUNPORTED`,
`CGUNPORTED`) rather than producing wrong output. Key recent additions include:
MIPS named-field variant construction (`Type.case { field: val }`), complete
compound-assign coverage (`/=`, `%=`, `<<=`, `>>=`), and the Tcl backend as the
primary `pak` CLI runtime. See **[CURRENTLY_SUPPORTED.md](CURRENTLY_SUPPORTED.md)**
for the full implementation-status snapshot.

## License

MIT — see [LICENSE](LICENSE).
