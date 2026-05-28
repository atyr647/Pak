#!/usr/bin/env python3
"""Serialize the Python parser's AST to a canonical S-expression for parity.

Form:
  node     -> (ClassName (field VALUE) (field VALUE) ...)   fields sorted by name
  list     -> [ VALUE VALUE ... ]
  None     -> nil
  bool     -> #t / #f
  str      -> "escaped"
  int/float-> "escaped"  (serialized as their str(), quoted, so the Tcl side can
              match the raw lexeme without numeric-normalization surprises)

Position fields (line, col) are omitted: structural parity first; position
parity is validated separately later.
"""
import dataclasses
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.parser import parse  # noqa: E402
from pak.parser import ParseError  # noqa: E402
from pak.lexer import LexError, Token  # noqa: E402

SKIP = {"line", "col"}


def esc(s: str) -> str:
    return ('"' + s.replace("\\", "\\\\").replace('"', '\\"')
                   .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"')


def ser(node) -> str:
    if node is None:
        return "nil"
    if isinstance(node, bool):
        return "#t" if node else "#f"
    if isinstance(node, Token):
        # Token-valued fields (e.g. LetDecl.mutable) normalize to the lexeme,
        # since a Token's repr carries positions the Tcl port can't reproduce.
        return esc(node.value)
    if isinstance(node, float):
        # %.17g is byte-identical between Python and Tcl (both use C printf).
        return esc(f"{node:.17g}")
    if dataclasses.is_dataclass(node):
        name = type(node).__name__
        parts = []
        for f in sorted(dataclasses.fields(node), key=lambda f: f.name):
            if f.name in SKIP:
                continue
            parts.append(f"({f.name} {ser(getattr(node, f.name))})")
        return f"({name} " + " ".join(parts) + ")"
    if isinstance(node, (list, tuple)):
        return "[ " + " ".join(ser(x) for x in node) + " ]"
    # scalar leaf (str, int, enum, ...) — serialize via str(), quoted
    return esc(str(node))


def main() -> None:
    path = sys.argv[1]
    src = Path(path).read_text(encoding="utf-8")
    try:
        prog = parse(src, path)
    except (ParseError, LexError) as e:
        print(f"PARSEERROR\t{e}")
        return
    print(ser(prog))


if __name__ == "__main__":
    main()
