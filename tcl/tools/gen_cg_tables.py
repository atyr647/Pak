#!/usr/bin/env python3
"""Generate tcl/cg_tables.tcl from pak.codegen's static data.

Mirrors the codegen lookup tables into Tcl from their resolved runtime values so
the Tcl codegen can never drift from the Python oracle (same approach as the
other gen_*.py mirrors). Only the *string-valued* MODULE_API entries are emitted
as data; the callable (lambda) entries encode lowering logic and are hand-ported
in tcl/codegen.tcl (pak::cg_api_lambda). The set of lambda keys is emitted too,
so the Tcl side can tell "needs a lambda I haven't ported yet" (→ raise/UNPORTED)
apart from "genuinely unknown module call".

Emits:
    ::pak::CG_API           dict ("mod fn" -> c_fn_string)  string entries only
    ::pak::CG_API_LAMBDA    dict ("mod fn" -> 1)            keys needing a lambda
    ::pak::CG_USE_INCLUDES  dict (use_path -> include text)
    ::pak::CG_PRIM          dict (pak_type -> c_type)
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from pak.codegen import MODULE_API, USE_INCLUDES, PRIMITIVE_TYPES  # noqa: E402
from pak.codegen import Codegen  # noqa: E402


def tcl_dict(name, items):
    out = [f"set ::pak::{name} [dict create \\"]
    for k, v in items:
        out.append(f"    {{{k}}} {{{v}}} \\")
    out.append("]")
    return out


api_str = []
api_lam = []
for (mod, fn), v in sorted(MODULE_API.items()):
    if callable(v):
        api_lam.append((f"{mod} {fn}", "1"))
    else:
        api_str.append((f"{mod} {fn}", v))

lines = [
    "# GENERATED from pak/codegen.py by tcl/tools/gen_cg_tables.py — DO NOT EDIT.",
    "# Regenerate: python3 tcl/tools/gen_cg_tables.py",
    "namespace eval pak {}",
    "# Include guard (reachable via multiple consumers; see ast.tcl).",
    "if {[info exists ::pak::_cg_tables_loaded]} { return }",
    "set ::pak::_cg_tables_loaded 1",
    "",
]
lines += tcl_dict("CG_API", api_str)
lines.append("")
lines += tcl_dict("CG_API_LAMBDA", api_lam)
lines.append("")
lines += tcl_dict("CG_USE_INCLUDES", sorted(USE_INCLUDES.items()))
lines.append("")
lines += tcl_dict("CG_PRIM", sorted(PRIMITIVE_TYPES.items()))
lines.append("")
lines += tcl_dict("CG_FMT_SPEC", sorted(Codegen._FMT_SPEC.items()))

dest = REPO / "tcl" / "cg_tables.tcl"
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(
    f"wrote {dest} ({len(api_str)} api strings, {len(api_lam)} api lambdas, "
    f"{len(USE_INCLUDES)} includes, {len(PRIMITIVE_TYPES)} primitives, "
    f"{len(Codegen._FMT_SPEC)} fmt specs)"
)
