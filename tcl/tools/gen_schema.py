#!/usr/bin/env python3
"""Generate tcl/ast_schema.tcl from pak/ast.py dataclasses.

Each AST node becomes a struct::record definition whose members are the
dataclass fields (minus line/col, which the AST serializer ignores). This makes
the Tcl node schema a mechanical mirror of the Python AST — it cannot drift,
and the schema-validating pak::N constructor enforces it.

Alongside the record set we emit ::pak::FKIND — a per-field "wrap kind" derived
from the dataclass field type. It lets pak::N auto-wrap scalar field values so
the Tcl parser reads like the Python one (`name $x` instead of
`name [pak::Lit $x]`). Kinds:
    s  str    -> (lit $v)        b  bool  -> (bool $v)
    i  int    -> (lit $v)        f  float -> (fnum $v)
    L  list   -> (seq $v)        Ls list[str] -> (seq of lit)
    n  other  -> passthrough (value is already a tagged AST value / nil)
"""
import dataclasses
import sys
import typing
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
import pak.ast as A  # noqa: E402

SKIP = {"line", "col"}

# Fields whose runtime value diverges from the dataclass annotation, so the
# annotation-derived kind would be wrong. Keep this list tiny and explained.
#   LetDecl.mutable: parser stores `self.match(TT.MUT)` (a Token or None), which
#   serializes as the lexeme/nil — not a bool. Treat as passthrough.
KIND_OVERRIDE = {("LetDecl", "mutable"): "n"}


def kind_of(t) -> str:
    if t is str:
        return "s"
    if t is bool:
        return "b"
    if t is int:
        return "i"
    if t is float:
        return "f"
    if typing.get_origin(t) is list:
        args = typing.get_args(t)
        return "Ls" if (args and args[0] is str) else "L"
    return "n"


out = [
    "# GENERATED from pak/ast.py by tcl/tools/gen_schema.py — DO NOT EDIT.",
    "# Each AST node kind is a struct::record; members mirror the dataclass",
    "# fields (excluding line/col). Regenerate: python3 tcl/tools/gen_schema.py",
    "package require struct::record",
    "",
]
kinds_lines = ["set ::pak::FKIND [dict create \\"]
node_names = []
for name in sorted(dir(A)):
    obj = getattr(A, name)
    if isinstance(obj, type) and dataclasses.is_dataclass(obj):
        node_names.append(name)
        flds = [f for f in dataclasses.fields(obj) if f.name not in SKIP]
        out.append(f"struct::record define {name} {{{' '.join(f.name for f in flds)}}}")
        pairs = " ".join(
            f"{f.name} {KIND_OVERRIDE.get((name, f.name), kind_of(f.type))}"
            for f in flds
        )
        kinds_lines.append(f"    {name} {{{pairs}}} \\")
kinds_lines.append("]")

out.append("")
out.append("# Per-field wrap kinds consumed by pak::N (see header).")
out.append("namespace eval pak {}")
out.extend(kinds_lines)

dest = REPO / "tcl" / "ast_schema.tcl"
dest.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"wrote {dest} ({len(node_names)} node kinds)")
