# Phase 0: Scaffolding & Infrastructure

## 0.1 — C Frontend Module Structure

Create `pak/c2pak/` with these modules:

| Module | Responsibility |
|--------|---------------|
| `c_parser.py` | C lexer + parser (or wrapper around pycparser/tree-sitter) |
| `c_ast.py` | Normalized C AST representation (simplified from full C AST) |
| `c_preprocess.py` | Minimal preprocessor: expand `#define` constants, resolve `#include` for type info, strip `#ifdef` |
| `type_mapper.py` | Map C types → PAK types (`int` → `i32`, `unsigned char` → `u8`, `float` → `f32`, etc.) |
| `expr_mapper.py` | Map C expressions → PAK AST expression nodes |
| `stmt_mapper.py` | Map C statements → PAK AST statement nodes |
| `decl_mapper.py` | Map C declarations (structs, enums, unions, functions, typedefs) → PAK declarations |
| `idiom_detector.py` | Pattern-match C idioms and emit idiomatic PAK (tagged unions, Result types, fixed-point) |
| `pak_emitter.py` | PAK AST → formatted `.pk64` source text (pretty-printer) |
| `cli.py` | CLI entry point: `pak convert <file.c> [--output file.pk64]` |

## 0.2 — C Parser Strategy

Two viable approaches, used in sequence:

### Option A: pycparser (Phases 0-3)

- Mature, pure-Python C99 parser with well-documented AST.
- Handles most decomp C (C89/C99).
- Limitation: requires preprocessing — use `gcc -E` or bundled fake headers.
- Install: `pip install pycparser`
- pycparser produces `c_ast.FileAST` with node types like `Decl`, `FuncDef`, `Struct`,
  `Enum`, `TypeDecl`, `BinaryOp`, `UnaryOp`, `If`, `While`, `For`, `Switch`, etc.

### Option B: tree-sitter-c (Phase 4+)

- Incremental, error-tolerant parser. Handles malformed/partial C.
- Better for decomp code with non-standard extensions (`__attribute__`, inline asm, GCC builtins).
- Can parse without preprocessing (tolerates unknown macros).
- Install: `pip install tree-sitter tree-sitter-c`

**Strategy**: Start with pycparser for clean C. Add tree-sitter when hitting real decomp code
with GCC extensions, `__attribute__`, asm blocks, etc. The normalized `c_ast.py` abstracts
over whichever parser is active.

## 0.3 — Normalized C AST

To decouple from the parser library, define a simplified intermediate C AST in `c_ast.py`:

```python
@dataclass
class CType:
    """Base for all C type representations."""

@dataclass
class CPrimitive(CType):
    name: str  # "int", "float", "unsigned char", etc.

@dataclass
class CPointer(CType):
    inner: CType
    is_const: bool = False

@dataclass
class CArray(CType):
    inner: CType
    size: Optional[int] = None  # None = flexible array member

@dataclass
class CStruct(CType):
    name: Optional[str]
    fields: List['CField']

@dataclass
class CUnion(CType):
    name: Optional[str]
    fields: List['CField']

@dataclass
class CEnum(CType):
    name: Optional[str]
    values: List[Tuple[str, Optional[int]]]

@dataclass
class CFuncPtr(CType):
    ret: CType
    params: List[CType]
```

This normalized AST is what `type_mapper.py`, `expr_mapper.py`, etc. consume.

## 0.4 — Test Harness

Build a comparison framework:

```
tests/c2pak/
├── inputs/          # .c source files
│   ├── basic_types.c
│   ├── structs.c
│   ├── enums.c
│   ├── control_flow.c
│   └── ...
├── expected/        # expected .pk64 output
│   ├── basic_types.pk64
│   ├── structs.pk64
│   └── ...
└── test_c2pak.py    # pytest runner
```

Test modes:
- **Syntax check**: transpiled PAK parses without errors (use existing PAK parser).
- **Semantic check**: transpiled PAK type-checks without errors.
- **Behavioral check**: compile both C and transpiled PAK → compare runtime output.
- **Snapshot check**: transpiled PAK matches expected `.pk64` file exactly.

## 0.5 — CLI Integration

Add a `convert` subcommand to the existing PAK CLI:

```
pak convert path/to/file.c                    # prints .pk64 to stdout
pak convert path/to/file.c -o output.pk64      # writes to file
pak convert path/to/project/ -o output_dir/   # batch convert directory
pak convert file.c --preserve-comments        # keep C comments
pak convert file.c --no-idioms                # skip idiom detection (literal translation)
pak convert file.c --decomp                   # enable decomp-specific patterns
```

## 0.6 — Milestone

- `pak convert` CLI accepts a trivial C file and produces syntactically valid (but possibly
  empty/stubbed) PAK output.
- Test harness runs and reports PASS/FAIL.
- pycparser integrated and parsing real C files.
