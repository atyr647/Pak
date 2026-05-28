#!/usr/bin/env python3
"""Generate tcl/check_tables.tcl from pak.checker's static data.

The checker validates `use` module names, N64 API call arity, and @cfg feature
names against three tables. Those tables are derived in Python (one of them from
codegen.MODULE_NAMES), so generating the Tcl mirror from the *resolved* runtime
values means the Tcl checker can never drift from the Python oracle — exactly
like tcl/ast_schema.tcl mirrors the AST dataclasses.

Emits:
    ::pak::KNOWN_MODULES   dict  (name -> 1)          set membership
    ::pak::API_ARITY       dict  ("mod fn" -> "min max")  max "" = variadic
    ::pak::KNOWN_CFG       dict  (feature -> 1)
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from pak.checker import (  # noqa: E402
    _KNOWN_MODULES,
    _API_ARITY,
    _KNOWN_CFG_FEATURES,
)


def set_dict(name, values):
    out = [f"set ::pak::{name} [dict create \\"]
    for v in sorted(values):
        out.append(f"    {v} 1 \\")
    out.append("]")
    return out


def arity_dict():
    out = ["set ::pak::API_ARITY [dict create \\"]
    for (mod, fn), arity in sorted(_API_ARITY.items()):
        if arity is None:
            continue  # unchecked — absence means "skip", matching .get() -> None
        lo, hi = arity
        hi_s = "" if hi is None else hi  # "" marks variadic (no upper bound)
        out.append(f"    {{{mod} {fn}}} {{{lo} {hi_s}}} \\")
    out.append("]")
    return out


lines = [
    "# GENERATED from pak/checker.py by tcl/tools/gen_check_tables.py — DO NOT EDIT.",
    "# Regenerate: python3 tcl/tools/gen_check_tables.py",
    "namespace eval pak {}",
    "# Include guard (reachable via multiple consumers; see ast.tcl).",
    "if {[info exists ::pak::_check_tables_loaded]} { return }",
    "set ::pak::_check_tables_loaded 1",
    "",
]
lines += set_dict("KNOWN_MODULES", _KNOWN_MODULES)
lines.append("")
lines += arity_dict()
lines.append("")
lines += set_dict("KNOWN_CFG", _KNOWN_CFG_FEATURES)

dest = REPO / "tcl" / "check_tables.tcl"
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(
    f"wrote {dest} "
    f"({len(_KNOWN_MODULES)} modules, "
    f"{sum(1 for v in _API_ARITY.values() if v is not None)} arities, "
    f"{len(_KNOWN_CFG_FEATURES)} cfg features)"
)
