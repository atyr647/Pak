# Tcl Port Status

The Tcl implementation under `tcl/` is a byte-exact port of the Python
reference compiler under `pak/`. Parity is enforced by per-stage harnesses in
`tcl/tools/` (each compares the Tcl output against the Python "oracle"); the
gate is **zero MISMATCH**.

## Parity gates (all green)

| Stage | Tcl source | Harness | Status |
|-------|-----------|---------|--------|
| Lexer | `lexer.tcl` | `lex_parity.sh` | PASS 61 |
| Parser (AST) | `parser.tcl` | `ast_parity.sh` | MATCH 61 |
| Typechecker | `typechecker.tcl` | `tc_parity.sh` | MATCH 80 |
| Checker | `checker.tcl` | `check_parity.sh` | MATCH 71 |
| C codegen | `codegen.tcl` | `cg_parity.sh` | MATCH 22 canonical / 43 corpus |
| MIPS codegen | `mips_codegen.tcl` | `mips_parity.sh` | MATCH 22 canonical / 18 corpus |
| MIPS optimizer | `optimize.tcl` | `opt_parity.sh` | MATCH 22 |
| Header generator | `headergen.tcl` | `header_dump.{tcl,py}` | MATCH |
| Makefile generator | `makefile_gen.tcl` | `makefile_parity.sh` | MATCH (4 scenarios) |
| PakFS archive | `pakfs.tcl` | `pakfs_parity.sh` | MATCH (3 scenarios) |
| CLI driver | `cli.tcl` | `cli_parity.sh` | MATCH (12 surfaces) |
| C→Pak transpiler | `c2pak.tcl`, `c2pak/` | `c2pak_parity.sh` | MATCH 8 |

Every Python module in the toolchain has a parity-verified Tcl port.
`c2pak` parity uses the Python transpiler (which wraps `pycparser`) as its
oracle; the Tcl side has its own C front-end and matches the final `.pak`
text byte-for-byte on the corpus.

## Known boundary: source positions

The Tcl AST schema is generated **without `line`/`col` fields** (see the
header in `tcl/ast_schema.tcl`: "structural parity first; position parity
validated separately later"). Consequently the parser/typechecker/checker
gates compare structure and diagnostics but not source positions, and the
`pak check` CLI command matches Python on diagnostic **text and codes** but
emits `:0:0` for the `--> file:line:col` location line. Threading real
positions through the lexer → every parser node → the diagnostic sites is a
separate cross-cutting change that the existing harnesses intentionally
exclude; it is the one remaining deferred item.
