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
| Record optimizer + encoded exec | `optimize.tcl` | `tcl/tools/enc_exec_test.tcl` | call/MMIO goldens |
| Array / sret / CStr / Result / generic / variant match | `mips_codegen.tcl` | `tcl/tools/array_addr_test.tcl` | mono queued after caller; variant by-addr |
| RDP stream (key/convert/scaled-texrect) | `runtime.pk64` | `tcl/tools/rdp_test.tcl` | 304 words unopt=opt |
| Exception paint + crt0 vectors | `boot.S`, `runtime.pk64` | `tcl/tools/exception_test.tcl` | red-screen + 4 MiB ROM |
| Audio PCM (AI) | `runtime.pk64` | `tcl/tools/audio_test.tcl` | DACRATE/LEN/kick |
| Linker + ROM packer | `n64link.tcl`, `n64rom.tcl` | `tcl/tools/n64link_test.tcl` | 44 assertions |

Token and AST dumps run to megabytes across the corpus, so those stages are
gated by hash; diagnostics are stored in full because they are worth reading in
a diff. Human-readable per-example C and MIPS also live in `tests/snapshots/`.

The `mips` stage is a self-snapshot: the Python MIPS backend was retired before
that port finished, so its goldens pin the current output rather than comparing
against an oracle. Every valid file in the corpus now lowers to assembly; the
only `UNPORTED` markers left are the 43 deliberately-invalid snippets, which
fail to parse. A construct the backend cannot lower would show up here as a
golden change rather than slipping through unnoticed.

## Source positions

Nodes carry their position out of band, as a fourth element of the node value
(`{node Kind {fields...} {line col}}`), rather than as schema fields. The
parser brackets three rule levels -- `parse_top_level`, `parse_stmt` and
`parse_primary` -- with the position of the token they start on, and `pak::N`
stamps whatever is innermost, so every node gets the start of the construct it
belongs to rather than wherever the parse happened to end.

Keeping it out of the field dict means the schema, `pak::nfield` and the AST
dump format are untouched: a node's structure is exactly what it was, and the
`ast` goldens did not move when positions were added. Nodes synthesized outside
parsing (by the checker, typechecker or codegen) get `{0 0}`, which the CLI
renders as no location rather than a wrong one.
