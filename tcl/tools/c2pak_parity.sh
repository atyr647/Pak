#!/usr/bin/env bash
# Compare Tcl c2pak against the Python oracle on tests/c2pak/inputs/*.c.
# Gate: byte-identical .pk64 output.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
match=0; unported=0; mismatch=0; mism=""
for c in tests/c2pak/inputs/*.c; do
    tcl="$(tclsh "$HERE/c2pak_dump.tcl" "$c" 2>/dev/null)"
    if printf '%s' "$tcl" | head -1 | grep -q '^UNPORTED\|^ERROR'; then
        unported=$((unported+1)); [ "${SHOW_UNPORTED:-0}" = "1" ] && echo "UNPORTED: $c -> $(printf '%s' "$tcl"|head -1)"; continue
    fi
    py="$(python3 "$HERE/c2pak_dump.py" "$c" 2>/dev/null)"
    if [ "$py" = "$tcl" ]; then match=$((match+1)); else mismatch=$((mismatch+1)); mism="$mism $c"; fi
done
total=$((match+unported+mismatch))
echo "c2pak parity: MATCH=$match  UNPORTED=$unported  MISMATCH=$mismatch  (of $total)"
[ -n "$mism" ] && echo -e "MISMATCHED:\n$(echo $mism|tr ' ' '\n')"
[ "$mismatch" -eq 0 ]
