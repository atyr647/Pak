#!/usr/bin/env python3
"""Emit the Python MIPS backend's UNOPTIMIZED assembly for a .pak file.

Calls MipsCodegen(optimize=False) directly (not the CLI, which forces
optimize=True) so the Tcl port can target unoptimized output first — the
instruction-scheduling optimizer is a separate, later concern.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pak.parser import parse, ParseError  # noqa: E402
from pak.lexer import LexError  # noqa: E402
from pak.mips import MipsCodegen, CodegenError  # noqa: E402


def main() -> None:
    path = sys.argv[1]
    src = Path(path).read_text(encoding="utf-8")
    try:
        prog = parse(src, path)
    except (ParseError, LexError):
        print("PARSEERROR")
        return
    try:
        cg = MipsCodegen(bounds_check=True, optimize=False)
        sys.stdout.write(cg.generate(prog))
    except CodegenError as e:
        print(f"CODEGENERROR\t{e}")


if __name__ == "__main__":
    main()
