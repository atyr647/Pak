# Pak — What Is Not Supported

This file is an explicit list of things Pak does **not** support.
It exists specifically to prevent AI models from hallucinating features.

**Rule:** If something is on this list, do not generate it. If it's not in
`LANGUAGE.md` either, also do not generate it.

---

## Language Constructs That Do Not Exist in Pak

### No `fn main()`
There is no `main` function. The entry point is the `entry { }` block.
```
-- WRONG:
fn main() { ... }

-- CORRECT:
entry { ... }
```

### No Semicolon-Terminated Statements
Pak is newline-delimited. Semicolons are not required and should not be added
to every line. (Semicolons are valid as separators between top-level decls
but are never required after statements.)
```
-- WRONG:
let x: i32 = 5;
return x;

-- CORRECT:
let x: i32 = 5
return x
```

### No `&&`, `||`, `!` Operators
Logical operators are words, not symbols.
```
-- WRONG:
if a && b { ... }
if !ready { ... }

-- CORRECT:
if a and b { ... }
if not ready { ... }
```

### No Implicit Type Conversions
All numeric conversions are explicit with `as`. There is no implicit promotion,
no implicit narrowing, and no implicit integer-to-bool coercion.
```
-- WRONG:
let f: f32 = some_i32    -- no implicit int→float
if count { ... }          -- no implicit int→bool

-- CORRECT:
let f: f32 = some_i32 as f32
if count != 0 { ... }
```

### No `null` Keyword
Use `none`. The keyword `null` does not exist.
```
-- WRONG:
let p: *Foo = null

-- CORRECT:
let p: ?*Foo = none
```

### No `void` Type
Functions with no return value simply omit the `->` return type.
```
-- WRONG:
fn foo() -> void { ... }

-- CORRECT:
fn foo() { ... }
```

### No If-Expressions
`if` is a statement, not an expression. You cannot assign the result of an
`if`/`else` to a variable. Declare the variable with a default and assign in
the branch instead (locals are mutable by default).
```
-- WRONG:
let color: u32 = if selected { RED } else { GRAY }

-- CORRECT:
let color: u32 = GRAY
if selected { color = RED }
```

### No `class` Keyword
Use `struct` with an `impl` block for methods.
```
-- WRONG:
class Player { ... }

-- CORRECT:
struct Player { ... }
impl Player { fn method(self: *Player) { ... } }
```

### No Exceptions
There is no `try`, `throw`, `catch` (as a keyword for exceptions), `raise`,
`except`, or `finally`. Error handling uses `Result(Ok, Err)`.
```
-- WRONG:
try { risky() } catch (e) { ... }
throw MyError()

-- CORRECT:
fn risky() -> Result(i32, MyError) { ... }
match risky() {
    .ok(v)  => { ... }
    .err(e) => { ... }
}
```

Note: `catch` IS a keyword in Pak but it works as a postfix expression on
`Result` values, not as an exception mechanism. See `LANGUAGE.md`.

### No Garbage Collector
Pak has no GC, no reference counting, and no automatic memory management.
All heap allocation uses `alloc(T)` / `free(ptr)` explicitly.
Do not generate code that assumes memory is automatically freed.

### No `new` / `delete`
```
-- WRONG:
let p = new Player()
delete p

-- CORRECT:
let p: *Player = alloc(Player)
free(p)
```

### No Rust-Style `?` Propagation Operator
```
-- WRONG:
let val = might_fail()?

-- CORRECT:
let result = might_fail()
let val = result catch |e| { return err(e) }
-- or:
match might_fail() {
    .ok(v)  => { ... }
    .err(e) => { return err(e) }
}
```

### No `if let` / `while let`
Pattern-binding in conditions does not exist.
```
-- WRONG:
if let Some(x) = maybe_value { ... }

-- CORRECT:
match maybe_value {
    .some(x) => { ... }
    .none    => {}
}
```

### No `#include`, `#define`, `#pragma`
Pak is not a C preprocessor. These directives don't exist.
C interop uses `extern "C" { ... }` blocks.

### No `typedef`
Use `struct`, `enum`, `variant`, or `const` instead.

### No Block Expressions Returning Values
Blocks (`{ ... }`) are statements, not expressions. You cannot do:
```
-- WRONG:
let x = { let a = 5; a + 1 }

-- CORRECT:
fn add_one(a: i32) -> i32 { return a + 1 }
let x = add_one(5)
```

### Closures Capture Environment — Supported (within the enclosing frame)
Lambda syntax works (`fn(x: i32) -> i32 { return x + 1 }`). A closure used inside
a function body **may capture** outer locals/params: it lowers to a GCC nested
function in the enclosing block and decays to a plain function pointer. Capture is
**by reference** and valid only while the enclosing call frame is alive (consistent
with Pak's manual-lifetime model) — do not store a capturing closure and call it
after its defining function returns. Top-level closures (in global/`static`
initializers) have no frame to capture and must be non-capturing.
```
-- WORKS (non-capturing):
let f: fn(i32) -> i32 = fn(x: i32) -> i32 { return x + 1 }

-- WORKS (captures `base` — emitted as a GCC nested function):
let base: i32 = 10
let g = fn(x: i32) -> i32 { return x + base }
```

### String Interpolation `{name}` IS Supported
A string literal containing `{name}` is a format string: the named locals are
interpolated via `snprintf` into a static buffer at codegen. Use it anywhere a
`*c_char` is expected. (There is no `$`-style or `f"..."` prefix syntax — just
`{name}` inside an ordinary string.)
```
-- WORKS:
let n: i32 = 42
debug.print("x={n}")      -- emits snprintf(..., "x=%ld", (long)(n))
```

### Trait Default Methods [Supported]
Traits **can** provide default method bodies; an `impl` may omit a method that
has a default. A method **without** a body is required — omitting it raises
`E602`. See LANGUAGE.md § Trait.

### No `::<>` Turbofish
```
-- WRONG:
foo::<i32>(arg)
-- RIGHT:
foo<i32>(arg)
```
Explicit type arguments use angle brackets directly before the call or struct
braces (`foo<i32>(arg)`, `Box<i32> { value: 1 }`). The Rust-style `::<>` form
is not recognized.

### No `impl Trait` Return Type
```
-- WRONG:
fn get_updatable() -> impl Updatable { ... }
```
Use explicit types or trait objects (`*dyn Trait`) instead.

### No Variadic Functions
Pak does not support variadic function definitions (e.g., `fn foo(args: ...)`).
The N64 `debug.log` module internally maps to `debugf` (variadic C function)
but this is handled by the runtime, not by Pak syntax.

### No Operator Overloading
You cannot define custom `+`, `*`, etc. for user types.

### Integer Pattern Matching — Supported but Limited
Integer literals are accepted as match arm patterns, but the match is not
exhaustiveness-checked (unlike enum/variant match). Use if/elif chains if you
want clarity; use match if the literal pattern reads better.
```
-- WORKS (but not exhaustiveness-checked):
match x {
    0 => { }
    1 => { }
    _ => { }  -- wildcard recommended to silence ambiguity
}

-- ALSO FINE for integer branching:
if x == 0 { }
elif x == 1 { }
```
Range patterns (`0..10 =>`) are not supported — see below.

### No Range Patterns in Match
```
-- WRONG:
match x {
    0..10 => { ... }
}
```

### No Struct Destructuring in `let`
```
-- WRONG:
let { x, y } = point

-- CORRECT:
let x = point.x
let y = point.y
```

### No Tuple Destructuring in `let`
```
-- WRONG:
let (a, b) = my_tuple

-- CORRECT:
let a = my_tuple.0
let b = my_tuple.1
```

---

## Standard Library / API Rules

### Do Not Invent Module Names
There are **37** valid module namespaces, all listed in `STDLIB.md`. The valid
N64 modules (after `use n64.X`) are:
`display`, `controller`, `joypad`, `rdpq`, `rdpq_mode`, `rdpq_tex`,
`rdpq_font`, `sprite`, `surface`, `timer`, `system`, `math`, `mem`, `dma`,
`cache`, `rsp`, `vi`, `audio`, `mixer`, `xm64`, `wav64`, `eeprom`, `sram`,
`flashram`, `backup`, `rumble`, `cpak`, `tpak`, `mouse`, `vru`, `rtc`, `disk`,
`debug`, `exception`.

The Pak runtime modules are `pak.str` and `pak.arena` (namespaces `str`, `arena`).

All Tiny3D submodules (`use t3d`, `use t3d.core`, `use t3d.model`,
`use t3d.math`, `use t3d.anim`, `use t3d.light`, `use t3d.viewport`,
`use t3d.skeleton`, `use t3d.fog`, `use t3d.state`, `use t3d.particles`) map
to the single `t3d` API namespace.

There IS an `n64.math` module — it provides `abs_*`, `min_*`, `max_*`,
`clamp_*`, `sin_f`/`cos_f`/`tan_f`/`sqrt_f`/`atan2_f`, `lerp_f`, fixed-point
conversions, and `rand*`. See `STDLIB.md`.

There is still no `n64.memory` (it is `n64.mem`), `n64.string` (use `pak.str`),
`n64.input`, `n64.graphics`, `n64.sound`, `n64.file`, or `n64.network`. If a
module is not in `STDLIB.md` / `MODULE_API`, it does not exist.

### Do Not Invent Function Signatures
If a function is not in `STDLIB.md`, it doesn't exist. Do not invent:
- `display.clear()` — use `rdpq.attach_clear()`
- `controller.button_pressed(btn)` — use the struct fields on the return of `controller.read()`
- `timer.sleep(ms)` — does not exist
- Any `string.*` module — does not exist (use `pak.str` + `Str`/`CStr` methods)
- Any `math.*` function beyond the list in `STDLIB.md`

### Container Methods Exist — Use Only the Documented Ones
Built-in containers DO have methods (e.g. `Vec(T)` has `.push()` / `.pop()` /
`.len()`; `FixedList`, `RingBuffer`, `FixedMap`, `Pool` have their own sets).
See `STDLIB.md` → "Built-in String / Slice / Container Methods". Do not invent
methods not listed there (e.g. there is no `.append()` or `.insert()`).

### String Types and Methods
Pak uses `*c_char` (`CStr`) for C-compatible strings and `Str` (a fat string)
for the runtime string type. Both have built-in methods (`.len()`, `.eq()`,
`.contains()`, `.slice()`, etc. — see `STDLIB.md`). There is still no string
concatenation with `+`, no `.to_string()`, and no `.length` property (it is
`.len()`).

### No Standard Print / IO
There is no `print()`, `println()`, `printf()`, `puts()`, `std.out.write()`.
For debug output, use `debug.log(msg)` via `use n64.debug`.

---

## Known Typechecker / Parser Limitations (Current Implementation)

These are not design choices — they are current implementation gaps.
Work around them as shown.

### `let _ = expr` — WORKS
`let _ = expr` is now supported. The expression is evaluated for side-effects
and the result is discarded. No variable is bound.
```
-- WORKS: evaluate and discard
let _ = some_fn_call()
```

### Variant Payload Binding in Match — WORKS
`.case(x) => { use x }` now type-checks: the bound names are declared in the
arm's scope. This pattern is fully supported.
```
-- WORKS:
match shape {
    .circle(r)  => { return r * r * 3.14 }
    .rect(w, h) => { return w * h }
}
```

### `.ok(val)` / `.err(e)` Match Patterns — WORK
The pattern parser now accepts keyword names after `.`, so matching on a
`Result` directly is supported (and the bound payload is in scope).
```
-- WORKS:
match result {
    .ok(v)  => { use(v) }
    .err(e) => { handle(e) }
}
```

### Named-Field Variant Arms — WORK
`.rect { w: ww, h: hh }` binds the named payload fields, and each binding
carries that field's type. The checker used to declare only POSITIONAL
bindings, so every use of `ww` was E010 even though both backends lower the
form correctly.
```
-- WORKS:
match shape {
    .circle(r)             => { sink = r }
    .rect { w: ww, h: hh } => { sink = ww * hh }
}
```

### Keyword Names as Variant Cases — WORK
`variant Foo { none, ok, err }` matches fine, with or without payloads: the
pattern parser accepts keyword names after `.`, and an arm's payload type
comes from the type being matched, so `.ok(v)` on a `Foo` and `.ok(v)` on a
`Result` in the same file each resolve to their own payload.
```
-- WORKS:
variant Foo { none(i32), ok(i32), err(i32) }
```

### Writing Through `alloc`'d Pointer Then `free` — FIXED
This previously failed: a deref-write was treated as a move, so a later
`free(ptr)` reported E010. The underlying parser/move-tracker bug is fixed and
the pattern now checks cleanly.
```
-- NOW OK:
let p: *mut i32 = alloc(i32)
*p = 42
free(p)
```

---

## Things That Look Plausible But Are Wrong

| What you might write       | Why it's wrong                         | What to write instead             |
|----------------------------|----------------------------------------|-----------------------------------|
| `fn main() { }`            | No main function                       | `entry { }`                       |
| `let x = 5;`               | No semicolons needed                   | `let x = 5`                       |
| `if (cond) { }`            | No parens on conditions                | `if cond { }`                     |
| `a && b`                   | No `&&` operator                       | `a and b`                         |
| `!flag`                    | No `!` unary                           | `not flag`                        |
| `ptr == null`              | No `null`                              | `ptr == none`                     |
| `-> void`                  | No void type                           | omit return type                  |
| `enum E { A, B, C }`       | Commas optional, not required          | `enum E { a\n b\n c }` (valid either way) |
| `match x { 0..10 => ... }` | No range patterns in match             | `if x >= 0 and x < 10 { ... }`    |
| `let { x, y } = p`         | No struct destructuring in `let`       | `let x = p.x` / `let y = p.y`     |
| `alloc<T>()`               | Wrong alloc syntax                     | `alloc(T)`                        |
| `Result<T, E>`             | Wrong Result syntax                    | `Result(T, E)`                    |
| `Option<T>`                | Wrong Option syntax                    | `Option(T)` or `?T`               |
| `size_of(T)`               | Removed alias                          | `sizeof(T)`                       |
| `align_of(T)`              | Removed alias                          | `alignof(T)`                      |
