# Pak — What Is Currently Supported

This file answers the question: **"Does this feature actually work right now?"**

It is separate from `LANGUAGE.md` (which describes the designed language) and
`NOT_SUPPORTED.md` (which lists things that never exist). This file covers
**implementation reality**: what is fully working, what is partial, and what
exists only in plans.

Key: **✅ Full** | **⚠️ Partial** | **🔲 Planned** | **❌ Known bug**

---

## Lexer

| Feature | Status | Notes |
|---------|--------|-------|
| All keywords | ✅ Full | See `LANGUAGE.md` §3 |
| Integer literals (decimal, hex `0x`) | ✅ Full | |
| Float literals (`.`, `f` suffix) | ✅ Full | |
| String literals with escape sequences | ✅ Full | `\n \t \r \\ \" \0` |
| `--` and `//` line comments | ✅ Full | No block comments |
| `@annotation` and `@annotation(args)` | ✅ Full | |
| Fixed-point type names (`fix16.16`) | ✅ Full | Lexed as identifier |
| `_` wildcard token | ✅ Full | Keyword, not identifier |

---

## Parser — Top-Level Declarations

| Feature | Status | Notes |
|---------|--------|-------|
| `use module.path` | ✅ Full | |
| `use ... as alias` | ✅ Full | |
| `asset name: Type from "path"` | ✅ Full | |
| `module path.name` | ✅ Full | |
| `struct Name { field: Type }` | ✅ Full | |
| `struct Name<T> { ... }` (generic) | ✅ Full | Params parsed |
| `@aligned(N) struct` | ✅ Full | |
| `enum Name { case }` | ✅ Full | |
| `enum Name: BaseType { case = val }` | ✅ Full | |
| `variant Name { case(Type) }` | ✅ Full | Positional payloads |
| `variant Name { case { field: T } }` | ✅ Full | `Type.case { field: val }` construction now supported |
| `union Name { field: Type }` | ✅ Full | Untagged C union |
| `fn name(params) -> ret { }` | ✅ Full | |
| `fn name<T>(params)` (generic) | ✅ Full | Params parsed |
| `impl TypeName { fn method(...) }` | ✅ Full | |
| `impl TypeName for TraitName { }` | ✅ Full | |
| `trait Name { fn sig(...) }` | ✅ Full | |
| `entry { }` | ✅ Full | |
| `extern "C" { fn ... }` | ✅ Full | |
| `extern const NAME: T` | ✅ Full | |
| `const NAME: T = expr` | ✅ Full | |
| `static name: T = expr` | ✅ Full | |
| `let name: T = expr` (top-level) | ✅ Full | |
| `@cfg(FEATURE) decl` | ✅ Full | Wraps in CfgBlock |
| `@cfg(not(FEATURE)) decl` | ✅ Full | |

---

## Parser — Types

| Feature | Status | Notes |
|---------|--------|-------|
| Primitive types (`i32`, `f32`, `bool`, etc.) | ✅ Full | |
| Fixed-point types (`fix16.16`, `fix10.5`, `fix1.15`) | ✅ Full | |
| `*T` pointer | ✅ Full | |
| `*mut T` mutable pointer | ✅ Full | |
| `?*T` nullable pointer | ✅ Full | |
| `*volatile T` volatile pointer | ✅ Full | |
| `volatile T` volatile value | ✅ Full | |
| `[N]T` fixed array | ✅ Full | |
| `[]T` / `[]mut T` slice | ✅ Full | |
| `(T1, T2)` tuple type | ✅ Full | |
| `Result(Ok, Err)` | ✅ Full | |
| `Option(T)` | ✅ Full | |
| `fn(A, B) -> R` function pointer | ✅ Full | |
| `dyn TraitName` trait object | ✅ Full | |
| `Vec(T)` / `FixedList(T,N)` etc. | ✅ Full | Parsed as generics |
| `c_char` | ✅ Full | |

---

## Parser — Expressions

| Feature | Status | Notes |
|---------|--------|-------|
| Integer / float / bool / string literals | ✅ Full | |
| `none`, `undefined` | ✅ Full | |
| Identifiers | ✅ Full | |
| Struct literal `Type { field: val }` | ✅ Full | |
| Array literal `[a, b, c]` | ✅ Full | |
| Tuple literal `(a, b)` | ✅ Full | |
| Field access `obj.field` | ✅ Full | |
| Index access `arr[i]` | ✅ Full | |
| Function call `f(args)` | ✅ Full | |
| Method call `obj.method(args)` | ✅ Full | |
| Binary operators (arithmetic, bitwise, compare) | ✅ Full | |
| Logical `and`, `or`, `not` | ✅ Full | |
| Compound assignment `+=`, `-=`, etc. | ✅ Full | |
| Type cast `expr as Type` | ✅ Full | |
| Address-of `&expr`, `&mut expr` | ✅ Full | |
| Dereference `*expr` | ✅ Full | |
| `ok(val)`, `err(val)` constructors | ✅ Full | |
| `alloc(T)`, `alloc(T, n)`, `free(ptr)` | ✅ Full | |
| `sizeof(T)`, `offsetof(S, f)`, `alignof(T)` | ✅ Full | |
| Range `start..end` | ✅ Full | |
| Slice `arr[start..end]` | ✅ Full | |
| Closure `fn(x: T) -> R { body }` | ✅ Full | |
| Turbofish `foo::<T>(args)` | ✅ Full | |
| `asm("template" : out : in : clobbers)` | ✅ Full | |
| Named args `f(x: val)` | ✅ Full | |
| `catch` expression | ✅ Full | |
| Null-check expression `ptr?` | ✅ Full | |
| Tuple access `t.0` | ✅ Full | |
| Format string `"text {var}"` | ✅ Full | Lowers to `snprintf` into a static buffer |

---

## Parser — Statements

| Feature | Status | Notes |
|---------|--------|-------|
| `let name: T = expr` | ✅ Full | `_` is NOT a valid name |
| `static name: T = expr` | ✅ Full | |
| Assignment `target = expr` | ✅ Full | |
| Compound assign `target += expr` | ✅ Full | |
| `if cond { }` | ✅ Full | No parens on condition |
| `elif cond { }` | ✅ Full | |
| `else { }` | ✅ Full | |
| `loop { }` | ✅ Full | |
| `while cond { }` | ✅ Full | |
| `do { } while cond` | ✅ Full | |
| `for x in range { }` | ✅ Full | |
| `for i, x in collection { }` | ✅ Full | |
| `match expr { .case => { } }` | ✅ Full | |
| `match expr { .case(x) => { } }` | ✅ Full | Payload binding now works |
| `match expr { .ok(v) => { } }` | ✅ Full | Fixed — keyword case names now accepted |
| `break` / `continue` | ✅ Full | |
| `return expr` | ✅ Full | |
| `defer { }` | ✅ Full | |
| `goto label` / `label:` | ✅ Full | |
| `comptime if (cond) { }` | ✅ Full | |
| `asm { "line" }` | ✅ Full | |

---

## Type Checker

| Feature | Status | Notes |
|---------|--------|-------|
| Undefined variable detection (E010) | ✅ Full | |
| Struct field existence check | ✅ Full | |
| Function arity check (E102) | ✅ Full | |
| Exhaustive match check (E301) | ✅ Full | Covers enums + variants |
| Match payload binding scope | ✅ Full | Fixed — bindings now declared |
| Move-after-use detection (E401) | ✅ Full | |
| DMA without cache writeback (E201) | ✅ Full | ⚠️ False positives on constant args — use inline literals |
| Unaligned DMA buffer (E202) | ✅ Full | ⚠️ Same caveat as E201 |
| Trait method validation (E601) | ✅ Full | |
| Return path checking (W201) | ✅ Full | Warning, not error |
| Naming convention checks (W001–W003) | ✅ Full | Suppressible |
| Asset declaration scope | ✅ Full | Fixed — asset names registered in typechecker scope |
| Generic type instantiation | ⚠️ Partial | Type params tracked; generic function bodies not checked (can't resolve types without instantiation) |
| Trait implementation completeness | ✅ Full | Method existence (E601/E602) and parameter count (E603) checked |
| Result/Option type checking | ⚠️ Partial | Constructors accepted; match types partially resolved |

---

## C Code Generator

| Feature | Status | Notes |
|---------|--------|-------|
| Struct / enum / variant declarations | ✅ Full | |
| Function definitions | ✅ Full | |
| All expression types | ✅ Full | |
| Fixed-point arithmetic | ✅ Full | Uses C macros |
| `alloc` / `free` | ✅ Full | Maps to `malloc`/`free` |
| `defer` → cleanup code | ✅ Full | |
| N64 module API calls | ✅ Full | All modules in `n64_runtime.py` |
| `asset` declarations | ✅ Full | |
| `extern "C"` blocks | ✅ Full | |
| `@cfg` conditional compilation | ✅ Full | Maps to `#if`/`#endif` |
| `comptime if` | ✅ Full | Maps to `#if` |
| Inline `asm` | ✅ Full | |
| Generic functions | ✅ Full | Monomorphised at call sites; type inference for unspecified type params; all 29 canonical examples byte-identical to Python backend |
| Non-capturing closures | ✅ Full | Lowered to a top-level fn + function pointer |
| Closures capturing environment | ✅ Full | Emitted as a GCC nested function; captures by reference within the enclosing frame |
| Trait object dispatch (`dyn`) | ✅ Full | Vtable struct + fat pointer + thunks; constructor helpers emitted |
| `goto` / labels | ✅ Full | |
| Format strings | ✅ Full | `"x={n}"` → `snprintf` into static buffer |

---

## MIPS Code Generator

| Feature | Status | Notes |
|---------|--------|-------|
| Integer arithmetic | ✅ Full | |
| Fixed-point arithmetic | ✅ Full | `mult`/`div` sequences |
| Float arithmetic (`f32`) | ⚠️ Partial | Float values held in `$f12` accumulator; load/store correct; arithmetic ops use integer path (mul.s/add.s not used) |
| Struct field access | ✅ Full | |
| Array indexing | ✅ Full | Bounds checking available |
| Function calls (o32 ABI) | ✅ Full | |
| N64 API calls via `jal` | ✅ Full | All modules |
| Register allocation | ✅ Full | Linear-scan with stack spilling: 18 GPRs ($t0–$t9, $s0–$s7) + 8 pre-reserved spill slots per frame = 26 simultaneous live values. Named variables mapped to callee-saved $s regs. |
| Peephole optimization | ✅ Full | |
| Delay slot filling | ✅ Full | |
| `defer` | ✅ Full | |
| `match` on enums | ✅ Full | |
| Named-field variant construction (`Type.case { f: v }`) | ✅ Full | Stack-allocated with tag + payload stores |
| Compound-assign `/=`, `%=`, `<<=`, `>>=` | ✅ Full | `/=` → `div`/`mflo`; `%=` → `div`/`mfhi`; shifts → `sllv`/`srav` |
| Generics / traits | ⚠️ Partial | Same as C backend |

---

## Known Bugs (current, not by design)

| Bug | Workaround |
|-----|------------|
| (fixed) `let _ = expr` — expression evaluated, result discarded | — |
| (fixed) Capturing closures — now emitted as GCC nested functions | — |
| (fixed) Named-field variant construction (`Event.move { x: 1 }`) | — |

## Recently Fixed Bugs

| Bug | Fix |
|-----|-----|
| `pak check` crashes with `key "filename" not known` on files with `@cfg` annotations | Fixed — Tcl `Checker.err`/`warn` now include `filename` in diagnostic dicts; `diag_str` also hardened against missing key |
| MIPS `GPR temporary pool exhausted` on deeply-nested binary expressions (e.g. 8+ chained `\|`) | Fixed — `emit_binop` now allocates the RHS temp *after* evaluating the LHS, reducing peak register pressure from O(depth×2) to O(depth+2) |
| Asset names not in typechecker scope (E010) | Fixed — `AssetDecl` now registered in `_check_top` |
| DMA checker fires on address/size argument names (false-positive E201/E202) | Fixed — checker now only inspects `args[0]` (the buffer); also `&buf[0]` form now detected |
| `.ok(v)` / `.err(e)` match patterns fail to parse (E002) | Fixed — `parse_pattern()` uses `expect_name()` to accept keyword names after `.` |
| Variant payload bindings not in scope (E010) | Fixed — `_check_match()` declares binding variables from `.Case(x, y)` arms |
| Writing through an alloc'd pointer (`*p = 42`) then `free(p)` reported E010 | Fixed — parser newline handling no longer treats the deref-write as a move |
| Format string uses `%ld`/`%lu` for `i32`/`u32` (wrong on LP64 hosts) | Fixed — `int32_t`→`%d`, `uint32_t`→`%u`; fallback changed from `%ld` to `%d` |
| `DotAccess` on a non-Ident pointer expression generates `.` instead of `->` | Fixed — `_expr_type` consulted for chained access; pointer results use `->` |
| MIPS `swc1`/`lwc1` used GPR operand (invalid assembly for float store/load) | Fixed — float typed-load/store always targets `$f12`; `FloatLit` drops spurious `move $dst $zero` |
| MIPS `break`/`continue` skipped `defer` blocks declared inside the loop | Fixed — `emit_defers_from` emits inner-loop defers on break/continue; loop depth tracked in `loop_defer_depth` |
| MIPS spill area (offsets 16–47) conflicted with O32 outgoing arg area | Fixed — spill base moved to offset 64; stack args (slots 5+) still go to 16–47, no overlap for ≤12 extra args |
| `?*mut T` and `?*volatile T` failed to parse | Fixed — `parse_type` handles `mut`/`volatile` after `?*` |
| Tcl parser missing match arm guard support (`pattern if cond =>`) | Fixed — `parse_match_arm` now checks for `IF` token before `FAT_ARROW` |
| `if expr -> binding { }` null-check evaluated `expr` twice when side-effecting | Fixed — `gen_null_check` emits an outer block with `__auto_type binding = (expr)` then checks binding |
| Tcl parser `start..end` range — end expression used stale `end` variable | Fixed — `parse_range_end` now correctly reads the end expression from tokens |
| MIPS `DotAccess` match pattern fell through to wrong emit path | Fixed — `emit_match` arm dispatch now handles `DotAccess` pattern before the wildcard branch |
| MIPS `emit_stmt`/`emit_expr` had silent `default {}` / `move $dst $zero` fallbacks | Fixed — both now raise `mips_unported` for any unrecognised node kind, surfacing bugs instead of silently emitting wrong code |
| MIPS `emit_binop` had a silent no-op default for unhandled operators | Fixed — now raises `mips_unported` |
| Tcl C codegen `gen_match` Ident binding pattern emitted invalid C `case /* name */:` | Fixed — now raises `cg_unported`; only the wildcard (`_`) is accepted as a default arm |
| MIPS named-field variant construction (`Type.case { field: val }`) silently emitted `$zero` | Fixed — `emit_expr` now handles `VariantLit`: stack-allocates a properly-aligned struct, stores the discriminant tag, then stores each named payload field at the correct offset |
| MIPS compound-assign `/=`, `%=`, `<<=`, `>>=` were silently discarded | Fixed — `/=` uses `div`/`mflo`, `%=` uses `div`/`mfhi`, `<<=` uses `sllv`, `>>=` uses `srav`; unrecognised operators now raise `mips_unported` |

---

## What Runs on Real Hardware

The C backend generates libdragon-compatible C. Projects produced by `pak build`
have been tested with the libdragon toolchain and produce `.z64` ROMs that run on
emulators (ares, cen64) and N64 flashcarts.

The MIPS backend generates MIPS I assembly compatible with the N64's R4300i CPU.
