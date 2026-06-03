# C-to-PAK Transpiler Plan

## Goal

Enable existing C projects — especially N64 homebrew and decompilation projects — to be
converted into idiomatic PAK source code. Today if you want to use PAK, you start from
scratch. This transpiler lets you bring existing C codebases into the PAK ecosystem:

```
C source (.c/.h) → C parser → C AST → PAK AST → PAK source (.pk64)
```

### What This Unlocks

- **Decomp imports**: N64 decompilation projects (SM64, OoT, MM, DK64, etc.) can be
  converted to PAK, gaining PAK's type system, fixed-point types, variants, and direct
  MIPS backend.
- **Library porting**: Existing C libraries (libdragon utilities, audio engines, math libs)
  can become native PAK modules.
- **Incremental adoption**: Convert file-by-file rather than rewriting from scratch.

## Methodology

Same approach as the PAK-to-MIPS transpiler — **differential testing**:

1. Take a known C project that compiles and runs correctly.
2. Transpile C → PAK via the new tool.
3. Compile the resulting PAK via the existing pipeline (PAK → MIPS).
4. Compare behavior: run both binaries, diff output, diff memory state.
5. When they diverge, fix the transpiler. Repeat.
6. Graduate when real-world decomp files transpile and compile cleanly.

### Key Difference from PAK-to-MIPS

The PAK-to-MIPS transpiler was a **backend** (AST → machine code). This is a **frontend**
(foreign source → AST). The output is human-readable `.pk64` files, not assembly:

- **Readability matters**: Output should look like code a human would write. Variable names
  preserved, comments preserved, idioms translated (e.g., `if (ptr != NULL)` → `if ptr != none`).
- **Lossy is OK**: We don't need to round-trip. Preprocessor macros, `#ifdef` guards, and
  other C-isms are resolved/expanded during transpilation.
- **Human review expected**: The transpiler gets you 90%+ of the way; a human cleans up the rest.

---

## Phase Index

| Phase | Name | Description | File |
|-------|------|-------------|------|
| **0** | Scaffolding & Infrastructure | Module structure, C parser selection, test harness, CLI | [phase-0-scaffolding.md](phase-0-scaffolding.md) |
| **1** | Core Type & Declaration Mapping | Primitive types, structs, enums, unions, typedefs, function signatures | [phase-1-types-and-declarations.md](phase-1-types-and-declarations.md) |
| **2** | Expression & Statement Transpilation | Arithmetic, pointers, control flow, assignments, casts | [phase-2-expressions-and-statements.md](phase-2-expressions-and-statements.md) |
| **3** | Idiom Detection & PAK-ification | Tagged unions → variants, method detection → impl blocks, fixed-point, error patterns → Result | [phase-3-idiom-detection.md](phase-3-idiom-detection.md) |
| **4** | Preprocessor & Multi-File Support | `#define` → const, `#include` resolution, header-to-module conversion, multi-file projects | [phase-4-preprocessor-and-multifile.md](phase-4-preprocessor-and-multifile.md) |
| **5** | N64 & Decomp Specialization | libdragon API mapping, N64 hardware patterns, decomp-specific idioms, GCC extensions | [phase-5-n64-and-decomp.md](phase-5-n64-and-decomp.md) |
| **6** | Output Quality & Polish | Pretty-printer tuning, comment preservation, naming conventions, `--style` options | [phase-6-output-quality.md](phase-6-output-quality.md) |
| **7** | Graduation & Real-World Validation | Full decomp file conversion, community testing, graduation criteria | [phase-7-graduation.md](phase-7-graduation.md) |

---

## Execution Order

```
Phase 0  [Scaffolding]       ░░░░░░░░░░  — Module structure, parser, test harness, CLI
Phase 1  [Types & Decls]     ░░░░░░░░░░  — Primitives, structs, enums, unions, typedefs, fn sigs
Phase 2  [Exprs & Stmts]     ░░░░░░░░░░  — Arithmetic, pointers, control flow, assignments
Phase 3  [Idiom Detection]   ░░░░░░░░░░  — Tagged unions→variants, methods→impl, fixed-point
Phase 4  [Preprocessor]      ░░░░░░░░░░  — #define→const, #include→use, multi-file projects
Phase 5  [N64 & Decomp]      ░░░░░░░░░░  — libdragon APIs, decomp patterns, GCC extensions
Phase 6  [Output Quality]    ░░░░░░░░░░  — Pretty-printing, comments, naming, style options
Phase 7  [Graduation]        ░░░░░░░░░░  — Real-world decomp validation, community testing
```

Phase 3 (idiom detection) is not purely sequential — it grows alongside Phases 1-2 as we
discover more patterns. Phase 6 (output quality) is similarly ongoing from Phase 1 onward.

## Architecture Overview

```
pak/c2pak/
├── __init__.py
├── c_parser.py          # C lexer + parser (pycparser wrapper, later tree-sitter)
├── c_ast.py             # Normalized C AST representation
├── c_preprocess.py      # Minimal preprocessor (#define, #include resolution)
├── type_mapper.py       # C types → PAK types
├── expr_mapper.py       # C expressions → PAK AST nodes
├── stmt_mapper.py       # C statements → PAK AST nodes
├── decl_mapper.py       # C declarations → PAK declarations
├── idiom_detector.py    # Pattern-match C idioms → idiomatic PAK
├── pak_emitter.py       # PAK AST → formatted .pk64 source text
└── cli.py               # CLI: pak convert <file.c> [--output file.pk64]
```
