#!/usr/bin/env bash
# Compare the Tcl typechecker's diagnostics against the Python typechecker
# (oracle) on every .pk64 file, plus the fixtures in tcl/tests that exercise the
# individual diagnostic codes. A file "matches" when both emit identical
# diagnostics (code + severity + message + hint) in the same accumulation order.
#
# Unlike the checker, no typechecker message embeds a source line, so no
# normalization is needed — output is compared verbatim.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

match=0; unported=0; mismatch=0; mism_files=""
while IFS= read -r f; do
    py="$(python3 "$HERE/tc_dump.py" "$f" 2>/dev/null)"
    tcl="$(tclsh "$HERE/tc_dump.tcl" "$f" 2>/dev/null)"
    if [ "$py" = "$tcl" ]; then
        match=$((match+1))
    elif printf '%s' "$tcl" | grep -q '^PARSEERROR\|^ERROR'; then
        unported=$((unported+1))
        [ "${SHOW_UNPORTED:-0}" = "1" ] && echo "UNPORTED: $f -> $tcl"
    else
        mismatch=$((mismatch+1))
        mism_files="$mism_files $f"
        if [ "${VERBOSE:-0}" = "1" ]; then
            echo "=== MISMATCH: $f ==="
            diff <(printf '%s' "$py") <(printf '%s' "$tcl") | head -25
        fi
    fi
done < <( { find examples ai tests -name '*.pk64'; find tcl/tests -name '*.pk64'; } | sort )

total=$((match+unported+mismatch))
echo "typechecker parity: MATCH=$match  UNPORTED=$unported  MISMATCH=$mismatch  (of $total)"
[ -n "$mism_files" ] && echo -e "MISMATCHED:\n$(echo $mism_files | tr ' ' '\n')"
[ "$mismatch" -eq 0 ]
