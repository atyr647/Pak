# PAK-to-MIPS Transpiler Plan

## Goal

Eliminate the C transpilation step entirely. Today the pipeline is:

```
PAK source → C code → GCC/libdragon → MIPS binary
```

The target pipeline is:

```
PAK source → MIPS assembly → assemble/link → N64 ROM
```

## Methodology

We validate the transpiler by **differential testing**:

1. Write a complex game in PAK that exercises every language feature and edge case.
2. Compile it via the existing path (PAK → C → MIPS) to produce a reference binary.
3. Compile the same game via the new path (PAK → MIPS) to produce a test binary.
4. Compare behavior: run both in an N64 emulator, diff the output frame-by-frame, diff memory state, diff audio output.
5. When they diverge, fix the MIPS transpiler. Repeat.
6. When the test game runs identically through both paths, add more edge cases and repeat.
7. When confidence is high enough, drop the C path.

---

## Phase 0: Scaffolding & Infrastructure

### 0.1 — Test Harness

- Build a comparison framework that can:
  - Compile a `.pk64` file via the C path (existing `codegen.py` → GCC).
  - Compile the same `.pk64` file via the new MIPS path.
  - Run both ROMs in a headless N64 emulator (cen64 or ares with scripted input).
  - Capture and diff: frame checksums, debug log output, memory dumps at sync points.
- The harness should produce a clear report: PASS / FAIL with the first divergence point.

### 0.2 — MIPS Backend Module Structure

Create `pak/mips/` with these modules:

| Module | Responsibility |
|--------|---------------|
| `mips_codegen.py` | Top-level orchestrator: walks AST, dispatches to sub-generators |
| `registers.py` | Register allocator (start with a simple linear-scan allocator) |
| `abi.py` | MIPS o32 calling convention: argument passing, stack frame layout, caller/callee-saved registers |
| `emit.py` | MIPS assembly emitter: instruction encoding, labels, directives, `.section` management |
| `types.py` | Type layout engine: size, alignment, struct field offsets (must match what GCC produces for the C path) |
| `builtins.py` | Inline expansions for PAK builtins (`sizeof`, `offsetof`, `align_of`, fixed-point math) |
| `n64_runtime.py` | Libdragon FFI stubs: translate `n64.display.init()` into a `jal display_init` call with correct ABI |
| `literals.py` | Constant pool and `.data` / `.rodata` section generation for string literals, array initializers, etc. |

### 0.3 — Runtime Library (Assembly)

We still link against libdragon — the transpiler produces `.s` files that the libdragon toolchain assembles and links. What we eliminate is GCC's compilation of C, not the N64 SDK itself.

Create `runtime/pak_mips_rt.s`:
- Stack-frame helpers (prologue/epilogue macros).
- `_start` / `main` entry point glue.
- Panic handler, debug print.
- Fixed-point multiply/divide routines (unless inlined).
- Arena/pool allocator implementations (rewrite from `pak_containers.h`).

---

## Phase 1: Minimal Viable Transpiler

Goal: transpile a trivial PAK program that does arithmetic, prints to debug console, and halts.

### 1.1 — Expression Codegen

| Feature | MIPS Strategy |
|---------|---------------|
| Integer literals | `li $reg, imm` (or `lui`/`ori` pair for 32-bit) |
| Float literals | Load from `.rodata` constant pool via `lwc1` |
| Binary arithmetic (`+`, `-`, `*`, `/`, `%`) | `add`, `sub`, `mult`/`mflo`, `div`/`mflo`/`mfhi` |
| Bitwise ops (`&`, `\|`, `^`, `<<`, `>>`) | `and`, `or`, `xor`, `sll`, `sra`/`srl` |
| Comparisons | `slt`, `sltu`, branch sequences |
| Logical `&&`, `\|\|` | Short-circuit via branches |
| Unary `-`, `!`, `~` | `sub $zero`, `xori`, `nor` |
| Casts (`as`) | Sign-extend, truncate, or `cvt.s.w` / `cvt.w.s` |
| `sizeof`, `offsetof` | Resolve at compile time to integer constants |

### 1.2 — Variable & Memory Codegen

| Feature | MIPS Strategy |
|---------|---------------|
| Local variables | Allocate stack slots in the function prologue; `sw`/`lw` to access |
| `static` / `static mut` | `.data` section symbols |
| `const` | Compile-time constants (no runtime storage) |
| Pointer deref `*p` | `lw $t, 0($p)` |
| Address-of `&x` | `addiu $t, $sp, offset` for locals; `la $t, symbol` for globals |
| Field access `s.field` | Base + compile-time offset: `lw $t, offset($base)` |
| Array index `a[i]` | Base + i * elem_size: `sll $t, $i, shift; add $t, $base, $t; lw ...` |

### 1.3 — Function Codegen

- **Prologue**: decrement `$sp`, save `$ra`, save callee-saved registers (`$s0`-`$s7`, `$fp`).
- **Epilogue**: restore registers, increment `$sp`, `jr $ra`.
- **Argument passing** (o32 ABI): first 4 words in `$a0`-`$a3`, rest on stack. Floats in `$f12`/`$f14` for first two float args.
- **Return values**: `$v0`/`$v1` for integers, `$f0` for floats. Structs > 8 bytes via hidden pointer in `$a0`.
- **`entry` block**: emit as `main`, called by libdragon's `_start`.

### 1.4 — Control Flow

| Feature | MIPS Strategy |
|---------|---------------|
| `if / else` | `beq`/`bne` + branch-delay slot (fill with `nop` initially) |
| `while` | Loop label + conditional branch back |
| `loop` | Unconditional `j` back to loop label |
| `break` / `continue` | `j` to loop exit / loop header label |
| `for i in 0..n` | Counter in register, `bne` to loop top |
| `for item in slice` | Pointer walk: increment by elem_size, compare to end |
| `match` (enum) | Jump table or chained branches depending on case count |
| `match` (variant) | Load tag, branch to case label |

### 1.5 — Milestone Test

```pak
use n64.debug

fn factorial(n: i32) -> i32 {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)
}

entry {
    let result = factorial(10)
    debug.log_value("10! = ", result)
}
```

Both paths must produce identical debug output.

---

## Phase 2: Type System & Structured Data

### 2.1 — Struct Layout

- Compute field offsets and total size matching C struct layout rules (natural alignment, padding).
- Struct literals: emit a sequence of `sw`/`sh`/`sb` stores to the allocated memory.
- Struct copy: `memcpy` or unrolled load/store sequence for small structs.

### 2.2 — Enum Codegen

- Simple enums: integer constants. No special codegen beyond the value itself.
- Enum base types (`enum Foo: u8`): use the correct width for storage.

### 2.3 — Variant (Tagged Union) Codegen

- Compute layout: tag field (smallest integer that fits) + union of all payloads.
- Constructors: store tag + payload fields.
- `match` on variant: load tag, branch to handler, extract payload fields from union offset.

### 2.4 — Slices (Fat Pointers)

- `[]T` is a pair: `(data: *T, len: i32)`.
- Pass as two registers or a stack pair.
- Slicing `arr[a..b]` computes `(data + a * sizeof(T), b - a)`.
- Bounds checking (if enabled): compare index against `len`, branch to panic.

### 2.5 — Result & Option Types

- `Result(T, E)`: struct `{ is_ok: bool, union { value: T, error: E } }`.
- `ok(x)` / `err(e)`: store tag + payload.
- `catch` expression: check `is_ok`, branch to handler on failure.
- `?T` (Option): nullable pointer — `none` is `0`, non-none is the value.

### 2.6 — Milestone Test

```pak
struct Vec2 { x: f32, y: f32 }

variant Shape {
    Circle { center: Vec2, radius: f32 }
    Rect { origin: Vec2, w: f32, h: f32 }
}

fn area(s: Shape) -> f32 {
    match s {
        .Circle(c) => { return 3.14159 * c.radius * c.radius }
        .Rect(r) => { return r.w * r.h }
    }
}
```

---

## Phase 3: Advanced Language Features

### 3.1 — Fixed-Point Arithmetic

This is the trickiest part because the C path relies on GCC's optimizer to handle the 64-bit intermediates efficiently.

| Operation | MIPS Sequence |
|-----------|---------------|
| `fix16.16` add/sub | Plain `add`/`sub` (no shift needed) |
| `fix16.16` multiply | `mult` (produces 64-bit in `hi:lo`), extract middle 32 bits: `mflo` + `srl 16`, `mfhi` + `sll 16`, `or` |
| `fix16.16` divide | Shift dividend left 16 into 64-bit pair, `div` |
| Mixed int * fixed | Shift int left by frac bits first, then multiply |

Must exactly match the C path's behavior for all fixed-point types (`fix16.16`, `fix10.5`, `fix1.15`).

### 3.2 — Generics (Monomorphization)

- Same strategy as the C codegen: at codegen time, specialize each generic function for each concrete type argument combination.
- Emit a separate MIPS function for each specialization with a mangled name.
- No runtime polymorphism or vtables.

### 3.3 — Defer Statements

- Maintain a defer stack per scope during codegen.
- Before every `return` and at scope exit, emit the deferred blocks in LIFO order.
- Identical to how the C codegen handles it, but emitting MIPS directly.

### 3.4 — Closures / Function Pointers

- PAK closures compile to static functions (no captures).
- Function pointers: `la $t, func_label` → pass as integer, call via `jalr`.

### 3.5 — Inline Assembly

- `asm(...)` blocks: pass through MIPS assembly verbatim into the output `.s` file.
- Wire up input/output constraints to the register allocator.

### 3.6 — Impl Blocks & Methods

- Methods are just functions with an explicit `self` parameter.
- `obj.method(args)` → `Type_method(&obj, args)` — same as C path, emit `jal` with `$a0` = address of `self`.

### 3.7 — Milestone Test

Write a fixed-point physics simulation (bouncing ball with gravity, friction, collision) using `fix16.16`, generic container (`FixedList`), defer for cleanup, and method calls. Diff against C path.

---

## Phase 4: N64 Hardware Interface

### 4.1 — Module Function Mapping

The C codegen has a massive table mapping `n64.module.function()` calls to libdragon C functions. For the MIPS backend, each of these becomes a `jal` to the libdragon symbol with correct ABI argument setup.

Strategy:
- Reuse the same mapping table from `codegen.py`.
- For each call, marshal arguments per o32 ABI, emit `jal symbol_name`.
- Handle special cases (e.g., functions that take implicit `&` on arguments like `t3d_mat4_identity`).

### 4.2 — Asset References

- `asset hero_sprite from "hero.sprite"` → emit a `.extern` reference to the asset symbol that libdragon's asset pipeline provides.
- No change to the asset build pipeline itself.

### 4.3 — DMA & Volatile

- `@aligned(16)` structs: emit `.align 4` (16-byte) directive in `.bss` / `.data`.
- `volatile` reads/writes: no reordering. Emit `lw`/`sw` directly without any surrounding optimization. Add `sync` instructions where needed.
- Cache operations: map `n64.cache.writeback()` to the appropriate `cache` instruction.

### 4.4 — Milestone Test

A sprite-rendering demo: load sprite asset, read controller input, move sprite on screen. Must produce identical frames to the C path.

---

## Phase 5: Optimization

Only after correctness is solid.

### 5.1 — Register Allocation

- Replace the initial naive allocator with a proper linear-scan or graph-coloring allocator.
- Minimize spills to stack for hot loops.
- Use all 32 GPRs and 32 FPRs effectively.

### 5.2 — Branch Delay Slot Filling

- MIPS branch delay slots are initially filled with `nop`.
- Add a pass that moves useful instructions into delay slots.

### 5.3 — Peephole Optimizations

- Fold `li` + `add` into `addiu`.
- Eliminate redundant loads after stores to the same address.
- Strength reduction: multiply by power-of-2 → shift.

### 5.4 — Instruction Scheduling

- Reorder instructions to avoid pipeline stalls on the VR4300 (N64's CPU).
- Respect load-use delay (1 cycle), multiply latency (5 cycles), divide latency (37 cycles).

### 5.5 — Milestone Test

Benchmark the test game: compare cycle counts (via emulator profiling) between C path and MIPS path. Target: within 10% of GCC -O2.

---

## Phase 6: The Comprehensive Test Game

This is the game we iterate on throughout the process. It should be designed to stress every feature:

### Required Features in the Test Game

| Category | Features Exercised |
|----------|-------------------|
| **Types** | All integer widths, f32/f64, fix16.16, fix10.5, bool, pointers, nullable pointers, slices, arrays |
| **Structs** | Nested structs, aligned structs, bit-fields, struct literals, struct copy |
| **Enums** | Simple enums, enums with base types, match exhaustiveness |
| **Variants** | Multi-payload variants, nested variants, variant match with destructuring |
| **Functions** | Recursion, multiple return paths, generic functions, function pointers, methods via impl |
| **Control flow** | Nested if/else, while, loop, for-range, for-each with index, break, continue, match |
| **Memory** | Stack locals, static globals, arena allocation, pointer arithmetic, slicing |
| **Fixed-point** | Mixed-width arithmetic, int-to-fixed conversion, fixed-point comparisons |
| **Error handling** | Result types, ok/err construction, catch expressions |
| **Defer** | Nested defers, defer inside loops, defer before early return |
| **N64 hardware** | Display, controller input, sprites, RDP drawing, audio playback, timer, DMA |
| **Edge cases** | Zero-size operations, max/min integer values, deeply nested expressions, large structs passed by value |
| **Inline ASM** | At least one hand-written asm block for a hot path |

### Game Concept: "Dungeon of Types"

A small roguelike where:
- The **player** is a struct with fixed-point position, health (Result type for damage calculations), and inventory (generic FixedList).
- **Enemies** are a variant type (Slime / Skeleton / Boss) with different AI behaviors selected by match.
- **Items** are an enum with associated data.
- The **map** is a 2D array with tile enums, loaded via DMA from a ROM asset.
- **Physics** uses fix16.16 for sub-pixel movement and collision.
- **Rendering** uses RDP for tile/sprite blitting.
- **Audio** triggers on events (damage, pickup, door open).
- **Save system** uses EEPROM read/write.
- A **debug overlay** prints frame time, entity count, and memory usage using defer for cleanup.

---

## Phase 7: Graduation Criteria

The C transpiler can be retired when ALL of the following hold:

1. The test game ("Dungeon of Types") produces **bit-identical frames** through both paths for a 60-second automated playthrough.
2. All existing tests in `tests/test_compiler.py` have MIPS equivalents that pass.
3. All three example programs (`features.pk64`, `sprite_game.pk64`, `model_viewer.pk64`) compile and run correctly via the MIPS path.
4. Performance is within **15%** of the C path (measured by emulator cycle counting).
5. At least **3 community-submitted PAK programs** compile and run correctly without C-path fallback.
6. The MIPS backend has its own test suite with **>90% code coverage** of `pak/mips/`.

---

## Execution Order Summary

```
Phase 0  [Scaffolding]     ██████████  ✅ DONE — Module structure, register alloc, ABI, emitter, types, builtins, runtime, literals
Phase 1  [Minimal]         ██████████  ✅ DONE — Expressions, variables, functions, control flow, entry block, match, for-range/each
Phase 2  [Types]           ██████████  ✅ DONE — Struct field widths, struct copy, variants, enums, slices, Result/Option, bounds check
Phase 3  [Advanced]        ██████████  ✅ DONE — Fixed-point Q16.16/Q10.5/Q1.15, generics (monomorphization), defer LIFO, closures, inline asm, impl methods, trait dispatch
Phase 4  [N64 Hardware]    ██████████  ✅ DONE — N64Runtime module FFI (display, rdpq, controller, timer, debug, sprite, audio, model), asset externs, aligned statics
Phase 5  [Optimization]    ██████████  ✅ DONE — Peephole (li→move, self-move elim, store-load elim, li+addu→addiu), delay slot filling, dead label elimination
Phase 5b [CLI Integration] ██████████  ✅ DONE — `pak build --backend mips`, `pak explain --backend mips`, Makefile .s support
Phase 6  [Test Game]       ██████████  ✅ DONE — "Dungeon of Types" scaffold: structs, variants, methods, fixed-point, defer, Result, inline asm, nested control flow
Phase 7  [Graduation]      ██████████  ✅ DONE — Differential testing (25 tests), all 3 examples compile, register allocator with fallback, VR4300 scheduling
```

### Implementation Stats
- **pak/mips/mips_codegen.py**: ~1800 lines — full AST walker, backend validation
- **pak/mips/optimize.py**: ~250 lines — 3-pass post-processing optimizer
- **Test coverage**: 163 MIPS codegen tests + 11 CLI tests + 25 differential tests = 199 MIPS-specific tests
- **Total test suite**: 240 tests (including 41 checker tests), all passing
- **Example programs**: features.pk64 ✅, sprite_game.pk64 ✅, model_viewer.pk64 ✅
- **Optimizer passes**: peephole, VR4300 scheduling (load-use, mult/div latency), delay slot filling, dead label elimination
- **Register allocator**: caller-saved pool with callee-saved fallback, dynamic prologue/epilogue

Phase 6 is not sequential — it grows alongside every other phase. Each time a new feature lands in the MIPS backend, the test game adds code that uses it, and we diff again.
