# Compiler Implementation Status

The compiler under `tcl/` is the implementation. It previously ran alongside a
Python reference under `pak/`, with per-stage harnesses comparing the two on
every push. That reference has been removed; its verified output is frozen in
`tests/golden/` and is now what the Tcl compiler is checked against.

## Regression gates (all green)

Run everything with `tclsh tcl/tools/golden_test.tcl`, or one stage at a time
by naming it. The corpus is every `.pk64` under `examples/`, `ai/`, `tests/`
and `tcl/tests/` — 588 files, including the 485 source snippets lifted out of
the old pytest suite into `tests/corpus/`.

| Stage | Source | Golden | Coverage |
|-------|--------|--------|----------|
| Lexer | `lexer.tcl` | `tests/golden/lex.sha256` | 588 |
| Parser (AST) | `parser.tcl` | `tests/golden/ast.sha256` | 588 |
| C codegen | `codegen.tcl` | `tests/golden/cg.sha256` | 588 |
| MIPS codegen | `mips_codegen.tcl` | `tests/golden/mips.sha256` | 588 |
| Checker | `checker.tcl` | `tests/golden/check/` | 588 |
| Typechecker | `typechecker.tcl` | `tests/golden/tc/` | 588 |
| Header generator | `headergen.tcl` | `tests/golden/header/` | 32 canonical |
| C→Pak transpiler | `c2pak.tcl` | `tests/golden/c2pak/` | 8 |
| Makefile generator | `makefile_gen.tcl` | `tests/golden/makefile.txt` | 4 scenarios |
| PakFS archive | `pakfs.tcl` | `tests/golden/pakfs.txt` | 3 scenarios |
| MIPS encoder | `n64enc.tcl` | `tcl/tools/n64enc_test.tcl` | 55 encodings |
| Linker + ROM packer | `n64link.tcl`, `n64rom.tcl` | `tcl/tools/n64link_test.tcl` | 44 assertions |

Token and AST dumps run to megabytes across the corpus, so those stages are
gated by hash; diagnostics are stored in full because they are worth reading in
a diff. Human-readable per-example C and MIPS also live in `tests/snapshots/`.

The `mips` stage is a self-snapshot: the Python MIPS backend was retired before
that port finished, so its goldens pin the current output *including* the
`UNPORTED` markers for constructs the backend cannot lower yet. Closing one of
those gaps therefore shows up as a deliberate golden change rather than slipping
through unnoticed.

## Known boundary: source positions

The AST schema carries no `line`/`col` fields (see the header in
`tcl/ast_schema.tcl`). Diagnostics therefore have the right text and codes but
report `:0:0` on the `--> file:line:col` location line, and E107's "first
defined at line N" hint is normalized in the golden comparison. Threading real
positions through the lexer, every parser node and each diagnostic site is a
cross-cutting change; it is the one remaining deferred item.
