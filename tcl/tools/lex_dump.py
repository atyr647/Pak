#!/usr/bin/env python3
"""Dump the Python lexer's tokens in a canonical line format for parity checks.

Format, one token per line:  TYPE \t LINE \t COL \t ESCAPED_VALUE
On a lex error:              LEXERROR \t LINE \t COL
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.lexer import Lexer, LexError  # noqa: E402


def escval(v: str) -> str:
    return (v.replace("\\", "\\\\")
             .replace("\n", "\\n")
             .replace("\t", "\\t")
             .replace("\r", "\\r"))


def main() -> None:
    path = sys.argv[1]
    src = Path(path).read_text(encoding="utf-8")
    try:
        toks = Lexer(src, path).tokenize()
    except LexError as e:
        print(f"LEXERROR\t{e.line}\t{e.col}")
        return
    out = []
    for t in toks:
        out.append(f"{t.type.name}\t{t.line}\t{t.col}\t{escval(t.value)}")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
