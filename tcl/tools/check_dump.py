#!/usr/bin/env python3
"""Serialize the Python checker's diagnostics to a canonical form for parity.

For each .pak file: parse, run semantic_check, and print one line per
diagnostic in walk order, errors first then warnings (mirroring the
(errors, warnings) split semantic_check returns):

    (CODE SEVERITY "message" "hint")

Source positions (the diagnostic's own line/col) are omitted — the Tcl AST
does not track positions yet, matching the parser-parity staging. The one
position-bearing text, E107's "first defined at line N" hint, is left intact
here and normalized in check_parity.sh so both sides compare equal.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.parser import parse, ParseError  # noqa: E402
from pak.lexer import LexError  # noqa: E402
from pak.checker import semantic_check  # noqa: E402


def esc(s: str) -> str:
    return ('"' + s.replace("\\", "\\\\").replace('"', '\\"')
                   .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"')


def ser(d) -> str:
    return f"({d.code} {d.severity} {esc(d.message)} {esc(d.hint)})"


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
    errors, warnings = semantic_check(prog, filename=path)
    for d in errors:
        print(ser(d))
    for d in warnings:
        print(ser(d))


if __name__ == "__main__":
    main()
