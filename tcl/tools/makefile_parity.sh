#!/usr/bin/env bash
# Compare Tcl makefile_gen against the Python oracle over representative
# scenarios. Gate: byte-identical.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.."
if diff <(python3 "$HERE/makefile_dump.py") <(tclsh "$HERE/makefile_dump.tcl") >/dev/null; then
    echo "makefile_gen parity: MATCH (4 scenarios)"; exit 0
else
    echo "makefile_gen parity: MISMATCH"; diff <(python3 "$HERE/makefile_dump.py") <(tclsh "$HERE/makefile_dump.tcl") | head -40; exit 1
fi
