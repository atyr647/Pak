#!/usr/bin/env python3
"""Generate tcl/mips_tables.tcl from pak.mips's static data.

Mirrors the MIPS backend's runtime symbol table into Tcl from resolved runtime
values, so the Tcl MIPS backend can't drift from the Python oracle (same
approach as the other gen_*.py mirrors).

Emits:
    ::pak::MIPS_EXTERNS   ordered, deduped list of .extern symbols (string syms
                          from N64_RUNTIME_API, in insertion order, + the fixed
                          runtime helpers _emit_externs appends)
    ::pak::MIPS_API       dict ("mod fn" -> sym) for module-call lowering; the
                          value is the libdragon symbol, or "" when the entry's
                          sym is a callable (the backend then jal's `mod_fn`).
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from pak.mips.n64_runtime import N64_RUNTIME_API  # noqa: E402

# Reproduce _emit_externs ordering exactly: iterate values, take string syms in
# first-seen order, then append the fixed helper list.
externs = []
seen = set()
for entry in N64_RUNTIME_API.values():
    sym = entry.get("sym")
    if isinstance(sym, str) and sym not in seen:
        externs.append(sym)
        seen.add(sym)
for helper in ("__pak_fix16_div", "__pak_alloc", "__pak_free",
               "__pak_panic", "memcpy", "memset"):
    externs.append(helper)

# Module-call lookup: every (mod, fn) key, value = string sym or "" for callable.
api = []
for (mod, fn), entry in N64_RUNTIME_API.items():
    sym = entry.get("sym")
    api.append((f"{mod} {fn}", sym if isinstance(sym, str) else ""))

lines = [
    "# GENERATED from pak/mips/n64_runtime.py by tcl/tools/gen_mips_tables.py — DO NOT EDIT.",
    "# Regenerate: python3 tcl/tools/gen_mips_tables.py",
    "namespace eval pak {}",
    "if {[info exists ::pak::_mips_tables_loaded]} { return }",
    "set ::pak::_mips_tables_loaded 1",
    "",
    "set ::pak::MIPS_EXTERNS [list \\",
]
for s in externs:
    lines.append(f"    {s} \\")
lines.append("]")
lines.append("")
lines.append("set ::pak::MIPS_API [dict create \\")
for key, sym in api:
    lines.append(f"    {{{key}}} {{{sym}}} \\")
lines.append("]")

dest = REPO / "tcl" / "mips_tables.tcl"
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {dest} ({len(externs)} externs, {len(api)} api entries)")
