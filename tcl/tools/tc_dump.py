#!/usr/bin/env python3
"""Serialize the Python typechecker's diagnostics to a canonical form for parity.

For each .pk64 file: parse, run typecheck (style warnings ON, the default), and
print one line per diagnostic in accumulation order (errors and warnings
interleaved, exactly as TypeChecker.check returns them):

    (CODE SEVERITY "message" "hint")

The diagnostic's own line/col are omitted (the Tcl AST tracks no positions yet);
no typechecker message embeds a source line, so nothing else needs normalizing.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.parser import parse, ParseError  # noqa: E402
from pak.lexer import LexError  # noqa: E402
from pak.typechecker import typecheck  # noqa: E402


def esc(s: str) -> str:
    return ('"' + s.replace("\\", "\\\\").replace('"', '\\"')
                   .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"')


def main() -> None:
    path = sys.argv[1]
    src = Path(path).read_text(encoding="utf-8")
    try:
        prog = parse(src, path)
    except (ParseError, LexError) as e:
        line = getattr(getattr(e, "token", None), "line", getattr(e, "line", 0))
        col = getattr(getattr(e, "token", None), "col", getattr(e, "col", 0))
        print(f"PARSEERROR\t{line}\t{col}")
        return
    for d in typecheck(prog, filename=path):
        print(f"({d.code} {d.severity} {esc(d.message)} {esc(d.hint)})")


if __name__ == "__main__":
    main()
