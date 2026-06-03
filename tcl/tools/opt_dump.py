#!/usr/bin/env python3
"""Emit the Python MIPS backend's OPTIMIZED assembly for a .pk64 file.

Oracle for the Tcl optimizer port: MipsCodegen(optimize=True) runs the same
unoptimized codegen and then optimize_asm() (peephole, VR4300 scheduling,
delay-slot filling, dead-label elimination), matching opt_dump.tcl.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from pak.parser import parse                       # noqa: E402
from pak.mips.mips_codegen import MipsCodegen       # noqa: E402


def main() -> None:
    path = sys.argv[1]
    src = Path(path).read_text()
    prog = parse(src)
    cg = MipsCodegen(bounds_check=True, optimize=True)
    sys.stdout.write(cg.generate(prog))


if __name__ == '__main__':
    main()
