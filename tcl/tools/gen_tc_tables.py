#!/usr/bin/env python3
"""Generate tcl/tc_tables.tcl from pak.typechecker's static data.

Mirrors the typechecker's constant tables into Tcl from their *resolved* runtime
values (MODULE_NAMESPACES is derived from codegen.MODULE_NAMES), so the Tcl
typechecker can never drift from the Python oracle — same approach as
gen_schema.py / gen_check_tables.py.

Emits set-membership dicts:
    ::pak::MODULE_NAMESPACES   module/namespace names that aren't variables
    ::pak::DMA_SAFE_ANNS       annotations implying 16-byte alignment
    ::pak::DMA_FNS             ("mod fn") libdragon DMA/cache functions
    ::pak::ALLOC_CALLS         ("mod fn") heap-allocating calls @no_alloc forbids
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from pak.typechecker import (  # noqa: E402
    MODULE_NAMESPACES,
    DMA_SAFE_ANNS,
    DMA_FNS,
    TypeChecker,
)


def set_dict(name, values):
    out = [f"set ::pak::{name} [dict create \\"]
    for v in sorted(values):
        out.append(f"    {{{v}}} 1 \\")
    out.append("]")
    return out


def pair_dict(name, pairs):
    out = [f"set ::pak::{name} [dict create \\"]
    for mod, fn in sorted(pairs):
        out.append(f"    {{{mod} {fn}}} 1 \\")
    out.append("]")
    return out


lines = [
    "# GENERATED from pak/typechecker.py by tcl/tools/gen_tc_tables.py — DO NOT EDIT.",
    "# Regenerate: python3 tcl/tools/gen_tc_tables.py",
    "namespace eval pak {}",
    "# Include guard (reachable via multiple consumers; see ast.tcl).",
    "if {[info exists ::pak::_tc_tables_loaded]} { return }",
    "set ::pak::_tc_tables_loaded 1",
    "",
]
lines += set_dict("MODULE_NAMESPACES", MODULE_NAMESPACES)
lines.append("")
lines += set_dict("DMA_SAFE_ANNS", DMA_SAFE_ANNS)
lines.append("")
lines += pair_dict("DMA_FNS", DMA_FNS)
lines.append("")
lines += pair_dict("ALLOC_CALLS", TypeChecker._ALLOC_CALLS)

dest = REPO / "tcl" / "tc_tables.tcl"
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(
    f"wrote {dest} ({len(MODULE_NAMESPACES)} namespaces, "
    f"{len(DMA_FNS)} dma fns, {len(TypeChecker._ALLOC_CALLS)} alloc calls)"
)
