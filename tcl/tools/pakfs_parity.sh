#!/usr/bin/env bash
# Compare Tcl pakfs_pack against the Python oracle (hex) over representative
# scenarios (ascii/binary data, empty files, 16-byte alignment padding).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.."
if diff <(python3 "$HERE/pakfs_dump.py") <(tclsh "$HERE/pakfs_dump.tcl") >/dev/null; then
    echo "pakfs parity: MATCH (3 scenarios)"; exit 0
else
    echo "pakfs parity: MISMATCH"; exit 1
fi
