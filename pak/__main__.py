"""Pak CLI entry point — delegates to tclsh tcl/cli.tcl.

The c2pak/convert subcommand is Python-only (depends on pycparser) and
falls back to the Python CLI. All other subcommands go to Tcl.
"""
import subprocess
import sys
from pathlib import Path

_TCL_CLI = Path(__file__).resolve().parent.parent / "tcl" / "cli.tcl"


def main():
    args = sys.argv[1:]
    if args and args[0] == "convert":
        from pak.cli import main as _py_main
        _py_main()
        return
    result = subprocess.run(["tclsh", str(_TCL_CLI)] + args)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
