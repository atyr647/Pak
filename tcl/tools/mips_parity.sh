#!/usr/bin/env bash
# Compare the Tcl MIPS backend's assembly against the Python backend (oracle)
# on the canonical examples. A file MATCHES when the unoptimized assembly is
# byte-identical. Files the Tcl backend can't yet lower print an UNPORTED marker
# and are counted separately — never as a content mismatch.
#
# Oracle: pak.mips.MipsCodegen(optimize=False), via tcl/tools/mips_dump.py.
# The MIPS port is early and incremental, so most files are expected UNPORTED;
# the gate is "zero MISMATCH" — already-lowered files must stay byte-exact.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

match=0; unported=0; mismatch=0; mism_files=""
while IFS= read -r f; do
    tcl="$(tclsh "$HERE/mips_dump.tcl" "$f" 2>/dev/null)"
    if printf '%s' "$tcl" | head -1 | grep -q '^UNPORTED\|^ERROR'; then
        unported=$((unported+1))
        [ "${SHOW_UNPORTED:-0}" = "1" ] && echo "UNPORTED: $f -> $(printf '%s' "$tcl" | head -1)"
        continue
    fi
    py="$(python3 "$HERE/mips_dump.py" "$f" 2>/dev/null)"
    if [ "$py" = "$tcl" ]; then
        match=$((match+1))
    else
        mismatch=$((mismatch+1))
        mism_files="$mism_files $f"
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "=== MISMATCH: $f ==="
            diff <(printf '%s' "$py") <(printf '%s' "$tcl") | head -40
        fi
    fi
done < <(find examples/canonical -name '*.pk64' | sort)

total=$((match+unported+mismatch))
echo "mips parity: MATCH=$match  UNPORTED=$unported  MISMATCH=$mismatch  (of $total canonical)"
[ -n "$mism_files" ] && echo -e "MISMATCHED:\n$(echo $mism_files | tr ' ' '\n')"
[ "$mismatch" -eq 0 ]
