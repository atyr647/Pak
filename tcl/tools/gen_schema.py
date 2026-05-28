#!/usr/bin/env python3
"""Generate tcl/ast_schema.tcl from pak/ast.py dataclasses.

Each AST node becomes a struct::record definition whose members are the
dataclass fields (minus line/col, which the AST serializer ignores). This makes
the Tcl node schema a mechanical mirror of the Python AST — it cannot drift,
and the schema-validating pak::N constructor enforces it.
"""
import dataclasses
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
import pak.ast as A  # noqa: E402

SKIP = {"line", "col"}
out = [
    "# GENERATED from pak/ast.py by tcl/tools/gen_schema.py — DO NOT EDIT.",
    "# Each AST node kind is a struct::record; members mirror the dataclass",
    "# fields (excluding line/col). Regenerate: python3 tcl/tools/gen_schema.py",
    "package require struct::record",
    "",
]
for name in sorted(dir(A)):
    obj = getattr(A, name)
    if isinstance(obj, type) and dataclasses.is_dataclass(obj):
        fields = [f.name for f in dataclasses.fields(obj) if f.name not in SKIP]
        out.append(f"struct::record define {name} {{{' '.join(fields)}}}")

dest = REPO / "tcl" / "ast_schema.tcl"
dest.write_text("\n".join(out) + "\n", encoding="utf-8")
n = sum(1 for line in out if line.startswith("struct::record"))
print(f"wrote {dest} ({n} node kinds)")
