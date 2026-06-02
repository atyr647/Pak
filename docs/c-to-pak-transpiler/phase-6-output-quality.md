# Phase 6: Output Quality & Polish

Goal: make the transpiler output clean, readable, and idiomatic — code a human would
be happy to maintain, not a mechanical dump.

## 6.1 — Pretty-Printer (`pak_emitter.py`)

The pretty-printer converts PAK AST nodes back into formatted `.pk64` source text.

### Formatting Rules

- **Indentation**: 4 spaces (matching existing PAK examples).
- **Braces**: opening brace on same line, closing brace on own line.
- **Commas**: trailing comma in struct literals, enum variants, function params (multi-line).
- **Blank lines**: one blank line between top-level declarations, no blank lines inside
  short function bodies (<5 lines), one blank line to separate logical sections in longer bodies.
- **Line width**: soft limit at 100 columns. Break long expressions at operators.
- **Imports**: `use` declarations grouped at top, sorted alphabetically.

### Expression Formatting

- Minimal parentheses: only emit parens where operator precedence requires them.
  PAK's precedence matches C's, so most parens can be dropped.
- Binary expressions: spaces around operators (`a + b`, not `a+b`).
- Chained method calls: one per line if the chain exceeds 3 calls.
- Struct literals: inline if <=3 fields, multi-line otherwise.

### Statement Formatting

- Single-expression `if` bodies: keep on one line if short (`if x > 0 { return x }`).
- `match` arms: align `=>` arrows, one arm per line.
- `for` / `while`: condition on same line as keyword.

## 6.2 — Comment Preservation

### Strategy

1. During C parsing, capture comments and associate them with the nearest AST node
   (preceding or trailing).
2. During PAK emission, re-emit comments at the corresponding location.

### Comment Types

| C Comment Style | PAK Comment Style |
|----------------|-------------------|
| `// single line` | `// single line` |
| `/* block */` | `// block` (convert to single-line) |
| `/* multi\nline */` | Multiple `//` lines |
| Doc comments (`/** ... */`) | `/// doc comment` |
| Offset comments (`/* 0x00C */`) | `// offset: 0x00C` (preserve for decomp) |

### Special Comments

- `// TODO:`, `// FIXME:`, `// HACK:` → preserve as-is.
- `// c2pak: ...` → transpiler-generated notes for human review.
- License headers → preserve at top of file.

## 6.3 — Naming Conventions

### Automatic Renaming

| C Convention | PAK Convention | Example |
|-------------|---------------|---------|
| `SCREAMING_SNAKE` (macros/constants) | `SCREAMING_SNAKE` | `MAX_ENTITIES` → `MAX_ENTITIES` |
| `snake_case` (functions/variables) | `snake_case` | `player_init` → `init` (in impl) |
| `CamelCase` (typedefs/structs) | `CamelCase` | `Vec2` → `Vec2` |
| `prefix_name` (namespaced funcs) | Strip prefix in impl | `player_init` → `Player.init` |
| `TYPE_VALUE` (enum values) | Strip prefix, snake_case | `DIR_UP` → `up` |

### Prefix Detection & Stripping

For enum values:
1. Find the longest common prefix shared by all enum values.
2. If the prefix matches the enum name (case-insensitive), strip it.
3. Convert remainder to snake_case.

Example: `PlayerState` enum with `PLAYER_STATE_IDLE`, `PLAYER_STATE_RUNNING` → strip
`PLAYER_STATE_` → `idle`, `running`.

For functions:
1. If a function name starts with `structname_` and takes `StructName *` as first param,
   strip the prefix and move into `impl StructName`.
2. Otherwise, keep the full name.

## 6.4 — Transpiler Annotations

When the transpiler is uncertain about a conversion, it emits annotations:

```pak
// c2pak: uncertain — original used raw pointer arithmetic, verify bounds
let item = data[offset as usize]

// c2pak: was goto-based cleanup, converted to defer — verify ordering
defer { free(buf) }

// c2pak: bit-field expanded — original was u32 flags:3
let flags: u32 = raw_flags & 0x7   // 3-bit field

// c2pak: possible tagged union — verify this is actually discriminated
variant MaybeEntity { ... }
```

These annotations help the human reviewer focus on the spots that need attention.

## 6.5 — Style Options

```
pak convert file.c --style compact     # minimal whitespace
pak convert file.c --style expanded    # generous whitespace (default)
pak convert file.c --no-idioms         # skip idiom detection, literal translation
pak convert file.c --preserve-names    # don't strip prefixes or rename
pak convert file.c --preserve-comments # keep all C comments
pak convert file.c --decomp            # enable decomp-specific patterns
```

## 6.6 — Milestone Test

Take a medium-sized C file (~200 lines) and verify:
- Output is properly formatted with consistent indentation.
- Comments are preserved in the right locations.
- Enum prefix stripping produces clean names.
- Method detection produces clean impl blocks.
- Transpiler annotations appear only where needed (not on every line).
- A human developer rates the output as "I'd be comfortable maintaining this."
