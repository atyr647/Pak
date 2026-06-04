#!/usr/bin/env python3
"""Emit MIPS assembly for a .pk64 file via the Tcl MIPS backend.

The Python MIPS backend has been deprecated; this shim delegates to
tclsh tcl/cli.tcl mips <file> so existing tooling continues to work.
"""
import sys
import subprocess
from pathlib import Path

TCL_CLI = Path(__file__).resolve().parents[2] / 'tcl' / 'cli.tcl'


def main() -> None:
    path = sys.argv[1]
    result = subprocess.run(
        ['tclsh', str(TCL_CLI), 'mips', path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"ERROR\t{result.stderr.strip()}")
    else:
        sys.stdout.write(result.stdout)


if __name__ == '__main__':
    main()
