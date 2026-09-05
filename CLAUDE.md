# Claude Code Instructions for Pak

This file is automatically read by Claude Code at session startup.
Follow these instructions when working in this repository.

---

## Automatic Validation (read this first)

**Every `.pk64` file you write or edit is automatically validated by the Pak
compiler via a PostToolUse hook.** You do not need to run it manually.

When a file fails validation, you will see output like:

```
============================================================
PAK VALIDATION FAILED: path/to/file.pk64
============================================================
error[E002]: 1:4: Expected identifier (got FN 'fn')
  --> path/to/file.pk64
  help: ...

Fix the errors above before proceeding.
Reference LANGUAGE.md and NOT_SUPPORTED.md.
============================================================
```

**When this happens:**
1. Read the error message carefully — it includes line, column, and error code.
2. Look up the correct construct in `LANGUAGE.md`.
3. Check `NOT_SUPPORTED.md` if the error suggests you used something that doesn't exist.
4. Fix the file. The hook will re-run automatically on the next write.
5. Repeat until the hook exits cleanly (no output).

**Do not move on until the file passes.** A `.pk64` file that does not pass
`pak check` is incorrect Pak code, regardless of how plausible it looks.

You can also run the validator manually at any time:
```
tools/validate_pak.sh file.pk64
pak check file.pk64
```

For deeper verification — especially when the logic seems right but something
feels off — use `pak explain` to see the generated C output:
```
pak explain file.pk64
```
If the C looks wrong (wrong struct layout, missing operations, bad control flow),
the Pak code has a semantic issue even if it passes `pak check`. Fix the Pak and
re-explain until the C matches your intent.

---

## Before Generating Any Pak Code

Read these files **in order** before writing or modifying `.pk64` files:

1. **`LANGUAGE.md`** — the canonical syntax reference. Every construct you write must appear here.
2. **`NOT_SUPPORTED.md`** — hard list of things Pak does not have. If something is on this list, do not use it.
3. **`STDLIB.md`** — all builtin functions and N64 API modules. Do not invent function signatures.
4. **`N64_HARDWARE.md`** — N64 hardware facts: correct arg values for `display.init`, required call sequences, DMA constraints, controller polling rules, EEPROM block size, audio buffer format, initialization order. **Read this before calling any N64 API.**
5. **`IDIOMS.md`** — canonical patterns for game loop, DMA, audio, EEPROM, fixed-point, etc.
6. **`examples/canonical/`** — 22 verified reference examples. Prefer patterns shown here.

If a language feature is not documented in `LANGUAGE.md` and not demonstrated
in `examples/canonical/`, do not use it. State uncertainty instead of guessing.

**Key behavioral rules from N64_HARDWARE.md (memorize these):**
- `display.init(0, 2, 3, 0, 1)` — 320×240, 16bpp, triple-buffer, no gamma, bilinear resample
- Call `controller.poll()` **every frame before** `controller.read()`
- DMA sequence: `cache.writeback` → `dma.read` → `dma.wait` → `cache.invalidate`
- DMA buffer **must** be `@aligned(16)` or E202 fires
- `rdpq.sync_pipe()` required between mode switches in the same frame
- `audio.get_buffer()` returns `none` if not ready — always check
- Always check `eeprom.present()` before any EEPROM operation
- Each EEPROM block = exactly 8 bytes

---

## Rules

- **Use only documented syntax.** No inventing keywords, operators, or constructs.
- **Use only documented APIs.** No inventing module names, function names, or signatures.
- **Prefer canonical examples** as templates for structure and style.
- **Mark implementation status.** `LANGUAGE.md` labels each feature `[IMPLEMENTED]`,
  `[PARTIAL]`, or `[PLANNED]`. Do not use `[PLANNED]` features in generated code.
- **Comments** use `--` (preferred) or `//`.
- **No semicolons** except where shown — Pak is mostly newline-delimited.
- **Entry point** is `entry { ... }`, not `main()` or `fn main`.
- **Logical operators** are `and`, `or`, `not` — never `&&`, `||`, `!`.
- **All casts are explicit** with `as` — no implicit numeric conversion.
- **Null is `none`** — the keyword `null` does not exist.

## When in Doubt

- Do not guess. Say "I'm not sure if Pak supports X — it's not in LANGUAGE.md."
- Do not use Rust, Zig, or C idioms unless they appear verbatim in Pak docs.
- If you need a feature that is `[PLANNED]`, say so and ask whether to implement a workaround.
- If the compiler rejects your code, trust the compiler over your intuition.

---

## Error Code Reference

When the compiler reports an error, use this table to understand it:

| Code | Meaning |
|------|---------|
| E001 | Lex error — invalid character or unterminated string |
| E002 | Parse error — syntax is wrong |
| E010 | Undefined variable or function |
| E102 | Wrong number of arguments |
| E103 | No `entry` block found (or more than one across the project) |
| E105 | `use path` has no matching `module path` declaration in the project |
| E201 | DMA used without `cache.writeback` first |
| E202 | DMA buffer not `@aligned(16)` |
| E301 | Non-exhaustive match — missing cases |
| E401 | Use-after-move |
| E601 | Method in `impl ... for Trait` is not declared in the trait |
| E602 | `impl ... for Trait` omits a required trait method (no default body) |
| E603 | Method signature mismatch — wrong number of parameters in trait impl |
| W001–W003 | Style warnings (naming conventions) |
| W004 | Function name collides with a libdragon symbol (rename it) |

---

## Quick Reference

```pak
-- comment syntax
use n64.display          -- import N64 module
asset bg: Sprite from "bg.png"  -- load asset

const MAX: i32 = 100

struct Foo { x: i32, y: f32 }

enum Dir { north, south, east, west }

variant Shape {
    circle(f32)
    rect(f32, f32)
}

fn add(a: i32, b: i32) -> i32 { return a + b }

impl Foo {
    fn new(self: *Foo) { self.x = 0 }
}

entry {
    let x: i32 = 42
    loop { ... }
}
```

See `LANGUAGE.md` for the full grammar.
